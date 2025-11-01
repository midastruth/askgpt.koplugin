# AskGPT: ChatGPT Highlight Plugin for KOReader

Introducing AskGPT, a new plugin for KOReader that allows you to ask questions about the parts of the book you're reading and receive insightful answers from ChatGPT, an AI language model. With AskGPT, you can have a more interactive and engaging reading experience, and gain a deeper understanding of the content.

## 🚀 New: Enhanced Network Robustness

This version includes significant improvements to network stability and error handling:

- **Automatic retry mechanism** - Failed requests are automatically retried up to 3 times
- **Request timeout protection** - Requests timeout after 10 seconds to prevent hanging
- **Improved error messages** - Clear, user-friendly error messages in your language
- **Configuration validation** - Pre-flight checks ensure proper setup
- **Graceful failure handling** - Plugin no longer crashes on network issues

## Getting Started

To use this plugin, You'll need to do a few things:

Get [KoReader](https://github.com/koreader/koreader) installed on your e-reader. You can find instructions for doing this for a variety of devices [here](https://www.mobileread.com/forums/forumdisplay.php?f=276).

If you want to do this on a Kindle, you are going to have to jailbreak it. I recommend following [this guide](https://www.mobileread.com/forums/showthread.php?t=320564) to jailbreak your Kindle.

Acquire an API key from an API account on OpenAI (with credits). Once you have your API key, create a `configuration.lua` file in the following structure or modify and rename the `configuration.lua.example` file:

> **Note:** The prior `api_key.lua` style configuration is deprecated. Please use the new `configuration.lua` style configuration.

```lua
local CONFIGURATION = {
    api_key = "YOUR_API_KEY",
    model = "gpt-4o-mini",
    base_url = "https://api.openai.com/v1/chat/completions"
}

return CONFIGURATION
```

In this new format you can specify the model you want to use, the API key, and the base URL for the API. The model is optional and defaults to `gpt-4o-mini`. The base URL is also optional and defaults to `https://api.openai.com/v1/chat/completions`. This is useful if you want to use a different model or a different API endpoint (such as via Azure or another LLM that uses the same API style as OpenAI).

For example, you could use a local API via a tool like [Ollama](https://ollama.com/blog/openai-compatibility) and set the base url to point to your computers IP address and port.

```lua
local CONFIGURATION = {
    api_key = "ollama",
    model = "zephyr",
    base_url = "http://192.168.1.87:11434/v1/chat/completions",
    additional_parameters = {}
}

return CONFIGURATION
```

## Other Features

Additionally, as other extra features are rolled out, they will be optional and can be set in the `features` table in the `configuration.lua` file.


### Translation

To enable translation, you can set the `translate_to` parameter in the `features` table. For example, if you want to translate the text to French, you can set the `translate_to` parameter to `"French"`.

By setting the `translate_to` parameter, you can have the plugin translate the text to the language you specify. This is useful if you are reading a book in a language you are not fluent in and want to understand a chunk of text in a language you are more comfortable with.

```lua
local CONFIGURATION = {
    api_key = "YOUR_API_KEY",
    model = "gpt-4o-mini",
    base_url = "https://api.openai.com/v1/chat/completions",
    features = {
        translate_to = "French"
    }
}
```

## Installation

If you clone this project, you should be able to put the directory, `askgpt.koplugin`, in the `koreader/plugins` directory and it should work. If you want to use the plugin without cloning the project, you can download the zip file from the releases page and extract the `askgpt.koplugin` directory to the `koreader/plugins` directory. If for some reason you extract the files of this repository in another directory, rename it before moving it to the `koreader/plugins` directory.

## How To Use

To use AskGPT, simply highlight the text that you want to ask a question about, and select "Ask ChatGPT" from the menu. The plugin will then send your highlighted text to the ChatGPT API, and display the answer to your question in a pop-up window.

## Troubleshooting

### Common Issues and Solutions

#### 1. Plugin crashes when clicking "Ask ChatGPT"
**Problem**: The plugin exits unexpectedly when you try to use it.
**Solutions**:
- Check that your `configuration.lua` file exists and is properly formatted
- Verify your network connection is working
- Ensure your API endpoint is accessible
- Check KOReader logs for specific error messages

#### 2. Network timeout errors
**Problem**: You see "网络请求超时" (Network request timeout) or similar timeout messages.
**Solutions**:
- Check your internet connection stability
- Try increasing the timeout value in your configuration
- Verify your API server is responding quickly
- Consider using a closer/more reliable API endpoint

#### 3. Connection failed errors
**Problem**: You see "无法连接到AI服务" (Cannot connect to AI service) messages.
**Solutions**:
- Verify your API URL is correct in `configuration.lua`
- Check if your API server is running and accessible
- Ensure your device can reach the API server (test with browser/curl)
- Check firewall settings on your device or network

#### 4. Configuration issues
**Problem**: Plugin shows configuration error messages.
**Solutions**:
- Copy `configuration.lua.example` to `configuration.lua` and modify it
- Ensure your configuration file returns a proper Lua table
- Check that required fields like `base_url` or `reader_ai_base_url` are present
- Validate your Lua syntax (no missing commas, brackets, etc.)

#### 5. API response errors
**Problem**: You see "字典查询失败" (Dictionary query failed) or similar API errors.
**Solutions**:
- Check your API key is valid and has credits
- Verify your API endpoint supports the requested operations
- Check API server logs for detailed error information
- Ensure your request format matches the API requirements

### Getting Help

If you continue to experience issues:

1. **Check KOReader logs**: Look for error messages in KOReader's debug logs
2. **Test your API**: Use curl or a web browser to test your API endpoint directly
3. **Verify network**: Ensure your device can access the internet and your API server
4. **Check configuration**: Compare your `configuration.lua` with the example file
5. **Report issues**: If problems persist, report them on the GitHub issues page with:
   - Your device type and KOReader version
   - The exact error message you're seeing
   - Your configuration (remove sensitive data like API keys)
   - Steps to reproduce the issue

I hope you enjoy using this plugin and that it enhances your e-reading experience. If you have any feedback or suggestions, please let me know!

If you want to support development, become a [Sponsor on GitHub](https://github.com/sponsors/drewbaumann).

License: GPLv3
