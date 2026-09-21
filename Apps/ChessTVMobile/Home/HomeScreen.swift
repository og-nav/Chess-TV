// Home: the TV's three shelves, laid out for a phone and an iPad.
//
// Lichess TV and the arenas scroll sideways, because each card is a line of text and a phone has
// room for two and a half of them. The events are the reason this app exists in November, so
// they get the full width and their banners.
import SwiftUI
import GameSessionKit
import LichessKit

struct HomeScreen: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(Navigator.self) private var navigator
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                continueWatching
                eventsShelf
                arenasShelf
                channelsShelf
            }
            .padding(.vertical, 12)
        }
        .background(Palette.ground)
        .scrollContentBackground(.hidden)
        .navigationTitle("Watch")
        .navigationBarTitleDisplayMode(.large)
        // `HomeModel.run()` is the screen's whole lifetime — three loops that never return until
        // SwiftUI cancels the task. There is deliberately no pull to refresh here: a gesture
        // wired to `run()` would spin until the user left the screen. The shelves reload
        // themselves every sixty seconds. (A one-shot `HomeModel.refresh()` would let this be a
        // proper pull to refresh; it is on the list for GameSessionKit.)
        .task { guard !AppEnvironment.isUnderTest else { return }; await app.home.run() }
    }

    // MARK: - Continue watching

    @ViewBuilder
    private var continueWatching: some View {
        if let source = app.settings.lastSource, let title = continueTitle(for: source) {
            Shelf(title: "Continue watching") {
                Button {
                    InteractionFeedback.tap()
                    navigator.push(.game(GameDestination(source: source, title: title)))
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "play.circle.fill")
                            .font(.title2)
                            .foregroundStyle(Palette.accent)
                            .decorative()
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title)
                                .font(.headline)
                                .foregroundStyle(Palette.ink)
                            Text("Pick up where you left off")
                                .font(.subheadline)
                                .foregroundStyle(Palette.muted)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").foregroundStyle(Palette.faint).decorative()
                    }
                    .padding(Metrics.cardPadding)
                    .panelCard()
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .accessibilityHint("Opens the last board you watched")
                .accessibilityIdentifier(UIID.Home.resume)
            }
        }
    }

    /// A title for the stored source, preferring whatever a shelf already knows about it.
    private func continueTitle(for source: GameSource) -> String? {
        switch source {
        case .tvChannel:
            return SourceTitle.text(for: source)
        case .arena(let id):
            guard let arena = app.home.liveArena(id: id) else { return nil }
            return SourceTitle.arena(arena)
        case .broadcastBoard:
            return SourceTitle.text(for: source)
        }
    }

    // MARK: - Events

    private var eventsShelf: some View {
        Shelf(title: "Events", subtitle: "Tournament broadcasts") {
            switch app.home.events {
            case .loading:
                ShelfPlaceholder(text: "Loading events\u{2026}")
            case .failed(let message):
                ShelfPlaceholder(text: message, isError: true)
            case .loaded(let events):
                if events.isEmpty {
                    ShelfPlaceholder(text: "No events being broadcast right now")
                } else {
                    LazyVGrid(columns: eventColumns, spacing: 14) {
                        ForEach(events) { event in
                            EventCard(event: event) {
                                navigator.push(.boards(roundId: event.roundId, tournamentName: event.name))
                            } rounds: {
                                navigator.push(.tournament(tourId: event.tourId, name: event.name))
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
    }

    private var eventColumns: [GridItem] {
        let count = horizontalSizeClass == .compact ? 1 : 2
        return Array(repeating: GridItem(.flexible(), spacing: 14), count: count)
    }

    // MARK: - Arenas

    private var arenasShelf: some View {
        Shelf(title: "Arenas", subtitle: "Live and starting soon") {
            switch app.home.arenas {
            case .loading:
                ShelfPlaceholder(text: "Loading arenas\u{2026}")
            case .failed(let message):
                ShelfPlaceholder(text: message, isError: true)
            case .loaded(let items):
                if items.isEmpty {
                    ShelfPlaceholder(text: "No arenas running")
                } else {
                    HorizontalShelf {
                        ForEach(items) { item in
                            ArenaCard(item: item) {
                                navigator.push(
                                    .game(GameDestination(source: .arena(tournamentId: item.summary.id), title: SourceTitle.arena(item.summary)))
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Lichess TV

    private var channelsShelf: some View {
        Shelf(title: "Lichess TV", subtitle: "Playing now") {
            HorizontalShelf {
                ForEach(HomeShelves.channelOrder, id: \.self) { channel in
                    ChannelCard(channel: channel, summary: app.home.summary(for: channel)) {
                        navigator.push(
                            .game(GameDestination(source: .tvChannel(channel), title: SourceTitle.text(for: .tvChannel(channel))))
                        )
                    }
                }
            }
        }
    }
}

// MARK: - Shelf chrome

struct Shelf<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Palette.ink)
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(Palette.muted)
                }
            }
            .padding(.horizontal, 16)
            .accessibilityAddTraits(.isHeader)

            content
        }
    }
}

/// A sideways row of cards that still respects the safe area and Dynamic Type.
struct HorizontalShelf<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 12) {
                content
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
    }
}

struct ShelfPlaceholder: View {
    let text: String
    var isError = false

    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(isError ? Palette.alert : Palette.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Metrics.cardPadding)
            .panelCard()
            .padding(.horizontal, 16)
    }
}
