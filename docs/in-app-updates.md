# In-app updates for Compositor AI

## Current delivery status

The updater implementation at f2891e3ffa6822484be8f072ecf06c2e0f6f09c8 passed both Verify #64 (37742645044) and Codex Integration #14 (37742645006), including standard/Codex builds, unit tests, serial window tests, update validation and development packaging. The artifact Compositor-AI-Updates-arm64-development contains Compositor-AI-Updates-arm64.zip and a source ZIP.

This is a **client implementation and test package**, not an activated public update service. The updates-codex/appcast.xml feed is currently empty. No matching signing secret has been provisioned through this chat, no owner private-key archive has been supplied, and no installed-Mac update round trip is claimed. Do not distribute the preliminary installer as the permanent update bootstrap before owner signing setup and initial release publication are complete.

## How it works

The Compositor-Codex distribution uses pinned Sparkle 2.10.0. Settings > Updates and the app menu offer Check for Updates. Sparkle presents release notes, download progress, errors and Install and Relaunch. Automatic checks are opt-in; installation and restart remain user-confirmed.

After signing is configured and the initial release is published, install that first release once into a writable Applications folder. The previous 1.4.5 AI build has no usable update feed and cannot bootstrap this feature itself. Subsequent upgrades still download bytes, but the app handles the download and installation.

Only this fork's AI release assets are accepted. The app pins an Ed25519 public key and verifies archives before extraction. Its persistent feed is on updates-codex, separate from main, the upstream author's distribution and expiring Actions artifact links. Keep that branch.

Updating replaces the app bundle, not Application Support, UserDefaults, Keychain entries or project files. The bundle identifier remains com.waynelee.compositor.codex. The existing quit/save/cancel flow covers every project tab. Active AI turns and image/file work postpone restart; Settings then offers Install and Restart. New AI messages are blocked while preparing to quit. Cancelling the save prompt cancels restart.

An update signature is not an Apple Developer ID signature. These packages remain ad-hoc-signed, non-notarized development builds. No Gatekeeper bypass is installed or requested.

## 一次性发布初始化（在仓库所有者的 Mac 上运行）

当前聊天连接器不能管理 GitHub Secrets，不能声称签名密钥已配置。不要把 GitHub Token 或签名私钥粘贴到聊天、源代码、发布说明或 Actions 日志里。

已经加入 scripts/setup_update_signing.swift，依赖 Xcode Command Line Tools 和 GitHub CLI。先用 gh auth login --hostname github.com 登录仓库所有者账号。在本地仓库切到 feat/in-app-updates 并拉取最新代码后运行：

```sh
swift scripts/setup_update_signing.swift --self-test
swift scripts/setup_update_signing.swift --configure
```

该脚本只允许初始化尚未发布的通道。它会先检查更新源为空且没有已经发布的 ai-v 安装包，再在你的 Mac 钥匙串生成/读取私钥，通过标准输入交给 gh secret set SPARKLE_PRIVATE_KEY，并把匹配的公钥原子提交到功能分支。不会修改 main，不会把私钥打印到终端或写入 Git。分支有并发修改时拒绝强制覆盖。首次初始化将重新构建带有你所掌握公钥的安装包，因此之前的临时测试包不应作为长期更新入口分发。

自测模式不访问钥匙串、网络或 GitHub 账号。--configure 会管理你本人仓库的发布密钥并更新三个公开配置文件；请先审阅脚本再运行。保管好钥匙串中的签名密钥并进行安全备份；不能用一个新私钥替代已经发布版本信任的旧私钥。

## Publishing future updates

1. Increment CURRENT_PROJECT_VERSION in the Codex configuration above all published builds and set MARKETING_VERSION. Keep bundle ID, public key, feed and existing AI features unchanged.
2. Push to feat/in-app-updates and let Codex Integration pass. It tests the real signed-out Codex protocol and local provider fixture, update publication checks, macOS builds, unit/window tests and the embedded helper package.
3. Commit release/codex.json with actual run_id, source_sha, version, build, archive_sha256 and plain-text notes. An optional owner-generated detached signature permits signing outside CI; otherwise SPARKLE_PRIVATE_KEY is required. Never put the private key in this JSON.
4. Publish signed Compositor AI update retrieves only the matching successful artifact and checks identity, checksum, signature, helper, architecture and code signature. It creates ai-v<version>-b<build> as a prerelease with Compositor-AI-arm64.zip and checks the uploaded digest before advertising it in the feed. Main, the upstream feed and the latest stable release pointer are untouched.

Branch filters intentionally target this feature branch. Change them explicitly when integrating into a permanent release branch; the updates-codex feed URL stays stable. A code push alone is not a published update.

Failed signatures, failed builds, wrong editions, missing helpers and duplicate/older builds stop publication. If release creation succeeds but the feed push fails, keep the asset unchanged and reconcile the feed. Never overwrite an advertised archive.

## Acceptance limits

Automated tests do not prove a physical Mac completed an in-place upgrade. Actual initial installation, download/install/relaunch, project-save cancellation, signing bootstrap permissions and Keychain prompts still require interactive owner acceptance. The added signing helper is checked independently by Update Signing Setup Checks; its self-tests deliberately do not provision a real credential.

Official references: https://sparkle-project.org/documentation/ and https://sparkle-project.org/documentation/publishing/
