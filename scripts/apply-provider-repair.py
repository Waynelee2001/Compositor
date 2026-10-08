from pathlib import Path
r = Path('.')
def edit(p, a, b):
    f = r/p
    s = f.read_text()
    assert a in s, (p, a[:80])
    f.write_text(s.replace(a, b))
edit('Compositor/AI/AIProviderProfile.swift', '"description": .string(name), "supported_reasoning_levels": [], "shell_type": "shell_command",', '''"description": .string(name),
                "base_instructions": "You are Compositor's photo-editing assistant. Follow the application's instructions and use only the supplied editor tools.",
                "supported_reasoning_levels": [], "shell_type": "shell_command",''')
edit('Compositor/AI/AIProviderProfile.swift', '    var isDeepSeek: Bool {', '''    /// Bind saved credentials to the exact normalized endpoint, not just an editable profile ID.
    func keychainAccount() throws -> String {
        id + "." + Data(try endpoint().absoluteString.utf8).base64EncodedString()
    }
    var isDeepSeek: Bool {''')
edit('Compositor/AI/AIProviderStore.swift', 'old.baseURL != value.baseURL || old.supportsImages != value.supportsImages { value.revision = UUID().uuidString }', 'old.baseURL != value.baseURL || old.supportsImages != value.supportsImages || !(key ?? "").isEmpty { value.revision = UUID().uuidString }')
edit('Compositor/AI/AIProviderStore.swift', 'try AIProviderKeys.set(key, for: value.id)', 'try AIProviderKeys.set(key, for: value.keychainAccount())')
edit('Compositor/AI/AIProviderStore.swift', '        try AIProviderKeys.remove(id)', '        if let profile = profiles.first(where: { $0.id == id }) { try AIProviderKeys.remove(profile.keychainAccount()) }')
edit('Compositor/AI/AIProviderControls.swift', 'AIProviderKeys.remove(profile.id)', 'AIProviderKeys.remove(profile.keychainAccount())')
edit('Compositor/AI/AIProviderControls.swift', 'AIProviderKeys.read(profile.id)', 'AIProviderKeys.read(profile.keychainAccount())')
edit('Compositor/AI/CodexChatSession.swift', 'AIProviderKeys.read(selected.id)', 'AIProviderKeys.read(selected.keychainAccount())')
edit('Compositor/UI/AppAppearance.swift', '''    static func canvas(_ appearance: NSAppearance) -> NSColor { NSColor(white: isDark(appearance) ? 0.105 : 0.90, alpha: 1) }
    static func checker(_ appearance: NSAppearance, alternate: Bool) -> NSColor {
        let value: CGFloat = isDark(appearance) ? (alternate ? 0.35 : 0.30) : (alternate ? 0.89 : 0.97)
        return NSColor(white: value, alpha: 1)
    }''', '''    // Both CPU and GPU canvases use these exact sRGB values. Chrome must never enter exported pixels.
    static func canvasWhite(_ appearance: NSAppearance) -> CGFloat { isDark(appearance) ? 0.105 : 0.90 }
    static func checkerWhite(_ appearance: NSAppearance, alternate: Bool) -> CGFloat {
        isDark(appearance) ? (alternate ? 0.35 : 0.30) : (alternate ? 0.89 : 0.97)
    }
    static func edgeWhite(_ appearance: NSAppearance) -> CGFloat { isDark(appearance) ? 1 : 0 }
    static func canvas(_ appearance: NSAppearance) -> NSColor { gray(canvasWhite(appearance)) }
    static func checker(_ appearance: NSAppearance, alternate: Bool) -> NSColor { gray(checkerWhite(appearance, alternate: alternate)) }
    static func edge(_ appearance: NSAppearance) -> NSColor { gray(edgeWhite(appearance)).withAlphaComponent(0.13) }
    private static func gray(_ value: CGFloat) -> NSColor { NSColor(srgbRed: value, green: value, blue: value, alpha: 1) }''')
