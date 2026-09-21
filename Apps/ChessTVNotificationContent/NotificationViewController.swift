// The expanded notification: a real board you can turn around without leaving the Lock Screen.
//
// Code-only — no storyboard — so the whole view is the SwiftUI below and the controller is a
// hosting shell. Two things make it interactive:
//
//   * `UNNotificationExtensionUserInteractionEnabled` in the Info.plist, which is what lets the
//     Flip button inside the view receive a tap at all; and
//   * `didReceive(_:completionHandler:)` returning `.doNotDismiss` for the `FLIP_BOARD` action, so
//     the notification's own button does the same thing without dismissing.
//
// Both paths call the same `flip()`. The text fallback is not an error screen: a payload whose FEN
// will not parse still has a title, a body and a result, and that is what it shows.
import SwiftUI
import UIKit
import UserNotifications
import UserNotificationsUI
import ChessCore
import ChessUI
import FollowKit

// `@preconcurrency` on the conformance: `UNNotificationContentExtension`'s requirements are not
// annotated for the main actor, but a content extension is only ever called on it, and both
// methods here touch views. Without it Swift 6 refuses the conformance outright; with it the
// isolation is checked at run time, which is the accurate description of what the system does.
final class NotificationViewController: UIViewController, @preconcurrency UNNotificationContentExtension {

    private let model = ExpandedModel()
    private var hosting: UIHostingController<ExpandedNotificationView>?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        let hosting = UIHostingController(rootView: ExpandedNotificationView(model: model))
        hosting.view.backgroundColor = .clear
        addChild(hosting)
        view.addSubview(hosting.view)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        hosting.didMove(toParent: self)
        self.hosting = hosting
    }

    func didReceive(_ notification: UNNotification) {
        model.load(userInfo: notification.request.content.userInfo, fallback: notification.request.content)
        resize()
    }

    /// The `FLIP_BOARD` action. `.doNotDismiss` keeps the notification open, which is the whole
    /// point: flipping is a thing you do *while* looking at the board.
    func didReceive(
        _ response: UNNotificationResponse,
        completionHandler completion: @escaping (UNNotificationContentExtensionResponseOption) -> Void
    ) {
        guard response.actionIdentifier == PushAction.flipBoard else {
            completion(.dismissAndForwardAction)
            return
        }
        model.flip()
        completion(.doNotDismiss)
    }

    /// A board is square, and the rest of the layout is roughly a third of it again. Setting this
    /// rather than leaning on `UNNotificationExtensionInitialContentSizeRatio` alone means a
    /// tournament alert, which has no board, does not reserve a square of empty space.
    private func resize() {
        let width = view.bounds.width > 0 ? view.bounds.width : 360
        preferredContentSize = CGSize(width: width, height: model.hasBoard ? width * 1.28 : width * 0.55)
    }
}

/// What the view draws. Not `@Observable`, because `UIHostingController` is built once here and
/// `ObservableObject` is the cheap way to push a change into it from `didReceive`.
final class ExpandedModel: ObservableObject {
    @Published private(set) var push: ChessPush?
    @Published private(set) var appearance = BoardAppearance.fallback
    /// Set only by the Flip button and the flip action; the stored setting is the starting point.
    @Published private(set) var isFlipped = false
    /// What the server wrote, shown when the payload is not one we can decode.
    @Published private(set) var fallbackTitle = ""
    @Published private(set) var fallbackBody = ""

    var hasBoard: Bool {
        guard let movePush = push?.movePush else { return false }
        return (try? Position(fen: movePush.fen)) != nil
    }

    var effectiveAppearance: BoardAppearance {
        isFlipped ? appearance.flipped() : appearance
    }

    func load(userInfo: [AnyHashable: Any], fallback content: UNNotificationContent) {
        appearance = BoardAppearance.fromAppGroup()
        isFlipped = false
        fallbackTitle = content.title
        fallbackBody = content.body
        push = ChessPush.decode(userInfo: userInfo)
        if push == nil {
            pushLog.notice("The expanded view got a payload it could not decode; showing the text the server sent")
        }
    }

    func flip() {
        isFlipped.toggle()
    }
}

struct ExpandedNotificationView: View {
    @ObservedObject var model: ExpandedModel

