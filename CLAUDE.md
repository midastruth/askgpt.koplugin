# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is the **AskGPT** plugin for KOReader, an e-reader application. The plugin enables users to highlight text and query AI for answers about selected content. It supports dictionary lookups, summaries, translations, and custom questions. The plugin has evolved from OpenAI ChatGPT integration to primarily use custom Reader AI FastAPI backends with enhanced Chinese language support.

## Architecture

The plugin follows KOReader's standard plugin architecture with these core components:

- **main.lua** - Plugin entry point that registers the "Ask ChatGPT" highlight action and handles initialization
- **dialogs.lua** - UI workflow manager that handles user input dialogs and coordinates between UI and AI services
- **gpt_query.lua** - Network client for AI API calls (Reader AI FastAPI backend with retry mechanisms)
- **chatgptviewer.lua** - Scrollable text viewer for displaying AI responses with interactive features
- **_meta.lua** - Plugin metadata for KOReader's plugin system
- **update_checker.lua** - Automatic update checking via GitHub API
- **configuration.lua** - User configuration file (git-ignored, see configuration.lua.example)

### Data Flow

1. User highlights text in KOReader → `main.lua` captures highlight action
2. `dialogs.lua` shows input dialog for user questions
3. `gpt_query.lua` sends requests to AI backend with retry logic
4. `chatgptviewer.lua` displays responses with scrolling, follow-up questions, and note-adding

## Development Commands

### Testing and Deployment
```bash
# Sync plugin to KOReader device for testing
rsync -av --delete . user@device:/mnt/onboard/koreader/plugins/askgpt.koplugin/

# Lint Lua code for style and runtime issues
luacheck *.lua

# Package for release (excludes dev files and secrets)
zip -r askgpt.koplugin.zip . -x ".git/*" ".vscode/*" "configuration.lua"
```

### Configuration Setup
```bash
# Copy example configuration and customize
cp configuration.lua.example configuration.lua
# Edit configuration.lua with your API endpoints and keys
```

Current configuration uses Reader AI backend by default with Chinese language support. The configuration follows this pattern:
```lua
local CONFIGURATION = {
    reader_ai_base_url = "http://your-server:8000",
    reader_ai_dictionary_path = "/ai/dictionary",
    reader_ai_summarize_path = "/ai/summarize",
    features = {
        translate_to = "Chinese",
        askQuestions = true,
        aiDictionary = true,
    }
}
```

## Key Configuration Options

The plugin supports multiple AI backends through `configuration.lua`:

- **Reader AI FastAPI** - Primary backend with dictionary and summarize endpoints (default configuration)
- **OpenAI API** - Standard ChatGPT API integration (legacy support)
- **Local APIs** - Ollama or other local LLM services
- **Translation** - Configurable target language via `features.translate_to` (defaults to Chinese)

Network robustness features include automatic retry (3 attempts), 1000s timeout (increased from 10s for slow API responses), and graceful error handling.

## File Structure & Responsibilities

### Core Plugin Files
- `main.lua:58-90` - Highlight action registration and network/config validation
- `dialogs.lua:314-599` - Main dialog coordination function `showChatGPTDialog()`
- `gpt_query.lua:260-342` - AI API client functions `dictionaryLookup()` and `summarizeContent()`
- `chatgptviewer.lua:86-332` - UI component initialization with scroll, buttons, and text selection

### Configuration & Metadata
- `_meta.lua` - Plugin version and description for KOReader
- `configuration.lua.example` - Template showing all supported options
- `update_checker.lua:14-81` - GitHub release checking with timeout protection

### UI Components
The plugin creates complex UI flows:
- Input dialogs for questions (Ask/Summarize/Translate buttons)
- Scrollable viewers with "Ask Another Question" and "Add Note" functionality
- Error handling with localized Chinese messages
- Text selection and clipboard integration

## Testing Guidelines

No automated tests are available. Verify changes by:

1. Loading plugin in KOReader
2. Testing highlight → "Ask ChatGPT" dialog flow
3. Verifying network requests work in online/offline scenarios
4. Confirming error handling for missing config/network failures
5. Testing UI components (scrolling, buttons, text selection)

## Common Development Tasks

### Adding New AI Features
1. Extend `gpt_query.lua` with new API endpoint functions
2. Add UI elements in `dialogs.lua` for new feature workflow
3. Update `configuration.lua.example` with new config options

### UI Modifications
- Edit `chatgptviewer.lua` for viewer changes (buttons, layout, scrolling)
- Modify `dialogs.lua` for input dialog customization
- Follow KOReader UI patterns (InputContainer, UIManager, etc.)

### Network & Error Handling
- All network calls go through `gpt_query.lua` retry mechanisms
- Use localized error messages via `_()` gettext function
- Test timeout scenarios and connection failures

## Security Notes

- Store API keys only in `configuration.lua` (git-ignored)
- Validate all user inputs before sending to AI APIs
- Use HTTPS endpoints only via `gpt_query.lua`
- Guard against nil/malformed AI API responses

## Commit Message Format

Use present-tense prefixes matching recent commits:
- `feat(component): description` - New features
- `fix: description` - Bug fixes
- `docs: description` - Documentation updates
- `refactor: description` - Code restructuring