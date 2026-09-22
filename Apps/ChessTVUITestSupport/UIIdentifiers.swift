// Accessibility identifiers, shared by the apps and their UI tests so a control is named once.
//
// Identifiers are for automation; the labels VoiceOver reads stay where they are. A control
// whose id takes a value (a card for one arena, a switch for one alert) builds it with the
// function of the same name.
import Foundation

enum UIID {

    // MARK: - Home (both apps)

    enum Home {
        static let settings = "home.settings"
        static let resume = "home.continue"
        static func channel(_ raw: String) -> String { "home.channel.\(raw)" }
        static func arena(_ id: String) -> String { "home.arena.\(id)" }
        static func event(_ roundId: String) -> String { "home.event.\(roundId)" }
        static func eventRounds(_ roundId: String) -> String { "home.event.\(roundId).rounds" }
    }

    // MARK: - Game (both apps)

    enum Game {
        static let settings = "game.settings"
        static let flip = "game.flip"
        static let engine = "game.engine"
        static let pin = "game.pin"
        static let lichess = "game.lichess"
        static let follow = "game.follow"
        static let status = "game.status"
        static let title = "game.title"
        /// The tournament-alert chip that takes the chips' place in the TV header.
        static let toast = "game.toast"
        /// "Ends in 34:05", arenas only.
        static let endsIn = "game.endsIn"
        /// The arena leaderboard beside the move list, and one of its rows by rank.
        static let standings = "game.standings"
        static func standingsRow(_ rank: Int) -> String { "game.standings.row.\(rank)" }
        static let evaluation = "game.evaluation"
        static let moveList = "game.moves"
        /// One numbered row of the TV move list.
        static func moveRow(_ number: Int) -> String { "game.moves.row.\(number)" }
        /// The board itself. Its accessibility children are the 64 squares, in reading order for
        /// whichever side is at the bottom, so a test reads the top-left square's label to see
        /// which way the board is facing.
        static let board = "game.board"
        static let scrubPrevious = "game.scrub.previous"
        static let scrubNext = "game.scrub.next"
        static let scrubLive = "game.scrub.live"
        static let scrubLabel = "game.scrub.label"
        static func move(ply: Int) -> String { "game.move.\(ply)" }
        static func playerBell(_ color: String) -> String { "game.player.\(color).bell" }
        static func clock(_ color: String) -> String { "game.clock.\(color)" }
    }

    // MARK: - Boards (TV board list, phone boards wall)

    enum Boards {
        static func card(_ gameId: String) -> String { "boards.card.\(gameId)" }
        static let title = "boards.title"
        static let allRounds = "boards.allRounds"
        static let follow = "boards.follow"
    }

    // MARK: - Tournament (phone)

    enum Tournament {
        static let follow = "tournament.follow"
        static func round(_ id: String) -> String { "tournament.round.\(id)" }
    }

    // MARK: - Following (phone)

    enum Following {
        static func row(_ kind: String, _ key: String) -> String { "following.row.\(kind).\(key)" }
        static func alerts(_ kind: String, _ key: String) -> String { "following.alerts.\(kind).\(key)" }
        static let browse = "following.browse"
        static let dismissNotices = "following.dismiss"
        static let syncLine = "following.sync"
    }

    enum FollowDetail {
        static let unfollow = "followDetail.unfollow"
        static func toggle(_ alert: String) -> String { "alerts.toggle.\(alert)" }
        static let moveInterval = "alerts.picker.moveInterval"
        static let longThink = "alerts.picker.longThink"
        static let startingSoon = "alerts.picker.startingSoon"
        static let topBoards = "alerts.picker.topBoards"
        static let applyToExisting = "followDefaults.apply"
    }

    // MARK: - Settings (both apps; the TV has its own controls for the same settings)

    enum Settings {
        static let done = "settings.done"
        /// The line under the TV preview board: theme, pieces, engine, keep-TV-on.
        static let summary = "settings.summary"
        static let boardTheme = "settings.boardTheme"
        static let pieces = "settings.pieces"
        static let depth = "settings.depth"
        static func theme(_ name: String) -> String { "settings.theme.\(name)" }
        static func pieceSet(_ raw: String) -> String { "settings.pieces.\(raw)" }
        static func depth(_ raw: String) -> String { "settings.depth.\(raw)" }
        static let coordinates = "settings.coordinates"
        static let sounds = "settings.sounds"
        static let soundSet = "settings.soundSet"
        static func soundSet(_ raw: String) -> String { "settings.soundSet.\(raw)" }
        static let previewSound = "settings.previewSound"
        static let followFeatured = "settings.followFeatured"
        static let engine = "settings.engine"
        static let keepTVOn = "settings.keepTVOn"
        static let tournamentAlerts = "settings.tournamentAlerts"
        static let notifications = "settings.notifications"
        /// The phone's About section rows and the row that opens Credits; the TV has its own
        /// Credits button in the Settings column.
        static let credits = "settings.credits"
        static let musicConnect = "settings.music.connect"
        static let musicPlay = "settings.music.play"
        static let musicNext = "settings.music.next"
        static func playlist(_ id: String) -> String { "settings.music.playlist.\(id)" }
    }

    enum Notifications {
        static let allow = "notifications.allow"
        static let openSystemSettings = "notifications.openSettings"
        /// "Reset push notifications", and the line it writes when it is done.
        static let resetPush = "notifications.resetPush"
        static let resetPushResult = "notifications.resetPush.result"
        static let muteAll = "notifications.mute"
        static let quietHours = "notifications.quietHours"
        static let quietFrom = "notifications.quietFrom"
        static let quietTo = "notifications.quietTo"
        static let resultsThrough = "notifications.resultsThrough"
        static func defaults(_ kind: String) -> String { "notifications.defaults.\(kind)" }
        static let openFollowing = "notifications.openFollowing"
    }

    // MARK: - Credits (both apps)

    enum Credits {
        /// The TV screen's Done button. The phone uses the navigation bar's Back.
        static let done = "credits.done"
        /// One block of the credits list, by `Credits.Entry.id`.
        static func entry(_ id: String) -> String { "credits.entry.\(id)" }
        /// The row that opens one bundled licence text, by `Credits.Licence.rawValue`.
        static func licence(_ raw: String) -> String { "credits.licence.\(raw)" }
        /// The scrollable licence text itself.
        static let licenceText = "credits.licence.text"
    }
}
