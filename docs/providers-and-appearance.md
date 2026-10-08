# API providers and appearance

The Codex App Server remains the agent runtime for all connections. DeepSeek V4.1 Flash uses the native Responses API and the official `deepseek-flash` model ID. Custom connections must support Responses, not only Chat Completions. No MCP or protocol proxy is introduced.

## Setup

Open the AI sidebar settings. Choose **Add DeepSeek**, enter the API key, and select **Save and use**. The preset address is `https://api.deepseek.com`. The editor controls remain available to the selected model, including the consent-based canvas preview.

For another service, choose **Add custom API**, enter a name, base URL (including a port when needed), API key, and model ID. **Fetch models** is optional; it uses only GET /models and is not a paid inference test. Manual model IDs remain supported. Local examples use `http://127.0.0.1:1234/v1`; other hosts require HTTPS. The endpoint must support Responses and function tools. Declare image support only for models that actually support it.

The compact provider/model selector appears above the transcript. Switching is disabled during a running turn or image edit. Changing providers resets canvas-sharing consent. A changed endpoint or credential gets a new isolated Codex home and conversation scope, so old chat/image context is not transferred to a newly configured server. Existing Codex/ChatGPT login and the user's normal ~/.codex are not modified. Keys are stored in macOS Keychain and passed only through the child process environment, never command-line arguments, UserDefaults or transcripts. A redirect from model discovery is not followed with the key.

## Appearance

Settings > General > Appearance provides Light (the default), Dark, and Follow System. The same switch is available in AI settings. SwiftUI, AppKit panels, toolbars, tabs, rulers, and the CPU/GPU viewport background share the preference. Document colors, masks, and exported image pixels are not themed.

## Validation

The provider smoke test builds its model catalog and launch arguments from the production Swift profile type, starts the pinned real Codex binary against a loopback-only Responses fixture, checks the model and authentication header, exercises dynamic tools and image tool output, and observes the final streamed answer. It never uses an actual provider account or paid inference. Unit tests cover endpoint normalization/rejection, profile metadata, credential separation, switching guards and appearance values.

Real DeepSeek credentials, account access, inference quality, Keychain approval prompts and full GUI visual acceptance still require interactive validation. A development app is not Apple-notarized.

## Sources

DeepSeek: https://api-docs.deepseek.com/zh-cn/updates/ and https://api-docs.deepseek.com/zh-cn/guides/responses_api/
Codex configuration: https://developers.openai.com/docs/config-file/config-reference
