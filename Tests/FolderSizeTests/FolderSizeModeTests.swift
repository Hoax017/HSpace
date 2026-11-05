import FolderSize
import Testing

@Suite struct FolderSizeModeTests {
    @Test func allMeasuresAnyVolume() {
        #expect(FolderSizeMode.all.shouldMeasure(isLocal: false, columnVisible: true))
        #expect(FolderSizeMode.all.shouldMeasure(isLocal: nil, columnVisible: true))
    }

    @Test func localOnlyLeavesNetworkAndUnknownVolumesAlone() {
        #expect(FolderSizeMode.localOnly.shouldMeasure(isLocal: true, columnVisible: true))
        #expect(!FolderSizeMode.localOnly.shouldMeasure(isLocal: false, columnVisible: true))
        #expect(!FolderSizeMode.localOnly.shouldMeasure(isLocal: nil, columnVisible: true))
    }

    @Test func neverMeasuresNothing() {
        #expect(!FolderSizeMode.never.shouldMeasure(isLocal: true, columnVisible: true))
    }

    @Test func aHiddenSizeColumnMeasuresNothing() {
        for mode in FolderSizeMode.allCases {
            #expect(!mode.shouldMeasure(isLocal: true, columnVisible: false))
        }
    }
}
