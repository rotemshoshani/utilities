Look at my recent screenshots and help me with them.

Arguments: $ARGUMENTS

Parse the arguments as follows:
- If the first word is a number N, read the N most recent screenshots. The rest of the arguments are the instruction for what to do with them.
- If there is no number, default to reading the 1 most recent screenshot. All arguments are the instruction.
- If there is no instruction, describe what you see in the screenshots.

To find the most recent screenshots, run this command (adjust N to the number needed):
```
ls -t ~/Pictures/*.png | head -N
```

Then use the Read tool to read each screenshot file path returned. Claude Code can view images natively.

After reading the screenshots, follow the user's instruction about them.
