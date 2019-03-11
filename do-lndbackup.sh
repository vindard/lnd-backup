#!/bin/bash

# DROPBOX API KEY
APITOKEN=<DROPBOX-API-KEY>

# SET ADMIN USER
ADMINUSER=<admin-user>

# OPTIONAL, SET GPG KEY FOR ENCRYPTING WITH (COMPRESSES AS WELL)
GPG=""

# OPTIONAL, SET A DEVICE NAME TO BE USED FOR BACKUPS
DEVICE=""

# LND/BITCOIND PATHS
lnd_dir="/home/bitcoin/.lnd"
bitcoin_dir="/home/bitcoin/.bitcoin"

# TRUE, TO STOP LND AND DUMP DATA IF POSSIBLE FOR BACKUP
STOP=true

#==============================

DATE=$(date +%Y%m%d)
TIME=$(date +%Hh%Mm)
if [ -z "$DEVICE" ] ; then
	DEVICE=$(echo $(cat /etc/hostname))
fi
DEVICE=$(echo $DEVICE | awk '{print tolower($0)}' | sed -e 's/ /-/g')

# Setup folders and filenames
DATADIR=/home/bitcoin/.lnd
WORKINGDIR=/home/$ADMINUSER/data-backups
BACKUPFOLDER=.lndbackup-$DEVICE
BACKUPFILE=lndbackup-$DEVICE--$DATE-$TIME.tar
CHANSTATEFILE=.chan_state.txt

# Make sure necessary folders exist
if [[ ! -e ${WORKINGDIR} ]]; then
        mkdir -p ${WORKINGDIR}
fi
cd ${WORKINGDIR}

if [[ ! -e ${BACKUPFOLDER} ]]; then
        mkdir -p ${BACKUPFOLDER}
fi

#==================
# CHECK CHANNEL STATE TO DETERMINE IF TO CONTINUE WITH BACKUP
#==================

# Function to check lnd status
function check_lnd_status {
	systemctl -q is-active lnd
	#kill -0 $(pidof lnd)
	if [[ $? -eq 0 ]]; then
	        LNDSTOPPED=false
	else
	        LNDSTOPPED=true
	fi
}

# Function to stop lnd
function stop_lnd {
	if [ $STOP = true ] ; then
		systemctl stop lnd
		echo
		echo "Stopping lnd..."
		/bin/sleep 5s
		check_lnd_status
	fi
}


# SETUP LNCLI COMMAND FOR ROOT USER
chain="$(bitcoin-cli -datadir=${bitcoin_dir} getblockchaininfo | jq -r '.chain')"
if [[ $chain = "test" ]] ; then
  macaroon_path="${lnd_dir}/data/chain/bitcoin/testnet/readonly.macaroon"
else
  macaroon_path="${lnd_dir}/data/chain/bitcoin/mainnet/readonly.macaroon"
fi
lncli_creds=( --macaroonpath=${macaroon_path} --tlscertpath=${lnd_dir}/tls.cert)

# GET LND CHANNEL STATE
if [[ ! -e ${CHANSTATEFILE} ]]; then
	LAST_STATE=0
else
	LAST_STATE=$(tail -n 1 ${CHANSTATEFILE})
fi

check_lnd_status
if [ ! $LNDSTOPPED = true ] ; then
	# <start> LND CHANNEL STATE CHECKS
	ROUTED=$(lncli $"${lncli_creds[@]}" fwdinghistory --start_time 1 --end_time 2000000000 | jq -r .last_offset_index)
	INVOICES=$(lncli $"${lncli_creds[@]}" listinvoices | jq -r .last_index_offset)
	PAYMENTS=$(lncli $"${lncli_creds[@]}" listpayments | jq '.payments | length')
	# < end > LND CHANNEL STATE CHECKS
	CHAN_STATE=$(($ROUTED + $INVOICES + $PAYMENTS))
	echo "---" >> $CHANSTATEFILE
	echo "$? $(date)" >> $CHANSTATEFILE
	echo $CHAN_STATE >> $CHANSTATEFILE
	BACKUPFILE=${BACKUPFILE::-4}"--state-"$(printf "%04d\n" $((${CHAN_STATE}))).tar

	STATE_CHANGE=$(("$LAST_STATE" - "$CHAN_STATE"))

	stop_lnd
else
	STATE_CHANGE=-1
fi

echo "State change: "$STATE_CHANGE
if [[ $STATE_CHANGE -eq 0 ]] ; then
        echo "No channel state change detected"
	/bin/sleep 0.5
	echo "exiting..."
        /bin/sleep 1
        exit
fi

#==================
# ...exits above if no state change detected
#==================

# ENSURE LND WAS SUCCESSFULLY STOPPED
max_tries=2
count=0
while [ ! $LNDSTOPPED = true -a $count -lt $max_tries ] ; do
	stop_lnd
	count=$(($count+1))
done

# SIGNAL IF LND WAS STOPPED
if [ $LNDSTOPPED = true ] ; then
	BACKUPFILE="[stopped]-"$BACKUPFILE
	echo "lnd successfully stopped!"
	echo
else
	BACKUPFILE="[inflight]-"$BACKUPFILE
	if [ ! $STOP = true ] ; then
		echo "Running in-flight backup!"
	else
		echo "Sorry, lnd could not be stopped."
	fi
	echo
fi

# COPY DATA FOR BACKUP
echo "------------"
echo "Starting rsync..."
rsync -avh --delete --progress ${DATADIR}/ ${BACKUPFOLDER}/

# RESTART LND (AFTER COPY)
systemctl start lnd
echo "Restarted lnd!"

# CREATE ARCHIVE OF DATA TO BE UPLOADED
echo "------------"
echo "Creating tar archive of files..."
tar cvf ${BACKUPFILE} ${BACKUPFOLDER}/
chown -R ${ADMINUSER}:${ADMINUSER} ${BACKUPFOLDER} ${BACKUPFILE}

# GPG ENCRYPT ARCHIVE
function encrypt_backup {
	GPGNOTFOUND=$(gpg -k ${GPG} 2>&1 >/dev/null | grep -c error)
	if [ $GPGNOTFOUND -gt 0 ]; then
		gpg --recv-keys ${GPG}
	fi

	gpg --trust-model always -r ${GPG} -e ${BACKUPFILE}
	rm ${BACKUPFILE}
	BACKUPFILE=$BACKUPFILE.gpg
}

if [ ! -z $GPG ] ; then
	echo "------------"
	echo "Starting gpg encryption..."
	encrypt_backup
fi

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
	    --header "Dropbox-API-Arg: {\"cursor\": {\"session_id\": \""${SESSIONID}"\",\"offset\": 0},\"commit\": {\"path\": \"/"${BACKUPFOLDER}"/"${BACKUPFILE}"\",\"mode\": \"add\",\"autorename\": true,\"mute\": false,\"strict_conflict\": false}}" \
	    --header "Content-Type: application/octet-stream" \
	    --data-binary @$BACKUPFILE)
	echo $FINISH | jq
}

if [ $ONLINE = true -a -e ${BACKUPFILE} ] ; then
	upload_to_dropbox
else
	echo "Please check that the internet is connected and try again."
fi

# CLEANUP & FINISH
rm ${BACKUPFILE}
echo
echo "Done!"
