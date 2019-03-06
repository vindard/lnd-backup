#!/bin/bash

# DROPBOX API KEY
APITOKEN=<DROPBOX-API-KEY>

# SET ADMIN USER
ADMINUSER=<admin-user>

#==============================

DATE=$(date +%Y%m%d)
TIME=$(date +%Hh%Mm)
DEVICE=$(echo $(cat /etc/hostname) | awk '{print tolower($0)}')

# Setup folders and filenames
DATADIR=/home/bitcoin/.lnd
WORKINGDIR=/home/$ADMINUSER/data-backups
BACKUPFOLDER=.lndbackup-$DEVICE
BACKUPFILE=lndbackup-$DEVICE--$DATE-$TIME.tar

# Make sure necessary folders exist
if [[ ! -e ${WORKINGDIR} ]]; then
        mkdir -p ${WORKINGDIR}
fi
cd ${WORKINGDIR}

if [[ ! -e ${BACKUPFOLDER} ]]; then
        mkdir -p ${BACKUPFOLDER}
fi

# COPY DATA FOR BACKUP
rsync -avh --delete --progress ${DATADIR}/ ${BACKUPFOLDER}/

# CREATE ARCHIVE OF DATA TO BE UPLOADED
tar cvf ${BACKUPFILE} ${BACKUPFOLDER}/
chown -R ${ADMINUSER}:${ADMINUSER} ${BACKUPFOLDER} ${BACKUPFILE}

#==============================
# The archive file can be backed up via rsync or a cloud service now.

# CHECK IF ONLINE
wget -q --tries=10 --timeout=20 --spider http://google.com
if [[ $? -eq 0 ]]; then
        ONLINE=true
else
        ONLINE=false
fi
echo
echo "Online: "$ONLINE
echo "-----"

# UPLOAD TO DROPBOX
function upload_to_dropbox {
	echo
	echo "Starting Dropbox upload..."
	SESSIONID=$(curl -s -X POST https://content.dropboxapi.com/2/files/upload_session/start \
	    --header "Authorization: Bearer "${APITOKEN}"" \
	    --header "Dropbox-API-Arg: {\"close\": false}" \
	    --header "Content-Type: application/octet-stream" | jq -r .session_id)
	echo "--> Session ID: "${SESSIONID}
	echo
	echo "Uploading "${BACKUPFILE}"..."
	FINISH=$(curl -X POST https://content.dropboxapi.com/2/files/upload_session/finish \
	    --header "Authorization: Bearer "${APITOKEN}"" \
	    --header "Dropbox-API-Arg: {\"cursor\": {\"session_id\": \""${SESSIONID}"\",\"offset\": 0},\"commit\": {\"path\": \"/"${BACKUPFILE}"\",\"mode\": \"add\",\"autorename\": true,\"mute\": false,\"strict_conflict\": false}}" \
	    --header "Content-Type: application/octet-stream" \
	    --data-binary @$BACKUPFILE)
	echo $FINISH | jq
}

if [ $ONLINE = true ] ; then
	upload_to_dropbox
else
	echo "Please check that the internet is connected and try again."
fi

# CLEANUP & FINISH
rm ${BACKUPFILE}
echo
echo "Done!"
