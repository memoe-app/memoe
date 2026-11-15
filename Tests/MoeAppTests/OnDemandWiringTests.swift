import Foundation
import Testing
@testable import Moe
import MoeComponents

/// The on-demand components and the app's own model tables must agree
/// (docs/SLIM-DOWNLOAD.md). Each of these is a way a slim build could lose a
/// model silently: fetched into one directory and looked for in another,
/// or left behind as a link to nothing.
struct OnDemandWiringTests {

    @Test func theFetcherPutsModelsWhereTheAppLinksThem() {
        #expect(ComponentCatalog.modelsRoot.path == Models.Root.appSupport.url.path)
    }

    @Test func everyOnDemandComponentIsAModelTheAppKnows() {
        for component in ComponentCatalog.all {
            let known = Models.bundled.first { $0.name == component.folder }
            #expect(known != nil, "\(component.folder) is on demand but not in Models.bundled")
            // Both of slice 1's are recognisers; a voice would live in the
            // other root and need its own `modelsRoot`.
            if let known, case .cache = known.root {
                Issue.record("\(component.folder) belongs in ~/.cache, but the fetcher installs under Application Support")
            }
        }
    }

    @Test func aTestProcessIsNeverASlimBuild() {
        // No Info.plist key → off. The whole suite runs with the app's
        // launch hooks able to fire; none may start a download.
        #expect(OnDemandModels.mode == .off)
    }

    /// A stand-in for an app's `Contents/Resources/Models`.
    private func scratch(_ carried: [String]) throws -> (bundle: URL, roots: URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("moe-ondemand-\(UUID().uuidString)", isDirectory: true)
        let bundle = base.appendingPathComponent("New.app/Models", isDirectory: true)
        for name in carried {
            let dir = bundle.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("weights".utf8).write(to: dir.appendingPathComponent("model.bin"))
        }
        return (bundle, base.appendingPathComponent("roots", isDirectory: true))
    }

    @Test func aSlimUpdateClearsTheLinkTheFullBuildLeft() throws {
        let fm = FileManager.default
        let boost = ComponentCatalog.vocabularyBoost.folder
        // The slim app carries the streaming recogniser and not the boost.
        let s = try scratch(["parakeet-eou-streaming"])
        defer { try? fm.removeItem(at: s.bundle.deletingLastPathComponent().deletingLastPathComponent()) }
        let cache = Models.Root.appSupport.url(under: s.roots)
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        // What the full build before it left: links into an app that is gone.
        for name in [boost, "parakeet-eou-streaming"] {
            try fm.createSymbolicLink(at: cache.appendingPathComponent(name),
                                      withDestinationURL: URL(fileURLWithPath: "/nonexistent/Old.app/Models/\(name)"))
        }

        let said = Models.linkIfNeeded(rootsUnder: s.roots, models: s.bundle)

        // The carried model is repointed at the new app, as it always was…
        #expect((try? fm.destinationOfSymbolicLink(atPath: cache.appendingPathComponent("parakeet-eou-streaming").path))
                == s.bundle.appendingPathComponent("parakeet-eou-streaming").path)
        // …and the link to a model no app carries is gone, not left dangling.
        #expect((try? fm.destinationOfSymbolicLink(atPath: cache.appendingPathComponent(boost).path)) == nil)
        #expect(ComponentFetcher.presence(of: ComponentCatalog.vocabularyBoost, in: cache) == .absent)
        #expect(said.contains("cleared 1 stale"))
    }

    @Test func aRealFolderOrALiveLinkIsNeverCleared() throws {
        let fm = FileManager.default
        let boost = ComponentCatalog.vocabularyBoost.folder
        let diarizer = ComponentCatalog.speakerDiarization.folder
        let s = try scratch(["parakeet-eou-streaming"])
        let base = s.bundle.deletingLastPathComponent().deletingLastPathComponent()
        defer { try? fm.removeItem(at: base) }
        let cache = Models.Root.appSupport.url(under: s.roots)
        // The boost was kept as a real folder by the `prepare` release…
        try fm.createDirectory(at: cache.appendingPathComponent(boost), withIntermediateDirectories: true)
        try Data("kept".utf8).write(to: cache.appendingPathComponent(boost).appendingPathComponent("vocab.json"))
        // …and the diarizer is a link into another app that still has it.
        let other = base.appendingPathComponent("Other.app/Models/\(diarizer)", isDirectory: true)
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: cache.appendingPathComponent(diarizer), withDestinationURL: other)

        let said = Models.linkIfNeeded(rootsUnder: s.roots, models: s.bundle)

        #expect((try? Data(contentsOf: cache.appendingPathComponent(boost).appendingPathComponent("vocab.json"))) == Data("kept".utf8))
        #expect((try? fm.destinationOfSymbolicLink(atPath: cache.appendingPathComponent(diarizer).path)) == other.path)
        #expect(!said.contains("cleared"))
    }
}
