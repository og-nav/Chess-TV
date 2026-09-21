// Reading just enough out of a push payload to open the right screen.
//
// Pulled out of the app delegate so it is a plain value type with no UIKit in sight, which is
// what lets the tests drive it from a dictionary.
import Foundation
import FollowKit

/// Reading just enough out of a push payload to open the right screen.
///
/// The payload's `d` key is a `MovePush` or a `TournamentPush`, told apart by `aps.category`.
/// The app does not decode the whole thing — the notification extension already did, and a
/// decode failure here must not cost the user the tap — so this reads the three ids it needs.
enum PushRouting {

    enum Target: Equatable, Sendable {
        case board(roundId: String, gameId: String, tourName: String?)
        case tournament(tourId: String, name: String?)
    }

    /// Widget links contain identifiers only; reject unrelated hosts and extra path components.
    static func target(from url: URL) -> Target? {
        guard url.scheme?.lowercased() == "chesstv", url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard url.host == "game", parts.count == 2,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" } }) else { return nil }
        return .board(roundId: parts[0], gameId: parts[1], tourName: nil)
    }

    static let gameCategory = PushCategory.gameMove
    static let tournamentCategory = PushCategory.tournamentEvent

    static func target(from userInfo: [AnyHashable: Any]) -> Target? {
        guard let payload = userInfo["d"] as? [String: Any] else { return nil }
        let category = (userInfo["aps"] as? [String: Any])?["category"] as? String
        if category == tournamentCategory || payload["tourId"] != nil && payload["gameId"] == nil {
            guard let tourId = payload["tourId"] as? String else { return nil }
            return .tournament(tourId: tourId, name: payload["tourName"] as? String)
        }
        guard let roundId = payload["roundId"] as? String, let gameId = payload["gameId"] as? String else { return nil }
        return .board(roundId: roundId, gameId: gameId, tourName: payload["tourName"] as? String)
    }

    /// The id the alert count deduplicates on: the collapse id the server sent, or the ids that
    /// make it up when the payload has no explicit one.
    static func identifier(from userInfo: [AnyHashable: Any]) -> String {
        switch target(from: userInfo) {
        case .board(let roundId, let gameId, _): "\(roundId):\(gameId)"
        case .tournament(let tourId, _): tourId
        case nil: UUID().uuidString
        }
    }
}
