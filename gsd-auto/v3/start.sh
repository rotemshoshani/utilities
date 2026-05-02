project=$(basename $(pwd))
tmux_name="gsd-auto-${project}"

if tmux has-session -t "$tmux_name" 2>/dev/null; then
    tmux kill-session -t "$tmux_name" 2>/dev/null
fi

tmux new-session -d -s "$tmux_name"
tmux set-option -t "$tmux_name" mouse on
tmux set-option -t "$tmux_name" history-limit 50000

sleep 5
tmux send-keys -t "$tmux_name" "claude --dangerously-skip-permissions --model default" Enter
sleep 10

if tmux has-session -t "$tmux_name" 2>/dev/null; then
    tmux attach-session -t "$tmux_name"
fi