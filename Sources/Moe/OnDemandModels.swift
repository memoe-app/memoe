import Foundation
import MoeComponents

/// The app's side of the on-demand components (docs/SLIM-DOWNLOAD.md): which
/// mode this build is in, the one call a loader makes before it asks
/// FluidAudio for an on-demand model, and what happens at launch.
///
/// In a build that carries every model — every build today — `ensure` finds
/// the link `Models.linkIfNeeded` made and returns without touching the
/// network, and `afterLinking` does nothing. That is the whole of `off`.
enum OnDemandModels {

    /// `MoeOnDemandComponents` in Info.plist, written by build.sh from
    /// `MOE_ON_DEMAND_COMPONENTS`. Absent or unreadable is `off`.
    static let mode = OnDemandMode.read(Bundle.main.infoDictionary)

    /// Call before loading an on-demand model. Returns when it is on disk;
    /// throws a `ComponentError`, whose description is fit for a person.
    ///
    /// This replaces FluidAudio's own download for these models, and that is
    /// the point: FluidAudio fetches whatever the repository's `main` holds
    /// and checks nothing, where this fetches a pinned commit and refuses any
    /// file whose sha256 is not the one in this source tree. So when this
    /// throws, the caller must not fall through to the library's downloader.
    static func ensure(_ component: Component) async throws {
        let root = ComponentCatalog.modelsRoot
        guard ComponentFetcher.presence(of: component, in: root) != .present else { return }
        Log.write("components: fetching \(component.title) (\(component.size))…")
        do {
            try await ComponentFetcher.shared.ensure(component, in: root)
            Log.write("components: \(component.id) installed, every file verified")
        } catch {
            Log.write("components: \(error.localizedDescription)")
            throw error
        }
    }

    /// The whole of what a `prepare` build does: every on-demand model that
    /// is a link into this app becomes a real folder beside the others.
    /// Returns the lines for the log — nothing when there was nothing to do,
    /// which is every launch after the first.
    ///
    /// A function of the root so that `Moe --launch-models <dir>` can run the
    /// real thing against a scratch directory: the root the app itself uses
    /// is the one the person's Memoe is reading its models through.
    static func keepAll(in root: URL) -> [String] {
        ComponentCatalog.all.compactMap { component in
            switch ComponentFetcher.keep(component, in: root) {
            case .copiedOut:
                return "components: kept \(component.id) outside the app, ready for a slim update"
            case let .refused(why):
                return "components: could not keep \(component.id) outside the app (\(why)); still linked"
            case .nothingToDo:
                return nil
            }
        }
    }

    /// `Moe --launch-models <dir>`: do to the two model roots under `<dir>`
    /// exactly what a launch of this build does to the real ones — link, then
    /// whatever this build's mode says — and print what is there afterwards.
    /// Nothing is fetched: for `on`, it says what a launch would go and get.
    ///
    /// docs/SLIM-DOWNLOAD.md §7 is a claim about three builds meeting one
    /// cache in order, and this is how that is run for real without the cache
    /// being the one the person's Memoe is using.
    static func rehearseLaunch(under base: URL) -> Int32 {
        print(Models.linkIfNeeded(rootsUnder: base))
        let root = Models.Root.appSupport.url(under: base)
        print("on-demand mode: \(mode.rawValue)")
        // Anything that leaves an on-demand model not fully in place, or a
        // keep that was refused, is a non-zero exit.
        var missing = 0
        switch mode {
        case .off:
            break
        case .prepare:
            let lines = keepAll(in: root)
            lines.forEach { print($0) }
            missing += lines.filter { $0.contains("could not keep") }.count
            if lines.isEmpty { print("components: nothing to keep — already outside the app, or not here") }
        case .on:
            break
        }
        for component in ComponentCatalog.all {
            let folder = root.appendingPathComponent(component.folder)
            let link = try? FileManager.default.destinationOfSymbolicLink(atPath: folder.path)
            let form = link.map { "a link to \($0)" } ?? "a real folder"
            switch ComponentFetcher.presence(of: component, in: root) {
            case .present:
                print("  \(component.id): present, \(form)")
            case .absent:
                missing += 1
                print("  \(component.id): absent" + (mode == .on ? " — a launch would fetch \(component.size)" : ""))
            case .danglingLink:
                missing += 1
                print("  \(component.id): \(form), which is not there" + (mode == .on ? " — a launch would fetch \(component.size)" : ""))
            case .incomplete:
                missing += 1
                print("  \(component.id): incomplete, \(form)" + (mode == .on ? " — a launch would fetch what is missing" : ""))
            }
        }
        return missing == 0 ? 0 : 1
    }

    /// Run once per launch, after `Models.linkIfNeeded`.
    static func afterLinking() {
        let root = ComponentCatalog.modelsRoot
        switch mode {
        case .off:
            return
        case .prepare:
            // The release before the slim one. Copy the on-demand models out
            // of this app, so the update that removes them from the bundle
            // finds them already on the Mac instead of a link to nothing.
            Task.detached(priority: .utility) {
                for line in keepAll(in: root) { Log.write(line) }
            }
        case .on:
            // The slim build. Nobody is waiting for these now, so fetch them
            // quietly — after launch has settled, and never over a metered
            // connection — and the first meeting or the first vocabulary
            // term finds them already here, online or not.
            Task.detached(priority: .utility) {
                try? await Task.sleep(nanoseconds: 120 * 1_000_000_000)
                for component in ComponentCatalog.all
                where ComponentFetcher.presence(of: component, in: root) != .present {
                    do {
                        try await ComponentFetcher.shared.ensure(component, in: root, why: .topUp)
                        Log.write("components: \(component.id) fetched in the background, every file verified")
                    } catch {
                        Log.write("components: background fetch of \(component.id) did not finish (\(error.localizedDescription))")
                    }
                }
            }
        }
    }
}
