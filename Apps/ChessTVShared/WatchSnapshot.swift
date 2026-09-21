// Where the watch keeps what the phone told it.
//
// Split out from `WatchSyncStore` because the **widget** needs to read this and must not link the
// store: a widget has no business owning a `WCSession`, and the widget target excludes that file
// for exactly that reason. Reading and writing one key is all either side needs in common.
//
// The container is the watch's own App Group. Nothing secret goes in it — the install token lives
// in the watch Keychain (`FollowKit.KeychainCredentialStore`) and never touches this file.
import Foundation
import FollowKit

public enum WatchSnapshot {

    static let key = "watchSyncPayload"

    /// The last payload the phone sent, or nil if this install has never heard from it.
    public static func read(defaults: UserDefaults = ChessTVAppGroup.defaults) -> WatchSyncPayload? {
        guard let data = defaults.data(forKey: key) else { return nil }
        guard let payload = try? FollowJSON.decoder.decode(WatchSyncPayload.self, from: data) else {
            watchLog.error("The stored watch snapshot did not decode; ignoring it")
            return nil
        }
        return payload
    }

    static func write(_ payload: WatchSyncPayload, defaults: UserDefaults = ChessTVAppGroup.defaults) {
        guard let data = try? FollowJSON.encoder.encode(payload) else {
            watchLog.error("Could not encode the watch snapshot")
            return
        }
        defaults.set(data, forKey: key)
    }
}

/// The Smart Stack widget's identity, shared so the watch app can ask WidgetKit to reload it.
public enum WatchPinnedWidget {
    public static let kind = "ChessTVWatchPinnedGame"
}
