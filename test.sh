DROPBOX_APITOKEN=""
DEVICE=$(echo $(cat /etc/hostname))
BACKUPFOLDER=.lndbackup-$DEVICE

# Hardcoded constants
KEEP_MAX=5
KEEP_STOP=7
GREP_KEEP=stop


#-----------------
# SHARED FUNCTIONS

# Pass 2 integers (KEEP_MAX, KEEP_STOP) and 2 arrays (FILES_STOP, FILES_NOSTOP)
function make_delete_list {
	if [[ $KEEP_STOP -gt $KEEP_MAX ]] ; then
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
}

#-----------------
# LOCAL FILES FUNCTIONS

# Get all files commands
function get_files_local {
	GREP_FILES='\S*\.tar|\S*\.gpg$'
	FILES=( $(ls -ctalh | grep -Po $GREP_FILES) )
	FILES_STOP=( $(ls -ctalh | grep -Po $GREP_FILES | grep $GREP_KEEP) )
	FILES_NOSTOP=( $(ls -ctalh | grep -Po $GREP_FILES | grep -v $GREP_KEEP) )
}

# Delete function taking the "FILES_TO_DELETE" array as input
function delete_files_local {
	rm ${FILES_TO_DELETE[@]} 2> /dev/null
	ls -clth
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


#-----------------
# RUN CLEANUP

#get_files_local
get_files_dropbox
make_delete_list
#delete_files_local


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
