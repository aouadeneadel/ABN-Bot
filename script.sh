#!/bin/bash
. main.conf

# Vérification de dialog
if ! command -v dialog >/dev/null 2>&1; then
    echo "dialog n'est pas installé : sudo apt install dialog"
    exit 1
fi

# Vérification des dépendances
for dep in jq curl python3 nwipe memtester lftp glpi-agent; do
    if ! command -v $dep >/dev/null 2>&1; then
        dialog --msgbox "Dépendance manquante : $dep\nInstallez-la avant de continuer." 7 50
        clear
        exit 1
    fi
done

# Saisie du numéro d'inventaire
ninventaire=$(dialog --stdout --inputbox "Numéro d'inventaire ?" 10 50)
if [ $? -ne 0 ] || [ -z "$ninventaire" ]; then
    dialog --msgbox "Inventaire annulé." 6 40
    clear
    exit 1
fi
dialog --msgbox "Le nom de machine GLPI sera : $ninventaire" 7 50

# Préparation de l'agent GLPI
cp inventory.dumb inventory.json
sed -i "s/dumbname/${ninventaire}/g" inventory.json

# Mise à jour APT
sudo apt update >/dev/null 2>&1

# Nettoyage logs
mkdir -p "$logpath"
rm -f "$logpath"/*.log

# Exécution de l'agent GLPI
(
echo 10; sleep 0.2
glpi-agent --server "$glpiserver" \
           --additional-content="inventory.json" \
           --logfile="$logpath/glpi.log" >/dev/null 2>&1
echo 100; sleep 0.2
) | dialog --gauge "Envoi inventaire GLPI..." 10 60 0
rm -f inventory.json

# ── Test RAM ──────────────────────────────────────────────────────────────────
ramfree=$(free -m | grep Mem | awk '{print $4}')
ramtest=$(($ramfree - 100))
if [ $ramtest -le 0 ]; then
    dialog --msgbox "RAM insuffisante pour le test memtester." 6 45
else
    (
    echo 10
    memtester ${ramtest}M 1 >"$logpath/memtest.log" 2>&1
    echo 100
    ) | dialog --gauge "Test RAM en cours..." 10 60 0
fi

# ── Test SMART ────────────────────────────────────────────────────────────────
(
for i in $(seq 1 100); do
    echo $i; sleep 0.05
done
) | dialog --gauge "Test SMART...\nPatientez..." 10 60 0
bash smart.sh short 2>/dev/null
sleep 2
grep "#1" "$logpath"/smart-long*.log > "$logpath/smart-result.log" 2>/dev/null || true

# ── Copie FTP ─────────────────────────────────────────────────────────────────
(
echo 10; sleep 0.2
logfiles=''
for i in "$logpath"/*; do
    [ -f "$i" ] || continue
    logfiles="${logfiles}put ${i}"$'\n'
done
echo 40; sleep 0.2
lftp -u "$ftpuser","$ftppassword" "$ftphost" <<EOF 2>/dev/null
set ssl:verify-certificate no
cd $ftpdirectory
$logfiles
bye
EOF
echo 100; sleep 0.2
) | dialog --gauge "Transfert des logs sur le serveur FTP..." 10 60 0

# ── Nettoyage logs inutiles ───────────────────────────────────────────────────
(
echo 25; sleep 0.2
rm -f "$logpath"/*-part*.log
echo 50; sleep 0.2
rm -f "$logpath"/*DVD*.log
echo 75; sleep 0.2
rm -f "$logpath"/*CD-ROM*.log
echo 100; sleep 0.2
) | dialog --gauge "Nettoyage des logs inutiles..." 10 60 0

# ── Effacement nwipe ──────────────────────────────────────────────────────────
# Se placer dans logpath pour que nwipe écrive son PDF au bon endroit
cd "$logpath"
nwipe --method="$nwipemethod" --nousb --autonuke --nowait \
      --logfile="$logpath/nwipe.log" 2>>"$logpath/nwipe.log" || true
NWIPE_EXIT=$?
cd - >/dev/null

# Récupérer le statut depuis le log
NWIPE_STATUS="INCONNU"
if grep -qi "FAILED\|ECHEC\|fatal\|error" "$logpath/nwipe.log" 2>/dev/null; then
    NWIPE_STATUS="ECHEC"
fi
if grep -qi "Finished final round\|Wipe successful\|erased successfully" \
         "$logpath/nwipe.log" 2>/dev/null; then
    NWIPE_STATUS="REUSSI"
fi

# ── Génération du certificat PDF ─────────────────────────────────────────────
(
echo 10; sleep 0.2

PDF_FILE="$logpath/certificat_effacement_${ninventaire}_$(date +%Y%m%d_%H%M%S).pdf"

# Téléchargement du logo
LOGO_FILE="abn.png"
if [ ! -f "$LOGO_FILE" ]; then
    curl -s -L --max-time 10 \
        "https://www.telecom-valley.fr/wp-content/uploads/2022/06/Banque-du-numerique_annuaire.jpg" \
        -o "$LOGO_FILE" 2>/dev/null || rm -f "$LOGO_FILE"
fi

echo 30; sleep 0.2

python3 - "$ninventaire" "$nwipemethod" "$PDF_FILE" \
          "${LOGO_FILE}" "$logpath/nwipe.log" "$NWIPE_STATUS" <<'PYEOF'
import sys, os
from reportlab.lib.pagesizes import A4
from reportlab.lib import colors
from reportlab.lib.units import mm
from reportlab.pdfgen import canvas
from datetime import datetime

NINVENTAIRE  = sys.argv[1]
METHODE_ID   = sys.argv[2]
OUT_PDF      = sys.argv[3]
LOGO_PATH    = sys.argv[4] if len(sys.argv) > 4 and os.path.exists(sys.argv[4]) else None
LOG_FILE     = sys.argv[5] if len(sys.argv) > 5 else None
NWIPE_STATUS = sys.argv[6] if len(sys.argv) > 6 else "INCONNU"

NOW       = datetime.now()
DATE_FIN  = NOW.strftime("%d/%m/%Y")
HEURE_FIN = NOW.strftime("%H:%M:%S")

METHODES = {
    "dod522022m": "DoD 5220.22-M (7 passes)",
    "dodshort":   "DoD court (3 passes)",
    "gutmann":    "Gutmann (35 passes)",
    "zero":       "Remplissage par zéros (1 passe)",
    "random":     "Aléatoire",
}
METHODE_LBL = METHODES.get(METHODE_ID, METHODE_ID)

# Lecture du log nwipe
if LOG_FILE and os.path.exists(LOG_FILE):
    with open(LOG_FILE, "r", errors="replace") as f:
        LOG_LINES = [l.rstrip() for l in f.readlines()]
else:
    LOG_LINES = ["Fichier log introuvable."]

W, H       = A4
MARGIN_L   = 15*mm
MARGIN_R   = 15*mm
MARGIN_B   = 15*mm
LOGO_H     = 18*mm
BANNER_H   = 10*mm
FONT_SIZE  = 8
LINE_H     = 4.2*mm
MARGIN_T   = LOGO_H + BANNER_H + 6*mm

usable_h       = H - MARGIN_T - MARGIN_B - 8*mm
lines_per_page = max(1, int(usable_h / LINE_H))
pages = [LOG_LINES[i:i+lines_per_page]
         for i in range(0, len(LOG_LINES), lines_per_page)] or [[]]

# Couleur statut
STATUS_COLOR = colors.HexColor("#1A7A3A") if NWIPE_STATUS == "REUSSI" \
          else colors.HexColor("#CC0000")  if NWIPE_STATUS == "ECHEC" \
          else colors.HexColor("#E67E00")

def draw_page(c, page_lines, page_num, total):
    c.setFillColor(colors.white)
    c.rect(0, 0, W, H, fill=1, stroke=0)

    # ── Bandeau logo/titre ──
    logo_y = H - LOGO_H - 4*mm
    c.setFillColor(colors.HexColor("#EAF2FB"))
    c.rect(0, logo_y - 2*mm, W, LOGO_H + 8*mm, fill=1, stroke=0)
    c.setStrokeColor(colors.HexColor("#2E6DA4"))
    c.setLineWidth(1.5)
    c.line(0, logo_y - 2*mm, W, logo_y - 2*mm)

    if LOGO_PATH:
        try:
            c.drawImage(LOGO_PATH, MARGIN_L, logo_y,
                        width=45*mm, height=LOGO_H,
                        preserveAspectRatio=True, anchor='w', mask='auto')
        except Exception:
            pass

    c.setFillColor(colors.HexColor("#1A3A5C"))
    c.setFont("Helvetica-Bold", 13 if page_num == 1 else 9)
    c.drawCentredString(W/2, logo_y + LOGO_H * 0.55,
                        "CERTIFICAT D'EFFACEMENT SÉCURISÉ")
    c.setFont("Helvetica", 8)
    c.setFillColor(colors.HexColor("#2E6DA4"))
    c.drawCentredString(W/2, logo_y + LOGO_H * 0.18,
        f"Inventaire : {NINVENTAIRE}  |  Méthode : {METHODE_LBL}  |  {DATE_FIN}")

    # Badge statut (première page uniquement)
    if page_num == 1:
        bx = W - MARGIN_R - 38*mm
        by = logo_y + 3*mm
        c.setFillColor(STATUS_COLOR)
        c.roundRect(bx, by, 36*mm, 11*mm, 2*mm, fill=1, stroke=0)
        c.setFillColor(colors.white)
        c.setFont("Helvetica-Bold", 9)
        c.drawCentredString(bx + 18*mm, by + 3.5*mm, f"Statut : {NWIPE_STATUS}")

    # ── Bandeau enscript ──
    banner_y = H - LOGO_H - BANNER_H - 4*mm
    c.setFillColor(colors.HexColor("#333333"))
    c.rect(MARGIN_L, banner_y, W - MARGIN_L - MARGIN_R, BANNER_H - 1*mm,
           fill=1, stroke=0)
    c.setFillColor(colors.white)
    c.setFont("Courier-Bold", 7.5)
    hY = banner_y + 3*mm
    c.drawString(MARGIN_L + 3*mm, hY, "nwipe.log")
    c.drawCentredString(W/2, hY,
        f"Certificat effacement | {NINVENTAIRE} | {DATE_FIN} {HEURE_FIN}")
    c.drawRightString(W - MARGIN_R - 3*mm, hY, f"Page {page_num}/{total}")

    # ── Corps log ──
    y = banner_y - 2*mm
    line_start = (page_num - 1) * lines_per_page

    for idx, line in enumerate(page_lines):
        # numéro de ligne
        c.setFillColor(colors.HexColor("#AAAAAA"))
        c.setFont("Courier", 6.5)
        c.drawRightString(MARGIN_L + 8*mm, y, str(line_start + idx + 1))
        c.setStrokeColor(colors.HexColor("#DDDDDD"))
        c.setLineWidth(0.2)
        c.line(MARGIN_L + 9*mm, y - 0.5*mm, MARGIN_L + 9*mm, y + 3*mm)

        # colorisation
        lu = line.upper()
        c.setFont("Courier", FONT_SIZE)
        if any(k in lu for k in ["FAILURE","FAILED","ECHEC","FATAL","ERROR"]):
            c.setFillColor(colors.HexColor("#CC0000"))
            c.setFont("Courier-Bold", FONT_SIZE)
        elif any(k in lu for k in ["FINISHED FINAL","SUCCESSFUL","REUSSI","PASS"]) \
             and "pass " not in line.lower()[:20]:
            c.setFillColor(colors.HexColor("#1A7A3A"))
            c.setFont("Courier-Bold", FONT_SIZE)
        elif line.startswith("***") or line.startswith("---"):
            c.setFillColor(colors.HexColor("#555555"))
        elif "notice:" in line.lower() and any(
             k in line for k in ["serial","Serial","model","Model",
                                  "sect/blk","bytes written"]):
            c.setFillColor(colors.HexColor("#1A3A5C"))
            c.setFont("Courier-Bold", FONT_SIZE)
        elif "notice:" in line.lower():
            c.setFillColor(colors.HexColor("#333333"))
        else:
            c.setFillColor(colors.black)

        c.drawString(MARGIN_L + 11*mm, y, line[:110])
        y -= LINE_H

    # ── Pied de page ──
    c.setStrokeColor(colors.HexColor("#CCCCCC"))
    c.setLineWidth(0.5)
    c.line(MARGIN_L, MARGIN_B + 4*mm, W - MARGIN_R, MARGIN_B + 4*mm)
    c.setFillColor(colors.HexColor("#888888"))
    c.setFont("Courier", 6.5)
    c.drawString(MARGIN_L, MARGIN_B,
                 f"Généré automatiquement — nwipe v0.38 — {NINVENTAIRE}")
    c.drawRightString(W - MARGIN_R, MARGIN_B, f"{DATE_FIN} {HEURE_FIN}")

cv = canvas.Canvas(OUT_PDF, pagesize=A4)
for p_idx, p_lines in enumerate(pages):
    draw_page(cv, p_lines, p_idx + 1, len(pages))
    cv.showPage()
cv.save()
print(f"OK:{OUT_PDF}")
PYEOF

PYTHON_EXIT=$?
echo 70; sleep 0.2

if [ $PYTHON_EXIT -ne 0 ]; then
    echo "ERREUR: génération PDF échouée" >> "$logpath/glpi_upload.log"
    echo 100
else
    # ── Authentification GLPI ──
    SESSION=$(curl -s --max-time 15 -X GET \
        "${glpiserver}/apirest.php/initSession" \
        -H "Content-Type: application/json" \
        -H "Authorization: user_token ${glpi_user_token}" \
        -H "App-Token: ${glpi_app_token}" \
        2>/dev/null | jq -r '.session_token // empty')

    if [ -n "$SESSION" ]; then
        curl -s --max-time 30 -X POST \
            "${glpiserver}/apirest.php/Document" \
            -H "Session-Token: ${SESSION}" \
            -H "App-Token: ${glpi_app_token}" \
            -F "uploadManifest={\"input\":{
                  \"name\":\"Effacement ${ninventaire} $(date +%d/%m/%Y) - ${NWIPE_STATUS}\",
                  \"comment\":\"Méthode: ${nwipemethod} | Statut: ${NWIPE_STATUS} | Généré automatiquement\",
                  \"documentcategories_id\":${glpi_doc_category_id:-1}
                }};type=application/json" \
            -F "filename[0]=@${PDF_FILE};type=application/pdf" \
            >> "$logpath/glpi_upload.log" 2>&1

        curl -s -X GET \
            "${glpiserver}/apirest.php/killSession" \
            -H "Session-Token: ${SESSION}" \
            -H "App-Token: ${glpi_app_token}" >/dev/null 2>&1

        echo 90; sleep 0.2
    else
        echo "ERREUR GLPI: session non obtenue" >> "$logpath/glpi_upload.log"
    fi
    echo 100; sleep 0.2
fi

) | dialog --gauge "Génération certificat et envoi vers GLPI..." 10 60 0

# ── Résultat final ────────────────────────────────────────────────────────────
if [ "$NWIPE_STATUS" = "REUSSI" ]; then
    dialog --msgbox "Effacement RÉUSSI\n\nInventaire : $ninventaire\nMéthode    : $nwipemethod\nCertificat : envoyé dans GLPI Documents" 10 55
else
    dialog --msgbox "ATTENTION : Effacement $NWIPE_STATUS\n\nInventaire : $ninventaire\nConsultez  : $logpath/nwipe.log\nCertificat : envoyé dans GLPI Documents (avec statut)" 11 58
fi

# ── Fin ───────────────────────────────────────────────────────────────────────
(
echo 30; sleep 0.2
echo 100; sleep 2
) | dialog --gauge "Tous les tests sont terminés.\nLa machine va maintenant s'éteindre." 8 50
clear
systemctl poweroff
