Upload all changes to GitHub by running the following command:

1. Run `git diff` and `git status` to understand what changed
2. Craft a concise, relevant commit message describing the actual changes
3. Run:

```
git add . && git commit -m "[PC/$(date +%Y-%m-%d)] <relevant commit message>" && git push
```

Replace `<relevant commit message>` with a short summary of the changes (e.g. "Add retry logic to API client" or "Fix phase execution ordering").
