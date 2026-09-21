// Quiet hours, as minutes from midnight in the device's own time zone.
//
// The server enforces them — a muted device should cost no push at all — but the phone has to
// show the same answer the server will compute, or the Settings screen is a lie. So the rule
// lives here, pure, and the same arithmetic is what goes over the wire.
import Foundation

enum QuietHours {

    static let minutesPerDay = 24 * 60

    /// The default window offered when quiet hours are switched on: 22:00 to 07:00.
    static let defaultStart = 22 * 60
    static let defaultEnd = 7 * 60

    /// Is `minute` (0..<1440) inside the window?
    ///
    /// A window that wraps past midnight (22:00 → 07:00) is the normal case, so the comparison
    /// flips rather than splitting into two ranges. A start equal to the end is no window at
    /// all — the same answer `NotificationPreferences.isQuiet` gives, and so the one the server
    /// enforces. (A whole quiet day is what the mute switch is for.)
    static func isQuiet(minute: Int, start: Int, end: Int) -> Bool {
        let minute = wrap(minute), start = wrap(start), end = wrap(end)
        if start == end { return false }
        if start < end { return minute >= start && minute < end }
        return minute >= start || minute < end
    }

    static func wrap(_ minute: Int) -> Int {
        let remainder = minute % minutesPerDay
        return remainder < 0 ? remainder + minutesPerDay : remainder
    }

    /// Minutes from midnight for a wall-clock time, in `calendar`'s time zone.
    static func minutes(from date: Date, calendar: Calendar = .current) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    /// A `Date` today at that minute, which is what a `DatePicker` binds to.
    ///
    /// Set by wall-clock hour and minute rather than by adding minutes to midnight: on a day a
    /// DST change makes 23 or 25 hours long, "22:00" is still 22:00.
    static func date(fromMinutes minutes: Int, on day: Date = .now, calendar: Calendar = .current) -> Date {
        let minutes = wrap(minutes)
        let midnight = calendar.startOfDay(for: day)
        return calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: midnight) ?? midnight
    }

    /// "22:00" or "10:00 PM", whichever the device's locale uses.
    static func text(_ minutes: Int, locale: Locale = .current, calendar: Calendar = .current) -> String {
        date(fromMinutes: minutes, calendar: calendar)
            .formatted(.dateTime.hour().minute().locale(locale))
    }

    /// "22:00 to 07:00", the summary on the Notifications row.
    static func rangeText(start: Int, end: Int, locale: Locale = .current) -> String {
        "\(text(start, locale: locale)) to \(text(end, locale: locale))"
    }

    /// How long the window lasts, for the explanatory line under the pickers.
    static func lengthMinutes(start: Int, end: Int) -> Int {
        let start = wrap(start), end = wrap(end)
        if start == end { return 0 }
        return start < end ? end - start : minutesPerDay - start + end
    }
}
