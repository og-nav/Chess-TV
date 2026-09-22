import AVFoundation
import Foundation
import GameSessionKit
import Testing
@testable import ChessTVMobile

@Suite("Bundled sound sets")
struct SoundResourceTests {
    @Test("Every selectable event has a playable resource in the app bundle", arguments: SoundSet.allCases)
    func resources(set: SoundSet) throws {
        for outcome in MoveOutcome.allCases {
            let url = try #require(Bundle.main.url(forResource: set.resourceName(for: outcome), withExtension: "wav"))
            let audio = try AVAudioFile(forReading: url)
            #expect(audio.length > 0)
            #expect(audio.fileFormat.sampleRate == 44_100)
            #expect(audio.fileFormat.channelCount == 1)
        }
    }

    @Test("Lichess sound licenses and notices ship with their attribution")
    func licenses() throws {
        let license = Credits.Licence.agpl3.text()
        #expect(license.contains("GNU AFFERO GENERAL PUBLIC LICENSE"))
        let notice = try #require(Bundle.main.url(forResource: "Lichess-Sounds-COPYING", withExtension: "txt"))
        #expect(try String(contentsOf: notice, encoding: .utf8).contains("Enigmahack"))
        #expect(Credits.entries.first(where: { $0.id == "sounds" })?.licences.contains(.agpl3) == true)
    }
}
