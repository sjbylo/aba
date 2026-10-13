#!/bin/bash
# Hook: sessionStart — check if Telegram inbox watcher is running in Cursor
# If no Cursor-managed watcher is alive, remind the agent to restart it.

input=$(cat)

# Check if a Telegram inbox watcher loop is running (Cursor shell process)
# The watcher's command contains "TELEGRAM_MSG:" and "sleep 5"
if pgrep -f 'TELEGRAM_MSG.*sleep' >/dev/null 2>&1; then
	echo '{}' 
	exit 0
fi

# No watcher found — nudge the agent
echo '{
  "agent_message": "TELEGRAM WATCHER DOWN: The Telegram inbox watcher loop is not running. Restart it immediately using a background Shell with notify_on_output pattern TELEGRAM_MSG: — see the pattern used in previous chats. The telegram daemon (telegram-inbox.sh) is separate and likely still running; only the Cursor-side polling loop needs restarting."
}'
exit 0
