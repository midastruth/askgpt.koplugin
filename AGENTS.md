# Repository Guidelines

## Project Structure & Module Organization
The plugin is self-contained at the repository root. Core modules include `main.lua` for registering the "Ask ChatGPT" highlight action, `dialogs.lua` for prompt assembly and request flow, `gpt_query.lua` for HTTPS access plus configuration lookup, and `chatgptviewer.lua` for rendering responses. Metadata lives in `_meta.lua`, while `update_checker.lua` handles release notices. Keep device-specific settings in an untracked `configuration.lua`; do not duplicate secrets in source control.

## Build, Test, and Development Commands
- `rsync -av --delete . user@device:/mnt/onboard/koreader/plugins/askgpt.koplugin/`: sync the plugin to a KOReader device during development (adjust path for your reader).
- `luacheck *.lua`: lint all Lua sources for style and common runtime issues.
- `zip -r askgpt.koplugin.zip . -x ".git/*" ".vscode/*" "configuration.lua"`: package the plugin for release without local tooling or secrets.

## Coding Style & Naming Conventions
Use two-space indentation and keep lines under 120 characters. Modules return a table exposing the public API, and exported tables use `UpperCamelCase` (e.g., `Dialogs`). Prefer `lower_snake_case` for locals unless surrounding code uses lowerCamelCase. Align table keys and string literals for readability, and wrap user-facing strings with `_()` to integrate KOReader’s gettext translations.

## Testing Guidelines
Automated tests are not available. Validate changes by loading the plugin in KOReader, highlighting sample text, and confirming the dialog, network request, and viewer output all behave correctly. Exercise both online and offline scenarios so `NetworkMgr` fallbacks remain stable, and ensure missing configuration keys fall back to defaults without runtime errors.

## Commit & Pull Request Guidelines
Write present-tense commit subjects such as `dialogs: improve translate toggle`, adding wrapped body text when extra context is helpful. Pull requests should summarize user-visible changes, mention manual verification steps, link related issues or forum threads, and provide screenshots for UI adjustments. Confirm that `configuration.lua` is excluded before sharing patches.

## Security & Configuration Tips
Never commit working API keys or personal endpoints. Store credentials in an untracked `configuration.lua` or rely on a documented sample file. Only use HTTPS endpoints, validate any user-provided prompts before sending upstream, and guard against unexpected `nil` responses when parsing ChatGPT results to prevent crashes on devices.
