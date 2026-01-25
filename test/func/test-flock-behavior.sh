#!/bin/bash
# Test flock behavior with killed processes

TEST_LOCK="/tmp/test-flock.lock"
rm -f "$TEST_LOCK"

echo "════════════════════════════════════════════════════════════════"
echo "Test 1: Basic flock acquisition and release"
echo "════════════════════════════════════════════════════════════════"

# Process 1: Acquire lock and sleep
(
	exec 9>>"$TEST_LOCK"
	flock -x 9
	echo "Process $$ acquired lock"
	sleep 10
	echo "Process $$ releasing lock"
) &
PID1=$!

sleep 1

# Process 2: Try to acquire same lock (should block)
echo "Process 2 trying to acquire lock (should block)..."
timeout 2 bash -c "exec 9>>$TEST_LOCK && flock -x 9 && echo 'Process 2 got lock'" &
PID2=$!

sleep 1
echo "Killing Process 1 (PID $PID1)..."
kill -9 $PID1
wait $PID1 2>/dev/null
echo "Process 1 killed"

echo "Waiting for Process 2..."
wait $PID2
RC=$?
if [ $RC -eq 124 ]; then
	echo "❌ Process 2 timed out (lock not released)"
elif [ $RC -eq 0 ]; then
	echo "✅ Process 2 got lock (kernel released it)"
else
	echo "⚠️  Process 2 exited with code $RC"
fi

echo
echo "════════════════════════════════════════════════════════════════"
echo "Test 2: Subshell holding lock, child killed"
echo "════════════════════════════════════════════════════════════════"

rm -f "$TEST_LOCK"

# Subshell that acquires lock, spawns child, waits for child
(
	exec 9>>"$TEST_LOCK"
	flock -x 9
	echo "Subshell $$ acquired lock, starting child..."
	sleep 999 &
	CHILD_PID=$!
	echo "Child PID: $CHILD_PID"
	echo $CHILD_PID > /tmp/test-child-pid
	wait $CHILD_PID
	echo "Subshell: child exited with $?"
) &
SUBSHELL_PID=$!
echo "Subshell PID: $SUBSHELL_PID"

sleep 1

# Another process tries to acquire lock
echo "Process 2 trying to acquire lock (should block)..."
(
	echo "Attempting lock acquisition at $(date +%H:%M:%S)"
	exec 9>>"$TEST_LOCK"
	if flock -w 5 -x 9; then
		echo "✅ Got lock at $(date +%H:%M:%S)"
	else
		echo "❌ Timeout acquiring lock at $(date +%H:%M:%S)"
	fi
) &
PID2=$!

sleep 1

# Kill ONLY the child (not the subshell)
CHILD_PID=$(cat /tmp/test-child-pid)
echo "Killing child PID $CHILD_PID (not subshell)..."
kill -9 $CHILD_PID
echo "Child killed at $(date +%H:%M:%S)"

echo "Waiting to see if subshell releases lock..."
wait $PID2
wait $SUBSHELL_PID 2>/dev/null
echo "Test complete at $(date +%H:%M:%S)"

echo
echo "════════════════════════════════════════════════════════════════"
echo "Test 3: Kill entire process group"
echo "════════════════════════════════════════════════════════════════"

rm -f "$TEST_LOCK"

# Create process group with setsid
setsid bash -c '
	exec 9>>"/tmp/test-flock.lock"
	flock -x 9
	echo "Process group $$ acquired lock"
	sleep 999 &
	CHILD_PID=$!
	echo $CHILD_PID > /tmp/test-pgid
	wait $CHILD_PID
' &
sleep 1

PGID=$(cat /tmp/test-pgid)
echo "Process group leader: $PGID"

# Try to get lock
echo "Process 2 trying to acquire lock..."
(
	echo "Attempting lock at $(date +%H:%M:%S)"
	exec 9>>"$TEST_LOCK"
	if flock -w 3 -x 9; then
		echo "✅ Got lock at $(date +%H:%M:%S)"
	else
		echo "❌ Timeout at $(date +%H:%M:%S)"
	fi
) &
PID2=$!

sleep 1

echo "Killing entire process group -$PGID..."
kill -9 -$PGID 2>/dev/null
echo "Process group killed at $(date +%H:%M:%S)"

wait $PID2
echo "Test complete at $(date +%H:%M:%S)"

echo
echo "════════════════════════════════════════════════════════════════"
echo "Test 4: Measure lock release time after kill"
echo "════════════════════════════════════════════════════════════════"

rm -f "$TEST_LOCK"

# Acquire lock
(
	exec 9>>"$TEST_LOCK"
	flock -x 9
	sleep 999
) &
LOCK_PID=$!

sleep 1

# Start waiting process
START_TIME=$(date +%s)
(
	exec 9>>"$TEST_LOCK"
	flock -x 9
	END_TIME=$(date +%s)
	ELAPSED=$((END_TIME - START_TIME))
	echo "Lock acquired after ${ELAPSED} seconds"
) &
WAITER_PID=$!

sleep 1
echo "Killing lock holder at $(date +%H:%M:%S)..."
kill -9 $LOCK_PID

wait $WAITER_PID
echo "Test complete"

# Cleanup
rm -f "$TEST_LOCK" /tmp/test-child-pid /tmp/test-pgid

echo
echo "════════════════════════════════════════════════════════════════"
echo "Summary: Key findings about flock and process death"
echo "════════════════════════════════════════════════════════════════"

