// The small, public surface the rest of the suite talks to the phone app through.
//
// The Live Activity controller and the WatchConnectivity bridge live in `Apps/ChessTVShared` and
// are compiled into this target, so there is no protocol in between: this object calls them
// directly and exists so that the extensions, the widget and any later caller have one door
// rather than reaching into `AppEnvironment`.
import Foundation
import FollowKit

@MainActor
public final class MobileIntegration {

    public static private(set) var shared: MobileIntegration?

    private let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    static func install(_ integration: MobileIntegration) { shared = integration }

    // MARK: - Reading

    public func currentFollows() -> [Follow] { environment.follows.follows }

    public func currentPreferences() -> NotificationPreferences { environment.follows.preferences }

    /// True when a server URL is configured, so a caller can tell "no alerts yet" from "alerts
    /// are impossible here".
    public var hasPushServer: Bool { environment.follows.hasServer }

    public var pushServerURL: URL? { environment.server.url }

    // MARK: - Writing

    /// Pulls the follow list and the preferences from the server, draining anything queued
    /// locally first. Called after the watch changes a switch, and on every activation.
    public func refreshFollows() { environment.follows.reconcile() }

    public func setPreferences(_ preferences: NotificationPreferences) {
        environment.follows.setPreferences(preferences)
    }

    /// A push woke the app, or arrived while it was in the foreground. `identifier` should be the
    /// `apns-collapse-id` when the payload had one, so the count deduplicates against Notification
    /// Center's own copy.
    public func handleRemoteNotification(identifier: String, at date: Date = .now) {
        environment.alerts.record(id: identifier, at: date)
    }

    /// Sends the current follow list, preferences, server URL and pinned game to the watch.
    public func syncWatch() { environment.syncWatch() }
}
