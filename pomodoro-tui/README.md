# Pomodoro TUI

Pomodoro++ is a terminal timer that splits work into smaller chunks. Instead of thinking about a full session, you only focus on the next cut, like running the next kilometer in a marathon.

## Run

```bash
python -m pomodoro_tui --work 10x5 --rest 10
```

Or after installing locally:

```bash
pip install -e .
pomopp --work 25 --rest 5
```

## Examples

```bash
# Regular Pomodoro: one 25 minute work chunk, then 5 minute rest
pomopp --work 25 --rest 5

# Pomodoro++: five 10 minute work cuts, then 10 minute rest
pomopp --work 10x5 --rest 10

# Award points based on work minutes instead of completed chunks
pomopp --work 10x5 --rest 10 --point-mode minutes
```

## Controls

- `Space`: pause or resume
- `n`: skip current interval
- `r`: reset current cycle
- `w`: edit work cut minutes
- `c`: edit cuts per cycle
- `b`: edit rest minutes
- `p`: toggle points mode
- `s`: save current settings as defaults
- `q`: quit

Stats are stored locally in `${XDG_DATA_HOME:-~/.local/share}/pomodoro-tui/stats.json`.
