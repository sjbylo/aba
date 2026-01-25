#!/bin/bash
# Test self-healing validation in run_once
# Verifies that tasks automatically recreate missing output files

set -e

cd "$(dirname "$0")/../.." || exit 1
source scripts/include_all.sh

# Use test runner directory to avoid conflicts
export RUN_ONCE_DIR="$HOME/.aba/runner-test-self-heal"
TEST_OUTPUT_DIR="/tmp/aba-test-self-heal-$$"

# Cleanup
cleanup() {
	rm -rf "$RUN_ONCE_DIR" "$TEST_OUTPUT_DIR"
}
trap cleanup EXIT
cleanup  # Clean any previous test runs

mkdir -p "$TEST_OUTPUT_DIR"

echo "======================================================================"
echo "Test 1: Task creates output, succeeds, output deleted, wait recreates"
echo "======================================================================"

output_file="$TEST_OUTPUT_DIR/test-output-1.txt"

# Create idempotent task that checks its output
task_cmd=(bash -c "
	if [[ -f '$output_file' ]]; then
		echo 'Output exists, nothing to do'
		exit 0
	fi
	echo 'Creating output file'
	echo 'test data' > '$output_file'
	exit 0
")

# Start task
echo "→ Starting task (creates output)..."
run_once -i "test:self-heal:1" -- "${task_cmd[@]}"

# Wait for completion
echo "→ Waiting for task to complete..."
run_once -w -i "test:self-heal:1"

# Verify output exists
if [[ ! -f "$output_file" ]]; then
	echo "❌ FAIL: Output file not created"
	exit 1
fi
echo "✓ Output file created"

# Delete the output file (simulate user deletion)
echo "→ Deleting output file (simulating user error)..."
rm -f "$output_file"

# Wait again - should trigger validation and recreate
echo "→ Waiting again (should trigger validation and self-heal)..."
run_once -w -i "test:self-heal:1"

# Verify output was recreated
if [[ ! -f "$output_file" ]]; then
	echo "❌ FAIL: Output file not recreated by self-heal"
	exit 1
fi
echo "✓ Output file recreated by self-heal validation"

echo ""
echo "======================================================================"
echo "Test 2: Output exists, wait runs quickly (no work)"
echo "======================================================================"

output_file2="$TEST_OUTPUT_DIR/test-output-2.txt"
counter_file="$TEST_OUTPUT_DIR/counter-2.txt"

# Task that increments a counter (to prove it ran)
task_cmd2=(bash -c "
	counter=0
	if [[ -f '$counter_file' ]]; then
		counter=\$(cat '$counter_file')
	fi
	counter=\$((counter + 1))
	echo \$counter > '$counter_file'
	
	if [[ -f '$output_file2' ]]; then
		echo 'Output exists, nothing to do'
		exit 0
	fi
	echo 'Creating output file'
	echo 'test data' > '$output_file2'
	exit 0
")

echo "→ Starting task..."
run_once -i "test:self-heal:2" -- "${task_cmd2[@]}"
run_once -w -i "test:self-heal:2"

# Counter should be 2 (first run + first validation)
count1=$(cat "$counter_file")
echo "✓ Counter after first wait: $count1"

if [[ "$count1" != "2" ]]; then
	echo "❌ FAIL: First validation didn't run (counter=$count1, expected 2)"
	exit 1
fi

# Wait again - should run validation again but exit quickly
echo "→ Waiting again (output exists, should exit quickly)..."
run_once -w -i "test:self-heal:2"

# Counter should be 3 (validation ran again)
count2=$(cat "$counter_file")
echo "✓ Counter after second validation: $count2"

if [[ "$count2" != "3" ]]; then
	echo "❌ FAIL: Second validation didn't run (counter=$count2, expected 3)"
	exit 1
fi

# But output should still exist (not recreated)
if [[ ! -f "$output_file2" ]]; then
	echo "❌ FAIL: Output file disappeared"
	exit 1
fi
echo "✓ Output file still exists (validation was quick)"

echo ""
echo "======================================================================"
echo "Test 3: Failed task doesn't retry on wait"
echo "======================================================================"

output_file3="$TEST_OUTPUT_DIR/test-output-3.txt"

# Task that fails
task_cmd3=(bash -c "
	echo 'Task failed intentionally'
	exit 1
")

echo "→ Starting task that fails..."
run_once -i "test:self-heal:3" -- "${task_cmd3[@]}"

# Wait should return failure
echo "→ Waiting (should return failure, no retry)..."
if run_once -w -i "test:self-heal:3"; then
	echo "❌ FAIL: Wait returned success for failed task"
	exit 1
fi
echo "✓ Wait correctly returned failure"

# Wait again - should NOT retry (exit ≠ 0)
echo "→ Waiting again (should NOT retry failed task)..."
if run_once -w -i "test:self-heal:3"; then
	echo "❌ FAIL: Wait returned success on retry"
	exit 1
fi
echo "✓ Failed task not retried"

echo ""
echo "======================================================================"
echo "Test 4: Wait without command uses saved command"
echo "======================================================================"

output_file4="$TEST_OUTPUT_DIR/test-output-4.txt"

# Task with command
task_cmd4=(bash -c "
	if [[ -f '$output_file4' ]]; then
		echo 'Output exists'
		exit 0
	fi
	echo 'Creating output'
	echo 'test data' > '$output_file4'
	exit 0
")

echo "→ Starting task WITH command..."
run_once -i "test:self-heal:4" -- "${task_cmd4[@]}"
run_once -w -i "test:self-heal:4"
echo "✓ Task completed"

# Delete output
rm -f "$output_file4"

# Wait WITHOUT providing command - should load saved command
echo "→ Waiting WITHOUT command (should load saved cmd and validate)..."
run_once -w -i "test:self-heal:4"  # No command!

# Verify output was recreated
if [[ ! -f "$output_file4" ]]; then
	echo "❌ FAIL: Saved command not executed"
	exit 1
fi
echo "✓ Saved command loaded and executed successfully"

echo ""
echo "======================================================================"
echo "Test 5: Lock held - validation skipped"
echo "======================================================================"

output_file5="$TEST_OUTPUT_DIR/test-output-5.txt"
echo "initial data" > "$output_file5"

# Long-running task
task_cmd5=(bash -c "
	if [[ -f '$output_file5' ]]; then
		echo 'Output exists'
	fi
	sleep 3  # Simulate long-running task
	exit 0
")

echo "→ Starting long-running task..."
run_once -i "test:self-heal:5" -- "${task_cmd5[@]}"

# Give it time to start
sleep 0.5

# Try to wait while it's running - validation should be skipped
echo "→ Waiting while task is running (validation should be skipped)..."
run_once -w -i "test:self-heal:5"

# Output should still exist (validation skipped because lock held)
if [[ ! -f "$output_file5" ]]; then
	echo "❌ FAIL: Output disappeared (validation ran while locked?)"
	exit 1
fi
echo "✓ Validation correctly skipped while task running"

echo ""
echo "======================================================================"
echo "✓ ALL TESTS PASSED"
echo "======================================================================"
