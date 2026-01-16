#!/bin/bash
# Script to output the operators for an image-set config file

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

source <(normalize-aba-conf)
source <(normalize-mirror-conf)

verify-aba-conf || exit 1
verify-mirror-conf || exit 1

export ocp_ver=$ocp_version
export ocp_ver_major=$(echo $ocp_version | cut -d. -f1-2)

declare -A added_operators  # Associative array to track added operators
op_names_arr=()  # Array to output op. list 

add_op() {
	local op=$1
	local catalog=$2

	# Extract operator name and default channel from the file
	read op_name op_default_channel < <(grep "^$op " .index/$catalog-index-v$ocp_ver_major | awk '{print $1, $NF}')

	# Check if the operator name exists
	if [ "$op_name" ]; then
		# Skip if the operator has already been added
		if [ -n "${added_operators[$op_name]}" ]; then
			aba_info "Operator '$op_name' already added. Skipping..." >&2
			return
		fi

		# Mark the operator as added
		added_operators["$op_name"]=1
		op_names_arr+=("$op_name")

		# Output the operator information
		if [ "$op_default_channel" ]; then
			cat <<-END
			    - name: $op_name
			      channels:
			      - name: "$op_default_channel"
			END
		else
			cat <<-END
			    - name: $op_name
			END
		fi
	else
		aba_warning "Operator '$op' not found in index file .index/$catalog-index-v$ocp_ver_major"
	fi
}

# If operators are given, ensure the catalogs are available!
if [ "$ops" -o "$op_sets" ]; then
	# Start catalog downloads (idempotent - skips if already done) and wait
	aba_debug "Ensuring catalog indexes for OCP $ocp_ver_major are available"
	download_all_catalogs "$ocp_ver_major" 86400  >&2 # Start downloads (idempotent)
	wait_for_all_catalogs "$ocp_ver_major"  >&2       # Wait for completion
	# If wait succeeds, the catalog files are guaranteed to exist
else
	aba_info "No operators to add to the image-set config file since values ops or op_sets not defined in aba.conf or mirror.conf." >&2

	exit 0
fi

aba_info "Adding operators to the image-set config file ..."  >&2


# 'all' is a special operator set which allows all operators to be downloaded!  The below "operators->catalog" entry will enable all op.
if echo $op_sets | grep -qe "^all$" -e "^all," -e ",all$" -e ",all,"; then
	aba_info_ok "Adding all redhat-operator operators to your image-set config file!" >&2
	cat <<-END
	  operators:
	  - catalog: registry.redhat.io/redhat/redhat-operator-index:v$ocp_ver_major
	    packages:
	END

	exit 0
fi

redhat_operators=()
certified_operators=()
community_operator=()

# Step though all the operator sets and determine which catalog they exist in,
# with priority order: redhat-operator, certified-operator, community-operator
# Operator names are selected from the catalogs in the above catalog order.
for op_set_name in $(echo $op_sets | tr "," " ")
do
	declare -A op_set_array

	# read in op list from template
	if [ -s templates/operator-set-$op_set_name ]; then
		aba_info -n "$op_set_name: " >&2  # Keep as aba_info

		for op in $(cat templates/operator-set-$op_set_name | sed -e 's/#.*//' -e '/^\s*$/d' -e 's/^\s*//g' -e 's/\s*$//g')
		do
			echo_white -n "$op " >&2  # Keep as echo_white

			# Check if this operator exists in each of the three catalogs
			if grep -q "^$op " .index/redhat-operator-index-v$ocp_ver_major; then
				[ ! "${op_set_array[$op_set_name]}" ] && redhat_operator+=("#-$op_set_name-operators") && op_set_array[$op_set_name]=1 # A bit of a hack!
				redhat_operator+=("$op")
			elif grep -q "^$op " .index/certified-operator-index-v$ocp_ver_major; then
				[ ! "${op_set_array[$op_set_name]}" ] && certified_operator+=("#-$op_set_name-operators") && op_set_array[$op_set_name]=1
				certified_operator+=("$op")
			elif grep -q "^$op " .index/community-operator-index-v$ocp_ver_major; then
				[ ! "${op_set_array[$op_set_name]}" ] && community_operator+=("#-$op_set_name-operators") && op_set_array[$op_set_name]=1
				community_operator+=("$op")
			fi
		done
	else
		# Should never reach here, but just in case...
		aba_warning \
			"Missing operator set file: 'templates/operator-set-$op_set_name'." \
			"Please adjust your operator settings (in aba.conf) or create the missing file: aba -d mirror catalog"
	fi
done

# Step though all the operators and determine which catalog they exist in,
# with priority order: redhat-operator, certified-operator, community-operator
# Operator names are selected from the catalogs in the above catalog order.
if [ "$ops" ]; then
	declare -A op_set_array
	op_set_name=misc

	echo >&2
	aba_info -n "$op_set_name: " >&2 # Keep as aba_info

	for op in $(echo $ops | tr "," " ")
	do
		echo_white -n "$op " >&2 # Keep as echo_

		# Check if this operator exists in each of the three catalogs
		if grep -q "^$op " .index/redhat-operator-index-v$ocp_ver_major; then
			[ ! "${op_set_array[$op_set_name]}" ] && redhat_operator+=("#-$op_set_name-operators") && op_set_array[$op_set_name]=1 # A bit of a hack!
			redhat_operator+=("$op")
		elif grep -q "^$op " .index/certified-operator-index-v$ocp_ver_major; then
			[ ! "${op_set_array[$op_set_name]}" ] && certified_operator+=("#-$op_set_name-operators") && op_set_array[$op_set_name]=1
			certified_operator+=("$op")
		elif grep -q "^$op " .index/community-operator-index-v$ocp_ver_major; then
			[ ! "${op_set_array[$op_set_name]}" ] && community_operator+=("#-$op_set_name-operators") && op_set_array[$op_set_name]=1
			community_operator+=("$op")
		fi
	done
else
	echo >&2
	aba_info "No 'ops' value set in aba.conf or mirror.conf. No individual operators to add to the image-set config file." >&2
fi


# Only output if there are operators! 
# Stderr is for app output
echo >&2
# Stdout is for the image-set config output
echo "  operators:"

for catalog in redhat_operator certified_operator community_operator
do
	list=$(eval echo '${'$catalog'[@]}')   # This is a bit of a hack
	catalog_name=$(echo $catalog | sed "s/_/-/g")

	if [ "$list" ]; then
		aba_debug "Print operator 'heading' for $catalog_name-index:v$ocp_ver_major"

		cat <<-END
		  - catalog: registry.redhat.io/redhat/$catalog_name-index:v$ocp_ver_major
		    packages:
		END

		aba_debug Stepping through list of operators: $list 

		for op in $list
		do
			echo $op | grep -q "^#" && echo $op | sed "s/-/ /g" >&2 && continue  # Print just the operator "heading" (a hack)

			aba_debug Adding operator: $op from catalog: $catalog_name
			add_op $op $catalog_name
		done
	fi
done

#echo >&2
aba_info_ok "Number of operators added: ${#op_names_arr[@]}:" >&2
aba_info_ok "${op_names_arr[@]}" >&2

exit 0
