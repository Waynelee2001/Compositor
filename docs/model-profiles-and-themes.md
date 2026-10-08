# Model profiles and appearance

## Use

Open the AI sidebar's service selector and select **ChatGPT / Codex**, **DeepSeek V4.1 Flash**, or a saved custom profile. The adjacent sliders button opens **Model profiles**.

For DeepSeek, keep the preset base URL `https://api.deepseek.com` and model ID `deepseek-flash`, enter your own API key, then choose **Save and use**. **Test connection / load models** only calls the configured service's `/models` endpoint: it neither sends the current photo nor performs paid inference. A successful model-list request is not a guarantee that an inference request or tool call will succeed.

A custom profile requires a name, a base URL (including any port and API path), and a model ID. The model ID can be typed or chosen after loading the model list. Remote endpoints must use HTTPS. HTTP is accepted only for the exact loopback hosts `localhost`, `127.0.0.1`, and `::1`. A local service may omit its API key. URLs containing credentials, queries, or fragments are rejected.

Codex remains the only agent runtime. API profiles use **Responses API with function calling**, not a second agent loop or a Chat Completions-to-Responses proxy. A service that only implements `/chat/completions` or Anthropic `/messages` is not compatible with this version. Arbitrary model IDs can be configured, but model abilities and account access are not assumed. Custom profiles default to text-only: enable image input only when the model supports it. DeepSeek `deepseek-flash` is declared image-capable; `deepseek-v4-pro` is not.

## Credentials and switching

API keys are macOS Keychain generic-password entries. Profile metadata in UserDefaults contains no key. The key is read only to test the selected endpoint or launch the app-owned Codex process, and passed to that process through `COMPOSITOR_PROVIDER_API_KEY`, never through command arguments or a TOML file. The model-catalog JSON contains capability metadata only. The app does not edit `~/.codex/config.toml` or the normal CLI login.

Switching profiles persists the current local transcript, disconnects its child process, loads the destination profile's transcript, and turns canvas sharing off. Switching is blocked during a running turn, an image edit, or connection startup. Each API destination has an independent credential namespace. Changing the endpoint requires a new key and creates a fresh conversation namespace; changing only the model keeps the key but creates a fresh conversation namespace. Switching does not automatically copy history to another model or endpoint. Old Codex homes may retain content already sent, including previews; disabling sharing only stops future preview requests.

The native ChatGPT / Codex profile retains the original browser and OpenAI API-key login flow and legacy conversation directory. Its model selector continues to use Codex's catalog. API model selection is in the profile editor; it can also be represented by several saved profiles for convenient switching.

The original editor safeguards remain: host-side tool validation, read-only Codex filesystem mode, disabled shell/exec/patch/web/app/plugin tools, and image-edit approval enabled by default. A model profile does not confer new OS permissions.

## Appearance

**Settings → General → Appearance** and the AI sidebar's settings both offer **Light**, **Dark**, and **Follow System**. The default is Light when no preference has been saved. Changes apply without restarting the editor or recreating the document session.

Dynamic neutral colors cover the application surround, tool rail, project tabs, canvas background/checkerboard, rulers, curve graphs and filter previews. AppKit menus, native controls and panels inherit the selected application appearance. ShadKit derives its palette from the same SwiftUI color scheme.

Colors that encode actual image meaning are intentionally unchanged: swatches, black/white mask references, color wheels, gradients, selection contrast and raster/export operations. CI compares PNG bytes before and after switching appearances and captures synthetic-document editor and model-dialog screenshots in both themes.

## Validation

The CI provider smoke test starts the pinned real Codex binary against a loopback-only mock Responses server. It uses the same Swift model-catalog and override generator as the app and checks configured model and credential routing, a streamed dynamic tool call, an image-bearing host response, and a streamed final answer. It uses a dummy key and no external model or user photo. This is a protocol integration test, not a real DeepSeek account or image-quality acceptance test.

Unit tests additionally cover endpoint validation, model-list parsing, safe quoting, capability metadata, credential/conversation namespace changes, busy-state switching guards and theme-independent export. The development package is ad-hoc signed and not Apple-notarized. User sign-in, Keychain prompts and actual provider quota/quality require interactive acceptance.

## Primary references checked during implementation

1. DeepSeek API setup and current model ID: https://api-docs.deepseek.com/zh-cn/
2. DeepSeek Responses API and tool-returned images: https://api-docs.deepseek.com/guides/responses_api/
3. DeepSeek's Codex integration and model catalog: https://api-docs.deepseek.com/quick_start/agent_integrations/codex/
4. Codex app-server custom provider / environment-key configuration: https://developers.openai.com/siwc/token-sharing-open-source/codex-app-server