    var body: some View {
        Group {
            switch model.push {
            case .game(let push):
                GameNotificationView(push: push, model: model)
            case .tournament(let push):
                TournamentNotificationView(push: push)
            case nil:
                TextFallbackView(title: model.fallbackTitle, message: model.fallbackBody)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(ChessTVPalette.ground)
    }
}

// MARK: - A game

private struct GameNotificationView: View {
    let push: MovePush
    @ObservedObject var model: ExpandedModel

    /// The side on the clock, from the FEN (a setup position breaks ply parity).
    private var sideToMove: PieceColor { ChessFormat.sideToMove(push) }
    private var finished: Bool { ChessFormat.isFinished(status: push.status) }

    /// Black is drawn above the board and White below, unless the board is turned around.
    private var topIsBlack: Bool { model.effectiveAppearance.orientation == .white }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            if topIsBlack { playerLine(.black) } else { playerLine(.white) }

            if (try? Position(fen: push.fen)) != nil {
                PositionBoard(fen: push.fen, lastMoveUCI: push.lastMove, appearance: model.effectiveAppearance)
                    .frame(maxWidth: .infinity)
            } else {
                // The one case where there is genuinely no board: say so instead of drawing an
                // empty one, which would read as "the pieces have been cleared".
                Text("The position in this alert could not be read.", comment: "Shown when a push's FEN is malformed")
                    .font(.footnote)
                    .foregroundStyle(ChessTVPalette.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if topIsBlack { playerLine(.white) } else { playerLine(.black) }

            footer
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(PushWordingBuilder.wording(for: .game(push)).title)
                    .font(.headline)
                    .foregroundStyle(ChessTVPalette.ink)
                    .lineLimit(2)
                Text(verbatim: "\(push.tourName) · \(push.roundName)")
                    .font(.caption)
                    .foregroundStyle(ChessTVPalette.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            ResultChip(status: push.status)
        }
    }

    private func playerLine(_ color: PieceColor) -> some View {
        let player = color == .white ? push.white : push.black
        let seconds = color == .white ? push.whiteClock : push.blackClock
        let running = !finished && sideToMove == color
        return PlayerLine(
            name: player.name,
            title: player.title,
            rating: player.rating,
            seconds: ChessFormat.remaining(seconds: seconds, asOf: push.sentAt, running: running),
            deadline: running ? ChessFormat.deadline(seconds: seconds, asOf: push.sentAt) : nil,
            isToMove: running
        )
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let move = ChessFormat.moveLabel(ply: push.ply, san: push.san, uci: push.lastMove) {
                Text(move)
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(ChessTVPalette.ink)
            }
            if push.ply > 0 {
                Text("Move \(ChessFormat.moveNumber(ply: push.ply))", comment: "The move number under an expanded notification")
                    .font(.caption)
                    .foregroundStyle(ChessTVPalette.muted)
            }
            Spacer(minLength: 8)
            Button {
                model.flip()
            } label: {
                Label {
                    Text("Flip", comment: "Button that turns the board around in a notification")
                } icon: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(ChessTVPalette.accent)
            .accessibilityLabel(Text("Flip the board", comment: "Accessibility label for the flip button"))
        }
    }
}

// MARK: - An event

private struct TournamentNotificationView: View {
    let push: TournamentPush

    private var wording: PushWording { PushWordingBuilder.wording(for: .tournament(push)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(wording.title)
                .font(.headline)
                .foregroundStyle(ChessTVPalette.ink)
            if let subtitle = wording.subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(ChessTVPalette.muted)
            }
            if let results = push.results, !results.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(results.prefix(5).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.footnote)
                            .foregroundStyle(ChessTVPalette.ink)
                            .lineLimit(1)
                    }
                }
            } else {
                Text(wording.body)
                    .font(.footnote)
                    .foregroundStyle(ChessTVPalette.ink)
            }
            if let count = push.boardCount {
                Text("^[\(count) board](inflect: true)", comment: "Board count under a tournament notification")
                    .font(.caption)
                    .foregroundStyle(ChessTVPalette.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Neither

private struct TextFallbackView: View {
    let title: String
    /// Named `message`, not `body`: a `View` already has a `body`.
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !title.isEmpty {
                Text(title).font(.headline).foregroundStyle(ChessTVPalette.ink)
            }
            if !message.isEmpty {
                Text(message).font(.footnote).foregroundStyle(ChessTVPalette.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
