# Repository Guidelines

## Project Structure & Module Organization
The plugin is self-contained in the repository root, with `main.lua` wiring the Ask ChatGPT highlight action, `dialogs.lua` handling user prompts, and `gpt_query.lua` performing HTTPS requests plus configuration lookup. `chatgptviewer.lua` renders responses, `_meta.lua` stores metadata, and `update_checker.lua` manages release notices. Device-specific secrets live in an untracked `configuration.lua`; avoid duplicating them elsewhere in source control.

## Build, Test, and Development Commands
- `rsync -av --delete . user@device:/mnt/onboard/koreader/plugins/askgpt.koplugin/`: Syncs the plugin to a KOReader device for live testing.
- `luacheck *.lua`: Lints all Lua sources to catch style and runtime issues.
- `zip -r askgpt.koplugin.zip . -x ".git/*" ".vscode/*" "configuration.lua"`: Packages a release-ready archive without local tooling or secrets.

## Coding Style & Naming Conventions
Use two-space indentation, keep lines under 120 characters, and follow KOReader patterns. Modules return tables with `UpperCamelCase` names (e.g., `Dialogs`), while locals prefer `lower_snake_case` unless surrounding code differs. Wrap user-visible strings with `_()` for gettext, align table keys for readability, and rely on `luacheck` for consistent formatting.

## Testing Guidelines
Automated tests are unavailable; verify changes on-device. Load the plugin, highlight sample text, and confirm dialog flow, network requests, and viewer output in both online and offline scenarios. Ensure missing configuration keys fall back gracefully without runtime errors.

## Commit & Pull Request Guidelines
- **Commit subjects**: Use present-tense prefixes like `dialogs: improve translate toggle` with optional wrapped body context.
- **Pull requests**: Summarize user-facing changes, document manual verification steps, and link related issues or forum threads.
- **UI updates**: Include screenshots or short videos demonstrating dialogs or viewer changes.

## Security & Configuration Tips
Restrict network calls to HTTPS endpoints via `gpt_query.lua`, validate prompts before sending upstream, and guard against `nil` fields in ChatGPT responses. Store API keys or personal endpoints only in `configuration.lua`, confirming the file remains git-ignored before sharing patches or releases.
