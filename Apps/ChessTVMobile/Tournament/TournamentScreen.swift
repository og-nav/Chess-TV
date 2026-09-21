// One broadcast's rounds, with dates and an ongoing marker, and the Follow button for the event.
//
// Following the *event* rather than a board is the thing the World Championship needs: the round
// list changes every day, the board a player sits at changes every round, and a follow that has
// to be re-pointed each morning is a follow that gets missed.
import SwiftUI
import GameSessionKit
import LichessKit

@MainActor
@Observable
final class TournamentModel {

    private(set) var state: LoadState<BroadcastTour> = .loading

    let tourId: String
    @ObservationIgnored private let client: BroadcastClient
    @ObservationIgnored private let backoff: PollBackoff

    init(tourId: String, client: BroadcastClient = BroadcastClient(), backoff: PollBackoff = .rounds) {
        self.tourId = tourId
        self.client = client
        self.backoff = backoff
    }

    var tour: BroadcastTour? { state.value }

    /// The round to open first: the one being played, else the next one to start, else the last.
    var highlightedRound: BroadcastRound? {
        guard let rounds = tour?.rounds, !rounds.isEmpty else { return nil }
        if let ongoing = rounds.first(where: { $0.ongoing }) { return ongoing }
        let upcoming = rounds
            .filter { !$0.finished }
            .sorted { ($0.startsAt ?? .distantFuture) < ($1.startsAt ?? .distantFuture) }
        return upcoming.first ?? rounds.last
    }

    func run() async {
        var failures = 0
        while !Task.isCancelled {
            do {
                let tour = try await client.tournament(id: tourId)
                guard !Task.isCancelled else { return }
                failures = 0
                state = .loaded(tour)
            } catch {
                if error is CancellationError { return }
                failures += 1
                mobileLog.error("Tour \(self.tourId, privacy: .public) load failed: \(String(describing: error), privacy: .public)")
                if state.value == nil { state = .failed("Couldn\u{2019}t load the rounds \u{00B7} retrying") }
            }
            do { try await Task.sleep(for: backoff.delay(afterFailures: failures)) } catch { return }
        }
    }

    #if DEBUG
    /// Drops a fetched tour straight in, so a test can ask which round the screen would open on
    /// without a network.
    func acceptForTesting(_ tour: BroadcastTour) { state = .loaded(tour) }
    #endif

    /// "Live", "Finished", "Today 14:00", "Sat 24 Nov, 14:00", or nothing when Lichess gives no
    /// start time (a round that begins when the previous one ends).
    static func status(for round: BroadcastRound, now: Date = .now) -> String {
        if round.ongoing { return "Live" }
        if round.finished { return "Finished" }
        guard let startsAt = round.startsAt else { return "Starts after the previous round" }
        if Calendar.current.isDateInToday(startsAt) { return "Today \(HomeShelves.time(startsAt))" }
        if Calendar.current.isDateInTomorrow(startsAt) { return "Tomorrow \(HomeShelves.time(startsAt))" }
        return startsAt.formatted(date: .abbreviated, time: .shortened)
    }
}

struct TournamentScreen: View {
    let tourId: String
    let name: String?

    @Environment(Navigator.self) private var navigator
    @State private var model: TournamentModel

    init(tourId: String, name: String?) {
        self.tourId = tourId
        self.name = name
        _model = State(initialValue: TournamentModel(tourId: tourId))
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text(model.tour?.name ?? name ?? "Event")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Palette.ink)
                    HStack {
                        FollowButton(followability: .followable(.tournament(tourId: tourId)), identifier: UIID.Tournament.follow) { target in
                            navigator.push(.followDetail(target: target))
                        }
                        Spacer()
                    }
                    OfflineFollowNote()
                }
                .padding(.vertical, 4)
                .listRowBackground(Palette.panel)
            }

            Section("Rounds") {
                switch model.state {
                case .loading:
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Loading rounds…").foregroundStyle(Palette.muted)
                    }
                    .frame(maxWidth: .infinity, minHeight: 72)
                    .listRowBackground(Palette.panel)
                case .failed(let message):
                    Text(message).foregroundStyle(Palette.alert).listRowBackground(Palette.panel)
                case .loaded(let tour):
                    ForEach(tour.rounds, id: \.id) { round in
                        Button {
                            InteractionFeedback.tap()
                            navigator.push(.boards(roundId: round.id, tournamentName: tour.name))
                        } label: {
                            RoundRow(round: round)
                        }
                        .listRowBackground(Palette.panel)
                        .accessibilityIdentifier(UIID.Tournament.round(round.id))
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.ground)
        .navigationTitle(model.tour?.name ?? name ?? "Event")
        .navigationBarTitleDisplayMode(.inline)
        .task { guard !AppEnvironment.isUnderTest else { return }; await model.run() }
    }
}

private struct RoundRow: View {
    let round: BroadcastRound

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(round.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Palette.ink)
                Text(TournamentModel.status(for: round))
                    .font(.subheadline)
                    .foregroundStyle(round.ongoing ? Palette.accent : Palette.muted)
            }
            Spacer(minLength: 0)
            if round.ongoing { Chip(text: "Live", filled: true) }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Palette.faint).decorative()
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(round.name), \(TournamentModel.status(for: round))")
    }
}
