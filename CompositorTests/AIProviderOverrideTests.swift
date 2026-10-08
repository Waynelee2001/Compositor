import Foundation
import Testing
@testable import Compositor

struct AIProviderOverrideTests {
    @Test func urlsAndCatalogPathsDoNotUseJSONOnlySlashEscapes() {
        #expect(AIProviderProfile.quoted("https://api.deepseek.com") == "\"https://api.deepseek.com\"")
        #expect(AIProviderProfile.quoted("/tmp/model catalog.json") == "\"/tmp/model catalog.json\"")
    }
    @Test func quotesAndBackslashesAreStillEscaped() throws {
        let value = "A \"quoted\" provider \\ name"
        let encoded = AIProviderProfile.quoted(value)
        #expect(try JSONDecoder().decode(String.self, from: Data(encoded.utf8)) == value)
    }
}
