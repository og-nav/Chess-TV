// The home screen: three shelves of focusable cards, walked with the Siri Remote.
// Left/right moves inside a shelf, up/down between shelves, Select opens.
import SwiftUI
import LichessKit
import ImageryKit

/// What the remote can focus on the home screen.
enum HomeFocus: Hashable {
    case resume
    case settings
    case channel(TVChannel)
    case arena(String)
    case event(String)
}

struct HomeScreen: View {
    @Environment(AppModel.self) private var model
    @State private var home = HomeModel()
    @FocusState private var focus: HomeFocus?
    /// The upcoming arena whose "Starts at …" note is showing, if any.
    @State private var noted: String?

    private enum Layout {
        static let shelfGap: Double = 32
        static let cardGap: Double = 26
        /// Room for the 1.06 focus scale and the ring, so nothing is clipped while scrolling.
        static let focusInset: Double = 18
        /// Card heights, chosen so all three shelves fit on a 1080-line screen at once.
        static let tvCardHeight: Double = 176
        static let cardHeight: Double = 216
    }

    var body: some View {
        @Bindable var model = model
        ZStack {
            Palette.ground.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16) {
                header
                shelves
            }
            .padding(.horizontal, Metrics.extraHorizontalPadding)
            .padding(.top, 8)
        }
        .foregroundStyle(Palette.ink)
        .defaultFocus($focus, defaultFocusTarget)
        // Back at the root would quit the app, so the home screen swallows it.
        .onExitCommand { appLog.debug("Menu pressed on the home screen; staying put") }
        // Music carries across screens, so Play/Pause works here too.
        .onPlayPauseCommand { Task { await model.music.toggleFromRemote() } }
        .task { await home.run() }
        .fullScreenCover(isPresented: $model.showingSettings) {
            SettingsScreen()
                .environment(model)
        }
        .onChange(of: model.showingSettings) { _, showing in
            if !showing { focus = .settings }
        }
    }

    private var defaultFocusTarget: HomeFocus {
        resumeSource != nil ? .resume : .channel(HomeShelves.channelOrder[0])
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 32) {
            Text("Chess TV")
                .font(.system(size: 44, weight: .semibold))
                .tracking(-1.5)
                .fixedSize()
            Spacer(minLength: 12)
            Text(model.wallClock, format: .dateTime.hour().minute())
                .font(.system(size: 26))
                .monospacedDigit()
                .foregroundStyle(Palette.muted)
                .fixedSize()
            settingsButton
        }
        .frame(height: Metrics.headerHeight)
        .focusSection()
    }

    private var settingsButton: some View {
        Button { model.showingSettings = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "gearshape")
                Text("Settings").lineLimit(1).fixedSize()
            }
            .font(.system(size: 26))
            .padding(.horizontal, 24)
            .padding(.vertical, 6)
            .frame(minHeight: 44)
            .foregroundStyle(Palette.ink)
        }
        .buttonStyle(TVFocusButtonStyle(cornerRadius: 30, padded: 4))
        .focused($focus, equals: .settings)
        .accessibilityLabel("Settings")
        .accessibilityIdentifier(UIID.Home.settings)
    }

    // MARK: - Shelves

    /// The shelves clip at their own edges: with clipping off, a shelf scrolled off the top kept
    /// drawing over the header. The inset inside leaves room for the focus scale and shadow, and
    /// the negative horizontal padding lets a focused card at either end grow past the margin.
    private var shelves: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: Layout.shelfGap) {
                if let resume = resumeSource { resumeShelf(resume) }
                channelShelf
                arenaShelf
                eventShelf
            }
            .padding(.horizontal, Layout.focusInset)
            .padding(.vertical, Layout.focusInset)
        }
        .scrollIndicators(.hidden)
        .padding(.horizontal, -Layout.focusInset)
    }

    private func shelf<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Palette.ink)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: Layout.cardGap) {
                    content()
                }
                .padding(.horizontal, Layout.focusInset)
                .padding(.vertical, Layout.focusInset / 2)
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
            .padding(.horizontal, -Layout.focusInset)
        }
        // Keeps left/right inside this shelf and makes up/down jump between shelves.
        .focusSection()
    }

    /// A placeholder card, so a shelf is never blank while it loads or after a failure.
    private func notice(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 26))
            .foregroundStyle(Palette.muted)
            .padding(.horizontal, 28)
            .frame(width: 460, height: Layout.cardHeight, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Palette.panel))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Palette.line, lineWidth: 2))
    }

    // MARK: - Continue watching

    /// The last source, offered again only while it can still be playing.
    private var resumeSource: (source: GameSource, title: String)? {
        switch model.settings.lastSource {
        case .tvChannel(let channel):
            return (.tvChannel(channel), SourceTitle.text(for: .tvChannel(channel)))
        case .arena(let id):
            guard let summary = home.liveArena(id: id) else { return nil }
            return (.arena(tournamentId: id), SourceTitle.arena(summary))
        default:
            return nil
        }
    }

    private func resumeShelf(_ resume: (source: GameSource, title: String)) -> some View {
        shelf("Continue watching") {
            NavigationLink(value: Route.game(GameDestination(source: resume.source, title: resume.title))) {
                VStack(alignment: .leading, spacing: 12) {
                    LiveDot(label: "CONTINUE")
                    Spacer(minLength: 0)
                    Text(resume.title)
                        .font(.system(size: 32, weight: .semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text("Pick up where you left off")
                        .font(.system(size: 24))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                }
                .padding(26)
                .frame(width: 560, height: Layout.tvCardHeight, alignment: .leading)
            }
            .buttonStyle(HomeCardButtonStyle())
            .focused($focus, equals: .resume)
            .accessibilityLabel("Continue watching \(resume.title)")
            .accessibilityIdentifier(UIID.Home.resume)
        }
    }

    // MARK: - Lichess TV

    private var channelShelf: some View {
        shelf("Lichess TV") {
            ForEach(HomeShelves.channelOrder, id: \.self) { channel in
                channelCard(channel)
            }
        }
    }

    private func channelCard(_ channel: TVChannel) -> some View {
        let summary = home.summary(for: channel)
        let title = SourceTitle.text(for: .tvChannel(channel))
        return NavigationLink(value: Route.game(GameDestination(source: .tvChannel(channel), title: title))) {
            VStack(alignment: .leading, spacing: 10) {
                LiveDot()
                Spacer(minLength: 0)
                Text(channel.displayName)
                    .font(.system(size: 32, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(channelSubtitle(summary))
                    .font(.system(size: 24))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .padding(24)
            .frame(width: 360, height: Layout.tvCardHeight, alignment: .leading)
        }
        .buttonStyle(HomeCardButtonStyle())
        .focused($focus, equals: .channel(channel))
        .accessibilityLabel("\(channel.displayName) on Lichess TV")
        .accessibilityIdentifier(UIID.Home.channel(channel.rawValue))
    }

    private func channelSubtitle(_ summary: TVChannelSummary?) -> String {
        if let summary {
            guard let rating = summary.rating else { return summary.userName }
            return "\(summary.userName) \u{00B7} \(rating)"
        }
        switch home.channels {
        case .loading: return "Loading\u{2026}"
        case .failed(let message): return message
        case .loaded: return "No game right now"
        }
    }

    // MARK: - Arenas

    private var arenaShelf: some View {
        shelf("Arenas") {
            switch home.arenas {
            case .loading:
                notice("Loading\u{2026}")
            case .failed(let message):
                notice(message)
            case .loaded(let items):
                if items.isEmpty {
                    notice("No arenas right now")
                } else {
                    ForEach(items) { item in arenaCard(item) }
                }
            }
        }
    }

    @ViewBuilder
    private func arenaCard(_ item: ArenaShelfItem) -> some View {
        let arena = item.summary
        let label = arenaLabel(item)
        if item.isLive {
            NavigationLink(value: Route.game(GameDestination(source: .arena(tournamentId: arena.id), title: SourceTitle.arena(arena)))) {
                label
            }
            .buttonStyle(HomeCardButtonStyle())
            .focused($focus, equals: .arena(arena.id))
            .accessibilityLabel("\(arena.fullName), live arena")
            .accessibilityValue(arenaStatus(item))
            .accessibilityIdentifier(UIID.Home.arena(arena.id))
        } else {
            // Upcoming arenas have no game to show yet, so Select only says when they begin.
            Button { noted = noted == arena.id ? nil : arena.id } label: { label }
                .buttonStyle(HomeCardButtonStyle())
                .focused($focus, equals: .arena(arena.id))
                .accessibilityLabel("\(arena.fullName), starts \(HomeShelves.time(arena.startsAt))")
                // The status line is the value, so Select showing "Starts at ..." is observable.
                .accessibilityValue(arenaStatus(item))
                .accessibilityIdentifier(UIID.Home.arena(arena.id))
        }
    }

    private func arenaLabel(_ item: ArenaShelfItem) -> some View {
        let arena = item.summary
        return VStack(alignment: .leading, spacing: 10) {
            if item.isLive {
                LiveDot()
            } else {
                LiveDot(label: "UPCOMING", color: Palette.muted)
            }
            Text(arena.fullName)
                .font(.system(size: 30, weight: .semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            Text("\(arena.nbPlayers) players \u{00B7} \(arena.perfKey.capitalized)")
                .font(.system(size: 24))
                .foregroundStyle(Palette.muted)
                .lineLimit(1)
            Text(arenaStatus(item))
                .font(.system(size: 24))
                .foregroundStyle(noted == arena.id ? Palette.accent : Palette.faint)
                .lineLimit(1)
        }
        .padding(24)
        .frame(width: 480, height: Layout.cardHeight, alignment: .leading)
    }

    private func arenaStatus(_ item: ArenaShelfItem) -> String {
        let arena = item.summary
        if noted == arena.id { return "Starts at \(HomeShelves.time(arena.startsAt))" }
        return item.isLive
            ? HomeShelves.endsIn(startsAt: arena.startsAt, minutes: arena.minutes, now: model.wallClock)
            : HomeShelves.startsIn(startsAt: arena.startsAt, now: model.wallClock)
    }

    // MARK: - Events

    private var eventShelf: some View {
        shelf("Events") {
            switch home.events {
            case .loading:
                notice("Loading\u{2026}")
            case .failed(let message):
                notice(message)
            case .loaded(let items):
                if items.isEmpty {
                    notice("No broadcasts right now")
                } else {
                    ForEach(items) { item in eventCard(item) }
                }
            }
        }
    }

    /// The organiser's banner fills the card, with the text over a gradient at the bottom so it
    /// stays readable on any picture. Tours without a banner get the placeholder.
    private func eventCard(_ tournament: BroadcastTournament) -> some View {
        NavigationLink(value: Route.boards(roundId: tournament.roundId, tournamentName: tournament.name)) {
            ZStack(alignment: .bottomLeading) {
                RemoteImage(bannerURL: tournament.imageURL, maxPixelSize: 1040)
                    .frame(width: 520, height: Layout.cardHeight)
                // Organisers' banners are often white; a flat dim plus a gradient towards the
                // text keeps the picture recognisable and the words readable on any of them.
                Palette.ground.opacity(0.42)
                LinearGradient(
                    stops: [
                        .init(color: Palette.ground.opacity(0.1), location: 0.0),
                        .init(color: Palette.ground.opacity(0.7), location: 0.45),
                        .init(color: Palette.ground.opacity(0.96), location: 1.0),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                VStack(alignment: .leading, spacing: 6) {
                    if tournament.roundOngoing {
                        LiveDot(label: "LIVE")
                    } else {
                        Text(HomeShelves.eventStatus(tournament, now: model.wallClock))
                            .font(.system(size: 20, weight: .semibold))
                            .tracking(1.4)
                            .foregroundStyle(Palette.muted)
                            .lineLimit(1)
                    }
                    Text(tournament.name)
                        .font(.system(size: 28, weight: .semibold))
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .multilineTextAlignment(.leading)
                    Text(tournament.roundName)
                        .font(.system(size: 24))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                    if let detail = eventDetail(tournament) {
                        Text(detail)
                            .font(.system(size: 22))
                            .foregroundStyle(Palette.faint)
                            .lineLimit(1)
                    }
                }
                .padding(24)
                .shadow(color: Palette.ground.opacity(0.8), radius: 6)
            }
            .frame(width: 520, height: Layout.cardHeight, alignment: .bottomLeading)
        }
        .buttonStyle(HomeCardButtonStyle())
        .focused($focus, equals: .event(tournament.roundId))
        .accessibilityLabel("\(tournament.name), \(tournament.roundName)")
        .accessibilityIdentifier(UIID.Home.event(tournament.roundId))
    }

    private func eventDetail(_ tournament: BroadcastTournament) -> String? {
        let parts = [tournament.format, tournament.location].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }
}
