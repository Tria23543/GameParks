//
//  GPStats.swift
//  GameParks
//
//  Local play statistics, counted on this phone: every stream
//  session's app, start, duration and bitrate. Backs the Stats
//  screen and the "Played / Last played" figures on Home and the
//  game page. Stored in UserDefaults; nothing leaves the device.
//

import Foundation

struct GPSessionRecord {
    let appKey: String
    let appName: String
    let start: Date
    let duration: TimeInterval
    let bitrateKbps: Int
}

final class GPStats {
    static let shared = GPStats()

    private let storageKey = "GPSessionsV2"
    private var records: [GPSessionRecord] = []

    private var activeKey: String?
    private var activeName: String?
    private var activeStart: Date?
    private var activeBitrateKbps: Int = 20000

    private init() {
        records = Self.load()
    }

    // MARK: - Recording

    func beginSession(appKey: String, appName: String, bitrateKbps: Int) {
        activeKey = appKey
        activeName = appName
        activeStart = Date()
        activeBitrateKbps = max(bitrateKbps, 1)
    }

    var hasActiveSession: Bool { activeStart != nil }

    func endSession() {
        guard let key = activeKey, let name = activeName, let start = activeStart else {
            return
        }
        let duration = Date().timeIntervalSince(start)
        activeKey = nil
        activeName = nil
        activeStart = nil
        guard duration >= 1 else { return }
        records.append(GPSessionRecord(appKey: key, appName: name, start: start,
                                       duration: duration, bitrateKbps: activeBitrateKbps))
        // Keep the store bounded and reasonably recent.
        let cutoff = Date().addingTimeInterval(-180 * 24 * 3600)
        records = records.filter { $0.start > cutoff }
        if records.count > 500 {
            records = Array(records.suffix(500))
        }
        save()
    }

    // MARK: - Aggregates

    var totalSeconds: TimeInterval {
        records.reduce(0) { $0 + $1.duration }
    }

    var sessionCount: Int {
        records.count
    }

    /// Estimated from each session's duration × its bitrate.
    var totalStreamedGB: Double {
        let bits = records.reduce(0.0) { $0 + $1.duration * Double($1.bitrateKbps) * 1000.0 }
        return bits / 8.0 / 1_000_000_000.0
    }

    func seconds(forAppKey key: String) -> TimeInterval {
        records.filter { $0.appKey == key }.reduce(0) { $0 + $1.duration }
    }

    func lastPlayed(forAppKey key: String) -> Date? {
        records.filter { $0.appKey == key }.map { $0.start }.max()
    }

    /// (appKey, appName, seconds) sorted by playtime, longest first.
    func mostPlayed(limit: Int = 4) -> [(key: String, name: String, seconds: TimeInterval)] {
        var totals: [String: (name: String, seconds: TimeInterval)] = [:]
        for record in records {
            var entry = totals[record.appKey] ?? (name: record.appName, seconds: 0)
            entry.seconds += record.duration
            entry.name = record.appName
            totals[record.appKey] = entry
        }
        return totals
            .map { (key: $0.key, name: $0.value.name, seconds: $0.value.seconds) }
            .sorted { $0.seconds > $1.seconds }
            .prefix(limit)
            .map { $0 }
    }

    /// Session counts for the current week, Monday first, plus the
    /// week's total — the Stats screen's "This week" chart.
    func thisWeek() -> (days: [Int], total: Int) {
        var calendar = Calendar.current
        calendar.firstWeekday = 2 // Monday
        guard let weekStart = calendar.dateInterval(of: .weekOfYear, for: Date())?.start else {
            return ([0, 0, 0, 0, 0, 0, 0], 0)
        }
        var days = [Int](repeating: 0, count: 7)
        var total = 0
        for record in records {
            let dayIndex = calendar.dateComponents([.day], from: weekStart, to: record.start).day ?? -1
            if dayIndex >= 0 && dayIndex < 7 {
                days[dayIndex] += 1
                total += 1
            }
        }
        return (days, total)
    }

    // MARK: - Persistence

    private static func load() -> [GPSessionRecord] {
        guard let raw = UserDefaults.standard.array(forKey: "GPSessionsV2") as? [[String: Any]] else {
            return []
        }
        return raw.compactMap { dict in
            guard let key = dict["key"] as? String,
                  let name = dict["name"] as? String,
                  let start = dict["start"] as? Double,
                  let duration = dict["duration"] as? Double,
                  let bitrate = dict["bitrate"] as? Int else {
                return nil
            }
            return GPSessionRecord(appKey: key, appName: name,
                                   start: Date(timeIntervalSince1970: start),
                                   duration: duration, bitrateKbps: bitrate)
        }
    }

    private func save() {
        let raw: [[String: Any]] = records.map {
            ["key": $0.appKey, "name": $0.appName,
             "start": $0.start.timeIntervalSince1970,
             "duration": $0.duration, "bitrate": $0.bitrateKbps]
        }
        UserDefaults.standard.set(raw, forKey: storageKey)
    }
}

// MARK: - Formatting

/// "12.4 h" / "45 min" / "—" for zero.
func gpFormatPlaytime(_ seconds: TimeInterval) -> String {
    if seconds < 60 {
        return "—"
    }
    if seconds < 3600 {
        return "\(Int(seconds / 60)) min"
    }
    return String(format: "%.1f h", seconds / 3600.0)
}

/// "Yesterday" / "2 days ago" / "12 Nov" style relative dates.
func gpFormatLastPlayed(_ date: Date?) -> String {
    guard let date = date else { return "Never" }
    let calendar = Calendar.current
    if calendar.isDateInToday(date) {
        return "Today"
    }
    if calendar.isDateInYesterday(date) {
        return "Yesterday"
    }
    let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                       to: calendar.startOfDay(for: Date())).day ?? 0
    if days > 1 && days < 30 {
        return "\(days) days ago"
    }
    let formatter = DateFormatter()
    formatter.dateFormat = "d MMM yyyy"
    return formatter.string(from: date)
}
