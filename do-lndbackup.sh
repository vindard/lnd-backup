#!/bin/bash
echo "Backup script started!"
echo

#==============================
# OPTIONAL USER HARDCODED VARIABLES
#==============================

# SET GPG KEY FOR ENCRYPTING WITH (COMPRESSES AS WELL)
GPG=""

# SET A DEVICE NAME TO BE USED FOR BACKUPS, DEFAULTS TO /etc/hostname
DEVICE=""

# SET DROPBOX API KEY FOR UPLOADS
DROPBOX_APITOKEN=""

# SET MINIMUM ELAPSED TIMES AFTER WHICH SCRIPT WILL RUN EVEN IF NO STATE CHANGES
# Set as '<num>h' for hours, '<num>m' for mins or '<num>' for seconds
#--
# STOP: Checks against the last "lnd was stopped" backup
STOP_RUN_MINTIME=""
# ABS: Checks against the absolute last backup, whether lnd was stopped or not
ABS_RUN_MINTIME=""

# BACKUP CLEANUP CONSTANTS
KEEP_MAX=20
# Note: Set KEEP_MAX to "" to disable backup file cleanups
KEEP_STOP=7
GREP_FILES='\S*\.tar$|\S*\.gpg$'
GREP_KEEP='stop.*state'

#==============================
# SETUP REQUIRED ENVIRONMENT VARIABLES
#==============================

# if true, stop lnd and dump data if possible for backup
STOP_LND=false

# if true, backup whether state change or not
STATE_IGNORE=false

# if true, treat as encrypted (whether encrypted or not) to pass upload pre-checks
ENCRYPTION_OVERRIDE=false

# "infinite" default time used to ensure default minimum time run checks fail
DEFAULT_RUN_MINTIME=2100000000

# Flags
for f in $@
do
	case $f in
		"-f") STATE_IGNORE=true ;;
		"-s") STOP_LND=true ;;
		"-u") ENCRYPTION_OVERRIDE=true ;;
	esac
done

# Arguments
while getopts :d:m:n: opt; do
        case $opt in
                d) DROPBOX_APITOKEN=$OPTARG ;;
		m) STOP_RUN_MINTIME=$OPTARG ;;
		n) ABS_RUN_MINTIME=$OPTARG ;;
                ?) ;;
        esac
done

# lnd/bitcoind paths
lnd_dir="/home/bitcoin/.lnd"
bitcoin_dir="/home/bitcoin/.bitcoin"

# Fetches the user whose home folder the directories will be stored under
ADMINUSER=( $(ls /home | grep -v bitcoin) )

DATE_SRC=$(date +%s)
DATE=$(date -d @$DATE_SRC +%Y%m%d)
TIME=$(date -d @$DATE_SRC +%Hh%Mm)
if [ -z "$DEVICE" ] ; then
	DEVICE=$(echo $(cat /etc/hostname))
fi
DEVICE=$(echo $DEVICE | awk '{print tolower($0)}' | sed -e 's/ /-/g')

# Setup folders and filenames
DATADIR=/home/bitcoin/.lnd
WORKINGDIR=/home/$ADMINUSER/lnd-data-backups
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
# CHECK TIME ELAPSED TO DETERMINE IF TO FORCE BACKUP
#==================

# allow different time formats to be input
function parse_mintime {
        PARSED_ARG=$DEFAULT_RUN_MINTIME
	if [[ $(echo $2 | grep -c -P "^\d+h$") -gt 0 ]] ; then
                PARSED_ARG=$(( ${2::-1} * 3600 ))
        elif [[ $(echo $2 | grep -c -P "^\d+m$") -gt 0 ]] ; then
                PARSED_ARG=$(( ${2::-1} * 60 ))
        elif [[ $(echo $2 | grep -c -P "^\d+$") -gt 0 ]] ; then
                PARSED_ARG=$2
	elif [[ -z $2 ]] ; then
		true
        else
                echo "Invalid parse data :( -> "$2
        fi

        case $1 in
                "ABS") ABS_RUN_MINTIME=$PARSED_ARG ;;
                "STOP") STOP_RUN_MINTIME=$PARSED_ARG ;;
        esac
}

