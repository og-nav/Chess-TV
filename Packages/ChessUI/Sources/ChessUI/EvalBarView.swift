// The evaluation bar beside the board.
import SwiftUI
import ChessCore

/// Vertical evaluation bar. `whiteShare` is 0...1, the fraction of the bar that is White's.
///
/// White's share grows from the bottom when `orientation` is `.white` (White is at the bottom of
/// the board) and from the top when it is `.black`, so the bar always agrees with the board.
public struct EvalBarView: View {
    public let whiteShare: Double
    public let orientation: PieceColor

    public init(whiteShare: Double, orientation: PieceColor) {
        self.whiteShare = whiteShare
        self.orientation = orientation
    }

    /// The bar's colors, from the mockup palette.
    static let whiteColor = Color(hex: 0xF4F0DF)
    static let blackColor = Color(hex: 0x33382F)
    static let cornerRadius: Double = 4

    private var clampedShare: Double { min(max(whiteShare, 0), 1) }

    public var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: orientation == .white ? .bottom : .top) {
                Rectangle()
                    .fill(Self.blackColor)
                Rectangle()
                    .fill(Self.whiteColor)
                    .frame(height: proxy.size.height * clampedShare)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .animation(.easeInOut(duration: 0.4), value: clampedShare)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Evaluation bar"))
        .accessibilityValue(Text("White \(Int((clampedShare * 100).rounded())) percent"))
    }
}

#if DEBUG
#Preview("Eval bar") {
    HStack(spacing: 40) {
        ForEach([-900, -200, 0, 40, 350, 900], id: \.self) { centipawns in
            VStack(spacing: 12) {
                EvalBarView(whiteShare: EvalMapping.whiteShare(centipawns: centipawns), orientation: .white)
                    .frame(width: 22, height: 420)
                Text(EvalMapping.displayString(centipawns: centipawns))
                    .foregroundStyle(Color(hex: 0xF4F2E9))
            }
        }
        VStack(spacing: 12) {
            EvalBarView(whiteShare: EvalMapping.whiteShare(mateIn: 3), orientation: .black)
                .frame(width: 22, height: 420)
            Text(EvalMapping.displayString(mateIn: 3))
                .foregroundStyle(Color(hex: 0xF4F2E9))
        }
    }
    .padding(40)
    .background(Color(hex: 0x161916))
}
#endif
