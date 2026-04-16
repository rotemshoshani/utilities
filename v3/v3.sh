SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPENAI_API_KEY=$(grep "^OPENAI_API_KEY=" "$SCRIPT_DIR/.env.local" | cut -d '=' -f 2-)

project=$(basename $(pwd))
tmux_name="gsd-auto-${project}"

sleep 10

tmux_output=$(cat /tmp/gsd-output.txt)

system_prompt='
You are a CLI automation controller. You read the last few lines of terminal output from a GSD framework session and decide what command to run next.

The presence of /clear in the output means the step completed successfully. Your ONLY job is to pick the next command.

Rules:
- Return ONLY one of these three things, nothing else:
  1. /gsd-plan-phase N --research (where N is the phase number you see in the output)
  2. /gsd-execute-phase N (where N is the phase number)
  3. The word DONE (if all phases are complete)
- The output often suggests multiple commands with different flags. Pick ONLY /gsd-plan-phase or /gsd-execute-phase. Ignore suggestions for /gsd-ui-phase, /gsd-discuss-phase, /gsd-list-phase-assumptions, etc.
- /gsd-plan-phase must always include --research
- Never explain, never add quotes, never add markdown. Return the command and nothing else.
- Ignore the CLI status bar and prompt lines at the bottom (lines with symbols like ❯, ⏵, ░, etc.)
- If you truly cannot determine a next phase command, return DONE
'

gpt_request=$(jq -n --arg o "$tmux_output" --arg s "$system_prompt"  '{
    "model": "gpt-4o-mini",
    "messages": [
      {
        "role": "system",
        "content": $s
      },
      {
        "role": "user",
        "content": $o
      }
    ]
  }' 
)

raw_response=$(curl https://api.openai.com/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $OPENAI_API_KEY" \
  -d "$gpt_request")

echo "$raw_response" >> /tmp/gsd-auto-debug.log                                                     

gpt_output=$(echo "$raw_response" | jq -r '.choices[0].message.content')                            


echo "$gpt_output" >> /tmp/gsd-auto-debug.log

if [[  "$gpt_output" == "HUMAN" ]]; then
	echo human
elif [[ "$gpt_output" == "DONE" ]]; then
	echo done
else
	tmux send-keys -t "$tmux_name" "/clear" Enter
  sleep 5
	tmux send-keys -t "$tmux_name" "$gpt_output" Enter
fi
