# Codex photo-editing integration

## Build and use

Use Xcode 26.6 on Apple Silicon with macOS 26 or later. Open `Compositor.xcodeproj` and select **Compositor-Codex**. The original **Compositor** scheme keeps App Sandbox enabled; it can display the chat UI but deliberately refuses to spawn an external agent. The additional **Codex** configuration is for direct distribution/development, uses a separate bundle identifier, preserves hardened runtime, and does not use the upstream application's Sparkle feed. It is not an App Store or notarized release.

1. Build and launch the Compositor-Codex scheme, or use the development artifact produced by the Codex Integration workflow after that workflow succeeds.
2. Open an image and open the AI sidebar. In its gear menu, connect Codex and choose **Sign in with ChatGPT**, or enter an API key in the secure field. Model access and usage depend on the authenticated account; a model appearing in the catalog is not an entitlement check.
3. A packaged development artifact includes a pinned Codex helper. A local Xcode build can use an existing Codex installation. Settings > Codex and the sidebar gear menu both support choosing an executable. The editor starts `codex app-server --listen stdio://` itself; no separate terminal session is required.
4. Enable **Share canvas preview** only when the model should inspect this document. Sharing is off by default. Keep **Confirm each image edit** enabled to review tool parameters before each change. Ask for a conservative exposure, dehaze, contrast or color adjustment, then approve the tool card.
5. Stop interrupts the Codex turn and retains partial output. Already committed native edits are not silently rolled back; use Undo. A native filter already rendering may finish before the interruption takes effect. A new turn cannot begin while that native edit is still finishing.

## 简体中文使用说明

选择 **Compositor-Codex** 构建，而不是标准的 Compositor 构建。启动后：打开照片 → AI 侧栏齿轮 → 连接 Codex → 使用 ChatGPT 登录或输入 API 密钥 → 选择模型。需要让模型看图时，主动打开“共享画布预览”。默认每一次修图都要确认，可查看参数后点击“应用修改”。例如输入“让照片更通透，但不要让肤质显得生硬”，模型可以获取文档信息、查看授权的预览，再调用 Camera Raw 调整。更改使用编辑器原生撤销历史，按 Command-Z 可以撤销。

本地 Xcode 构建会查找已安装的 Codex；成功的 Codex Integration 工作流会提供内含 Codex 的开发测试包。开发包采用临时签名，没有经过 Apple 公证，不是正式发行版。登录仍由你在浏览器中完成，CI 不会读取你的账号，也不会调用收费模型替你测试照片效果。

## Architecture

`AIChatPanel (ShadKit) → AgentChatSession (event projection) → CodexRPCConnection (JSONL/stdio) → codex app-server`

Server-initiated `item/tool/call` requests return through `CodexEditorTools → EditorSession → native filter/history`. This is not a second model loop and does not parse terminal prose. The earlier `AgentProvider` and `AgentToolRegistry` files remain for compatibility with foundation tests; the active sidebar no longer instantiates the unconfigured provider. The existing EditorSession Camera Raw adapter is reused.

ShadKit supplies `AIConversation`, `AIResponse`, `AICodeBlock` and `AIPromptInput`. Editor-specific tool cards and approval controls are native wrappers so their status labels can remain localized. Only the public reasoning summary is displayed. ShadKit's current Markdown renderer is not a full rich-document/table engine; it is isolated to the conversation presentation layer.

The transport supports typed string/integer RPC IDs, split UTF-8/JSONL frames, server requests, bounded frame size, timeouts, cancellation and disconnect cleanup. Conversation state is projected from item/turn notifications, reconciles final text without duplication, and is associated with a document UUID. Reopening that document restores the local transcript and resumes its Codex thread. Starting a new conversation detaches the previous thread; it is not a deletion request for Codex's own stored history.

## Host tools implemented

