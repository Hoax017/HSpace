import Testing
import Foundation
import VolumeInfo

/// Black-box acceptance: real system volumes (no fakes or mocks)
@Suite struct VolumeInfoTests {
    @Test func volumesContainRootWithCapacity() {
        let vols = VolumeInfo().volumes()
        #expect(!vols.isEmpty)
        let root = vols.first { $0.isRoot }
        #expect(root != nil)
        #expect((root?.totalCapacity ?? 0) > 0)
        #expect((root?.availableCapacity ?? 0) > 0)
        #expect(root?.isEjectable != true)
    }

    @Test func ejectRootFailsClassified() {
        // The root volume cannot be ejected: must throw a classified error, not crash
        do {
            try VolumeInfo().eject(URL(fileURLWithPath: "/"))
            Issue.record("Ejecting the root volume should fail")
        } catch let e as VolumeError {
            #expect(e.errorClass == .external)
        } catch {
            Issue.record("Unclassified error:\(error)")
        }
    }
}
