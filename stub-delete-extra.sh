DROPBOX_APITOKEN=""
DEVICE=$(echo $(cat /etc/hostname))
BACKUPFOLDER=.lndbackup-$DEVICE

# Hardcoded constants
KEEP_MAX=20
KEEP_STOP=7
GREP_KEEP='stop.*state'


#-----------------
# SHARED FUNCTIONS


# Function to ensure that 'non-state stops' dont get overwritten
# by inflight backups should a large number of inflights be made
# after a legitimate 'non-state stop' backup.
#
# e.g. scenario: if lnd was inactive and the script restarted it
# with one good 'non-state stop' backup as the latest good stopped
# backup of the .lnd folder.
function swap_files {
	# Note: This num_to_move takes the highest priority. It edges inflight backups
	# out first and then 'stopped-state' backups after. Keep lower than KEEP_STOP
	# to ensure 'stopped-state' backups aren't all deleted.
	num_to_move=1

        move_search=*'stop'*
        move_exclude=*'state'*
        temp=( "${FILES_TO_DELETE[@]}" )

        # Set num_to_move so that swaps don't exceed 2nd array length
        num_to_move=$(( ${#FILES_TO_KEEP[@]} > $num_to_move ? $num_to_move : ${#FILES_TO_KEEP[@]} ))
	echo "Num to move: "$num_to_move

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

#-----------------
# LOCAL FILES FUNCTIONS

# Get all files commands
function get_files_local {
	GREP_FILES='\S*\.tar$|\S*\.gpg$'
	FILES=( $(ls -ctalh | grep -Po $GREP_FILES) )
	FILES_STOP=( $(ls -ctalh | grep -Po $GREP_FILES | grep -P $GREP_KEEP) )
	FILES_NOSTOP=( $(ls -ctalh | grep -Po $GREP_FILES | grep -v $GREP_KEEP) )
}

# Delete function taking the "FILES_TO_DELETE" array as input
function delete_files_local {
	rm ${FILES_TO_DELETE[@]} 2> /dev/null
	ls -clth
	echo
}


#-----------------
# DROPBOX FILES FUNCTIONS

function get_files_dropbox {
	FILES=( $(curl -s -X POST https://api.dropboxapi.com/2/files/list_folder \
	    --header "Authorization: Bearer "$DROPBOX_APITOKEN \
	    --header "Content-Type: application/json" \
	    --data "{\"path\": \"/"$BACKUPFOLDER"\",\"recursive\": false,\"include_media_info\": false,\"include_deleted\": false,\"include_has_explicit_shared_members\": false,\"include_mounted_folders\": true}" \
	    | jq -r .entries[].name) )
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
		echo
	fi
}

function delete_files_dropbox {
	# Assemble Dropbox delete object
	#BACKUPFOLDER="test-delete"
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
	echo "-----"
	echo "cleaning up extra files..."
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


#-----------------
# RUN CLEANUP

#get_files_local
get_files_dropbox

make_delete_list

#delete_files_local
delete_files_dropbox


echo "Files: "${FILES[@]}
echo
echo "Max: "$KEEP_MAX
echo
echo "Total: "$(( ${#FILES_STOP[@]} + ${#FILES_NOSTOP[@]} ))
echo "---"
echo
echo "Delete: "$(( ${#FILES_STOP_DELETE[@]} + ${#FILES_NOSTOP_DELETE[@]} ))
echo
echo "Files to delete: "${FILES_TO_DELETE[@]}
echo
echo "Files to keep: "${FILES_TO_KEEP[@]}
echo
echo "-----"
