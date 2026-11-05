import AppKit
import HSpaceContracts
import HSpaceKernel
import HSpaceTestSupport
import ImageConvert
import Testing
@testable import HSpaceApp

@MainActor @Suite struct ImageConvertModelTests {
    private func image(at url: URL) throws {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
    }

    @Test func aSizeIsRequiredOnceResizingIsOn() {
        let model = ImageConvertModel(sources: [])
        #expect(model.resize == .original)
        model.resizeMode = .percent
        #expect(model.resize == nil)
        #expect(model.options == nil)
        model.resizeValue = "150"
        #expect(model.resize == nil)
        model.resizeValue = "50"
        #expect(model.resize == .percent(50))
        model.resizeMode = .longestSide
        model.resizeValue = "1600"
        #expect(model.resize == .longestSide(1600))
        model.resizeValue = "0"
        #expect(model.resize == nil)
    }

    @Test func outputsAndFailuresAreBothKept() async throws {
        let dir = try FaultFixture.tempDir("hspace-image-model")
        defer { FaultFixture.remove(dir) }
        let good = dir.appendingPathComponent("a.png"), bad = dir.appendingPathComponent("b.png")
        try image(at: good)
        try FaultFixture.write(to: bad)
        let model = ImageConvertModel(sources: [good, bad])
        model.formatIndex = 0
        model.resizeMode = .percent
        model.resizeValue = "50"
        await model.run()
        #expect(!model.isRunning)
        #expect(model.outputs.map(\.lastPathComponent) == ["a 2.png"])
        #expect(model.failures.count == 1)
    }

    @Test func onlyImagesAreOffered() {
        func item(_ type: String?, directory: Bool = false) -> FileItem {
            FileItem(url: URL(fileURLWithPath: "/x"), name: "x", isDirectory: directory, isPackage: false, isSymlink: false,
                     isHidden: false, size: nil, modified: nil, created: nil, contentTypeID: type)
        }
        #expect(ImageConvertModel.isImage(item("public.png")))
        #expect(!ImageConvertModel.isImage(item("public.plain-text")))
        #expect(!ImageConvertModel.isImage(item(nil)))
        #expect(!ImageConvertModel.isImage(item("public.png", directory: true)))
    }

    @Test func aConversionIsOneUndo() {
        let coordinator = FileOpsCoordinator(kernel: OperationKernel(), grid: PaneGridController(initialDirectory: URL(fileURLWithPath: "/")))
        coordinator.undoManager.groupsByEvent = false
        coordinator.undoManager.beginUndoGrouping()
        coordinator.registerImageOutputUndo([URL(fileURLWithPath: "/nonexistent/a.jpg")])
        coordinator.undoManager.endUndoGrouping()
        #expect(coordinator.undoManager.undoActionName == L10n.t("undo.imageConvert"))
    }

    @Test func noOutputsNoUndo() {
        let coordinator = FileOpsCoordinator(kernel: OperationKernel(), grid: PaneGridController(initialDirectory: URL(fileURLWithPath: "/")))
        coordinator.undoManager.groupsByEvent = false
        coordinator.registerImageOutputUndo([])
        #expect(!coordinator.undoManager.canUndo)
    }

    @Test func theSheetBuilds() {
        let coordinator = FileOpsCoordinator(kernel: OperationKernel(), grid: PaneGridController(initialDirectory: URL(fileURLWithPath: "/")))
        let sheet = ImageConvertSheetController(sources: [URL(fileURLWithPath: "/a.png")], coordinator: coordinator, host: NSWindow())
        #expect(sheet.model.sources.count == 1)
    }
}
