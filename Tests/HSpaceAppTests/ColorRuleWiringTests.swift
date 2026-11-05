import AppKit
import FileMetadata
import HSpaceContracts
import HSpaceTestSupport
import Testing
@testable import HSpaceApp

@Suite struct RuleConditionFormTests {
    @Test func everyConditionSurvivesTheForm() {
        let conditions: [RuleCondition] = [
            .nameContains("draft"), .fileExtension(["jpg", "png"]), .hasTag("Work"), .isFolder, .modifiedWithin(days: 7),
        ]
        for condition in conditions {
            #expect(RuleConditionForm(condition).condition == condition)
        }
    }

    @Test func extensionsAcceptDotsCommasAndSpaces() {
        let form = RuleConditionForm(kind: .fileExtension, value: " .jpg, png  .heic")
        #expect(form.condition == .fileExtension(["jpg", "png", "heic"]))
    }

    @Test func unusableValuesGiveNoCondition() {
        #expect(RuleConditionForm(kind: .nameContains, value: "  ").condition == nil)
        #expect(RuleConditionForm(kind: .hasTag, value: "").condition == nil)
        #expect(RuleConditionForm(kind: .fileExtension, value: " , ").condition == nil)
        #expect(RuleConditionForm(kind: .modifiedWithin, value: "soon").condition == nil)
        #expect(RuleConditionForm(kind: .modifiedWithin, value: "0").condition == nil)
    }
}

@MainActor @Suite struct NameCellInkTests {
    private let item = FileItem(url: URL(fileURLWithPath: "/x/a"), name: "a", isDirectory: false, isPackage: false,
                                isSymlink: false, isHidden: false, size: nil, modified: nil, created: nil, contentTypeID: nil)

    private func cell() -> NameCellView {
        let cell = NameCellView(identifier: .init("t"))
        cell.configure(icon: NSImage(), name: "a", dimmed: false)
        return cell
    }

    @Test func aColourTintsTheName() {
        let cell = cell()
        cell.decorate(FileDecoration(item, ItemMetadata(color: .red)))
        #expect(cell.textField?.textColor == .systemRed)
    }

    @Test func aSelectedRowKeepsTheSystemInk() {
        let cell = cell()
        cell.decorate(FileDecoration(item, ItemMetadata(color: .red)))
        cell.backgroundStyle = .emphasized
        #expect(cell.textField?.textColor != .systemRed)
        cell.backgroundStyle = .normal
        #expect(cell.textField?.textColor == .systemRed)
    }

    @Test func reusingACellDropsTheColour() {
        let cell = cell()
        cell.decorate(FileDecoration(item, ItemMetadata(color: .red)))
        cell.configure(icon: NSImage(), name: "b", dimmed: false)
        #expect(cell.textField?.textColor == .labelColor)
    }
}