# CHECK TIME ELAPSED AGAINST MINIMUM TIME BEFORE NEXT RUN
#---------

function check_time_for_run {
	# Set variables
	ABS_ELAPSED=$(( $DATE_SRC - $(tail -n 2 .chan_state.txt | head -n 1 | jq -r .date) ))
	STOP_ELAPSED=$(( $DATE_SRC - $(cat .chan_state.txt | grep stopped | jq -r .date | tail -n 1) ))
	parse_mintime "STOP" $STOP_RUN_MINTIME
	parse_mintime "ABS" $ABS_RUN_MINTIME

	if [ ! $ABS_RUN_MINTIME -eq $DEFAULT_RUN_MINTIME ] ; then
		echo "Abs Elapsed: "$ABS_ELAPSED"  |  Abs Min Time: "$ABS_RUN_MINTIME
	fi
	if [ ! $STOP_RUN_MINTIME -eq $DEFAULT_RUN_MINTIME ] ; then
		echo "Stop Elapsed: "$STOP_ELAPSED"  |  Stop Min Time: "$STOP_RUN_MINTIME
	fi

	# Decide if to ignore state or not
	if [[ ! $STOP_LND = false && $STOP_ELAPSED -gt $STOP_RUN_MINTIME ]] ; then
		STATE_IGNORE=true
	elif [[ $ABS_ELAPSED -gt $ABS_RUN_MINTIME ]] ; then
		STATE_IGNORE=true
	fi
}

if [[ -e ${CHANSTATEFILE} ]]; then
	check_time_for_run
fi

#==================
# CHECK CHANNEL STATE TO DETERMINE IF TO CONTINUE WITH BACKUP
#==================

# DEFINE STATE CHANGE FUNCTIONS
# ------------

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
	if [ ! $STOP_LND = false ] ; then
		systemctl stop lnd
		echo
		echo "Stopping lnd..."
		/bin/sleep 5s
		check_lnd_status
	fi
}

# Function to fetch channel state
function fetch_channel_state {
	num_updates_array=( $(lncli listchannels | grep num_updates | grep -oP '\d+') )
	for num in ${num_updates_array[@]}
	do
		CHAN_STATE=$(( $CHAN_STATE + $num ))
	done
}

# Function to write fetched state to log
function update_run_log {
	# 1/ Log separator
	echo "---" >> $CHANSTATEFILE

	# 2/ Log entry date
	# (Use "$ date -d @$DATE_SRC" instead of "$ date" to
	#  log script start time instead of script log time)
	date -d @$DATE_SRC >> $CHANSTATEFILE

	# 3/ Log data object
	echo -n "{\"date\": \""$DATE_SRC"\"" >> $CHANSTATEFILE
	if [ ! $STOP_LND = false ] ; then
		echo ", \"stopped\": \""$CHAN_STATE"\"}" >> $CHANSTATEFILE
	else
		echo "}" >> $CHANSTATEFILE
	fi

	# 4/ Log raw channel state
	echo $CHAN_STATE >> $CHANSTATEFILE
}


# RUN STATE CHANGE FUNCTIONS
# ------------

# SETUP LNCLI COMMAND FOR ROOT USER
chain="$(bitcoin-cli -datadir=${bitcoin_dir} getblockchaininfo | jq -r '.chain')"
if [[ $chain = "test" ]] ; then
  macaroon_path="${lnd_dir}/data/chain/bitcoin/testnet/readonly.macaroon"
else
  macaroon_path="${lnd_dir}/data/chain/bitcoin/mainnet/readonly.macaroon"
fi
lncli_creds=( --macaroonpath=${macaroon_path} --tlscertpath=${lnd_dir}/tls.cert)

# GET PRIOR BACKUP'S LND CHANNEL STATE, IF IT EXISTS
if [[ ! -e ${CHANSTATEFILE} ]]; then
	LAST_STATE=0
elif [ ! $STOP_LND = false ] ; then
	LAST_STATE=$(cat ${CHANSTATEFILE} | grep stopped | jq -r .stopped | tail -n 1)
else
	LAST_STATE=$(tail -n 1 ${CHANSTATEFILE})
