// The notification service extension: it has roughly 24 MB and 30 seconds to turn a 1 KB payload
// into a notification with a board in it.
//
// The shape of this file is dictated by one rule: **the content handler is called exactly once,
// whatever happens.** iOS gives an extension a single shot; call it twice and the second call is
// ignored, call it zero times and the user sees the server's raw alert after a visible delay.
// `OnceDelivery` owns that guarantee, under a lock, and every path — success, decode failure,
// render failure, our own 20-second budget, and the system's `serviceExtensionTimeWillExpire` —
// goes through it.
//
// The second rule: **the fallback is always a good notification.** The server writes a complete
// `aps.alert`; everything here is an improvement on it, never a prerequisite. A board that will
// not draw, a banner that will not download, a FEN that will not parse — each of those costs the
// picture and nothing else.
import Foundation
import UniformTypeIdentifiers
import UserNotifications
import FollowKit

final class NotificationService: UNNotificationServiceExtension {

    /// The self-imposed budget, comfortably inside the system's ~30 s. Leaving headroom means our
    /// own timeout fires first and we deliver the enriched-as-far-as-it-got content, rather than
    /// being cut off mid-render.
    private static let budget: Duration = .seconds(20)

    private var delivery: OnceDelivery?
    private var work: Task<Void, Never>?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        let fallback = (request.content.mutableCopy() as? UNMutableNotificationContent)
            ?? UNMutableNotificationContent()
        let delivery = OnceDelivery(content: fallback, handler: contentHandler)
        self.delivery = delivery

        guard let push = ChessPush.decode(userInfo: request.content.userInfo) else {
            // Not one of ours, or a payload this build does not understand. The server's alert is
            // already correct; send it unchanged.
            delivery.deliver(applying: nil)
            return
        }

        // `UNNotificationRequest` is not `Sendable`; its identifier is, and it is all the async
        // work needs (it names the temporary files so two pushes cannot collide).
        let identifier = request.identifier
        work = Task {
            let enrichment = await withTimeout(Self.budget) { () -> Enrichment? in
                await Enrichment.build(for: push, identifier: identifier)
            }
            delivery.deliver(applying: enrichment)
        }
    }

    /// The system is about to take the extension away. Deliver the best we have — which, because
    /// `OnceDelivery` holds the original content, is at worst exactly what the server sent.
    override func serviceExtensionTimeWillExpire() {
        pushLog.notice("The system ended the extension's time; delivering the fallback")
        work?.cancel()
        delivery?.deliver(applying: nil)
    }
}

/// Everything the async work produces, and nothing that is not `Sendable`.
///
/// Keeping `UNMutableNotificationContent` out of the concurrent part is what lets the rest of this
/// file be ordinary Swift 6 code; the one unchecked type is `OnceDelivery` below, which is the
/// honest place for it.
struct Enrichment: Sendable {
    var wording: PushWording
    var threadId: String
    var attachment: AttachmentPlan?
    var relevanceScore: Double
    var interruptionLevel: UNNotificationInterruptionLevel

    struct AttachmentPlan: Sendable {
        var url: URL
        var typeHint: String
        var identifier: String
    }

    @MainActor
    static func build(for push: ChessPush, identifier: String) async -> Enrichment {
        switch push {
        case .game(let move):
            return game(move, identifier: identifier)
        case .tournament(let event):
            return await tournament(event, identifier: identifier)
        }
    }

    // MARK: - A board

    @MainActor
    private static func game(_ push: MovePush, identifier: String) -> Enrichment {
        let finished = ChessFormat.isFinished(status: push.status)
        var enrichment = Enrichment(
            wording: PushWordingBuilder.wording(for: .game(push)),
            threadId: push.roundId,
            attachment: nil,
            // A finished game is the one a person most wants pulled to the top of the stack.
            relevanceScore: finished ? 1.0 : 0.6,
            interruptionLevel: .active
        )

        // The board is drawn from the viewer's own settings, and from the side they watch: a user
        // who watches from Black should not get a notification from White's side of the table.
        let appearance = BoardAppearance.fromAppGroup()
        if let file = BoardImageRenderer.pngFile(
            fen: push.fen,
            lastMoveUCI: push.lastMove,
            options: .init(appearance: appearance),
            named: "board-\(identifier)"
        ) {
            enrichment.attachment = AttachmentPlan(
                url: file, typeHint: UTType.png.identifier, identifier: "board"
            )
        } else {
            pushLog.notice("Sending \(push.kind, privacy: .public) for \(push.gameId, privacy: .public) without a board image")
        }
        return enrichment
    }

