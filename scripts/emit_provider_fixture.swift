import Foundation

/// Built against the same profile encoder as the app; no duplicated provider configuration in the smoke test.
@main
struct EmitProviderFixture {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { fatalError("Expected endpoint and catalog path") }
        var profile = ModelProfile.deepSeek
        profile.baseURL = CommandLine.arguments[1]
        let catalogURL = URL(fileURLWithPath: CommandLine.arguments[2])
        let flags = try ModelProviderConfiguration.overrides(profile, catalogURL: catalogURL, usesKey: true)
        let output: CodexJSON = [
            "catalog": ModelProviderConfiguration.catalog(profile, instructions: "Use only compositor_ci_probe. Then say Done."),
            "flags": .array(flags.map(CodexJSON.string)), "model": .string(profile.model),
            "envKey": .string(ModelProviderConfiguration.credentialEnvironmentKey)
        ]
        print(output.pretty)
    }
}
