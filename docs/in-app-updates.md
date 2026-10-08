# In-app updates for Compositor AI

The Compositor-Codex distribution uses the pinned Sparkle 2.10.0 dependency. Settings > Updates and the app menu offer Check for Updates. Sparkle handles release notes, download progress, errors and Install and Relaunch. Automatic checks are opt-in; installation and restart remain user-confirmed.

Install the first update-enabled build, 1.5.0 (100), once into a writable Applications folder. The previous 1.4.5 AI development build has no feed and cannot bootstrap this feature itself. Subsequent upgrades still download bytes, but the app handles the process.

## Safety and persistence

Only this fork's AI release assets are accepted. The app pins an Ed25519 public key and verifies archives before extraction. Its persistent feed is on the updates-codex branch, not main, the upstream author's feed or an expiring Actions artifact URL. Keep that branch.

Updating replaces the application bundle, not Application Support, UserDefaults, Keychain entries or project files. The bundle identifier remains com.waynelee.compositor.codex. The existing quit/save/cancel flow covers every project tab. Active AI turns and image/file work postpone restart; Settings then offers Install and Restart. New AI messages are blocked while preparing to quit. Cancelling the save prompt cancels restart.

Update requests do not contain model API keys, photos, chats or projects. An update signature is not an Apple Developer ID signature: this is still an ad-hoc-signed, non-notarized development build. No Gatekeeper bypass is installed or requested.

## One-time owner setup

Store the matching base64 Ed25519 private seed in the repository Actions secret SPARKLE_PRIVATE_KEY. Back it up offline. Never commit it, embed it in the app, put it in release notes or upload it as an Actions artifact. The public key is tracked in Config/SparklePublicKey.txt and InfoCodex.plist.

The separately supplied owner-only setup archive can set the secret through gh secret set using standard input, or open GitHub's secret settings. It does not request a GitHub token in chat. The current connector cannot administer repository secrets; creating a workflow does not mean the secret has been configured. The first release may instead use an owner-generated detached signature, which contains no private key. Future automated signing needs the one-time secret.

## Publishing future updates

1. Increment CURRENT_PROJECT_VERSION in the Codex configuration above all published builds and set MARKETING_VERSION. Keep the bundle identifier, key, feed and existing AI features unchanged.
2. Push to feat/in-app-updates and let Codex Integration pass. It runs protocol tests, release validation, macOS builds, unit and window tests and packages the embedded Codex helper.
3. Commit release/codex.json with real run_id, source_sha, version, build, archive_sha256 and plain-text notes. An optional detached signature permits signing outside CI; otherwise the secret is required. Never place the private key in this JSON.
4. Publish signed Compositor AI update retrieves only the matching successful workflow artifact and checks identity, checksum, signature, helper, architecture and code signature. It creates a prerelease tagged ai-v<version>-b<build> with Compositor-AI-arm64.zip. It verifies the uploaded asset digest before advertising it in the feed. It never changes main, the upstream feed or the latest stable release pointer.

The workflow branch filters intentionally target this feature branch. Change both filters explicitly when integrating into a permanent release branch; the updates-codex URL stays stable. A code push alone is not a published update.

Failed signatures, failed builds, wrong editions, missing helpers and duplicate or older build numbers stop publication. If a release is created but the feed push fails, leave the asset unchanged and reconcile the feed; never overwrite an already advertised archive.

## Validation limits

Tests cover update source/configuration policy, no-network test hosts, active AI work, explicitly delayed restarts, retained drafts, Ed25519 valid/tampered/wrong-key cases, release metadata and monotonic feed publication. A successful build alone is not proof of an installed app completing an in-place upgrade. Actual upgrade, save/cancel interactions and Keychain prompts remain Mac acceptance checks with a disposable project.

Official references: https://sparkle-project.org/documentation/ and https://sparkle-project.org/documentation/api-reference/Protocols/SPUUpdaterDelegate.html
