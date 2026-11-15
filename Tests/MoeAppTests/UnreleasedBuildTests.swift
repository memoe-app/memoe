import Foundation
import Testing
@testable import Moe

/// A build of main between two releases carries the last release's version,
/// so the app has to say which of the two it is. build.sh stamps
/// `MoeReleaseBuild` ("1" only under publish-release.sh); these pin what the
/// app does with each value, without a bundle.
struct UnreleasedBuildTests {

    @Test("a published build says nothing extra")
    func releaseIsQuiet() {
        let info: [String: Any] = ["MoeReleaseBuild": "1", "MoeCommit": "ae3b2d4d"]
        #expect(BuildInfo.isUnreleasedBuild(info) == false)
        #expect(BuildInfo.unreleasedNote(info) == nil)
    }

    @Test("any other build of the same version names its commit")
    func unreleasedNamesTheCommit() {
        let info: [String: Any] = ["MoeReleaseBuild": "0", "MoeCommit": "ae3b2d4d",
                                   "CFBundleShortVersionString": "0.3.24", "CFBundleVersion": "31"]
        #expect(BuildInfo.isUnreleasedBuild(info))
        #expect(BuildInfo.unreleasedNote(info) == "Not the published release: built from commit ae3b2d4d.")
    }

    @Test("a bundle with no stamp claims nothing")
    func absentIsNotUnreleased() {
        // Every Memoe published before the stamp existed has no key. Calling
        // those "unreleased" would be a false statement about a real release.
        #expect(BuildInfo.isUnreleasedBuild(["MoeCommit": "ae3b2d4d"]) == false)
        #expect(BuildInfo.isUnreleasedBuild(nil) == false)
        #expect(BuildInfo.unreleasedNote(nil) == nil)
    }

    @Test("an unreleased build with no commit still says it is not the release")
    func unreleasedWithoutCommit() {
        #expect(BuildInfo.unreleasedNote(["MoeReleaseBuild": "0"]) == "Not the published release: built on this Mac.")
    }
}
