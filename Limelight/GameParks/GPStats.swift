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

    /// Serialises recording: the four stores are read-modify-write
    /// cycles and must not interleave or lose each other's updates.
    private let recordQueue = DispatchQueue(label: "com.gameparks.stats.record")
    /// Bumped on every recorded session; screens include it in their
    /// rebuild signatures so stats changes refresh them exactly once.
    private(set) var revision = 0

    private init() {}

    /// A stable per-game key. The host's app id is the real identity;
    /// the fallbacks exist so a missing id degrades gracefully instead
    /// of collapsing unrelated games into one bucket: install path is
    /// unique per install, the name at least separates different games.
    static func appKey(host: TemporaryHost, app: TemporaryApp) -> String {
        let discriminator: String
        if let id = app.id, !id.isEmpty {
            discriminator = id
        } else if let path = app.installPath, !path.isEmpty {
            discriminator = path
        } else if let name = app.name, !name.isEmpty {
            discriminator = name
        } else {
            discriminator = "unknown"
        }
        return "\(host.uuid)/\(discriminator)"
    }

    // MARK: - Recording

    func recordSession(appKey: String, duration: TimeInterval, bitrateKbps: Int) {
        guard duration >= 5 else {
            return
        }
        recordQueue.async { [weak self] in
            guard let self = self else { return }
            // One timestamp for the whole event, so the session date
            // and last-played can never straddle a midnight boundary.
            let end = Date()
            let endInterval = end.timeIntervalSince1970

            var playtime = self.doubleDictionary(forKey: self.playtimeKey)
            playtime[appKey, default: 0] += duration
            self.defaults.set(playtime, forKey: self.playtimeKey)

            // Prune as we append: the raw session list must not grow
            // for the life of the install (every read used to re-read
            // and re-write the whole, ever-growing array).
            let cutoff = endInterval - 365 * 24 * 3600
            var sessions = (self.defaults.array(forKey: self.sessionsKey) as? [Double] ?? [])
                .filter { $0 >= cutoff }
            sessions.append(endInterval)
            self.defaults.set(sessions, forKey: self.sessionsKey)

            var lastPlayed = self.doubleDictionary(forKey: self.lastPlayedKey)
            lastPlayed[appKey] = endInterval
            self.defaults.set(lastPlayed, forKey: self.lastPlayedKey)

            // Streamed data estimate: bitrate (kb/s) * seconds / 8 = KB,
            // / 1000 = MB. Video bitrate only, so it is an estimate.
            // A corrupt (zero/negative) stored bitrate must not record
            // zero or negative data — fall back to the default.
            let effectiveBitrate = bitrateKbps > 0 ? bitrateKbps : 20000
            let megabytes = Double(effectiveBitrate) * duration / 8.0 / 1000.0
            self.defaults.set(self.defaults.double(forKey: self.dataKey) + megabytes, forKey: self.dataKey)

            self.revision += 1
        }
    }

    /// Reads a [String: Double] store value by value: if any single
    /// stored value is not a number, only that entry is dropped —
    /// an all-or-nothing cast would reset the whole history to zero.
    private func doubleDictionary(forKey key: String) -> [String: Double] {
        guard let raw = defaults.dictionary(forKey: key) else {
            return [:]
        }
        var result: [String: Double] = [:]
        for (entryKey, value) in raw {
            if let number = value as? NSNumber {
                result[entryKey] = number.doubleValue
            }
        }
        return result
    }

    // MARK: - Reading

    func playtime(forAppKey key: String) -> TimeInterval {
        return doubleDictionary(forKey: playtimeKey)[key] ?? 0
    }

    func lastPlayed(forAppKey key: String) -> Date? {
        guard let interval = doubleDictionary(forKey: lastPlayedKey)[key] else {
            return nil
        }
        return Date(timeIntervalSince1970: interval)
    }

    func totalPlaytime() -> TimeInterval {
        return doubleDictionary(forKey: playtimeKey).values.reduce(0, +)
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
        let playtime = doubleDictionary(forKey: playtimeKey)
        // Stable tie-break by key so equal-playtime games do not
        // reshuffle between launches (dictionary order is not stable).
        return playtime.map { (key: $0.key, seconds: $0.value) }
            .sorted { $0.seconds != $1.seconds ? $0.seconds > $1.seconds : $0.key < $1.key }
    }
}
