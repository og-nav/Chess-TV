// Feedback belongs to an explicit interaction, never to the state that interaction changes.
// In particular, a stream move, a clock tick or a server reconciliation must remain silent.
import Foundation
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(watchOS)
import WatchKit
#endif

@MainActor
enum InteractionFeedback {
    enum Kind { case selection, tap, confirmation }

    private static var lastPlayedAt: TimeInterval = -.infinity
    #if os(iOS)
    private static let selectionGenerator = UISelectionFeedbackGenerator()
    private static let tapGenerator = UIImpactFeedbackGenerator(style: .light)
    private static let confirmationGenerator = UINotificationFeedbackGenerator()
    #endif

    static func selection() { play(.selection) }
    static func tap() { play(.tap) }
    static func confirmation() { play(.confirmation) }

    private static func play(_ kind: Kind) {
        guard ProcessInfo.processInfo.environment["CHESSTV_TESTING"] != "1" else { return }
        // One tap can both select a row and navigate. Avoid double pulses from that one gesture.
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastPlayedAt >= 0.05 else { return }
        lastPlayedAt = now
        #if os(iOS)
        switch kind {
        case .selection:
            selectionGenerator.selectionChanged()
            selectionGenerator.prepare()
        case .tap:
            tapGenerator.impactOccurred(intensity: 0.6)
            tapGenerator.prepare()
        case .confirmation:
            confirmationGenerator.notificationOccurred(.success)
            confirmationGenerator.prepare()
        }
        #elseif os(watchOS)
        WKInterfaceDevice.current().play(kind == .confirmation ? .success : .click)
        #endif
    }
}

extension Binding where Value: Equatable {
    /// Only an actual control write emits feedback; model/remote changes bypass this setter.
    @MainActor
    func withSelectionFeedback() -> Binding<Value> {
        Binding(get: { wrappedValue }, set: { value in
            guard value != wrappedValue else { return }
            InteractionFeedback.selection()
            wrappedValue = value
        })
    }
}

extension View {
    /// For destination-based links that do not write a typed navigation-path binding.
    /// A simultaneous tap keeps the link's own activation and scrolling behavior intact.
    @MainActor
    func navigationFeedback() -> some View {
        simultaneousGesture(TapGesture().onEnded { InteractionFeedback.tap() })
    }
}
