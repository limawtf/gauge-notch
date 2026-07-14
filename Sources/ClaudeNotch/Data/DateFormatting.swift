import Foundation

/// Parseia ISO8601 vindo da API (com ou sem fracao de segundo). nil se invalido/ausente.
func parseISO8601(_ iso: String?) -> Date? {
    guard let iso else { return nil }
    let withFraction = ISO8601DateFormatter()
    withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = withFraction.date(from: iso) { return d }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: iso)
}

private let englishWeekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

/// Hora do reset no fuso local, arredondada pra hora cheia (bate com a Web UI).
/// Porta de `fmt_reset` do plugin Python.
func formatReset(_ date: Date?) -> String {
    guard let date else { return "?" }
    let now = Date()
    if date <= now { return "resetting..." }

    let calendar = Calendar.current
    var comps = calendar.dateComponents([.year, .month, .day, .hour], from: date)
    comps.minute = 0
    comps.second = 0
    guard let rounded = calendar.date(from: comps) else { return "?" }

    if calendar.isDateInToday(rounded) {
        return "today " + hourMinute(rounded)
    }
    if calendar.isDateInTomorrow(rounded) {
        return "tomorrow " + hourMinute(rounded)
    }
    let weekdayIndex = calendar.component(.weekday, from: rounded) // 1 = Sunday
    let mondayFirst = (weekdayIndex + 5) % 7 // 0 = Monday ... 6 = Sunday
    return "\(englishWeekdays[mondayFirst]) \(hourMinute(rounded))"
}

private let hhmmFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    return f
}()

private func hourMinute(_ date: Date) -> String {
    hhmmFormatter.string(from: date)
}