fi

# EXECUTE CHANNEL-STATE-CHANGE CHECKS AND LOGGING
check_lnd_status

if [ ! $LNDSTOPPED = true ] ; then
	WAS_RUNNING=true
	fetch_channel_state
	BACKUPFILE=${BACKUPFILE::-4}"--state-"$(printf "%04d\n" $((${CHAN_STATE}))).tar

	STATE_CHANGE=$(("$LAST_STATE" - "$CHAN_STATE"))

else
	STATE_CHANGE=-1
fi


# TERMINATE SCRIPT IF NO CHANGES DETECTED OR CHANGES IGNORED
echo "------------"
echo "State change: "$STATE_CHANGE
if [[ $STATE_CHANGE -eq 0 && $STATE_IGNORE = false ]] ; then
	echo "No channel state change detected"
	/bin/sleep 0.5
	echo "exiting..."
        /bin/sleep 1
        exit
else
	stop_lnd
fi

#==================
# ...exits above if no state change detected
#==================



# ENSURE LND WAS SUCCESSFULLY STOPPED
max_tries=4
count=0
while [[ ! $LNDSTOPPED = true && $count -lt $(($max_tries - 1)) && ! $STOP_LND = false ]] ; do
        stop_lnd
        count=$(($count+1))
        echo "Lnd stop, attempt#: "$(( $count  + 1 ))" of "$max_tries
done

# SIGNAL IF LND WAS STOPPED
if [ $LNDSTOPPED = true ] ; then
	BACKUPFILE="[stopped]-"$BACKUPFILE
	echo "lnd successfully stopped!"
	echo
else
	BACKUPFILE="[inflight]-"$BACKUPFILE
	if [ $STOP_LND = false ] ; then
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
if [[ $LNDSTOPPED = true && $WAS_RUNNING = true ]] ; then
	systemctl start lnd
	echo "Restarted lnd!"
fi

# CREATE ARCHIVE OF DATA TO BE SAVED/UPLOADED
echo "------------"
echo "Creating tar archive of files..."
tar cvf ${BACKUPFILE} ${BACKUPFOLDER}/
chown -R ${ADMINUSER}:${ADMINUSER} ${BACKUPFOLDER} ${BACKUPFILE}
# Update log here because everything else below this is optional
update_run_log
# Setup type-of-backup for backup files cleanup operations
BACKUP_LOC='local'

#==============================
# ENCRYPTING THE ARCHIVE FILE BEFORE CLOUD UPLOAD.
#==============================

# GPG ENCRYPT ARCHIVE
function encrypt_backup {
	GPGNOTFOUND=$(gpg -k ${GPG} 2>&1 >/dev/null | grep -c error)
	if [ $GPGNOTFOUND -gt 0 ]; then
		gpg --recv-keys ${GPG}
	fi

	gpg --trust-model always -r ${GPG} -e ${BACKUPFILE}
	rm ${BACKUPFILE}
	BACKUPFILE=$BACKUPFILE.gpg
	chown -R ${ADMINUSER}:${ADMINUSER} ${BACKUPFILE}
}

if [ ! -z $GPG ] ; then
	echo "------------"
	echo "Running gpg encryption..."
	encrypt_backup
	echo "Encrypted!"
	echo
fi

#==============================
# The archive file can be backed up via rsync or a cloud service now.
#==============================

function online_check {
	wget -q --tries=10 --timeout=20 --spider http://google.com
	if [[ $? -eq 0 ]]; then
	        ONLINE=true
	else
	        ONLINE=false
	fi
	echo
	echo "Online: "$ONLINE
	echo "-----"
}

function encryption_check {
	FILE_CHECK=$(file ${BACKUPFILE} | grep -c -E "PGP.*encrypted|GPG.*encrypted")
	if [ $FILE_CHECK -gt 0 ] || [ $ENCRYPTION_OVERRIDE = true ]; then
		ENCRYPTED=true
	else
		ENCRYPTED=false
	fi

	echo
	echo -n "Encrypted: "$ENCRYPTED
	if [ $ENCRYPTION_OVERRIDE = true ] ; then
		echo " [overridden]"
	else
		echo
	fi
	echo "-----"
}

