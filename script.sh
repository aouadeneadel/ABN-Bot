#!/bin/bash

. main.conf

# Vérification de dialog
if ! command -v dialog >/dev/null 2>&1; then
    echo "dialog n'est pas installé : sudo apt install dialog"
    exit 1
fi

# Saisie du numéro d'inventaire
ninventaire=$(dialog --stdout --inputbox "Numéro d'inventaire ?" 10 50)
rc=$?
if [ $rc -ne 0 ] || [ -z "$ninventaire" ]; then
    dialog --msgbox "Inventaire annulé." 6 40
    clear
    exit 1
fi

dialog --msgbox "Le nom de machine GLPI sera : $ninventaire" 7 50

# Préparation de l'agent GLPI
if [ ! -f inventory.dumb ]; then
    dialog --msgbox "Erreur : fichier inventory.dumb introuvable." 6 50
    clear
    exit 1
fi

cp inventory.dumb inventory.json
sed -i "s/dumbname/${ninventaire}/g" inventory.json

# Mise à jour APT
sudo apt update >/dev/null 2>&1

# Nettoyage logs
rm -f "$logpath"/*.log

# Exécution de l'agent GLPI
glpi-agent --server "$glpiserver" \
           --additional-content="inventory.json" \
           --logfile="$logpath/glpi.log"

rm -f inventory.json

# Test RAM
ramfree=$(free -m | grep Mem | awk '{print $4}')
ramtest=$(( ramfree - 100 ))

if [ "$ramtest" -le 0 ]; then
    dialog --msgbox "Erreur : mémoire disponible insuffisante pour memtester." 6 60
    clear
    exit 1
fi

# Lance memtester en arrière-plan
memtester "${ramtest}M" 1 >"$logpath/memtest.log" 2>&1 &
memtester_pid=$!

# Anime la progression pendant que memtester tourne
(
pct=0
while kill -0 "$memtester_pid" 2>/dev/null; do
    echo $pct
    # Avance rapidement jusqu'à 90, puis ralentit pour ne pas dépasser avant la fin
    if [ $pct -lt 90 ]; then
        pct=$(( pct + 2 ))
    fi
    sleep 2
done
echo 100
) | dialog --gauge "Test RAM en cours..." 10 60 0

# Attendre la fin propre de memtester (au cas où il finit avant la gauge)
wait "$memtester_pid"

# Test SMART
(
for i in $(seq 1 100); do
    echo $i
    sleep 0.05
done
) | dialog --gauge "Test SMART (long)...\nPatientez..." 10 60 0

bash smart.sh short
sleep 2
grep "#1" "$logpath"/smart-long*.log > "$logpath/smart-result.log" 2>/dev/null

# Copie FTP
(
echo 0; sleep 0.2

logfiles=''
total=$(ls "$logpath" | wc -l)
count=0

for i in "$logpath"/*; do
    [ -f "$i" ] || continue
    logfiles="${logfiles}put \"${i}\""
    logfiles+=$'\n'
    count=$(( count + 1 ))
    pct=$(( count * 50 / (total > 0 ? total : 1) ))
    echo $pct; sleep 0.1
done

echo 60; sleep 0.2

lftp -u "$ftpuser","$ftppassword" "$ftphost" <<FTPEOF
set ssl:verify-certificate yes
cd $ftpdirectory
$logfiles
bye
FTPEOF

echo 100; sleep 0.2
) | dialog --gauge "Transfert des logs sur le serveur FTP..." 10 60 0

# Nettoyage
(
shopt -s nullglob
echo 25; sleep 0.2
files=("$logpath"/*-part*.log)
[ ${#files[@]} -gt 0 ] && rm -f "${files[@]}"
echo 50; sleep 0.2
files=("$logpath"/*DVD*.log)
[ ${#files[@]} -gt 0 ] && rm -f "${files[@]}"
echo 75; sleep 0.2
files=("$logpath"/*CD-ROM*.log)
[ ${#files[@]} -gt 0 ] && rm -f "${files[@]}"
echo 100; sleep 0.2
) | dialog --gauge "Nettoyage des logs inutiles..." 10 60 0

# Effacement (Nwipe)
nwipe --method="$nwipemethod" --nousb --autonuke --nowait --logfile="$logpath/nwipe.log"

# Fin
(
echo 30; sleep 0.2
echo 100; sleep 2
) | dialog --gauge "Tous les tests sont terminés.\nLa machine va maintenant s'éteindre." 8 50

clear
systemctl poweroff
