#!/bin/bash
. main.conf

# Vérification que le répertoire de logs existe
if [ ! -d "$logpath" ]; then
    echo "Erreur : le répertoire de logs '$logpath' n'existe pas." >&2
    exit 1
fi

# Construction de la liste des commandes put pour lftp
logfiles=''
for i in "$logpath"/*; do
    [ -f "$i" ] || continue
    logfiles="${logfiles}put \"${i}\""
    logfiles+=$'\n'
done

if [ -z "$logfiles" ]; then
    echo "Aucun fichier à transférer dans '$logpath'." >&2
    exit 0
fi

echo "$logfiles"

lftp -u "$ftpuser","$ftppassword" "$ftphost" <<EOF
set ssl:verify-certificate yes
cd $ftpdirectory
$logfiles
bye
EOF
