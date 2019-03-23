function reset_arrs {
	arr=( 'aa' 'bb2' 'dd' 'ee' 'cc' 'bb3' 'dd' 'ee' 'bb4' )
	arr2=( 'bb1' 'bbs1' 'bbs2' )
	temp=( "${arr[@]}" )

	echo
	echo ${arr[@]}
	echo ${arr2[@]}
	echo
}


# Function to ensure that 'non-state stops' dont get overwritten
# by inflight backups should a large number of inflights be made
# after a legitimate 'non-state stop' backup.
#
# e.g. in case lnd was inactive and the script restarted it with
# one good 'non-state stop' backup as the latest good stopped
# backup.

function swap_files {
	move_search=*'bb'*
	move_exclude=*'s'*
	num_to_move=$1

	# set num_to_move so that swaps don't exceed 2nd array length
	num_to_move=$(( ${#arr2[@]} > $num_to_move ? $num_to_move : ${#arr2[@]} ))

	# Set num_to_move to actually be 'num to remain' in 2nd array
	count2=0
	for file2 in ${arr2[@]}
	do
		if [[ $file2 == $move_search ]] && [[ ! $file2 == $move_exclude ]] ; then
			((++count2))
		fi
	done
	num_to_move=$(( $num_to_move - $count2 ))


	# Execute swap across both arrays
	i=0
	count=0
	for file in ${arr[@]}
	do
		if [[ $file == $move_search ]] && [ $count -lt $num_to_move ] ; then
			unset 'temp[$(($i-$count))]'
			temp=( "${temp[@]}" "${arr2[-1]}" )
			unset 'arr2[-1]'
			arr2=( "$file" "${arr2[@]}" )
			((++count))
		fi
		((++i))
	done
	arr=( "${temp[@]}" )

	echo "Pass "$1
	echo "---"
	echo ${arr[@]}
	echo ${arr2[@]}
	echo

}

reset_arrs
swap_files 1

reset_arrs
swap_files 2

reset_arrs
swap_files 3

reset_arrs
swap_files 4
