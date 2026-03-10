#!/bin/bash

. main.conf

# Vérification de dialog
if ! command -v dialog >/dev/null 2>&1; then
    echo "dialog n'est pas installé : sudo apt install dialog"
    exit 1
fi


# Saisie du numéro d' inventaire

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

# Stockage NFS

#(
#echo 10 ; sleep 0.2
#mkdir -p /mnt/nfs/logs
#echo 30 ; sleep 0.2
#mount -t nfs "$nfspath" /mnt/nfs/logs
#echo 60 ; sleep 0.2
#mkdir -p /mnt/nfs/logs/"$ninventaire"
#echo 100 ; sleep 0.2
#) | dialog --gauge "Préparation du stockage NFS..." 10 60 0

# Test RAM

ramfree=$(free -m | awk '/Mem:/ {print $4}')
ramtest=$((ramfree - 100))

memtester ${ramtest}M 1 > "$logpath/memtest.log" 2>&1 &
pid=$!

(
progress=10
while kill -0 $pid 2>/dev/null; do
    echo $progress
    progress=$((progress + 2))
    [ $progress -gt 95 ] && progress=95
    sleep 1
done

echo 100
) | dialog --gauge "Test RAM en cours..." 10 60 0

wait $pid

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
for i in $(ls $logpath)
do
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


# Copie vers NFS

#(
#echo 30 ; sleep 0.2
#cp $logpath/* /mnt/nfs/logs/"$ninventaire"/
#echo 100 ; sleep 0.2
#) | dialog --gauge "Transfert des logs vers le serveur NFS..." 10 60 0

# Effacement (Nwipe)

#(
#for i in $(seq 1 100); do
#    echo $i
#done
#) | dialog --gauge "Effacement des données (nwipe)...\nCela peut prendre plusieurs minutes." 10 60 0
nwipe --method="$nwipemethod" --nousb --autonuke --nowait --logfile="$logpath/nwipe.log"

# Fin

(
echo 30; sleep 0.2
echo 100; sleep 2
) | dialog --gauge "Tous les tests sont terminés.\nLa machine va maintenant s'éteindre." 8 50
clear
systemctl poweroff
