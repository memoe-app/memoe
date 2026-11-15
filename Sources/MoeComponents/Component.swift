import Foundation

/// A part of Memoe that a slim build leaves out of the download and fetches
/// the first time it is needed. docs/SLIM-DOWNLOAD.md is the design.
///
/// A component is a folder of files at a pinned place on the network, and
/// **every file has a sha256 written in this source tree**
/// (`ComponentManifest.swift`, generated from the staged models). Nothing is
/// ever installed that does not hash to what is written there — not a file
/// that arrived short, not one a proxy rewrote, not whatever the repository's
/// `main` happens to hold next month.
public struct ComponentFile: Sendable, Equatable {
    /// Relative to the component's folder, `/`-separated.
    public let path: String
    public let bytes: Int64
    /// Lowercase hex.
    public let sha256: String

    public init(_ path: String, _ bytes: Int64, _ sha256: String) {
        self.path = path
        self.bytes = bytes
        self.sha256 = sha256
    }
}

public struct Component: Sendable, Equatable {
    /// Stable name for logs and the command line: `vocabulary-boost`.
    public let id: String
    /// The folder under the models root — FluidAudio's own cache name, so
    /// the library finds what was fetched exactly where it already looks.
    public let folder: String
    /// What it is, as it reads mid-sentence: "the vocabulary model".
    public let title: String
    /// What the person goes without until it arrives, as a whole sentence.
    public let without: String
    /// Every file is at `base` + its path. Ends in `/`, and names a pinned
    /// revision, never a branch.
    public let base: URL
    public let files: [ComponentFile]

    public init(id: String, folder: String, title: String, without: String,
                base: URL, files: [ComponentFile]) {
        self.id = id
        self.folder = folder
        self.title = title
        self.without = without
        self.base = base
        self.files = files
    }

    public var bytes: Int64 { files.reduce(0) { $0 + $1.bytes } }

    /// "103 MB" — decimal megabytes, the unit a download is quoted in.
    public var size: String { Self.megabytes(bytes) }

    static func megabytes(_ n: Int64) -> String {
        n < 1_000_000 ? "under 1 MB" : "\(Int((Double(n) / 1_000_000).rounded())) MB"
    }

    func url(for file: ComponentFile) -> URL {
        // Appended a segment at a time so a space or a `#` in a file name
        // is escaped rather than read as part of the URL's structure.
        file.path.split(separator: "/").reduce(base) { $0.appendingPathComponent(String($1)) }
    }
}

/// The on-demand components, and where they live on disk.
public enum ComponentCatalog {

    /// Used every time a transcript is corrected against the person's own
    /// vocabulary — which a fresh install does not have yet.
    public static let vocabularyBoost = huggingFace(
        id: "vocabulary-boost",
        folder: "parakeet-ctc-110m-coreml",
        title: "the vocabulary model",
        without: "Dictation and conversation work as usual; the names and terms in your vocabulary are not corrected until it arrives.")

    /// Used once, when a meeting ends, to tell the other people apart.
    public static let speakerDiarization = huggingFace(
        id: "speaker-diarization",
        folder: "speaker-diarization",
        title: "the model that tells meeting speakers apart",
        without: "Meeting notes are still taken; the other people's lines are not split by speaker until it arrives.")

    public static let all: [Component] = [vocabularyBoost, speakerDiarization]

    public static func named(_ id: String) -> Component? { all.first { $0.id == id } }

    /// `~/Library/Application Support/FluidAudio/Models` — where FluidAudio
    /// keeps its recognisers, and so where both of these belong. The same
    /// directory as `Models.Root.appSupport`; `OnDemandWiringTests` holds
    /// the two together.
    public static var modelsRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio/Models", isDirectory: true)
    }

    private static func huggingFace(id: String, folder: String, title: String,
                                    without: String) -> Component {
        // Both tables are generated together; a folder in one and not the
        // other is a broken generator, and that must not ship as an empty
        // component that "installs" by downloading nothing.
        guard let pin = pins[folder], let files = manifest[folder], !files.isEmpty,
              let base = URL(string: "https://huggingface.co/\(pin.repository)/resolve/\(pin.revision)/")
        else { fatalError("ComponentManifest.swift has no entry for \(folder)") }
        return Component(id: id, folder: folder, title: title, without: without,
                         base: base, files: files)
    }
}

/// What a build does about the on-demand components. One build flag,
/// `MOE_ON_DEMAND_COMPONENTS`, stamped into Info.plist as
/// `MoeOnDemandComponents`.
public enum OnDemandMode: String, Sendable {
    /// Today: everything is in the app, and nothing here changes that.
    case off
    /// Still everything in the app — and this build copies the on-demand
    /// components out of itself into the cache, so the slim build that
    /// follows finds them already there. The release *before* `on`.
    case prepare
    /// The slim build: the components are not in the app.
    case on

    /// Anything unreadable is `off`. A typo in a plist must never be what
    /// makes an app stop carrying its models.
    public static func read(_ info: [String: Any]?) -> OnDemandMode {
        (info?["MoeOnDemandComponents"] as? String).flatMap(OnDemandMode.init(rawValue:)) ?? .off
    }
}
