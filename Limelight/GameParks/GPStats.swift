//
//  GPStats.swift
//  GameParks
//
//  Local play statistics, counted on this phone: every stream
//  session's app, start, duration and bitrate. Backs the Stats
//  screen and the "Played / Last played" figures on Home and the
//  game page. Stored in UserDefaults; nothing leaves the device.
//
//  The active session is persisted as it runs (A-15): beginSession
//  writes it to UserDefaults and a heartbeat keeps it fresh, so a
//  crash, kill or reboot mid-stream is reconciled on next launch
//  instead of vanishing. Duration is accumulated from the
//  monotonic system-uptime clock and pauses while the app is
//  backgrounded (A-44). Lifetime totals live in their own persisted
//  counters that record pruning never reduces (A-46).
//

import UIKit

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
    private let activeSessionKey = "GPActiveSessionV1"
    private let aggregatesKey = "GPLifetimeAggregatesV1"
    private var records: [GPSessionRecord] = []

    private var activeKey: String?
    private var activeName: String?
    private var activeStart: Date?
    private var activeBitrateKbps: Int = 20000

    // Monotonic accumulation (A-44): banked seconds plus the
    // uptime at which the current un-paused stretch began.
    private var activeAccumulated: TimeInterval = 0
    private var activeStretchStartUptime: TimeInterval?
    private var heartbeatTimer: Timer?

    // Lifetime aggregates (A-46), persisted separately so pruning
    // the record list can never shrink them.
    private var lifetimeSeconds: TimeInterval = 0
    private var lifetimeSessions: Int = 0

    private init() {
        records = Self.load()
        loadAggregates()
        reconcilePersistedActiveSession()
        NotificationCenter.default.addObserver(self, selector: #selector(appWillResignActive),
                                               name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appDidBecomeActive),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    // MARK: - Recording

    func beginSession(appKey: String, appName: String, bitrateKbps: Int) {
        // A-42: never silently overwrite a session in progress.
        if hasActiveSession {
            endSession()
        }
        activeKey = appKey
        activeName = appName
        activeStart = Date()
        activeBitrateKbps = max(bitrateKbps, 1)
        activeAccumulated = 0
        activeStretchStartUptime = ProcessInfo.processInfo.systemUptime
        persistActiveSession(heartbeat: Date())
        startHeartbeat()
    }

    var hasActiveSession: Bool { activeStart != nil }

    func endSession() {
        guard let key = activeKey, let name = activeName, let start = activeStart else {
            return
        }
        let duration = currentAccumulatedDuration()
        let bitrate = activeBitrateKbps
        activeKey = nil
        activeName = nil
        activeStart = nil
        activeAccumulated = 0
        activeStretchStartUptime = nil
        stopHeartbeat()
        UserDefaults.standard.removeObject(forKey: activeSessionKey)
        guard duration >= 1 else { return }
        appendRecord(GPSessionRecord(appKey: key, appName: name, start: start,
                                     duration: duration, bitrateKbps: bitrate))
    }

    private func currentAccumulatedDuration() -> TimeInterval {
        var total = activeAccumulated
        if let stretchStart = activeStretchStartUptime {
            total += ProcessInfo.processInfo.systemUptime - stretchStart
        }
        return total
    }

    private func appendRecord(_ record: GPSessionRecord) {
        records.append(record)
        lifetimeSeconds += record.duration
        lifetimeSessions += 1
        saveAggregates()
        // Keep the store bounded and reasonably recent. Pruning
        // touches only the record list, never the aggregates above.
        let cutoff = Date().addingTimeInterval(-180 * 24 * 3600)
        records = records.filter { $0.start > cutoff }
        if records.count > 500 {
            records = Array(records.suffix(500))
        }
        save()
    }

    // MARK: - Background pausing (A-44)

    @objc private func appWillResignActive() {
        guard hasActiveSession, let stretchStart = activeStretchStartUptime else { return }
        activeAccumulated += ProcessInfo.processInfo.systemUptime - stretchStart
        activeStretchStartUptime = nil
        if let start = activeStart {
            persistActiveSession(heartbeat: start.addingTimeInterval(activeAccumulated))
        }
    }

    @objc private func appDidBecomeActive() {
        guard hasActiveSession, activeStretchStartUptime == nil else { return }
        activeStretchStartUptime = ProcessInfo.processInfo.systemUptime
    }

    // MARK: - Active-session persistence (A-15)

    private func persistActiveSession(heartbeat: Date) {
        guard let key = activeKey, let name = activeName, let start = activeStart else { return }
        let dict: [String: Any] = ["key": key, "name": name,
                                   "start": start.timeIntervalSince1970,
                                   "heartbeat": heartbeat.timeIntervalSince1970,
                                   "bitrate": activeBitrateKbps]
        UserDefaults.standard.set(dict, forKey: activeSessionKey)
    }

    private func startHeartbeat() {
        stopHeartbeat()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            guard let self = self, self.hasActiveSession else { return }
            self.persistActiveSession(heartbeat: Date())
        }
    }

    private func stopHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    /// A persisted active session at launch means the previous
    /// process died mid-stream: credit it up to its last heartbeat.
    private func reconcilePersistedActiveSession() {
        guard let dict = UserDefaults.standard.dictionary(forKey: activeSessionKey) else { return }
        UserDefaults.standard.removeObject(forKey: activeSessionKey)
        guard let key = dict["key"] as? String,
              let name = dict["name"] as? String,
              let startTs = dict["start"] as? Double,
              let heartbeatTs = dict["heartbeat"] as? Double,
              let bitrate = dict["bitrate"] as? Int else {
            return
        }
        let duration = max(heartbeatTs - startTs, 0)
        guard duration >= 1 else { return }
        appendRecord(GPSessionRecord(appKey: key, appName: name,
                                     start: Date(timeIntervalSince1970: startTs),
                                     duration: duration, bitrateKbps: bitrate))
    }

    // MARK: - Aggregates

    /// Lifetime playtime (A-46): never reduced by pruning.
    var totalSeconds: TimeInterval {
        lifetimeSeconds
    }

    /// Lifetime session count (A-46): never reduced by pruning.
    var sessionCount: Int {
        lifetimeSessions
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
        // A-45: when the most recent session *ended*, not started.
        guard let latest = records.filter({ $0.appKey == key }).max(by: { $0.start < $1.start }) else {
            return nil
        }
        return latest.start.addingTimeInterval(latest.duration)
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

    private func loadAggregates() {
        if let dict = UserDefaults.standard.dictionary(forKey: aggregatesKey),
           let seconds = dict["totalSeconds"] as? Double,
           let sessions = dict["totalSessions"] as? Int {
            lifetimeSeconds = seconds
            lifetimeSessions = sessions
        } else {
            // First run with aggregates: seed them from the records
            // on disk so existing history keeps its totals.
            lifetimeSeconds = records.reduce(0) { $0 + $1.duration }
            lifetimeSessions = records.count
            saveAggregates()
        }
    }

    private func saveAggregates() {
        UserDefaults.standard.set(["totalSeconds": lifetimeSeconds,
                                   "totalSessions": lifetimeSessions], forKey: aggregatesKey)
    }

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

/// "12.4 h" / "45 min" / "45 s" / "—" only for zero. (A-75: sub-minute
/// sessions are real playtime and must not render as "no data"; minutes
/// are rounded, not truncated.)
func gpFormatPlaytime(_ seconds: TimeInterval) -> String {
    if seconds <= 0 {
        return "—"
    }
    if seconds < 60 {
        return "\(Int(seconds)) s"
    }
    let minutes = Int((seconds / 60).rounded())
    if minutes < 60 {
        return "\(minutes) min"
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
