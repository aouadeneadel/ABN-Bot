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
echo 30; sleep 0.2
echo 50; sleep 0.2
lftp -u $ftpuser,$ftppassword $ftphost <<EOF
set ssl:verify-certificate no
cd $ftpdirectory
$logfiles
bye
EOF
echo 100; sleep 0.2
) | dialog --gauge "Transferts des logs sur le serveur FTP..." 10 60 0

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

# ── Génération du certificat PDF ──────────────────────────────────────────────
PDF_FILE="$logpath/certificat_effacement_${ninventaire}_$(date +%Y%m%d_%H%M%S).pdf"
enscript --font=Courier10 \
         --header="Certificat d'effacement | $ninventaire | %D %C" \
         --output="$logpath/nwipe.ps" \
         "$logpath/nwipe.log" 2>/dev/null
ps2pdf "$logpath/nwipe.ps" "$PDF_FILE"
rm -f "$logpath/nwipe.ps"

# ── Upload du PDF dans GLPI Documents ────────────────────────────────────────
(
echo 10; sleep 0.2

# Authentification GLPI
SESSION=$(curl -s -X GET \
    "${glpiserver}/apirest.php/initSession" \
    -H "Content-Type: application/json" \
    -H "Authorization: user_token ${glpi_user_token}" \
    -H "App-Token: ${glpi_app_token}" \
    | jq -r '.session_token')

echo 40; sleep 0.2

if [ -n "$SESSION" ] && [ "$SESSION" != "null" ]; then
    # Upload du PDF
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

    echo 80; sleep 0.2

    # Fermeture session
    curl -s -X GET \
        "${glpiserver}/apirest.php/killSession" \
        -H "Session-Token: ${SESSION}" \
        -H "App-Token: ${glpi_app_token}" >/dev/null
else
    echo "ERREUR: Session GLPI non obtenue" >> "$logpath/glpi_upload.log"
fi

echo 100; sleep 0.2
) | dialog --gauge "Upload du certificat dans GLPI..." 10 60 0

# ── Fin ───────────────────────────────────────────────────────────────────────
(
echo 30; sleep 0.2
echo 100; sleep 2
) | dialog --gauge "Tous les tests sont terminés.\nLa machine va maintenant s'éteindre." 8 50
clear
systemctl poweroff
