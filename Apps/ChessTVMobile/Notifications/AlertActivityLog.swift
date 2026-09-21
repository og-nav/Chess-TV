// Recent alert activity: prefer the server's count of APNs-accepted sends, with locally observed
// notifications as an offline fallback. APNs acceptance is not proof that iOS displayed an alert.
// The local fallback merges notifications still in Notification Center with the app's own log.
import Foundation
import FollowKit
import UserNotifications

enum AlertLog {

    /// Entries older than this are dropped on every write: this is a counter, not a history.
    static let retention: TimeInterval = 48 * 3600

    static func pruning(_ entries: [AlertEntry], now: Date, retention: TimeInterval = AlertLog.retention) -> [AlertEntry] {
        let cutoff = now.addingTimeInterval(-retention)
        return entries.filter { $0.date > cutoff }
    }

    /// The union of two sources by identifier, so a delivered notification the app also logged
    /// is counted once.
    static func merging(_ logged: [AlertEntry], with delivered: [AlertEntry]) -> [AlertEntry] {
        var byID: [String: AlertEntry] = [:]
        for entry in logged + delivered { byID[entry.id] = entry }
        return byID.values.sorted { $0.date > $1.date }
    }

    static func count(_ entries: [AlertEntry], since: Date) -> Int {
        entries.count { $0.date >= since }
    }

    /// "3 alerts in the last 24 hours" / "No alerts in the last 24 hours".
    static func summary(count: Int) -> String {
        switch count {
        case 0: "No alerts in the last 24 hours"
        case 1: "1 alert in the last 24 hours"
        default: "\(count) alerts in the last 24 hours"
        }
    }
}

/// One alert this device received.
struct AlertEntry: Codable, Sendable, Hashable, Identifiable {
    /// The APNs collapse id where there is one, otherwise the notification request id. Two
    /// sources reporting the same push agree on it.
    var id: String
    var date: Date
}

/// The stored log plus the reading of Notification Center.
@MainActor
@Observable
final class AlertActivityLog {

    enum Key { static let entries = "alertActivityLog" }

    private(set) var last24Hours = 0

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var entries: [AlertEntry]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let data = defaults.data(forKey: Key.entries) ?? Data()
        entries = (try? Self.decoder.decode([AlertEntry].self, from: data)) ?? []
        last24Hours = AlertLog.count(entries, since: Date.now.addingTimeInterval(-24 * 3600))
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// A push arrived while the app was running or was woken by one.
    func record(id: String, at date: Date = .now) {
        entries = AlertLog.pruning(AlertLog.merging(entries, with: [AlertEntry(id: id, date: date)]), now: date)
        persist()
    }

    /// Adds whatever Notification Center still holds, and recounts. Run when the Notifications
    /// screen appears and on activation.
    func refresh(now: Date = .now, client: (any FollowServerClient)? = nil) async {
        let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
        // iOS uses the push's `apns-collapse-id` as the request identifier when one was sent,
        // which is exactly the id the app logs for itself, so the union deduplicates correctly.
        let fromCenter = delivered.map { AlertEntry(id: $0.request.identifier, date: $0.date) }
        entries = AlertLog.pruning(AlertLog.merging(entries, with: fromCenter), now: now)
        persist(now: now)
        if let count = try? await client?.alertCount() {
            last24Hours = max(0, count.last24h)
        }
    }

    private func persist(now: Date = .now) {
        entries = AlertLog.pruning(entries, now: now)
        last24Hours = AlertLog.count(entries, since: now.addingTimeInterval(-24 * 3600))
        if let data = try? Self.encoder.encode(entries) {
            defaults.set(data, forKey: Key.entries)
        }
    }
}
