# Provider switching and appearance

This update is built on the Codex/ShadKit integration, without changing the image file format or replacing the Agent runtime.

## Quick setup

Open the AI sidebar. The provider and model menus are directly above the conversation. Select **DeepSeek V4.1 Flash**, click the pencil, enter your DeepSeek API key, and save. The preset uses `https://api.deepseek.com` and the official API model ID `deepseek-flash`. You can also add a named custom provider with a base URL (including a port or `/v1` prefix when needed), API key and model ID. Fetching `/models` is optional; a model ID can be entered manually. The model test is an explicit, potentially billable, small `/responses` request without photos or conversation history.

**Compatibility boundary:** Custom services must implement OpenAI-compatible **Responses API**, including streaming and function/tool calls. A Chat Completions-only or Anthropic Messages-only endpoint is not automatically compatible. This is intentional: all providers continue to use Codex App Server rather than a second improvised Agent loop. A gateway translating to Responses can be entered as the base URL. Remote HTTP is rejected; unencrypted HTTP is allowed only on literal localhost/127.0.0.1/::1 endpoints. There is no proxy daemon, global config synchronization, auto-fallback, or load balancing.

DeepSeek's official documentation confirms V4.1 Flash's `deepseek-flash` model ID, image input and native Codex/Responses integration:

1. https://api-docs.deepseek.com/quick_start/agent_integrations/codex/
2. https://api-docs.deepseek.com/news/news260910/
3. https://developers.openai.com/siwc/token-sharing-open-source/codex-app-server

The app emits its own model catalog. DeepSeek gets its documented one-million-token context and image support; custom profiles start with conservative 32K metadata. Enable image input only for a model that actually supports it. A `/models` result is a catalog, not an entitlement or protocol compatibility guarantee.

## Switching and privacy

Provider metadata is saved separately from credentials. Keys are stored in macOS Keychain and passed only to the selected child process using `env_key`. They are never placed in UserDefaults, command-line arguments, model catalogs or the UI transcript. Existing ChatGPT authentication and the user's ordinary `~/.codex` remain untouched.

Each provider endpoint revision and model has its own local conversation scope. Switching while a turn, connection or editor tool is active is disabled. Switching closes the old process and restores that provider/model's own conversation; it does **not** forward the previous provider's history. Changing an endpoint rotates its scope. Canvas sharing resets to off on switches; native edit confirmations stay enabled. Previously transmitted data may remain in the prior provider's systems and Codex's local home. Deleting the app's Keychain entry does not revoke the key at its issuer.

## Appearance

Fresh installs default to **Light**. Settings → General → Appearance and the toolbar appearance menu offer Light, Dark and Follow System. Preferences persist across launches and update SwiftUI roots, AppKit windows, floating panels, toolbars, tabs, rulers, graph controls and canvas surround. The canvas transparency checker follows the selected appearance. Image swatches, masks, image processing and exported pixels are unchanged.

## Verification

Provider tests cover official presets, URL/port validation, unsafe URLs, TOML quoting, metadata without secrets, endpoint revision isolation and model scopes. A real Codex process talks to a loopback Responses fixture, validating provider key routing, custom model catalogs, streamed assistant output, host tool callbacks and inline image results without external model calls or real credentials. Appearance tests run serially and save native light/dark screenshots while asserting identical PNG exports across themes.

CI results belong to the exact commit/run recorded on the pull request. Passing fixture tests does not mean a real DeepSeek account or arbitrary third-party gateway has been tested. Signed-in API billing, real model output and photograph quality still require account-specific acceptance.
