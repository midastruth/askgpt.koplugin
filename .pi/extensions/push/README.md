# Pi `/push` extension

Adds a `/push` slash command for Pi.

When invoked, `/push` injects the user message:

> Please push this worktree to GitHub main.

The extension then synthesizes a built-in `bash` tool call that runs a safe Git push workflow. It detects the Git worktree, verifies `origin` exists and appears to be GitHub, shows the current branch and `git status --short`, refuses dirty worktrees, fetches `origin main`, and pushes the current `HEAD` to `origin/main` with:

```bash
git push origin HEAD:main
```

Safety notes:

- pushes current `HEAD` to `origin/main`;
- refuses to run with uncommitted changes;
- never runs `git add` or `git commit`;
- never force-pushes;
- never pushes tags.