edit('Compositor/Rendering/EditorCanvas.swift', '        context.setFillColor(NSColor.separatorColor.cgColor)\n        context.fill(rect)', '        context.setFillColor(CGColor(gray: 1, alpha: 1))\n        context.fill(rect)')
edit('Compositor/Rendering/EditorCanvas.swift', 'context.setStrokeColor(NSColor.labelColor.withAlphaComponent(0.13).cgColor)', 'context.setStrokeColor(EditorPalette.edge(effectiveAppearance).cgColor)')
edit('Compositor/Rendering/EditorCanvas.swift', 'var frame = gray(0.105).cropped(to: full)', 'var frame = gray(EditorPalette.canvasWhite(effectiveAppearance)).cropped(to: full)')
edit('Compositor/Rendering/EditorCanvas.swift', '''        let squares = gray(0.35).cropped(to: CGRect(x: 0, y: 0, width: tile, height: tile))
            .composited(over: gray(0.30).cropped(to: CGRect(x: tile, y: 0, width: tile, height: tile)))
            .composited(over: gray(0.30).cropped(to: CGRect(x: 0, y: tile, width: tile, height: tile)))
            .composited(over: gray(0.35).cropped(to: CGRect(x: tile, y: tile, width: tile, height: tile)))''', '''        let plain = gray(EditorPalette.checkerWhite(effectiveAppearance, alternate: false))
        let alternate = gray(EditorPalette.checkerWhite(effectiveAppearance, alternate: true))
        let squares = alternate.cropped(to: CGRect(x: 0, y: 0, width: tile, height: tile))
            .composited(over: plain.cropped(to: CGRect(x: tile, y: 0, width: tile, height: tile)))
            .composited(over: plain.cropped(to: CGRect(x: 0, y: tile, width: tile, height: tile)))
            .composited(over: alternate.cropped(to: CGRect(x: tile, y: tile, width: tile, height: tile)))''')
edit('Compositor/Rendering/EditorCanvas.swift', 'let edge = gray(1, alpha: 0.13)', 'let edge = gray(EditorPalette.edgeWhite(effectiveAppearance), alpha: 0.13)')
edit('CompositorTests/GPUCanvasTests.swift', '''backingScale: Int = 2, inWindow: Bool = false) throws -> Difference {
        let canvas = CanvasView(session: session)''', '''backingScale: Int = 2, inWindow: Bool = false, appearance: NSAppearance? = nil) throws -> Difference {
        let canvas = CanvasView(session: session)
        canvas.appearance = appearance''')
needle = '    @Test(arguments: [1.0, 2.0 / 3.0, 1.0 / 3.0, 2.0])'
edit('CompositorTests/GPUCanvasTests.swift', needle, '''    @Test(arguments: ["NSAppearanceNameAqua", "NSAppearanceNameDarkAqua"])
    func themeChromeMatchesBetweenRenderers(appearanceName: String) throws {
        guard GPUCanvasRenderer.shared != nil else { return }
        let appearance = try #require(NSAppearance(named: NSAppearance.Name(appearanceName)))
        let difference = try compare(try session(zoom: 1), name: "theme-" + appearanceName, appearance: appearance)
        #expect(difference.mean < 1.5 && difference.over < 0.01,
                "CPU/GPU theme parity: mean \\(difference.mean), over 12 levels \\(difference.over * 100)%")
    }

''' + needle)
edit('CompositorTests/ProviderTests.swift', '    @Test func endpointsAreNormalizedAndUnsafeAddressesRejected()', '''    @Test func customCatalogHasRequiredBaseInstructions() {
        var custom = AIProviderProfile.custom()
        custom.baseURL = "http://127.0.0.1:1234/v1"; custom.model = "example-model"
        for profile in [AIProviderProfile.deepSeek, custom] {
            for model in profile.catalog()["models"].array {
                #expect(!(model["base_instructions"].string ?? "").isEmpty)
            }
        }
    }
    @Test func credentialsAreBoundToNormalizedEndpoint() throws {
        let original = AIProviderProfile.deepSeek
        var edited = original; edited.baseURL = "https://other-provider.example/v1"
        #expect(try edited.keychainAccount() != original.keychainAccount())
        edited.baseURL = "https://api.deepseek.com/responses/"
        #expect(try edited.keychainAccount() == original.keychainAccount())
        edited.id = "different-profile"
        #expect(try edited.keychainAccount() != original.keychainAccount())
    }
    @Test func endpointsAreNormalizedAndUnsafeAddressesRejected()''')
f = r/'docs/providers-and-appearance.md'
s = f.read_text().replace('Changing an endpoint rotates its scope.', 'Changing an endpoint or saving a replacement key rotates its scope. Keychain accounts are bound to the normalized endpoint: changing the host, port or base path never silently reuses the previous endpoint’s key.')
s += '\nBoth the Core Graphics and GPU canvas paths share the same sRGB appearance palette. Theme parity is regression-tested in both appearances; export rendering remains independent of the appearance.\n'
f.write_text(s)
f = r/'.github/workflows/providers-themes.yml'
s = f.read_text()
start = s.index('  source:\n'); end = s.index('  codex:\n')
s = s[:start] + s[end:]
s = s.replace('    needs: source\n', '').replace('          ref: ${{ needs.source.outputs.sha }}\n', '')
f.write_text(s)