    // MARK: - An event

    @MainActor
    private static func tournament(_ push: TournamentPush, identifier: String) async -> Enrichment {
        var enrichment = Enrichment(
            wording: PushWordingBuilder.wording(for: .tournament(push)),
            threadId: push.roundId ?? push.tourId,
            attachment: nil,
            relevanceScore: push.kind == "roundLive" ? 1.0 : 0.5,
            interruptionLevel: .active
        )

        // The banner is optional in every sense: optional in the payload, optional to fetch, and
        // refused outright unless it is HTTPS on a Lichess host and stays under half a megabyte.
        guard let banner = push.bannerURL else { return enrichment }
        let userAgent = ExtensionIdentity.userAgent
        if let file = await BannerDownloader.imageFile(
            for: banner, named: "banner-\(identifier)", userAgent: userAgent
        ) {
            enrichment.attachment = AttachmentPlan(
                url: file, typeHint: UTType.jpeg.identifier, identifier: "banner"
            )
        }
        return enrichment
    }
}

/// Calls the content handler exactly once.
///
/// `@unchecked Sendable` because `UNMutableNotificationContent` is not `Sendable` and the handler
/// may be invoked from whichever context finishes first — the async work, the system's expiry
/// callback, or the synchronous early return. Every access to both is inside the lock, and after
/// the first delivery neither is touched again, so the unchecked claim is one this type actually
/// keeps rather than one it asserts.
final class OnceDelivery: @unchecked Sendable {

    private let lock = NSLock()
    private var content: UNMutableNotificationContent?
    private var handler: ((UNNotificationContent) -> Void)?

    init(content: UNMutableNotificationContent, handler: @escaping (UNNotificationContent) -> Void) {
        self.content = content
        self.handler = handler
    }

    /// - Parameter enrichment: nil delivers the server's content untouched, which is the fallback
    ///   every failure path takes.
    func deliver(applying enrichment: Enrichment?) {
        let (content, handler): (UNMutableNotificationContent?, ((UNNotificationContent) -> Void)?) = lock.withLock {
            defer { self.content = nil; self.handler = nil }
            return (self.content, self.handler)
        }
        guard let content, let handler else { return }   // already delivered

        if let enrichment {
            apply(enrichment, to: content)
        }
        handler(content)
    }

    private func apply(_ enrichment: Enrichment, to content: UNMutableNotificationContent) {
        content.title = enrichment.wording.title
        if let subtitle = enrichment.wording.subtitle { content.subtitle = subtitle }
        content.body = enrichment.wording.body
        content.threadIdentifier = enrichment.threadId
        content.relevanceScore = enrichment.relevanceScore
        content.interruptionLevel = enrichment.interruptionLevel

        guard let plan = enrichment.attachment else { return }
        do {
            let attachment = try UNNotificationAttachment(
                identifier: plan.identifier,
                url: plan.url,
                options: [UNNotificationAttachmentOptionsTypeHintKey: plan.typeHint]
            )
            content.attachments = [attachment]
        } catch {
            // The picture is gone; the words are not. Nothing else changes.
            pushLog.error("Could not attach the image: \(String(describing: error), privacy: .public)")
            try? FileManager.default.removeItem(at: plan.url)
        }
    }
}

/// The `User-Agent` an extension sends. The app's `AppIdentity` lives in the app target, which an
/// extension does not link, so the string is rebuilt here from the extension's own bundle — which
/// carries the same version because the build bumps them together.
enum ExtensionIdentity {
    static let contact = "zzzlabshq@gmail.com"

    static var version: String {
        let value = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return "0.1" }
        return value
    }

    static var userAgent: String { "ChessTV/\(version) (\(contact))" }
}
