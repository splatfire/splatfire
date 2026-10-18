import Foundation
import Observation
import UserNotifications

/// Remembers on which days you practised (for the streak on the home
/// screen) and, if you want, reminds you to review a dance a couple of days
/// later.
///
/// A day counts once you've played a project's video for a minute in total,
/// or recorded a take. Stored in UserDefaults (just a list of dates), so it
/// never leaves the iPhone.
@MainActor
@Observable
final class PracticeLog {
    static let shared = PracticeLog()

    /// Practice days as "yyyy-MM-dd" (local time).
    private(set) var days: Set<String>

    private static let daysKey = "practiceDays"
    static let remindersKey = "reviewReminders"
    /// Review reminder: this many days after you last practised a project, at 18:00.
    static let reviewAfterDays = 2

    private init() {
        days = Set(UserDefaults.standard.stringArray(forKey: Self.daysKey) ?? [])
    }

    // MARK: - Streak

    /// Days in a row up to today (or up to yesterday, if you haven't
    /// practised yet today – the streak isn't lost until the day is over).
    var streak: Int {
        let calendar = Calendar.current
        var day = calendar.startOfDay(for: .now)
        if !days.contains(Self.key(day)) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: day) else { return 0 }
            day = yesterday
        }
        var count = 0
        while days.contains(Self.key(day)) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return count
    }

    var practisedToday: Bool { days.contains(Self.key(.now)) }

    /// Call when you've practised `project` (played a minute / recorded a take).
    func recordPractice(of project: Project) {
        let today = Self.key(.now)
        if !days.contains(today) {
            days.insert(today)
            // Keep about a year.
            let sorted = days.sorted()
            if sorted.count > 400 { days = Set(sorted.suffix(400)) }
            UserDefaults.standard.set(Array(days), forKey: Self.daysKey)
        }
        if UserDefaults.standard.bool(forKey: Self.remindersKey) {
            scheduleReview(of: project)
        }
    }

    private static func key(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    // MARK: - Review reminders

    /// Asks iOS for permission to show notifications. Returns true if allowed.
    func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// One reminder per project, `reviewAfterDays` days from now at 18:00.
    /// Practising again moves it (same identifier replaces the old one).
    func scheduleReview(of project: Project) {
        let calendar = Calendar.current
        guard let day = calendar.date(byAdding: .day, value: Self.reviewAfterDays, to: .now) else { return }
        var when = calendar.dateComponents([.year, .month, .day], from: day)
        when.hour = 18
        when.minute = 0

        let content = UNMutableNotificationContent()
        content.title = "Time to review \"\(project.title)\""
        content.body = "A quick run-through now helps you remember the dance. Try a memory test!"
        content.sound = .default
        let trigger = UNCalendarNotificationTrigger(dateMatching: when, repeats: false)
        let request = UNNotificationRequest(identifier: Self.identifier(for: project),
                                            content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }

    func cancelReview(of project: Project) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: [Self.identifier(for: project)])
    }

    func cancelAllReviews() {
        UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
            let ids = requests.map(\.identifier).filter { $0.hasPrefix("review-") }
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
        }
    }

    private static func identifier(for project: Project) -> String {
        "review-\(project.id.uuidString)"
    }
}
