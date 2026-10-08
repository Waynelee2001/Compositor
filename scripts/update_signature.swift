import Foundation
import CryptoKit

// Uses the same Ed25519 seed/public-key format as Sparkle 2 generate_keys (-x).
// Only the SIGN operation reads SPARKLE_PRIVATE_KEY; private material is never an argument or output.
func decoded(_ text: String, length: Int) throws -> Data {
    guard let data = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)), data.count == length else {
        throw NSError(domain: "UpdateSignature", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid key or signature length"])
    }
    return data
}
do {
    let args = Array(CommandLine.arguments.dropFirst())
    if args == ["self-test"] {
        let key = Curve25519.Signing.PrivateKey()
        let data = Data("Compositor update signature test".utf8)
        let signature = try key.signature(for: data)
        precondition(key.publicKey.isValidSignature(signature, for: data))
        precondition(!key.publicKey.isValidSignature(signature, for: data + Data([0])))
        precondition(!Curve25519.Signing.PrivateKey().publicKey.isValidSignature(signature, for: data))
        print("Ed25519 valid, altered-archive and wrong-key checks passed")
    } else {
        guard args.count == 3 || args.count == 4 else {
            throw NSError(domain: "UpdateSignature", code: 2, userInfo: [NSLocalizedDescriptionKey: "Use sign archive public-key or verify archive public-key signature"])
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: args[1]), options: .mappedIfSafe)
        let expected = try decoded(args[2], length: 32)
        if args[0] == "sign", args.count == 3 {
            let secret = ProcessInfo.processInfo.environment["SPARKLE_PRIVATE_KEY"] ?? ""
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: decoded(secret, length: 32))
            guard key.publicKey.rawRepresentation == expected else {
                throw NSError(domain: "UpdateSignature", code: 3, userInfo: [NSLocalizedDescriptionKey: "Signing secret does not match the public key embedded in this app"])
            }
            print(try key.signature(for: data).base64EncodedString())
        } else if args[0] == "verify", args.count == 4 {
            let key = try Curve25519.Signing.PublicKey(rawRepresentation: expected)
            guard try key.isValidSignature(decoded(args[3], length: 64), for: data) else {
                throw NSError(domain: "UpdateSignature", code: 4, userInfo: [NSLocalizedDescriptionKey: "Update signature verification failed"])
            }
            print("Update signature verified")
        } else { throw NSError(domain: "UpdateSignature", code: 5) }
    }
} catch {
    // The errors above deliberately never interpolate the secret.
    FileHandle.standardError.write(Data(("Update signing/verification failed: " + error.localizedDescription + "\n").utf8))
    exit(1)
}
