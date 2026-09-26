import Foundation
import Testing
@testable import PromptImage

struct PhotoSearchSnippetTests {
    @Test
    func russianAndEnglishTermsKeepOriginalSpellingAndNormalizeWhitespace() throws {
        let snippet = try #require(PhotoSearchSnippet.make(
            recognizedText: "  РЕЦЕПТ\n\tпирога. Add   Cinnamon\r\nand sugar.  ",
            query: "рецепт cinnamon"))

        #expect(snippet.text == "РЕЦЕПТ пирога. Add Cinnamon and sugar.")
        #expect(highlights(snippet) == ["РЕЦЕПТ", "Cinnamon"])
        #expect(snippet.segments.map(\.text).joined() == snippet.text)
    }

    @Test
    func usesWholeWordsAndLiteralTermsWithoutStemmingOrOperators() throws {
        let snippet = try #require(PhotoSearchSnippet.make(
            recognizedText: "concatenate cats cat: OR собака, собаке; 12 123", query: "cat OR собака 12"))
        #expect(highlights(snippet) == ["cat", "OR", "собака", "12"])
        #expect(PhotoSearchSnippet.make(recognizedText: "concatenate cats", query: "cat") == nil)
        #expect(PhotoSearchSnippet.make(recognizedText: "собаке", query: "собака") == nil)
    }

    @Test
    func punctuationSeparatesQueryTermsAndTextIsNeverInterpretedAsMarkup() throws {
        let snippet = try #require(PhotoSearchSnippet.make(
            recognizedText: "<b>кот</b> & собака — test@example.com", query: "\"кот\" (собака*) example.com"))
        #expect(highlights(snippet) == ["кот", "собака", "example", "com"])
        #expect(snippet.text == "<b>кот</b> & собака — test@example.com")
    }

    @Test
    func commonLatinAccentsMatchWithoutConflatingRussianLetters() throws {
        let latin = try #require(PhotoSearchSnippet.make(
            recognizedText: "CAFÉ cafe\u{301} naïve", query: "cafe naive"))
        #expect(highlights(latin) == ["CAFÉ", "cafe\u{301}", "naïve"])
        let russian = try #require(PhotoSearchSnippet.make(
            recognizedText: "все всё ВСЁ", query: "всё"))
        #expect(highlights(russian) == ["всё", "ВСЁ"])
        #expect(PhotoSearchSnippet.make(recognizedText: "ёлка", query: "елка") == nil)
    }

    @Test
    func findsMatchingContextFarIntoOCRAndBoundsBothEnds() throws {
        let text = String(repeating: "далёкое вступление ", count: 1_000)
            + "нужный РЕЦЕПТ яблочного пирога "
            + String(repeating: "дальнейшие указания ", count: 1_000)
        let snippet = try #require(PhotoSearchSnippet.make(recognizedText: text, query: "рецепт"))
        #expect(snippet.text.hasPrefix("… "))
        #expect(snippet.text.hasSuffix(" …"))
        #expect(snippet.text.contains("РЕЦЕПТ яблочного пирога"))
        #expect(highlights(snippet) == ["РЕЦЕПТ"])
        #expect(snippet.text.count <= PhotoSearchSnippet.maximumCharacters)
    }

    @Test(arguments: ["beginning", "end"])
    func omitsOnlyTheTruncatedSide(_ location: String) throws {
        let padding = String(repeating: "filler ", count: 100)
        let text = location == "beginning" ? "needle " + padding : padding + "needle"
        let snippet = try #require(PhotoSearchSnippet.make(recognizedText: text, query: "needle"))
        #expect(snippet.text.hasPrefix("… ") == (location == "end"))
        #expect(snippet.text.hasSuffix(" …") == (location == "beginning"))
        #expect(highlights(snippet) == ["needle"])
        #expect(snippet.text.count <= PhotoSearchSnippet.maximumCharacters)
    }

    @Test
    func preservesGraphemesAndDoesNotHighlightPartialNeighborWords() throws {
        let text = String(repeating: "👨‍👩‍👧‍👦 ", count: 40)
            + "cat " + String(repeating: "concatenate ", count: 40)
        let snippet = try #require(PhotoSearchSnippet.make(recognizedText: text, query: "cat"))
        #expect(highlights(snippet) == ["cat"])
        #expect(!snippet.text.contains("�"))
        #expect(snippet.text.count <= PhotoSearchSnippet.maximumCharacters)
        #expect(snippet.text.filter { $0 == "👨‍👩‍👧‍👦" }.count > 0)
    }

    @Test
    func unusuallyLongMatchingWordStillHasBoundedMarkedExcerpt() throws {
        let word = String(repeating: "a", count: 500)
        let snippet = try #require(PhotoSearchSnippet.make(recognizedText: word, query: word))
        #expect(snippet.text.count <= PhotoSearchSnippet.maximumCharacters)
        #expect(snippet.text.hasSuffix(" …"))
        #expect(highlights(snippet) == [String(word.prefix(196))])
    }

    @Test(arguments: ["", " \n ", "!!!", String(repeating: "a", count: 4_097),
                      String(repeating: "word ", count: 33)])
    func invalidQueriesProduceNoExcerpt(_ query: String) {
        #expect(PhotoSearchSnippet.make(recognizedText: "word recipe", query: query) == nil)
    }

    @Test
    func absentOrEmptyRecognizedTextProducesNoExcerpt() {
        #expect(PhotoSearchSnippet.make(recognizedText: "", query: "recipe") == nil)
        #expect(PhotoSearchSnippet.make(recognizedText: "other words", query: "recipe") == nil)
    }

    private func highlights(_ snippet: PhotoSearchSnippet) -> [String] {
        snippet.segments.filter(\.isMatch).map(\.text)
    }
}
