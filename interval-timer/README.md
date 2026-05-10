# Interval Timer

Open `index.html` in a browser.

CSV import expects a header row with:

```csv
name,work,rest,repeat
Pushups,45,15,4
Squats,00:30,00:10,3
```

`work` and `rest` can be seconds, `MM:SS`, or values like `1m 30s`.

Saved templates can be edited, exported back to CSV, or deleted after confirmation.

The runner uses MP3 files in `Audio/` before falling back to browser speech synthesis. Current mapped files:

- `Roll.mp3`
- `Lunge ISO.mp3`
- `Calf Raises.mp3`
- `Hamstring Stretch.mp3`
- `Squat.mp3`
- `Jump.mp3`
- `Curls-Swings-Cycle.mp3`
- `Rest.mp3`
- `Next.mp3`

Firefox depends on local OS voices. If it shows `No voice`, install/enable a system TTS voice or run the app in a browser with built-in speech voices.
