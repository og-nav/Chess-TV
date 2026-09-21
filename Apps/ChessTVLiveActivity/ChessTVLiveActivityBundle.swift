// The widget extension's entry point.
//
// Two widgets in one bundle: the Live Activity for the pinned game, and a home-screen/Lock Screen
// widget that draws the same pinned game from the App Group when no activity is running. They
// share every view below the top level, so the board on the Lock Screen and the board in the
// Smart Stack are the same board.
import SwiftUI
import WidgetKit

@main
struct ChessTVLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        ChessGameLiveActivity()
        PinnedGameWidget()
    }
}