#==============================
# CLOUD BACKUP OPTIONS
#==============================


# BACKUP VIA DROPBOX
# ----------------------

function dropbox_api_check {
	VALID_DROPBOX_APITOKEN=false
	curl -s -X POST https://api.dropboxapi.com/2/users/get_current_account \
	    --header "Authorization: Bearer "$DROPBOX_APITOKEN | grep rror
	if [[ ! $? -eq 0 ]] ; then
	        VALID_DROPBOX_APITOKEN=true
	else
		echo "Invalid Dropbox API Token!"
	fi
}


function dropbox_upload_check {
	UPLOAD_TO_DROPBOX=false
	if [ ! -z $DROPBOX_APITOKEN ] ; then
		online_check
		if [ $ONLINE = true ] ; then
			dropbox_api_check
		else
			echo "Please check that the internet is connected and try again."
		fi

		if [ $VALID_DROPBOX_APITOKEN = true ] ; then
			encryption_check
			if [ $ENCRYPTED = true ] ; then
				UPLOAD_TO_DROPBOX=true
			else
				echo "Sorry can't safely upload, backup archive not encrypted."
				echo
				echo "If you would like to upload an unencrypted backup file (unsafe), please run again with '-u' flag."
			fi
		fi
	fi
}


function upload_to_dropbox {
	echo
	echo "Starting Dropbox upload..."
	SESSIONID=$(curl -s -X POST https://content.dropboxapi.com/2/files/upload_session/start \
	    --header "Authorization: Bearer "${DROPBOX_APITOKEN}"" \
	    --header "Dropbox-API-Arg: {\"close\": false}" \
	    --header "Content-Type: application/octet-stream" | jq -r .session_id)
	echo "--> Session ID: "${SESSIONID}
	echo
	echo "Uploading "${BACKUPFILE}"..."
	FINISH=$(curl -X POST https://content.dropboxapi.com/2/files/upload_session/finish \
	    --header "Authorization: Bearer "${DROPBOX_APITOKEN}"" \
	    --header "Dropbox-API-Arg: {\"cursor\": {\"session_id\": \""${SESSIONID}"\",\"offset\": 0},\"commit\": {\"path\": \"/"${BACKUPFOLDER}"/"${BACKUPFILE}"\",\"mode\": \"add\",\"autorename\": true,\"mute\": false,\"strict_conflict\": false}}" \
	    --header "Content-Type: application/octet-stream" \
	    --data-binary @$BACKUPFILE)
	echo $FINISH | jq .
}



# RUN CHECKS AND IF PASS, EXECUTE BACKUP TO DROPBOX
dropbox_upload_check
if [ $UPLOAD_TO_DROPBOX = true ] ; then
	BACKUP_LOC='dropbox'
	upload_to_dropbox
	rm ${BACKUPFILE}
fi



# BACKUP VIA RSYNC TO REMOTE SERVER
# ----------------------

# Consider adding this as a backup method




# BACKUP VIA GOOGLE CLOUD
# ----------------------

# Consider adding this as a backup method



#====================================
# CLEAUP EXTRA BACKUP FILES
#====================================


# FUNCTIONS
# ----------------------

