#!/bin/bash
# Script to output the operators for an image-set config file
#
# Usage: add-operators-to-imageset.sh --output <yaml-file>
#
# This script appends operator configuration to an imageset YAML file.
# All user messages go to stderr, YAML content goes to the specified file.

source scripts/include_all.sh

# Parse command line arguments
OUTPUT_FILE=""
while [[ $# -gt 0 ]]; do
	case $1 in
		--output|-o)
			OUTPUT_FILE="$2"
			shift 2
			;;
		*)
			echo "Error: Unknown option: $1" >&2
			echo "Usage: $0 --output <yaml-file>" >&2
			exit 1
			;;
	esac
done

# Validate output file parameter
if [[ -z "$OUTPUT_FILE" ]]; then
	echo "Error: --output parameter is required" >&2
	echo "Usage: $0 --output <yaml-file>" >&2
	exit 1
fi

aba_debug "Starting: $0 --output $OUTPUT_FILE"

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
		cat <<-END >> "$OUTPUT_FILE"
		    - name: $op_name
		      channels:
		      - name: "$op_default_channel"
		END
	else
		cat <<-END >> "$OUTPUT_FILE"
		    - name: $op_name
		END
	fi
	else
		aba_warning "Operator '$op' not found in index file mirror/.index/$catalog-index-v$ocp_ver_major"
	fi
}

# If operators are given, ensure the catalogs are available!
if [ "$ops" -o "$op_sets" ]; then
	aba_debug "add-operators-to-imageset.sh: ops='$ops' op_sets='$op_sets' - calling wait_for_all_catalogs for OCP $ocp_ver_major"
	# Wait for all catalogs to complete (Makefile dependency should have started them)
	# Note: Makefile has 'catalog' as dependency, so downloads should already be in progress
	if ! wait_for_all_catalogs "$ocp_ver_major"; then
		aba_abort \
			"Catalog downloads failed or timed out for OCP $ocp_ver_major" \
			"Your options are:" \
			"- Check network connectivity" \
			"- Increase timeout in ~/.aba/config (CATALOG_DOWNLOAD_TIMEOUT_MINS)" \
			"- Run './install' to clear cache and retry" \
			"- Check that the following command works:" \
			"    oc-mirror list operators --catalog registry.redhat.io/redhat/redhat-operator-index:v$ocp_ver_major"
	fi

	# Verify catalog files exist (only check the 3 main catalogs we download)
	catalog_file_errors=
	for catalog in redhat-operator certified-operator community-operator
	do
		# Check for the index file
		if [ ! -s .index/$catalog-index-v$ocp_ver_major ]; then
			catalog_file_errors=1
			aba_warning "Missing operator catalog file: $PWD/.index/$catalog-index-v$ocp_ver_major" >&2
		fi
	done

    	if [ "$catalog_file_errors" ]; then
		aba_abort \
			"Cannot add required operators to the image-set config file!" \
			"Your options are:" \
			"- Refresh any existing catalog files by running: 'cd $PWD; rm -f .index/redhat-operator-index-v${ocp_ver_major}*' and try again." \
			"- run 'cd mirror; aba catalog' to try to download the catalog file again." \
			"- Check that the following command is working:" \
			"    oc-mirror list operators --catalog registry.redhat.io/redhat/redhat-operator-index:v$ocp_ver_major" \
			"- Check access to registry is working: 'curl -IL http://registry.redhat.io/v2'" 
		# We want to ensure the user gets what they expect, i.e. operators downloaded! So we abort.
	fi
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
redhat_marketplace=()
community_operator=()

# Step though all the operator sets and determine which catalog they exist in,
# with priority order: redhat-operator, certified-operator, redhat-marketplace, community-operator
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
			elif grep -q "^$op " .index/redhat-marketplace-index-v$ocp_ver_major; then
				[ ! "${op_set_array[$op_set_name]}" ] && redhat_marketplace+=("#-$op_set_name-operators") && op_set_array[$op_set_name]=1
				redhat_marketplace+=("$op")
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
# with priority order: redhat-operator, certified-operator, redhat-marketplace, community-operator
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
		elif grep -q "^$op " .index/redhat-marketplace-index-v$ocp_ver_major; then
			[ ! "${op_set_array[$op_set_name]}" ] && redhat_marketplace+=("#-$op_set_name-operators") && op_set_array[$op_set_name]=1
			redhat_marketplace+=("$op")
		elif grep -q "^$op " .index/community-operator-index-v$ocp_ver_major; then
			[ ! "${op_set_array[$op_set_name]}" ] && community_operator+=("#-$op_set_name-operators") && op_set_array[$op_set_name]=1
			community_operator+=("$op")
		fi
	done
else
	if [ "$op_sets" ]; then
		# We have op_sets but no individual ops - this is fine, don't show confusing message
		:
	else
		echo >&2
		aba_info "No 'ops' value set in aba.conf or mirror.conf. No individual operators to add to the image-set config file." >&2
	fi
fi


# Only output if there are operators! 
echo >&2
# Write YAML to output file
echo "  operators:" >> "$OUTPUT_FILE"

for catalog in redhat_operator certified_operator redhat_marketplace community_operator
do
	list=$(eval echo '${'$catalog'[@]}')   # This is a bit of a hack
	catalog_name=$(echo $catalog | sed "s/_/-/g")

	if [ "$list" ]; then
		aba_debug "Print operator 'heading' for $catalog_name-index:v$ocp_ver_major"

		cat <<-END >> "$OUTPUT_FILE"
		  - catalog: registry.redhat.io/redhat/$catalog_name-index:v$ocp_ver_major
		    packages:
		END

		aba_debug Stepping through list of operators: $list 

		for op in $list
		do
			# If this is a comment marker (e.g., #-mesh3-operators), format it as a YAML comment
			if echo $op | grep -q "^#"; then
				# Convert #-mesh3-operators to "    # mesh3 operators" (4 spaces for YAML indentation)
				echo "    $(echo $op | sed 's/-/ /g')" >> "$OUTPUT_FILE"
				continue
			fi

			aba_debug Adding operator: $op from catalog: $catalog_name
			add_op $op $catalog_name
		done
	fi
done

#echo >&2
aba_info_ok "Number of operators added: ${#op_names_arr[@]}:" >&2
aba_info_ok "${op_names_arr[@]}" >&2

exit 0
