// The three shelf cards.
//
// Countdowns redraw on a one-minute TimelineView rather than the app's clock ticker: a shelf
// showing "Starts in 12m" gains nothing from a per-second redraw and the phone keeps the battery.
import SwiftUI
import GameSessionKit
import ImageryKit
import LichessKit

// MARK: - Event

struct EventCard: View {
    let event: BroadcastTournament
    let open: () -> Void
    let rounds: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                InteractionFeedback.tap()
                open()
            } label: {
                VStack(alignment: .leading, spacing: 0) {
                    RemoteImage(bannerURL: event.imageURL, maxPixelSize: 900, title: event.name)
                        .frame(height: 132)
                        .frame(maxWidth: .infinity)
                        .clipped()
                        .decorative()

                    VStack(alignment: .leading, spacing: 6) {
                        Text(event.name)
                            .font(.headline)
                            .foregroundStyle(Palette.ink)
                            .multilineTextAlignment(.leading)
                            .lineLimit(2)

                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            HStack(spacing: 8) {
                                if event.roundOngoing {
                                    Chip(text: "Live", tint: Palette.accent, filled: true)
                                }
                                let status = event.roundOngoing
                                    ? event.roundName
                                    : HomeShelves.eventStatus(event, now: context.date)
                                if !status.isEmpty && !(event.roundOngoing && status.lowercased() == "live") {
                                    Text(status)
                                        .font(.subheadline)
                                        .foregroundStyle(Palette.muted)
                                        .lineLimit(1)
                                }
                            }
                        }

                        if let location = event.location, !location.isEmpty {
                            Text(location)
                                .font(.caption)
                                .foregroundStyle(Palette.faint)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Metrics.cardPadding)
                }
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint("Opens the boards of this round")
            .accessibilityIdentifier(UIID.Home.event(event.roundId))

            Divider().overlay(Palette.line)

            Button {
                InteractionFeedback.tap()
                rounds()
            } label: {
                HStack(spacing: 6) {
                    Text("All rounds")
                    Image(systemName: "chevron.right").font(.caption)
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Palette.accent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Metrics.cardPadding)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Lists every round of this event with its date")
            .accessibilityIdentifier(UIID.Home.eventRounds(event.roundId))
        }
        .panelCard()
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardCorner, style: .continuous))
    }

    private var accessibilityLabel: String {
        var parts = [event.name, event.roundName]
        if event.roundOngoing { parts.append("live now") }
        if let location = event.location, !location.isEmpty { parts.append(location) }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Arena

struct ArenaCard: View {
    let item: ArenaShelfItem
    let open: () -> Void

    var body: some View {
        Button {
            InteractionFeedback.tap()
            open()
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    if item.isLive {
                        Chip(text: "Live", tint: Palette.accent, filled: true)
                    } else {
                        Chip(text: "Soon", tint: Palette.amber)
                    }
                    Spacer(minLength: 0)
                }
                Text(item.summary.fullName)
                    .font(.headline)
                    .foregroundStyle(Palette.ink)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(status(now: context.date))
                        .font(.subheadline)
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                }

                Text("\(item.summary.nbPlayers.formatted(.number)) players")
                    .font(.caption)
                    .foregroundStyle(Palette.faint)
            }
            .padding(Metrics.cardPadding)
            .frame(width: 220, alignment: .leading)
            .panelCard()
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.summary.fullName), \(item.summary.nbPlayers) players")
        .accessibilityIdentifier(UIID.Home.arena(item.summary.id))
    }

    private func status(now: Date) -> String {
        item.isLive
            ? HomeShelves.endsIn(startsAt: item.summary.startsAt, minutes: item.summary.minutes, now: now)
            : HomeShelves.startsIn(startsAt: item.summary.startsAt, now: now)
    }
}

// MARK: - Lichess TV

struct ChannelCard: View {
    let channel: TVChannel
    let summary: TVChannelSummary?
    let open: () -> Void

    var body: some View {
        Button {
            InteractionFeedback.tap()
            open()
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(channel.displayName)
                    .font(.headline)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let summary {
                    Text(summary.userName)
                        .font(.subheadline)
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                    Text(summary.rating.map { "\($0)" } ?? " ")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Palette.faint)
                } else {
                    Text("Loading\u{2026}")
                        .font(.subheadline)
                        .foregroundStyle(Palette.faint)
                    Text(" ").font(.caption)
                }
            }
            .padding(Metrics.cardPadding)
            .frame(width: 152, alignment: .leading)
            .panelCard()
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(summary.map { "\(channel.displayName), \($0.userName)" } ?? channel.displayName)
        .accessibilityIdentifier(UIID.Home.channel(channel.rawValue))
    }
}
