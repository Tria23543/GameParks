//
//  GPStats.swift
//  GameParks
//
//  Local play statistics, counted automatically as sessions happen:
//  playtime per game, session counts, streamed data and last-played dates.
//  Stored in UserDefaults on this phone only.
//

import Foundation

final class GPStats {
    static let shared = GPStats()

    private let defaults = UserDefaults.standard
    private let playtimeKey = "GPStats.playtime"       // [appKey: seconds]
    private let sessionsKey = "GPStats.sessionDates"   // [Date.timeIntervalSince1970]
    private let lastPlayedKey = "GPStats.lastPlayed"   // [appKey: timeIntervalSince1970]
    private let dataKey = "GPStats.dataMB"             // total MB streamed (Double)

    private init() {}

    static func appKey(host: TemporaryHost, app: TemporaryApp) -> String {
        return "\(host.uuid)/\(app.id ?? app.name ?? "")"
    }

    // MARK: - Recording

    func recordSession(appKey: String, duration: TimeInterval, bitrateKbps: Int) {
        guard duration >= 5 else {
            return
        }
        var playtime = defaults.dictionary(forKey: playtimeKey) as? [String: Double] ?? [:]
        playtime[appKey, default: 0] += duration
        defaults.set(playtime, forKey: playtimeKey)

        var sessions = defaults.array(forKey: sessionsKey) as? [Double] ?? []
        sessions.append(Date().timeIntervalSince1970)
        defaults.set(sessions, forKey: sessionsKey)

        var lastPlayed = defaults.dictionary(forKey: lastPlayedKey) as? [String: Double] ?? [:]
        lastPlayed[appKey] = Date().timeIntervalSince1970
        defaults.set(lastPlayed, forKey: lastPlayedKey)

        // Streamed data estimate: bitrate (kb/s) * seconds / 8 = KB, / 1000 = MB
        let megabytes = Double(bitrateKbps) * duration / 8.0 / 1000.0
        defaults.set(defaults.double(forKey: dataKey) + megabytes, forKey: dataKey)
    }

    // MARK: - Reading

    func playtime(forAppKey key: String) -> TimeInterval {
        let playtime = defaults.dictionary(forKey: playtimeKey) as? [String: Double] ?? [:]
        return playtime[key] ?? 0
    }

    func lastPlayed(forAppKey key: String) -> Date? {
        let lastPlayed = defaults.dictionary(forKey: lastPlayedKey) as? [String: Double] ?? [:]
        guard let interval = lastPlayed[key] else {
            return nil
        }
        return Date(timeIntervalSince1970: interval)
    }

    func totalPlaytime() -> TimeInterval {
        let playtime = defaults.dictionary(forKey: playtimeKey) as? [String: Double] ?? [:]
        return playtime.values.reduce(0, +)
    }

    func totalSessions() -> Int {
        return (defaults.array(forKey: sessionsKey) as? [Double] ?? []).count
    }

    func totalDataMB() -> Double {
        return defaults.double(forKey: dataKey)
    }

    /// Session counts for the current week, Monday first (7 values).
    func sessionsThisWeek() -> [Int] {
        let sessions = (defaults.array(forKey: sessionsKey) as? [Double] ?? []).map { Date(timeIntervalSince1970: $0) }
        var calendar = Calendar.current
        calendar.firstWeekday = 2 // Monday
        guard let week = calendar.dateInterval(of: .weekOfYear, for: Date()) else {
            return [Int](repeating: 0, count: 7)
        }
        var counts = [Int](repeating: 0, count: 7)
        for date in sessions where week.contains(date) {
            // weekday: 1 = Sunday ... 7 = Saturday; convert to Monday-first index
            let weekday = calendar.component(.weekday, from: date)
            let index = (weekday + 5) % 7
            counts[index] += 1
        }
        return counts
    }

    func sessionsThisWeekCount() -> Int {
        return sessionsThisWeek().reduce(0, +)
    }

    /// Playtime ranked across all known app keys: [(appKey, seconds)] highest first.
    func rankedPlaytime() -> [(key: String, seconds: TimeInterval)] {
        let playtime = defaults.dictionary(forKey: playtimeKey) as? [String: Double] ?? [:]
        return playtime.map { (key: $0.key, seconds: $0.value) }.sorted { $0.seconds > $1.seconds }
    }
}
