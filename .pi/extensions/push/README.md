# Pi `/push` extension

Adds a `/push` slash command for Pi.

When invoked, `/push` injects the user message:

> Please push this worktree to GitHub main.

The extension then switches to a synthetic internal model that emits a built-in `bash` tool call. The bash tool result is recorded normally in the conversation.

Workflow:

1. Detect the Git worktree.
2. Verify `origin` exists and appears to be GitHub.
3. Show the current branch and `git status --short`.
4. Refuse dirty worktrees.
5. Fetch `origin main`.
6. Push the current `HEAD` to `origin/main` with:

   ```bash
   git push origin HEAD:main
   ```

7. If the push succeeds, create a GitHub release:
   - uses `_meta.lua` `version = "..."` when available;
   - falls back to `package.json` `version`;
   - otherwise uses a timestamp plus commit SHA;
   - for KOReader-style Lua plugins, builds and uploads a zip asset from tracked plugin Lua files;
   - refuses to overwrite an existing release tag.
8. If any step fails, restore the user's previously selected model and send the captured bash output to that model so it can explain the likely cause and suggest next steps.

Safety notes:

- pushes current `HEAD` to `origin/main`;
- refuses to run with uncommitted changes;
- never runs `git add` or `git commit`;
- never force-pushes;
- creates a GitHub release only after the push succeeds;
- does not overwrite existing releases.
