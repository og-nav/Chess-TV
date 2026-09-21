// The baseline rule, which is the single thing that stops this server from being a nuisance.
//
// From the plan: "Startup and reconnects take a baseline: the current PGN of every watched game is
// stored without emitting anything. Only a game whose stored ply is lower than the new ply emits,
// and only for the plies above the stored one. A PGN correction that lowers the ply resets the
// baseline silently."
//
// Pure functions over values, so the awkward cases — a restart mid-game, a correction, a game that
// ends on the same update that started it — are ordinary unit tests.

import Foundation

public enum GameDiffer {

    public struct Outcome: Sendable, Equatable {
        public var events: [MoveEvent]
        public var baseline: GameBaseline
    }

    /// Compares a fresh snapshot against what the server had stored.
    ///
    /// At most one of `gameStart`, `move` and `gameEnd` describes an advance, because they are
    /// three ways of saying "this game moved" and a device wants one push, not three. The one
    /// exception is a game that both starts and finishes between two updates, which is a real
    /// thing (a short stream gap over a quick resignation) and produces both.
    ///
    /// A gap of several plies produces a single `move` event at the latest ply. The intermediate
    /// positions are not pushed: a collapse-id notification would have replaced them within the
    /// second anyway, and the plan's cap on alert volume is the point.
    public static func advance(baseline: GameBaseline?, snapshot: GameSnapshot, now: Date) -> Outcome {
        guard let baseline else {
            // First sight. Store and say nothing — this is the rule that makes a restart in the
            // middle of a round silent instead of a flood of historical alerts.
            return Outcome(events: [], baseline: snapshot.baseline(observedAt: now, longThinkEligible: false))
        }

        if snapshot.ply < baseline.ply {
            // A correction: the operator took a move back. Re-baseline, emit nothing, and mark
            // the ply ineligible for a long think — we do not know when the player arrived on it.
            return Outcome(events: [], baseline: snapshot.baseline(observedAt: now, longThinkEligible: false))
        }

        if snapshot.ply == baseline.ply {
            // The ply did not move but the result did: the game was agreed drawn, or resigned.
            // This still has to be delivered — it is the alert the viewer most wanted — and it has
            // its own dedupe key, so it is not swallowed by the move that reached this ply.
            let justFinished = snapshot.isFinished && !baseline.isFinished
            let events = justFinished ? [MoveEvent(kind: .gameEnd, snapshot: snapshot, at: now)] : []

            // The ply count is the same but the position is not: the operator retyped the last
            // move as a different one. It is a correction, so it says nothing of its own, and the
            // player did *not* arrive on this position when the baseline says they did — the
            // clock on the old, wrong position cannot be claimed as a think on the new one. Both
            // the observation time and the eligibility reset, exactly as for a correction that
            // lowers the ply.
            guard snapshot.fen == baseline.fen else {
                var corrected = snapshot.baseline(observedAt: now, longThinkEligible: false)
                corrected.updatedAt = now
                return Outcome(events: events, baseline: corrected)
            }

            var updated = snapshot.baseline(observedAt: baseline.observedAt, longThinkEligible: baseline.longThinkEligible)
            updated.updatedAt = now
            return Outcome(events: events, baseline: updated)
        }

        var events: [MoveEvent] = []
        // `baseline.ply == 0` means the server watched this game sit at move zero and then begin.
        // A game first seen at ply 30 has no start to announce.
        if baseline.ply == 0 { events.append(MoveEvent(kind: .gameStart, snapshot: snapshot, at: now)) }
        if snapshot.isFinished && !baseline.isFinished {
            events.append(MoveEvent(kind: .gameEnd, snapshot: snapshot, at: now))
        } else if events.isEmpty {
            events.append(MoveEvent(kind: .move, snapshot: snapshot, at: now))
        }

        // The new ply was watched arriving, so a long think measured from now is honest.
        return Outcome(events: events, baseline: snapshot.baseline(observedAt: now, longThinkEligible: true))
    }

    /// Whether a game that has not moved has been still long enough to be worth an alert.
    ///
    /// - Parameters:
    ///   - baseline: the stored state, whose `observedAt` is when the current ply was first seen.
    ///   - minimumSeconds: the smallest `longThinkMinutes` among the follows that want one. Each
    ///     follow's own threshold is applied again by the policy; this is only the question of
    ///     whether the watcher should raise the event at all.
    /// - Returns: a `longThink` event carrying the elapsed time, or nil.
    ///
    /// Note what is *not* used: the clocks. With a 30-second increment a player's clock can be
    /// higher after a two-minute think than before it, so `whiteClock` differences do not measure
    /// thinking time. Elapsed observation does.
    public static func longThink(
        baseline: GameBaseline,
        snapshot: GameSnapshot,
        now: Date,
        minimumSeconds: Int
    ) -> MoveEvent? {
        guard baseline.longThinkEligible else { return nil }
        guard !baseline.isFinished, !snapshot.isFinished else { return nil }
        guard baseline.ply == snapshot.ply, baseline.ply > 0 else { return nil }
        let elapsed = now.timeIntervalSince(baseline.observedAt)
        guard elapsed >= Double(minimumSeconds) else { return nil }
        return MoveEvent(kind: .longThink, snapshot: snapshot, at: now, thinkSeconds: Int(elapsed))
    }
}
