#!/bin/bash -e
# Basic/primitive tests for aba interactive mode

#cd $(dirname $0)

./install
cp aba $(which aba) -v || exit 1

aba reset -f

########################
[ -s aba.conf ] && sed -i -e "s/^ocp_channel=.*/ocp_channel=/g" -e "s/^ocp_version=.*/ocp_version=/g" -e "s/^editor=.*/editor=/g" aba.conf
for i in f 4.20 cat y n y   # use cat just to test with!
do
	echo -e "$i"
done | aba > test/.test.log
echo aba returned: $?
echo Verifying ...
# Verify
cat aba.conf | grep -E -o "^ocp_channel=fast"
cat aba.conf | grep -E -o "^ocp_version=4\.20\.[0-9]+"
cat aba.conf | grep -E -o "^editor=cat"
cat test/.test.log | grep "^Fully Disconnected"
cat test/.test.log | grep "^Partially Disconnected"

########################
[ -s aba.conf ] && sed -i -e "s/^ocp_channel=.*/ocp_channel=/g" -e "s/^ocp_version=.*/ocp_version=/g" -e "s/^editor=.*/editor=/g" aba.conf
for i in f 4.20 none   # After none, user is asked to edit aba.,conf manually
do
	echo -e "$i"
done | aba > test/.test.log
echo aba returned: $?
echo Verifying ...
# Verify
cat aba.conf | grep -E -o "^ocp_channel=fast"
cat aba.conf | grep -E -o "^ocp_version=4\.20\.[0-9]+"
cat aba.conf | grep -E -o "^editor=none"
! cat test/.test.log | grep "^Fully Disconnected"
! cat test/.test.log | grep "^Partially Disconnected"

########################
[ -s aba.conf ] && sed -i -e "s/^ocp_channel=.*/ocp_channel=/g" -e "s/^ocp_version=.*/ocp_version=/g" -e "s/^editor=.*/editor=/g" aba.conf
for i in s 4.19 vi n y
do
	echo -e "$i"
done | aba > test/.test.log
echo aba returned: $?
echo Verifying ...
# Verify
cat aba.conf | grep -E -o "^ocp_channel=stable"
cat aba.conf | grep -E -o "^ocp_version=4\.19\.[0-9]+"
cat aba.conf | grep -E -o "^editor=vi"
! cat test/.test.log | grep "^Fully Disconnected"
! cat test/.test.log | grep "^Partially Disconnected"

echo
echo "ALL INTERACTIVE TESTS PASSED!!"

