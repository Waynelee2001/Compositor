# Compositor AI update feed

This persistent branch hosts the update catalog for the AI edition, bundle identifier com.waynelee.compositor.codex. It is separate from main and the upstream distribution.

The feed currently has no published releases. An empty feed is not proof that the owner signing key has been provisioned. The initial signing setup must be completed before distributing the first permanent update-enabled installer.

The authoritative public key is Config/SparklePublicKey.txt on the release source branch (currently feat/in-app-updates); it must match Compositor/Updates/UpdatePolicy.swift and the packaged Info.plist. Do not copy a preliminary key out of a README. Never commit its private seed.

Do not delete this branch or overwrite advertised release assets. New entries are published only after a successful matching Codex Integration artifact passes identity, signature and checksum validation. A code push alone does not publish an update.

The owner-only bootstrap script is scripts/setup_update_signing.swift on feat/in-app-updates. It operates only on an unpublished channel and stores the signing seed in the owner's Mac Keychain and the repository Actions secret. It must not be run to rotate keys after releases have been advertised.

Install the first signed-channel installer manually once. Subsequent published releases use Settings > Updates. Current development packages are not Apple-notarized.