# Function to ensure that 'non-state stops' dont get overwritten
# by inflight backups should a large number of inflights be made
# after a legitimate 'non-state stop' backup.
function swap_files {
	# Note: This 'num_to_move' value takes the highest priority. It edges inflight backups
	# out first and then 'stopped-state' backups after. Keep lower than KEEP_STOP
	# to ensure 'stopped-state' backups aren't all deleted.
	num_to_move=1

        move_search=*'stop'*
        move_exclude=*'state'*
        temp=( "${FILES_TO_DELETE[@]}" )

        # Set num_to_move so that swaps don't exceed 2nd array length
        num_to_move=$(( ${#FILES_TO_KEEP[@]} > $num_to_move ? $num_to_move : ${#FILES_TO_KEEP[@]} ))

        # Set num_to_move to actually be 'num to remain' in 2nd array
        count2=0
        for file2 in ${FILES_TO_KEEP[@]}
        do
                if [[ $file2 == $move_search ]] && [[ ! $file2 == $move_exclude ]] ; then
                        ((++count2))
                fi
        done
        num_to_move=$(( $num_to_move - $count2 ))


        # Execute swap across both arrays
        i=0
        count=0
        for file in ${FILES_TO_DELETE[@]}
        do
                if [[ $file == $move_search ]] && [[ ! $file == $move_exclude ]] && [ $count -lt $num_to_move ] ; then
                        echo "Moving: "$file
			unset 'temp[$(($i-$count))]'
                        temp=( "${temp[@]}" "${FILES_TO_KEEP[-1]}" )
                        unset 'FILES_TO_KEEP[-1]'
                        FILES_TO_KEEP=( "$file" "${FILES_TO_KEEP[@]}" )
                        ((++count))
                fi
                ((++i))
        done
        FILES_TO_DELETE=( "${temp[@]}" )
}

# Pass 2 integers (KEEP_MAX, KEEP_STOP) and 2 arrays (FILES_STOP, FILES_NOSTOP)
function make_delete_list {
	if [[ ! $KEEP_STOP -lt $KEEP_MAX ]] ; then
		KEEP_STOP=KEEP_MAX
	fi
	NUM_STOP_DELETE=$(( ${#FILES_STOP[@]} - $KEEP_STOP ))
	NUM_STOP_DELETE=$(( $NUM_STOP_DELETE > 0 ? $NUM_STOP_DELETE : 0 ))
	FILES_STOP_DELETE=( "${FILES_STOP[@]: -$NUM_STOP_DELETE:$NUM_STOP_DELETE}" )
	FILES_STOP_KEEP=( "${FILES_STOP[@]::$KEEP_STOP}" )

	KEEP_NOSTOP=$(( $KEEP_MAX - ${#FILES_STOP_KEEP[@]} ))

	NUM_NOSTOP_DELETE=$(( ${#FILES_NOSTOP[@]} - $KEEP_NOSTOP ))
	NUM_NOSTOP_DELETE=$(( $NUM_NOSTOP_DELETE > 0 ? $NUM_NOSTOP_DELETE : 0 ))
	FILES_NOSTOP_DELETE=( "${FILES_NOSTOP[@]: -$NUM_NOSTOP_DELETE:$NUM_NOSTOP_DELETE}" )
	FILES_NOSTOP_KEEP=( "${FILES_NOSTOP[@]::$KEEP_NOSTOP}" )

	FILES_TO_DELETE=( "${FILES_STOP_DELETE[@]}" "${FILES_NOSTOP_DELETE[@]}" )
	FILES_TO_KEEP=( "${FILES_STOP_KEEP[@]}" "${FILES_NOSTOP_KEEP[@]}" )

	swap_files
}

# LOCAL-SPECIFIC FILES FUNCTIONS
#-----------------

# Get all files commands
function get_files_local {
	FILES=( $(ls -ctalh | grep -Po $GREP_FILES) )
	FILES_STOP=( $(ls -ctalh | grep -Po $GREP_FILES | grep -P $GREP_KEEP) )
	FILES_NOSTOP=( $(ls -ctalh | grep -Po $GREP_FILES | grep -v $GREP_KEEP) )
}

# Delete function taking the "FILES_TO_DELETE" array as input
function delete_files_local {
	rm ${FILES_TO_DELETE[@]} 2> /dev/null
}


# DROPBOX-SPECIFIC FILES FUNCTIONS
#-----------------

function get_files_dropbox {
	FILES=( $(curl -s -X POST https://api.dropboxapi.com/2/files/list_folder \
	    --header "Authorization: Bearer "$DROPBOX_APITOKEN \
	    --header "Content-Type: application/json" \
	    --data "{\"path\": \"/"$BACKUPFOLDER"\",\"recursive\": false,\"include_media_info\": false,\"include_deleted\": false,\"include_has_explicit_shared_members\": false,\"include_mounted_folders\": true}" \
	    | jq -r .entries[].name) )
        FILES=( $(printf '%s\n' "${FILES[@]}" | grep -Po $GREP_FILES) )
        IFS=$'\n' FILES=($(sort -r <<<"${FILES[*]}"))
        unset IFS
	FILES_STOP=( $(printf '%s\n' "${FILES[@]}" | grep $GREP_KEEP) )
	FILES_NOSTOP=( $(printf '%s\n' "${FILES[@]}"  | grep -v $GREP_KEEP) )
}

# Optional delete status function
function check_delete_dropbox {
	max_tries=10
	count=0
	echo
	echo "Checking delete job status..."
	while [[ ! $STATUS = "complete" && $count -lt $max_tries ]] ; do
	        CHECK_DEL=$(curl -s -X POST https://api.dropboxapi.com/2/files/delete_batch/check \
	            --header "Authorization: Bearer "$DROPBOX_APITOKEN \
	            --header "Content-Type: application/json" \
	            --data "{\"async_job_id\": \""$DELETE_ID"\"}")
	        STATUS=$(echo $CHECK_DEL | jq -r '.".tag"')
	        count=$(( $count + 1 ))
	        echo "Try #"$count" of "$max_tries" || Status: "$STATUS
		/bin/sleep 1.5
	done
	if [[ $STATUS = "complete" ]] ; then
		success=$(echo $CHECK_DEL | jq '.entries[].".tag"' | grep -c success)
		failure=$(echo $CHECK_DEL | jq '.entries[].".tag"' | grep -c failure)
		echo "-------"
		echo "Deleted "$success" files successfully ("$failure" files failed)"
	fi
}

function delete_files_dropbox {
	#BACKUPFOLDER="test-delete"

	# Assemble Dropbox delete object
	dropbox_del_obj="{\"entries\":["
	for file in "${FILES_TO_DELETE[@]::$(( ${#FILES_TO_DELETE[@]} - 1 ))}"
	do
	        dropbox_del_obj=$dropbox_del_obj"{\"path\":\"/"$BACKUPFOLDER"/"$file"\"},"
	done
	if [[ ${#FILES_TO_DELETE[-1]} -gt 0 ]] ; then
		dropbox_del_obj=$dropbox_del_obj"{\"path\":\"/"$BACKUPFOLDER"/"${FILES_TO_DELETE[-1]}"\"}"
	fi
	dropbox_del_obj=$dropbox_del_obj"]}"

	# Api POST call to delete
	DELETE_ID=$(curl -s -X POST https://api.dropboxapi.com/2/files/delete_batch \
	    --header "Authorization: Bearer "$DROPBOX_APITOKEN \
	    --header "Content-Type: application/json" \
	    --data $dropbox_del_obj | jq -r .async_job_id)

	echo "Cleanup job sent!"
	echo "SESSION ID -> "$DELETE_ID
	echo

	# Choose whether to include here or not (on a verbose toggle maybe)
	check_delete_dropbox
	echo
}


# RUN CLEANUP
#-----------------

BACKUP_LOC_OPTIONS=( "local" "dropbox" )
function run_backup_cleanup {
	# Choose cleanup location from arg passed
	j=0
	for option in ${BACKUP_LOC_OPTIONS[@]}
	do
		if [ "$1" = "$option" ] ; then
			CLEANUP_LOC=${BACKUP_LOC_OPTIONS[j]}
		fi
		((++j))
	done
	if [ -z $CLEANUP_LOC ] ; then
		echo "No valid cleanup options found..."
		return 1
	fi

	# Execute cleanup
	echo
	echo "Starting cleanup of older backup files..."
	echo "-----"
	echo "Max number of backups: "$KEEP_MAX
	get_files_$CLEANUP_LOC
	echo "Backups found: "${#FILES[@]}
	echo
	make_delete_list
	delete_files_$CLEANUP_LOC
	echo
	echo "Cleanup done!"
	echo "-----"
	/bin/sleep 0.25s
	echo "Kept   : "${#FILES_TO_KEEP[@]}" files"
	echo "Deleted: "${#FILES_TO_DELETE[@]}" files"
}

if [ ! -z $KEEP_MAX ] ; then
	run_backup_cleanup $BACKUP_LOC
fi

#====================================
# FINISH
#====================================

echo
echo " Done!"
echo "======="
