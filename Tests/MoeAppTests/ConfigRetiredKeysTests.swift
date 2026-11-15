import Foundation
import Testing
@testable import Moe

/// `silenceSeconds`, `useModifierTap` and `meetingSessionID` were decoded,
/// written back and read by nothing. They are gone; a config file written by
/// an older Memoe still has them and must load as it always did.
struct ConfigRetiredKeysTests {
    @Test func anOldConfigThatStillHasThemLoadsAndKeepsItsOtherSettings() throws {
        let old = #"""
        {"silenceSeconds": 2.5, "useModifierTap": false, "meetingSessionID": "abc-123",
         "hotKeyModifiers": 2048, "meetingSendTelegram": true}
        """#
        let config = try JSONDecoder().decode(Config.self, from: Data(old.utf8))
        #expect(config.hotKeyModifiers == 2048)
        #expect(config.meetingSendTelegram)
    }

    @Test func aConfigWrittenNowNoLongerCarriesThem() throws {
        let json = String(decoding: try JSONEncoder().encode(Config()), as: UTF8.self)
        for key in ["silenceSeconds", "useModifierTap", "meetingSessionID"] {
            #expect(!json.contains("\"\(key)\""))
        }
    }
}
