import AppKit
import Foundation
import Testing
@testable import Moe

/// ⌘V in the box attaches a picture or a copied file (deep dive §2.12):
/// the composer is a plain-text view, so a screenshot pasted nothing and a
/// file copied in Finder pasted its name as words.
@MainActor
struct ComposerPasteTests {

    private func board(_ fill: (NSPasteboard) -> Void) -> NSPasteboard {
        let pb = NSPasteboard(name: .init("moe-paste-test-\(UUID().uuidString)"))
        pb.clearContents()
        fill(pb)
        return pb
    }

    private var png: Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }

    @Test func aScreenshotAttaches() {
        let pb = board { $0.setData(png, forType: .png) }
        #expect(AttachmentIntake.pasteAttaches(pb))
    }

    /// Finder puts the file's name on the pasteboard as text too; the file
    /// still wins.
    @Test func aFileCopiedInFinderAttaches() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("moe-paste-\(UUID().uuidString).txt")
        try "hello".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let pb = board {
            $0.writeObjects([url as NSURL])
            $0.setString(url.lastPathComponent, forType: .string)
        }
        #expect(AttachmentIntake.pasteAttaches(pb))
    }

    @Test func wordsPasteAsWords() {
        #expect(!AttachmentIntake.pasteAttaches(board { $0.setString("Book Nopa for 7", forType: .string) }))
    }

    /// Text copied from a page that carries a picture as well is text.
    @Test func wordsWithAPictureBesideThemPasteAsWords() {
        let pb = board {
            $0.declareTypes([.string, .png], owner: nil)
            $0.setString("Nopa, 560 Divisadero", forType: .string)
            $0.setData(png, forType: .png)
        }
        #expect(!AttachmentIntake.pasteAttaches(pb))
    }

    @Test func anEmptyBoardPastesNothing() {
        #expect(!AttachmentIntake.pasteAttaches(board { _ in }))
    }
}
