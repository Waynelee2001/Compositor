import Foundation
import CryptoKit
import Security

// Run on the repository owner's Mac, never in CI with --configure.
// The private seed is kept in Keychain and piped to `gh secret set`, never printed or committed.
private let repository = "Waynelee2001/Compositor"
private let branch = "feat/in-app-updates"
private let keyService = "com.waynelee.compositor.update-signing"
private let keyAccount = "Waynelee2001/Compositor"

struct SetupError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw SetupError(message: message) }
}

final class FeedInspector: NSObject, XMLParserDelegate {
    var root: String?
    var channels = 0
    var items = 0
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
        if root == nil { root = name }
        if name == "channel" { channels += 1 }
        if name == "item" { items += 1 }
    }
}
func requireUnpublishedFeed(_ data: Data) throws {
    let inspector = FeedInspector()
    let parser = XMLParser(data: data)
    parser.shouldResolveExternalEntities = false
    parser.delegate = inspector
    try require(parser.parse() && inspector.root == "rss" && inspector.channels == 1,
                "Cannot validate the update feed. No keys or repository settings were changed.")
    try require(inspector.items == 0,
                "Updates have already been advertised. Refusing to replace their trust key; recover the existing private key instead.")
}

@discardableResult
func gh(_ arguments: [String], input: Data? = nil) throws -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["gh"] + arguments
    var environment = ProcessInfo.processInfo.environment
    environment["GH_HOST"] = "github.com"
    environment["GH_PROMPT_DISABLED"] = "1"
    environment.removeValue(forKey: "GH_DEBUG")
    process.environment = environment
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.standardError
    let source = Pipe()
    process.standardInput = source
    try process.run()
    if let input { try source.fileHandleForWriting.write(contentsOf: input) }
    try source.fileHandleForWriting.close()
    let result = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    try require(process.terminationStatus == 0,
                "GitHub CLI could not complete this step. Check gh auth status and repository permissions, then retry. No private key is printed.")
    return result
}
func api(_ path: String, method: String = "GET", body: [String: Any]? = nil) throws -> Any {
    var arguments = ["api", "--hostname", "github.com", "--method", method, path]
    var input: Data?
    if let body {
        arguments += ["--input", "-"]
        input = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }
    return try JSONSerialization.jsonObject(with: gh(arguments, input: input))
}
func object(_ value: Any) throws -> [String: Any] {
    guard let result = value as? [String: Any] else { throw SetupError(message: "Unexpected GitHub response.") }
    return result
}
func field(_ value: [String: Any], _ key: String) throws -> String {
    guard let result = value[key] as? String, !result.isEmpty else {
        throw SetupError(message: "Missing GitHub metadata: " + key)
    }
    return result
}
func readSource(_ path: String, ref: String) throws -> Data {
    let result = try object(api("repos/\(repository)/contents/\(path)?ref=\(ref)"))
    guard result["encoding"] as? String == "base64",
          let encoded = result["content"] as? String,
          let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters) else {
        throw SetupError(message: "Could not read tracked source: " + path)
    }
    return data
}
func signingKey() throws -> Curve25519.Signing.PrivateKey {
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                               kSecAttrService as String: keyService, kSecAttrAccount as String: keyAccount]
    var lookup = query
    lookup[kSecReturnData as String] = true
    lookup[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(lookup as CFDictionary, &item)
    if status == errSecSuccess, let bytes = item as? Data {
        return try Curve25519.Signing.PrivateKey(rawRepresentation: bytes)
    }
    try require(status == errSecItemNotFound, "Cannot read the signing key from the login Keychain. Unlock it and retry.")
    let key = Curve25519.Signing.PrivateKey()
    var addition = query
    addition[kSecValueData as String] = key.rawRepresentation
    addition[kSecAttrLabel as String] = "Compositor AI update signing seed (keep safe)"
    addition[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    try require(SecItemAdd(addition as CFDictionary, nil) == errSecSuccess,
                "Could not save the signing seed to Keychain. Nothing was uploaded.")
    return key
}

func configure() throws {
    try require(ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] != "true",
                "Run --configure on the repository owner's Mac, not in Actions.")
    try gh(["auth", "status", "--hostname", "github.com"])
    let repo = try object(api("repos/\(repository)"))
    let permissions = repo["permissions"] as? [String: Any] ?? [:]
    try require(permissions["admin"] as? Bool == true,
                "Use the repository owner's GitHub account with permission to manage Actions secrets.")
    try requireUnpublishedFeed(readSource("appcast.xml", ref: "updates-codex"))
    guard let releases = try api("repos/\(repository)/releases?per_page=100") as? [[String: Any]] else {
        throw SetupError(message: "Could not inspect published releases.")
    }
    try require(releases.count < 100, "Too many releases for a safe bootstrap. Review the existing signing setup manually.")
    try require(!releases.contains { ($0["tag_name"] as? String ?? "").hasPrefix("ai-v") && $0["draft"] as? Bool != true },
                "An AI installer has already been published. Refusing to rotate its trust key automatically.")

    let reference = try object(api("repos/\(repository)/git/ref/heads/\(branch)"))
    let head = try field(object(reference["object"] as Any), "sha")
    let commit = try object(api("repos/\(repository)/git/commits/\(head)"))
    let tree = try field(object(commit["tree"] as Any), "sha")
    let keyPath = "Config/SparklePublicKey.txt"
    let policyPath = "Compositor/Updates/UpdatePolicy.swift"
    let infoPath = "Config/InfoCodex.plist"
    let oldPublic = String(decoding: try readSource(keyPath, ref: head), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    try require(Data(base64Encoded: oldPublic)?.count == 32, "The current public-key configuration is invalid.")
    let policy = String(decoding: try readSource(policyPath, ref: head), as: UTF8.self)
    var info = try PropertyListSerialization.propertyList(from: readSource(infoPath, ref: head), options: [], format: nil) as? [String: Any] ?? [:]
    try require(policy.components(separatedBy: oldPublic).count == 2 && info["SUPublicEDKey"] as? String == oldPublic,
                "The committed trust settings disagree. Refusing a partial key change.")

    let key = try signingKey()
    let newPublic = key.publicKey.rawRepresentation.base64EncodedString()
    info["SUPublicEDKey"] = newPublic
    let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    let changes: [[String: Any]] = [
        ["path": keyPath, "mode": "100644", "type": "blob", "content": newPublic + "\n"],
        ["path": policyPath, "mode": "100644", "type": "blob", "content": policy.replacingOccurrences(of: oldPublic, with: newPublic)],
        ["path": infoPath, "mode": "100644", "type": "blob", "content": String(decoding: plist, as: UTF8.self)]
    ]
    // Only this subprocess receives the private seed, via stdin; its command arguments contain no secret.
    try gh(["secret", "set", "SPARKLE_PRIVATE_KEY", "--repo", repository],
           input: Data((key.rawRepresentation.base64EncodedString() + "\n").utf8))
    let createdTree = try object(api("repos/\(repository)/git/trees", method: "POST", body: ["base_tree": tree, "tree": changes]))
    let createdCommit = try object(api("repos/\(repository)/git/commits", method: "POST", body: [
        "message": "Initialize owner-controlled signing key for the unpublished AI update channel",
        "tree": try field(createdTree, "sha"), "parents": [head]
    ]))
    let sha = try field(createdCommit, "sha")
    // A normal fast-forward fails if somebody changed the feature branch meanwhile. Never force-push.
    _ = try api("repos/\(repository)/git/refs/heads/\(branch)", method: "PATCH", body: ["sha": sha, "force": false])
    print("Signing secret stored in GitHub Actions; private seed retained in your Mac's Keychain.")
    print("Only the public key was committed to \(branch): \(sha)")
    print("Main and the update feed were not changed. GitHub will build the new trust configuration.")
    print("Install the newly built initial app once. Do not distribute earlier test packages with the old public key.")
    print("Future signed releases can then be installed from Settings > Updates.")
}
func selfTest() throws {
    let key = Curve25519.Signing.PrivateKey()
    let message = Data("owner bootstrap self-test".utf8)
    let signature = try key.signature(for: message)
    try require(key.publicKey.isValidSignature(signature, for: message), "Signature test failed")
    try require(!key.publicKey.isValidSignature(signature, for: message + Data([0])), "Tamper test failed")
    try requireUnpublishedFeed(Data("<rss><channel><title>Test</title></channel></rss>".utf8))
    for invalid in ["<rss><channel><item/></channel></rss>", "<rss><channel><item ></item></channel></rss>", "<html/>", "<rss>"] {
        var rejected = false
        do { try requireUnpublishedFeed(Data(invalid.utf8)) } catch { rejected = true }
        try require(rejected, "Published or invalid feed was accepted")
    }
    print("Bootstrap validation passed; no Keychain, GitHub, or repository mutations occurred.")
}
do {
    let args = Array(CommandLine.arguments.dropFirst())
    switch args {
    case ["--self-test"]: try selfTest()
    case ["--configure"]: try configure()
    default:
        print("Run on your Mac: swift scripts/setup_update_signing.swift --configure")
        print("Requires Xcode Command Line Tools and GitHub CLI (gh auth login).")
        print("Initializes only an unpublished channel. For validation without side effects, use --self-test.")
    }
} catch {
    FileHandle.standardError.write(Data(("Signing setup stopped: " + error.localizedDescription + "\n").utf8))
    exit(1)
}
