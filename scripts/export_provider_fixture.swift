import Foundation

@main
struct ExportProviderFixture {
    static func main() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var profile = AIProviderProfile.deepSeek()
        profile.baseURL = CommandLine.arguments[2]
        let catalog = directory.appendingPathComponent("models.json")
        try profile.catalogData().write(to: catalog)
        let parameters = try profile.overrides(catalog: catalog)
        try JSONEncoder().encode(parameters).write(to: directory.appendingPathComponent("arguments.json"))
        let endpoint = try AIProviderProfile.normalizedEndpoint("http://127.0.0.1:1234/v1/responses/")
        precondition(endpoint.absoluteString == "http://127.0.0.1:1234/v1")
        for bad in ["http://example.com", "https://user:secret@example.com", "https://example.com?key=x", "https://example.com/chat/completions"] {
            do { _ = try AIProviderProfile.normalizedEndpoint(bad); fatalError("Unsafe endpoint accepted") }
            catch is AIProviderError { }
        }
        precondition(profile.acceptsImages && profile.model == "deepseek-flash")
        precondition(!parameters.joined().contains("test-secret"))
        print("PASS: provider endpoint validation and production catalog/launch arguments")
    }
}
