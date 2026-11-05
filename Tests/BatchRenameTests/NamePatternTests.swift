import BatchRename
import Testing

@Suite struct NamePatternTests {
    private func glob(_ text: String, _ name: String, caseSensitive: Bool = false) throws -> Bool {
        try NamePattern(text, kind: .glob, caseSensitive: caseSensitive).matches(name)
    }

    @Test func starsAndQuestionMarks() throws {
        #expect(try glob("*.jpg", "photo.jpg"))
        #expect(try !glob("*.jpg", "photo.jpg.txt"))
        #expect(try glob("img_??.png", "img_01.png"))
        #expect(try !glob("img_??.png", "img_1.png"))
    }

    @Test func aDotIsADot() throws {
        #expect(try !glob("a.b", "axb"))
    }

    @Test func oneCharacterMeansOneCharacterInAnyScript() throws {
        #expect(try glob("?.txt", "é.txt"))
        #expect(try glob("?.txt", "日.txt"))
    }

    @Test func caseFollowsTheOption() throws {
        #expect(try glob("*.JPG", "a.jpg"))
        #expect(try !glob("*.JPG", "a.jpg", caseSensitive: true))
    }

    @Test func sets() throws {
        #expect(try glob("[abc].txt", "b.txt"))
        #expect(try !glob("[abc].txt", "d.txt"))
        #expect(try glob("[!abc].txt", "d.txt"))
        #expect(try glob("[0-9].txt", "7.txt"))
    }

    @Test func anUnclosedBracketIsLiteral() throws {
        #expect(try glob("a[b", "a[b"))
    }

    @Test func alternatives() throws {
        #expect(try glob("*.jpg; *.png", "a.png"))
        #expect(try !glob("*.jpg; *.png", "a.gif"))
    }

    @Test func emptyMatchesNothing() throws {
        for kind in NamePatternKind.allCases {
            #expect(try !NamePattern("", kind: kind).matches("a"))
        }
        #expect(try !glob(" ; ", "a"))
    }

    @Test func containsIsLiteral() throws {
        let pattern = try NamePattern("(1)", kind: .contains)
        #expect(pattern.matches("report (1).pdf"))
        #expect(!pattern.matches("report 1.pdf"))
    }

    @Test func regexSearchesAnywhere() throws {
        let pattern = try NamePattern(#"\d{4}"#, kind: .regex)
        #expect(pattern.matches("IMG_2024.png"))
        #expect(!pattern.matches("IMG_24.png"))
    }

    @Test func aBadRegexThrows() {
        #expect(throws: BatchRenameError.self) { try NamePattern("(", kind: .regex) }
    }
}
