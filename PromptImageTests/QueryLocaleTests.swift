import Foundation
import Testing
@testable import PromptImage

@MainActor
struct QueryLocaleTests {
    @Test
    func translationPairIsExplicitRegardlessOfSystemLocale() throws {
        // Also run this suite with xcodebuild -testLanguage fr -testRegion FR.
        let manifest = try TranslationModelResources().manifest
        #expect(manifest.sourceLanguages == ["ru"])
        #expect(manifest.targetLanguage == "en")
        print("QUERY_LOCALE locale=\(Locale.current.identifier) languages=\(Locale.preferredLanguages.joined(separator: ","))")
    }

    @Test
    func explicitLanguageChoiceNeverUsesTheSystemLanguage() throws {
        let router = QueryLanguageRouter(detector: { _ in
            Issue.record("Explicit choice must not ask for language detection.")
            return [:]
        })
        #expect(try router.route("кот", choice: .russian).language == .russian)
        #expect(try router.route("cat", choice: .english).language == .english)
    }
}
