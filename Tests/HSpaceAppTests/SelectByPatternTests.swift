import AppKit
import HSpaceContracts
import Testing
@testable import HSpaceApp

@MainActor @Suite struct SelectByPatternTests {
    private func item(_ name: String, directory: Bool = false, package: Bool = false) -> FileItem {
        FileItem(url: URL(fileURLWithPath: "/x/" + name), name: name, isDirectory: directory, isPackage: package,
                 isSymlink: false, isHidden: false, size: nil, modified: nil, created: nil, contentTypeID: nil)
    }

    private func names(_ urls: [URL]) -> [String] { urls.map(\.lastPathComponent) }

    private func model(selected: [String] = []) -> SelectByPatternModel {
        let items = [item("a.jpg"), item("b.png"), item("c.jpg"), item("photos.jpg", directory: true), item("Pages.app", directory: true, package: true)]
        return SelectByPatternModel(items: items, selected: Set(selected.map { URL(fileURLWithPath: "/x/" + $0) }))
    }

    @Test func anEmptyPatternSelectsNothingEvenInverted() {
        let model = model(selected: ["a.jpg"])
        model.invert = true
        #expect(model.matches.isEmpty)
        #expect(model.result.isEmpty)
    }

    @Test func replaceAddAndRemove() {
        let model = model(selected: ["b.png", "c.jpg"])
        model.text = "*.jpg"
        #expect(names(model.result) == ["a.jpg", "c.jpg", "photos.jpg"])
        model.mode = .add
        #expect(names(model.result) == ["a.jpg", "b.png", "c.jpg", "photos.jpg"])
        model.mode = .remove
        #expect(names(model.result) == ["b.png"])
    }

    @Test func invertPicksTheRest() {
        let model = model()
        model.text = "*.jpg"
        model.invert = true
        #expect(names(model.result) == ["b.png", "Pages.app"])
    }

    @Test func filesAndFoldersCanBeLeftOutAndAPackageIsAFile() {
        let model = model()
        model.text = "*"
        model.kinds = .files
        #expect(names(model.result) == ["a.jpg", "b.png", "c.jpg", "Pages.app"])
        model.kinds = .folders
        #expect(names(model.result) == ["photos.jpg"])
    }

    @Test func aBadExpressionIsShownInPlace() {
        let model = model()
        model.text = "("
        model.kind = .regex
        #expect(model.problem != nil)
        #expect(model.summary == model.problem)
        #expect(model.matches.isEmpty)
    }

    @Test func theCountIsSaid() {
        let model = model()
        model.text = "*.png"
        #expect(model.summary == L10n.f("pattern.summary", 1, 5))
    }

    @Test func theSheetBuilds() {
        let sheet = SelectByPatternSheetController(items: [], selected: [], host: NSWindow()) { _ in }
        #expect(sheet.model.items.isEmpty)
    }
}
