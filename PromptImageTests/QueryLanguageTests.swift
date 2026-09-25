import Foundation
import NaturalLanguage
import Testing
@testable import PromptImage

struct QueryLanguageTests {
    @Test
    func preservesOriginalTextAndOnlyTrimsTheProcessingCopy() throws {
        let text = "\n  Фото кота  на диване\t"
        let route = try QueryLanguageRouter(detector: { _ in [.russian: 0.99] }).route(text)
        #expect(route.originalText == text)
        #expect(route.text == "Фото кота  на диване")
        #expect(route.language == .russian)
    }

    @Test
    func validatesBeforeApplyingExplicitLanguageChoice() throws {
        let router = QueryLanguageRouter(detector: { _ in [:] })
        for choice in QueryLanguageChoice.allCases {
            for empty in ["", " \n\t", "\u{00A0}\u{2003}"] {
                #expect(throws: QueryInputError.empty) {
                    try router.route(empty, choice: choice)
                }
            }
            #expect(throws: QueryInputError.tooLong) {
                try router.route(String(repeating: "a", count: 16_385), choice: choice)
            }
            #expect(throws: QueryInputError.tooLong) {
                try router.route(String(repeating: "🐱", count: 4097), choice: choice)
            }
            // A huge whitespace suffix cannot evade the bound by being trimmed first.
            #expect(throws: QueryInputError.tooLong) {
                try router.route("a" + String(repeating: " ", count: 16_384), choice: choice)
            }
        }
        #expect(try router.route(String(repeating: "я", count: 8192), choice: .russian).text.utf8.count == 16_384)
        #expect(try router.route(String(repeating: "a", count: 16_384), choice: .english).text.utf8.count == 16_384)
    }

    @Test
    func explicitChoiceHandlesShortWordsAndMixedDescriptionsWithoutDetection() throws {
        let router = QueryLanguageRouter(detector: { _ in
            Issue.record("An explicit language choice must not invoke automatic detection")
            return [:]
        })
        for text in ["cat", "кот", "кот рядом с MacBook", "2024", "🐱"] {
            #expect(try router.route(text, choice: .russian).language == .russian)
            #expect(try router.route(text, choice: .english).language == .english)
        }
    }

    @Test
    func automaticChoiceRequiresEnoughTextAndOneSupportedScript() throws {
        let router = QueryLanguageRouter(detector: { _ in
            Issue.record("Insufficient text or unsupported scripts should be handled before detection")
            return [:]
        })
        for text in ["cat", "кот", "🐱 2024", "...", "кот рядом с MacBook"] {
            #expect(throws: QueryInputError.ambiguousLanguage) { try router.route(text) }
        }
        for text in ["这是一张猫的照片", "これは猫の写真です", "صورة قطة"] {
            #expect(throws: QueryInputError.unsupportedLanguage) { try router.route(text) }
        }
    }

    @Test
    func automaticChoiceRequiresConfidenceAndSeparationFromAlternatives() throws {
        let uncertain: [[NLLanguage: Double]] = [
            [:], [.english: 0.79], [.english: 0.85, .dutch: 0.7],
            [.english: 0.9, .russian: 0.9], [.undetermined: 1],
            [.english: .nan], [.english: .infinity], [.english: -1], [.english: 1.01],
        ]
        for hypotheses in uncertain {
            let router = QueryLanguageRouter(detector: { _ in hypotheses })
            #expect(throws: QueryInputError.ambiguousLanguage) { try router.route("a sleeping cat") }
        }
        let confident = QueryLanguageRouter(detector: { _ in [.english: 0.9, .dutch: 0.1] })
        #expect(try confident.route("a sleeping cat").language == .english)
        #expect(try confident.route("a cafe\u{0301} in the city").language == .english)
    }

    @Test
    func automaticChoiceDoesNotTreatLatinAsEnglishOrCyrillicAsRussian() {
        let cases: [(String, NLLanguage)] = [
            ("un chat sur le canapé", .french),
            ("una foto de un gato", .spanish),
            ("кіт на дивані", .ukrainian),
            ("котка на дивана", .bulgarian),
        ]
        for (text, language) in cases {
            let router = QueryLanguageRouter(detector: { _ in [language: 0.99] })
            #expect(throws: QueryInputError.unsupportedLanguage) { try router.route(text) }
        }
        #expect(throws: QueryInputError.ambiguousLanguage) {
            try QueryLanguageRouter(detector: { _ in [.english: 0.99] }).route("Фотография спящего кота")
        }
        #expect(throws: QueryInputError.ambiguousLanguage) {
            try QueryLanguageRouter(detector: { _ in [.russian: 0.99] }).route("a sleeping cat")
        }
    }

    @Test
    func naturalLanguageRecognizesClearRussianAndEnglishDescriptions() throws {
        let router = QueryLanguageRouter()
        #expect(try router.route("Фотография рыжего кота, который спит на диване рядом с окном").language == .russian)
        #expect(try router.route("A photograph of an orange cat sleeping on the sofa beside the window").language == .english)
    }
}