| Tool | Behavior |
|---|---|
| `compositor_get_document_info` | Reports document/layer IDs, size, active layer and sharing state. |
| `compositor_get_canvas_preview` | With explicit consent, returns a composite JPEG up to 1024 pixels on its long side. Canvases over 50 megapixels are rejected instead of allocating an unbounded preview. Transparency is displayed on white. |
| `compositor_apply_camera_raw` | Requires the current active layer UUID and validated numeric parameters. Exposure is limited to -5…5; other exposed parameters to -100…100. Reuses the editor's filter commit/undo path. |
| `compositor_undo` / `compositor_redo` | Operates on the bound document's real history, including manual edits. The model is instructed to use these only on user request. |

Camera Raw calls process the current raster; repeating an adjustment is cumulative, not an absolute persistent Camera Raw layer. Tool calls run serially, duplicate call IDs are checked and cached within a turn, unknown fields/tools are rejected, stale document/layer requests are blocked, and mutations ask for confirmation by default. The current tool surface does not claim to expose every Compositor command. LUTs, a curated movie-preset library, generative fill, background replacement and arbitrary file export are not implemented by this change.

## Privacy and permissions

The runtime uses a private `CODEX_HOME` under `~/Library/Application Support/Compositor/AI/CodexHome`, not the user's usual `~/.codex`. Authentication and Codex's own thread storage are managed there. API keys are not saved in UserDefaults, source code, or the UI transcript. The credential directory is created with owner-only permissions. This isolation means a first sign-in for this editor may be required even when another Codex client is already signed in.

Application transcripts are stored separately under `Conversations` with owner-only file permissions and a size limit; preview base64 is omitted from that display cache. **Codex itself may persist conversation/tool content, including images, in its own home**, and model-provider retention rules still apply. Disabling sharing prevents future preview tool calls; it does not delete content already transmitted. Layer names and document metadata can appear in tool context even when preview sharing is off. No original EXIF or `.comp` package is attached by the preview adapter.

A Tool Registry is not an OS sandbox. This integration additionally uses a private working directory, Codex read-only filesystem mode, disabled shell/unified-exec/web/app/plugin features, no configured MCP servers, rejected non-editor execution/file-change approvals, and interruption upon unexpected non-editor execution events. These controls must be revalidated on a Codex upgrade; they are not a claim that every future built-in capability is confined by the registry alone. The macOS application itself is unsandboxed only in the explicit Codex build so it can run the external helper.

## Version baseline and validation

The packaging baseline is official **Codex 0.160.1** (`rust-v0.160.1`). Dynamic tools remain experimental and require `initialize.capabilities.experimentalApi = true`. The adapter uses that release's function-tool schema (`type: function`, `name`, `description`, `inputSchema`) and responds with `success` plus `contentItems` (`inputText` / `inputImage`). Other installed versions are not automatically assumed compatible; their server version is shown in the connection panel.

ShadKit is pinned to revision `6dbefdeb72a276708b7ca748c71ac166c0f4f17d` rather than following main. Its MIT notice is retained in `ThirdParty/ShadKit-LICENSE.txt` and included in packaged development apps. Codex is downloaded from its official release and checked against GitHub's published SHA-256 digest before packaging; its license is included alongside it.

`CodexRuntimeTests` covers framing, typed IDs, text reconciliation, public-summary filtering, denial preservation, strict tool validation, privacy/document guards, approved authentication URLs, and a real subprocess/mock-server exchange including timeout and EOF. The subprocess test is explicitly skipped in the normal sandboxed build and runs in the Codex configuration. Existing editor tests still run.

The new CI also launches the **real pinned Codex binary** in an empty private home and exercises initialize → initialized → account/read without credentials or inference. This is a protocol smoke test, **not** proof of account login, paid-model access or the quality of an actual photo edit. Signed-in end-to-end acceptance must be done interactively: sign in, share a preview, approve a conservative grade, verify the canvas, undo it, stop a turn, and reopen the same document to resume its thread. Consult the actual Actions result for the tested commit; this document does not assert that an unobserved CI run succeeded.

## Sources

1. OpenAI App Server documentation: https://developers.openai.com/codex/app-server/
2. Pinned Codex schema: https://github.com/openai/codex/tree/rust-v0.160.1/codex-rs/app-server-protocol/schema/typescript/v2
3. ShadKit source revision: https://github.com/jasonkneen/ShadKit/tree/6dbefdeb72a276708b7ca748c71ac166c0f4f17d
