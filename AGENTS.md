# Repository Guidelines

## Project Structure & Module Organization
The plugin is self-contained in the repository root. `main.lua` registers the "Ask ChatGPT" highlight action, while `dialogs.lua` orchestrates prompt assembly and the request flow. `gpt_query.lua` wraps HTTPS calls and configuration lookup, and `chatgptviewer.lua` renders responses inside KOReader. `_meta.lua` exposes metadata expected by the KOReader plugin loader, and `update_checker.lua` handles release notices. Keep device-specific settings in a local `configuration.lua` copy and avoid committing secrets.

## Build, Test, and Development Commands
The Lua sources run directly inside KOReader—no build step is required. Use `rsync -av --delete . user@device:/mnt/onboard/koreader/plugins/askgpt.koplugin/` (adjust the target path for your reader) to sync the plugin during development. Package a release archive with `zip -r askgpt.koplugin.zip . -x ".git/*" ".vscode/*" "configuration.lua"`. Run `luacheck *.lua` before sending changes to catch common style or runtime issues.

## Coding Style & Naming Conventions
Follow the existing two-space indentation and keep lines under 120 characters. Treat modules as tables that return their public API, and prefer descriptive function names (`showChatGPTDialog`, `checkForUpdates`). Use `UpperCamelCase` for module tables, `lower_snake_case` or lowerCamelCase for locals depending on context, and reserve ALL_CAPS for constants. Align string literals and table keys for readability and keep translations wrapped with `_()` for KOReader’s gettext integration.

## Testing Guidelines
There is currently no automated test harness. Verify changes by loading the plugin in KOReader, highlighting sample text, and confirming the dialog, network call, and viewer output behave as expected. Test both online and offline states to ensure `NetworkMgr` flows degrade gracefully. When altering configuration handling, validate that missing keys fall back to defaults without throwing runtime errors.

## Commit & Pull Request Guidelines
Write concise, present-tense commit subjects such as `dialogs: improve translate toggle` followed by wrapped body text when context is needed. Reference related issues or KOReader forum threads in the commit body or PR description. Pull requests should include a summary of the user-visible impact, screenshots of UI changes when practical, notes on manual test scenarios, and a reminder that secrets were stripped from `configuration.lua` before submission.

## Security & Configuration Tips
Never commit working API keys or personal endpoints—store them in an untracked `configuration.lua` (or rely on `configuration.lua.sample` if you create one). Document new configuration options in the README and provide safe defaults in code. When integrating third-party endpoints, prefer HTTPS, validate user input before sending, and guard against unexpected `nil` values when parsing responses from the LLM service.
