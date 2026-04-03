#!/bin/bash
. main.conf

# Vérification de dialog
if ! command -v dialog >/dev/null 2>&1; then
    echo "dialog n'est pas installé : sudo apt install dialog"
    exit 1
fi

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
echo 100 ; sleep 0.2

# Mise à jour APT
sudo apt update >/dev/null 2>&1

# Nettoyage logs
rm -f $logpath/*.log

# Exécution de l'agent GLPI
glpi-agent --server "$glpiserver" \
           --additional-content="inventory.json" \
           --logfile="$logpath/glpi.log"
rm inventory.json

# Test RAM
ramfree=$(free -m | grep Mem | awk '{print $4}')
ramtest=$(($ramfree - 100))
(
echo 10
memtester $ramtest 1 >"$logpath/memtest.log"
echo 100
) | dialog --gauge "Test RAM en cours..." 10 60 0

# Test SMART
(
for i in $(seq 1 100); do
  echo $i
done
) | dialog --gauge "Test SMART (long)...\nPatientez..." 10 60 0
bash smart.sh short
sleep 2
grep "#1" "$logpath"/smart-long*.log > "$logpath/smart-result.log"

# Copie FTP
(
echo 0; sleep 0.2
logfiles=''
count=0
for i in $(ls $logpath); do
    echo $count; sleep 0.2
    logfiles="${logfiles}put $logpath/$i"
    logfiles+=$'\n'
    count=$(($count+1))
done
echo 50; sleep 0.2
lftp -u $ftpuser,$ftppassword $ftphost <<EOF
set ssl:verify-certificate no
cd $ftpdirectory
$logfiles
bye
EOF
echo 100; sleep 0.2
) | dialog --gauge "Transfert des logs sur le serveur FTP..." 10 60 0

# Nettoyage
(
echo 25 ; sleep 0.2
rm -f $logpath/*-part*.log
echo 50 ; sleep 0.2
rm -f $logpath/*DVD*.log
echo 75 ; sleep 0.2
rm -f $logpath/*CD-ROM*.log
echo 100 ; sleep 0.2
) | dialog --gauge "Nettoyage des logs inutiles..." 10 60 0

# ── Effacement nwipe ──────────────────────────────────────────────────────────
nwipe --method="$nwipemethod" --nousb --autonuke --nowait \
      --logfile="$logpath/nwipe.log"

# ── Génération du certificat PDF en français avec logo ────────────────────────
(
echo 10; sleep 0.2

PDF_FILE="$logpath/certificat_effacement_${ninventaire}_$(date +%Y%m%d_%H%M%S).pdf"

# Téléchargement du logo si absent
LOGO_FILE="/tmp/logo_org.jpg"
if [ ! -f "$LOGO_FILE" ]; then
    curl -s -L --max-time 10 \
        "https://www.telecom-valley.fr/wp-content/uploads/2022/06/Banque-du-numerique_annuaire.jpg" \
        -o "$LOGO_FILE" 2>/dev/null || rm -f "$LOGO_FILE"
fi

echo 30; sleep 0.2

# Génération du PDF via Python/reportlab
python3 - "$ninventaire" "$nwipemethod" "$PDF_FILE" "${LOGO_FILE:-}" \
          "$logpath/nwipe.log" <<'PYEOF'
import sys, os
from reportlab.lib.pagesizes import A4
from reportlab.lib import colors
from reportlab.lib.units import mm
from reportlab.pdfgen import canvas

NINVENTAIRE = sys.argv[1]
METHODE_ID  = sys.argv[2]
OUT_PDF     = sys.argv[3]
LOGO_PATH   = sys.argv[4] if len(sys.argv) > 4 and os.path.exists(sys.argv[4]) else None
LOG_FILE    = sys.argv[5] if len(sys.argv) > 5 else None

DATE_FIN  = __import__('datetime').datetime.now().strftime("%d/%m/%Y")
HEURE_FIN = __import__('datetime').datetime.now().strftime("%H:%M:%S")

METHODES = {
    "dod522022m":  "DoD 5220.22-M (7 passes)",
    "dodshort":    "DoD court (3 passes)",
    "gutmann":     "Gutmann (35 passes)",
    "zero":        "Remplissage par zéros (1 passe)",
    "random":      "Aléatoire",
}
METHODE_LBL = METHODES.get(METHODE_ID, METHODE_ID)

# Lecture du log nwipe
if LOG_FILE and os.path.exists(LOG_FILE):
    with open(LOG_FILE, "r", errors="replace") as f:
        LOG_LINES = [l.rstrip() for l in f.readlines()]
else:
    LOG_LINES = [f"Fichier log introuvable : {LOG_FILE}"]

W, H = A4
MARGIN_L   = 15*mm
MARGIN_R   = 15*mm
MARGIN_B   = 15*mm
LOGO_H     = 18*mm
BANNER_H   = 10*mm
MARGIN_T   = LOGO_H + BANNER_H + 4*mm
FONT_SIZE  = 8
LINE_H     = 4.2*mm

usable_h      = H - MARGIN_T - MARGIN_B - 8*mm
lines_per_page = int(usable_h / LINE_H)
pages = [LOG_LINES[i:i+lines_per_page] for i in range(0, len(LOG_LINES), lines_per_page)]
if not pages:
    pages = [[]]

def draw_page(c, page_lines, page_num, total):
    c.setFillColor(colors.white)
    c.rect(0, 0, W, H, fill=1, stroke=0)

    # ── Entête logo + titre ──
    logo_y = H - LOGO_H - 4*mm
    c.setFillColor(colors.HexColor("#EAF2FB"))
    c.rect(0, logo_y - 2*mm, W, LOGO_H + 8*mm, fill=1, stroke=0)
    c.setStrokeColor(colors.HexColor("#2E6DA4"))
    c.setLineWidth(1.5)
    c.line(0, logo_y - 2*mm, W, logo_y - 2*mm)

    if page_num == 1:
        if LOGO_PATH:
            c.drawImage(LOGO_PATH, MARGIN_L, logo_y,
                        width=45*mm, height=LOGO_H,
                        preserveAspectRatio=True, anchor='w', mask='auto')
        c.setFillColor(colors.HexColor("#1A3A5C"))
        c.setFont("Helvetica-Bold", 13)
        c.drawCentredString(W/2, logo_y + LOGO_H*0.55,
                            "CERTIFICAT D'EFFACEMENT SÉCURISÉ")
        c.setFont("Helvetica", 8.5)
        c.setFillColor(colors.HexColor("#2E6DA4"))
        c.drawCentredString(W/2, logo_y + LOGO_H*0.18,
                            f"Inventaire : {NINVENTAIRE}  |  Méthode : {METHODE_LBL}  |  {DATE_FIN}")
    else:
        c.setFillColor(colors.HexColor("#1A3A5C"))
        c.setFont("Helvetica-Bold", 8)
        c.drawCentredString(W/2, logo_y + LOGO_H*0.4,
                            f"Certificat d'effacement — {NINVENTAIRE} — {DATE_FIN}")

    # ── Bandeau enscript ──
    banner_y = H - LOGO_H - BANNER_H - 4*mm
    c.setFillColor(colors.HexColor("#333333"))
    c.rect(MARGIN_L, banner_y, W - MARGIN_L - MARGIN_R, BANNER_H - 1*mm, fill=1, stroke=0)
    c.setFillColor(colors.white)
    c.setFont("Courier-Bold", 7.5)
    hY = banner_y + 3*mm
    c.drawString(MARGIN_L + 3*mm, hY, "nwipe.log")
    c.drawCentredString(W/2, hY,
        f"Certificat d'effacement | {NINVENTAIRE} | {DATE_FIN} {HEURE_FIN}")
    c.drawRightString(W - MARGIN_R - 3*mm, hY, f"Page {page_num}/{total}")

    # ── Corps du log ──
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
        c.setFont("Courier", FONT_SIZE)
        lu = line.upper()
        if any(k in lu for k in ["REUSSI","SUCCES","SUCCESS","PASS"]) and \
           not any(k in line for k in ["pass ", "passe "]):
            c.setFillColor(colors.HexColor("#1A7A3A"))
            c.setFont("Courier-Bold", FONT_SIZE)
        elif any(k in lu for k in ["ECHEC","ERREUR","ERROR","FAIL"]):
            c.setFillColor(colors.HexColor("#CC0000"))
            c.setFont("Courier-Bold", FONT_SIZE)
        elif line.startswith("---"):
            c.setFillColor(colors.HexColor("#555555"))
        elif any(line.lstrip().startswith(k) for k in
                 ["Disque","Modèle","Drive","Model","Serial","Série","Numéro"]):
            c.setFillColor(colors.HexColor("#1A3A5C"))
            c.setFont("Courier-Bold", FONT_SIZE)
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
                 f"Généré par nwipe v0.36 — {NINVENTAIRE} — {METHODE_LBL}")
    c.drawRightString(W - MARGIN_R, MARGIN_B, f"{DATE_FIN} {HEURE_FIN}")

cv = canvas.Canvas(OUT_PDF, pagesize=A4)
for p_idx, p_lines in enumerate(pages):
    draw_page(cv, p_lines, p_idx + 1, len(pages))
    cv.showPage()
cv.save()
print(f"PDF généré : {OUT_PDF}")
PYEOF

echo 70; sleep 0.2

# ── Authentification GLPI ──
SESSION=$(curl -s -X GET \
    "${glpiserver}/apirest.php/initSession" \
    -H "Content-Type: application/json" \
    -H "Authorization: user_token ${glpi_user_token}" \
    -H "App-Token: ${glpi_app_token}" \
    | jq -r '.session_token')

if [ -n "$SESSION" ] && [ "$SESSION" != "null" ]; then
    # Upload du PDF dans GLPI Documents
    curl -s -X POST \
        "${glpiserver}/apirest.php/Document" \
        -H "Session-Token: ${SESSION}" \
        -H "App-Token: ${glpi_app_token}" \
        -F "uploadManifest={\"input\":{
              \"name\":\"Effacement ${ninventaire} $(date +%d/%m/%Y)\",
              \"comment\":\"Méthode: ${nwipemethod} — Généré automatiquement\",
              \"documentcategories_id\":${glpi_doc_category_id:-1}
            }};type=application/json" \
        -F "filename[0]=@${PDF_FILE};type=application/pdf" \
        >> "$logpath/glpi_upload.log" 2>&1

    # Fermeture session GLPI
    curl -s -X GET \
        "${glpiserver}/apirest.php/killSession" \
        -H "Session-Token: ${SESSION}" \
        -H "App-Token: ${glpi_app_token}" >/dev/null
else
    echo "ERREUR GLPI: session non obtenue" >> "$logpath/glpi_upload.log"
fi

echo 100; sleep 0.2
) | dialog --gauge "Génération et envoi du certificat vers GLPI..." 10 60 0

# ── Fin ───────────────────────────────────────────────────────────────────────
(
echo 30; sleep 0.2
echo 100; sleep 2
) | dialog --gauge "Tous les tests sont terminés.\nLa machine va maintenant s'éteindre." 8 50
clear
systemctl poweroff
