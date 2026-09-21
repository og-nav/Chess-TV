import Foundation
import Testing
import UserNotifications
@testable import ChessTVMobile

/// A device crash showed UIKit restoration being completed off-main by the previous async
/// Objective-C bridge even though navigation itself had already hopped to MainActor. These
/// tests enter the delegate's shared handler from a detached executor and check the position
/// where UIKit receives its completion. Cold/warm routing is covered by PresentationTests.
@Suite("Notification callbacks complete on UIKit's main thread")
struct NotificationCallbackTests {
    @Test(arguments: [UNNotificationDefaultActionIdentifier, PushAction.openGame,
                      PushAction.openTournament, PushAction.flipBoard])
    func completionReturnsToMainThread(_ action: String) async {
        let completedOnMain = await withCheckedContinuation { continuation in
            Task.detached {
                AppDelegate.handleNotificationResponse(
                    actionIdentifier: action,
                    identifier: "notification-callback-regression",
                    date: Date(timeIntervalSince1970: 1_700_000_000),
                    target: nil
                ) {
                    // A missing target or ignored action must still complete, on main, exactly
                    // once. A double callback also fails this checked continuation immediately.
                    continuation.resume(returning: Thread.isMainThread)
                }
            }
        }
        #expect(completedOnMain)
    }
}
