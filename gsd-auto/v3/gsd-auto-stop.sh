#!/bin/bash
# gsd-auto-stop.sh — Stop hook for gsd-auto v2
# When gsd-auto is waiting for a command to finish (marker file exists),
# signal completion by creating the done file.
# This fires on EVERY claude stop (including mid-skill pauses),
# so the auto-runner must verify via filesystem before acting.

# MARKER="$PWD/.planning/.gsd-auto-waiting"
# DONE="$PWD/.planning/.gsd-auto-done"

# if [ -f "$MARKER" ]; then
#    touch "$DONE"
# fi

# exit 0
echo "hook fired at $(date)" >> /tmp/gsd-hook-debug.log

project=$(basename $(pwd))
tmux_name="gsd-auto-${project}"

if tmux has-session -t "$tmux_name" 2>/dev/null; then
	echo "hook fired at $(date)" >> /tmp/gsd-hook-debug.log
	tmux capture-pane -t "$tmux_name" -p -S -25 > /tmp/gsd-output.txt
	if grep -q "/clear" /tmp/gsd-output.txt; then
		echo "hook fired at $(date)" >> /tmp/gsd-hook-debug.log
		bash ~/projects/gsd-auto/v3/v3.sh
	fi
fi
