#!/bin/bash
. main.conf

logfiles=''

for i in $(ls $logpath)
do
	logfiles="${logfiles}put $logpath/$i"
	logfiles+=$'\n'
done
echo -e $logfiles


lftp -u $ftpuser,$ftppassword $ftphost <<EOF
set ssl:verify-certificate yes
cd $ftpdirectory
$logfiles
bye
EOF
