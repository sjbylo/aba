#!/bin/bash
# Convenience script to download the latest operator catalog and add what's required into the imageset file. 

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
		aba_warning "Operator '$op' not found in index file mirror/.index/$catalog-index-v$ocp_ver_major"
	fi
}

if [ "$ops" -o "$op_sets" ]; then
	catalog_file_errors=
	for catalog in redhat-operator certified-operator redhat-marketplace community-operator
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
			"- Refresh any existing catalog files by running: 'cd $PWD/mirror; rm -f .index/redhat-operator-index-v${ocp_ver_major}*' and try again." \
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


# FIXME: What about the other catalogs? certified, marketplace and community?
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
for set in $(echo $op_sets | tr "," " ")
do
	declare -A op_set

	# read in op list from template
	if [ -s templates/operator-set-$set ]; then
		#echo "# $set operators"
		aba_info -n "$set: " >&2
		for op in $(cat templates/operator-set-$set | sed -e 's/#.*//' -e '/^\s*$/d' -e 's/^\s*//g' -e 's/\s*$//g')
		do
			aba_info -n "$op " >&2

			# Check if this operator exists in each of the three catalogs
			#echo op=$op
			#ls -l .index/redhat-operator-index-v$ocp_ver_major
			if grep -q "^$op " .index/redhat-operator-index-v$ocp_ver_major; then
				[ ! "${op_set[$set]}" ] && redhat_operator+=("#-$set-operators") && op_set[$set]=1 # A bit of a hack!
				redhat_operator+=("$op")
			elif grep -q "^$op " .index/certified-operator-index-v$ocp_ver_major; then
				[ ! "${op_set[$set]}" ] && certified_operator+=("#-$set-operators") && op_set[$set]=1
				certified_operator+=("$op")
			elif grep -q "^$op " .index/redhat-marketplace-index-v$ocp_ver_major; then
				[ ! "${op_set[$set]}" ] && redhat_marketplace+=("#-$set-operators") && op_set[$set]=1
				redhat_marketplace+=("$op")
			elif grep -q "^$op " .index/community-operator-index-v$ocp_ver_major; then
				[ ! "${op_set[$set]}" ] && community_operator+=("#-$set-operators") && op_set[$set]=1
				community_operator+=("$op")
			fi
		done
	else
		aba_warning "Missing operator set file: 'templates/operator-set-$set'.  Please adjust your operator settings (in aba.conf) or create the missing file."
	fi
done

# Step though all the operators and determine which catalog they exist in,
# with priority order: redhat-operator, certified-operator, redhat-marketplace, community-operator
# Operator names are selected from the catalogs in the above catalog order.
if [ "$ops" ]; then
	declare -A op_set
	set=misc

	echo_white -n "Operators: " >&2 # Keep as echo_white

	for op in $(echo $ops | tr "," " ")
	do
		echo_white -n "$op " >&2 # Keep as echo_white

		# Check if this operator exists in each of the three catalogs
		if grep -q "^$op " .index/redhat-operator-index-v$ocp_ver_major; then
			[ ! "${op_set1[$set]}" ] && redhat_operator+=("#-$set-operators") && op_set1[$set]=1 # A bit of a hack!
			redhat_operator+=("$op")
		elif grep -q "^$op " .index/certified-operator-index-v$ocp_ver_major; then
			[ ! "${op_set2[$set]}" ] && certified_operator+=("#-$set-operators") && op_set2[$set]=1
			certified_operator+=("$op")
		elif grep -q "^$op " .index/redhat-marketplace-index-v$ocp_ver_major; then
			[ ! "${op_set3[$set]}" ] && redhat_marketplace+=("#-$set-operators") && op_set3[$set]=1
			redhat_marketplace+=("$op")
		elif grep -q "^$op " .index/community-operator-index-v$ocp_ver_major; then
			[ ! "${op_set4[$set]}" ] && community_operator+=("#-$set-operators") && op_set4[$set]=1
			community_operator+=("$op")
		fi
	done
else
	aba_info "No 'ops' value set in aba.conf or mirror.conf. No individual operators to add to the image-set config file." >&2
fi

# Only output if there are operators! 
echo "  operators:"

for catalog in redhat_operator certified_operator redhat_marketplace community_operator
do
	list=$(eval echo '${'$catalog'[@]}')   # This is a bit of a hack
	c_name=$(echo $catalog | sed "s/_/-/g")

	if [ "$list" ]; then
		cat <<-END
		  - catalog: registry.redhat.io/redhat/$c_name-index:v$ocp_ver_major
		    packages:
		END

		for op in $list
		do
			echo $op | grep -q "^#" && echo $op | sed "s/-/ /g" && continue  # Print just the operator "heading" (a hack)
			add_op $op $c_name
		done
	fi
done

echo >&2
aba_info_ok "Number of operators added: ${#op_names_arr[@]}" >&2
aba_info_ok "Operators added: ${op_names_arr[@]}" >&2

exit 0
