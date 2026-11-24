//
//  GPCatalog.swift
//  GameParks
//
//  Everything GameParks knows about a game beyond what the host
//  reports: which bundled cover it gets, whether it belongs to
//  "Your classics" (her own setup installs) or the big Steam shelf,
//  the source tag and detail line the design shows, and favourites.
//
//  Matching is deliberately conservative and specific-before-broad:
//  a title only earns a cover or a "Your setup" tag when it matches
//  one of Glenda's known games exactly enough that a prefix can't
//  misfire (the v1.2 register recorded "Grand Theft Auto: Vice City"
//  being swallowed by GTA V's prefix — the token rules below exist
//  because of that).
//

import UIKit

struct GPGameInfo {
    let coverImageName: String?
    let isClassic: Bool
    let sourceTag: String?
    let detailLine: String?
}

enum GPCatalog {

    // MARK: - App identity

    static func appKey(host: TemporaryHost, app: TemporaryApp) -> String {
        return (host.uuid ?? "") + "|" + (app.id ?? app.name ?? "")
    }

    /// The host's visible apps, name-sorted — the one list every
    /// screen renders from.
    static func sortedApps(for host: TemporaryHost) -> [TemporaryApp] {
        let apps = host.appList.compactMap { $0 as? TemporaryApp }.filter { !$0.hidden }
        return apps.sorted {
            ($0.name ?? "").localizedCaseInsensitiveCompare($1.name ?? "") == .orderedAscending
        }
    }

    static func isDesktop(_ app: TemporaryApp) -> Bool {
        return normalized(app.name ?? "") == "desktop"
    }

    // MARK: - Classification

    static func info(for app: TemporaryApp) -> GPGameInfo {
        let name = app.name ?? ""
        let norm = normalized(name)
        let tokens = norm.split(separator: " ").map(String.init)

        func hasPhrase(_ phrase: String) -> Bool {
            return (" " + norm + " ").contains(" " + phrase + " ")
        }

        // Desktop is Sunshine's built-in entry, not a game.
        if norm == "desktop" {
            return GPGameInfo(coverImageName: nil, isClassic: false,
                              sourceTag: "Sunshine", detailLine: "Your PC's desktop")
        }

        // --- Your classics (her own setup installs) ---

        if hasPhrase("vice city") {
            return GPGameInfo(coverImageName: "cover_vicecity", isClassic: true,
                              sourceTag: "Your setup", detailLine: "Open world · Rockstar Games")
        }
        if norm == "tomb raider" || hasPhrase("tomb raider ii") || hasPhrase("tomb raider iii")
            || hasPhrase("tomb raider the angel of darkness") || hasPhrase("tomb raider legend")
            || hasPhrase("tomb raider anniversary") || hasPhrase("tomb raider underworld") {
            return GPGameInfo(coverImageName: "cover_tombraider", isClassic: true,
                              sourceTag: "Your setup", detailLine: "Adventure · Core Design")
        }
        if norm == "call of duty" || norm == "call of duty 2"
            || hasPhrase("call of duty united offensive") {
            return GPGameInfo(coverImageName: "cover_cod", isClassic: true,
                              sourceTag: "Your setup", detailLine: "WWII shooter · Infinity Ward")
        }
        if hasPhrase("most wanted") && (hasPhrase("need for speed") || hasPhrase("nfs")) {
            return GPGameInfo(coverImageName: "cover_nfsmw", isClassic: true,
                              sourceTag: "Your setup", detailLine: "Racing · Electronic Arts")
        }

        // --- Big games (Steam shelf) ---

        if tokens == ["grand", "theft", "auto", "v"] || tokens == ["gta", "v"]
            || norm == "grand theft auto 5" || norm == "gta5" || norm == "gtav" {
            return GPGameInfo(coverImageName: "cover_gta5", isClassic: false,
                              sourceTag: "Steam", detailLine: "Open world · Rockstar Games")
        }
        if hasPhrase("red dead redemption 2") || hasPhrase("red dead redemption ii") || norm == "rdr2" {
            return GPGameInfo(coverImageName: "cover_rdr2", isClassic: false,
                              sourceTag: "Steam", detailLine: "Western · Rockstar Games")
        }
        if hasPhrase("the last of us part i") || hasPhrase("the last of us part 1") {
            return GPGameInfo(coverImageName: "cover_tlou", isClassic: false,
                              sourceTag: "Steam", detailLine: "Story-driven · Naughty Dog")
        }
        if hasPhrase("mafia") {
            if hasPhrase("mafia ii") || hasPhrase("mafia 2") {
                return GPGameInfo(coverImageName: "cover_mafia", isClassic: false,
                                  sourceTag: "Steam", detailLine: "Crime saga · 2K Czech")
            }
            return GPGameInfo(coverImageName: "cover_mafia", isClassic: false,
                              sourceTag: "Steam", detailLine: "Crime saga · Hangar 13")
        }
        if hasPhrase("rise of the tomb raider") || hasPhrase("shadow of the tomb raider") {
            return GPGameInfo(coverImageName: nil, isClassic: false,
                              sourceTag: "Steam", detailLine: "Adventure · Crystal Dynamics")
        }
        if hasPhrase("the last of us part ii") || hasPhrase("the last of us part 2") {
            return GPGameInfo(coverImageName: nil, isClassic: false,
                              sourceTag: "Steam", detailLine: "Story-driven · Naughty Dog")
        }
        if hasPhrase("red dead redemption") {
            return GPGameInfo(coverImageName: nil, isClassic: false,
                              sourceTag: "Steam", detailLine: "Western · Rockstar Games")
        }
        if hasPhrase("grand theft auto") || tokens.first == "gta" {
            return GPGameInfo(coverImageName: nil, isClassic: false,
                              sourceTag: "Steam", detailLine: "Open world · Rockstar Games")
        }
        if hasPhrase("call of duty") {
            return GPGameInfo(coverImageName: nil, isClassic: false,
                              sourceTag: "Steam", detailLine: "Shooter · Activision")
        }
        if hasPhrase("need for speed") || tokens.first == "nfs" {
            return GPGameInfo(coverImageName: nil, isClassic: false,
                              sourceTag: "Steam", detailLine: "Racing · Electronic Arts")
        }

        // Unknown title: a big game with no claims we can't back up.
        return GPGameInfo(coverImageName: nil, isClassic: false,
                          sourceTag: nil, detailLine: nil)
    }

    /// The art a game tile shows, in priority order:
    /// 1. the box art the host itself serves (Sunshine supplies an
    ///    image per application), fetched and disk-cached by
    ///    upstream's AppAssetManager;
    /// 2. a bundled cover matched by the game's name;
    /// 3. nil — the views render their title tile instead.
    /// While host art is still arriving, the bundled cover (or the
    /// tile) is the placeholder.
    static func coverImage(for app: TemporaryApp) -> UIImage? {
        if let art = hostBoxArt(for: app) {
            return art
        }
        guard let name = info(for: app).coverImageName else { return nil }
        return UIImage(named: name)
    }

    // MARK: - Host box art

    private static let boxArtCache = NSCache<NSString, UIImage>()
    private static let boxArtDecodeQueue = DispatchQueue(label: "com.gameparks.boxart", qos: .userInitiated)
    /// Keys whose decode has been kicked off (main-thread confined:
    /// coverImage is only ever called from screen rebuilds). A key
    /// stays in the set after a failed decode so a bad file is not
    /// retried on every rebuild.
    private static var boxArtRequested = Set<NSString>()

    /// The decoded host box art for an app, or nil if it isn't
    /// decoded yet. The PNG itself is fetched from the host by
    /// AppAssetManager (driven by GPSessionController after each
    /// app-list load) into the on-disk cache; here it is only read
    /// and decoded — off the main thread, force-decoded, so a
    /// scrolling list never pays the decode cost. When a decode
    /// lands, the normal app-list notification re-renders the
    /// screens and they pick the image up from the memory cache.
    static func hostBoxArt(for app: TemporaryApp) -> UIImage? {
        guard let uuid = app.host?.uuid, let appID = app.id else { return nil }
        let key = "\(uuid)/\(appID)" as NSString
        if let cached = boxArtCache.object(forKey: key) {
            return cached
        }
        let path = AppAssetManager.boxArtPath(for: app)
        guard FileManager.default.fileExists(atPath: path),
              !boxArtRequested.contains(key) else { return nil }
        boxArtRequested.insert(key)
        let host = app.host
        boxArtDecodeQueue.async {
            var decoded: UIImage?
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
               let image = UIImage(data: data) {
                // Force the decode here, on this queue, by drawing
                // the image once (the same trick upstream's
                // loadBoxArtForCaching uses against scroll jank).
                let renderer = UIGraphicsImageRenderer(size: image.size)
                decoded = renderer.image { _ in image.draw(at: .zero) }
            }
            guard let decoded = decoded else { return }
            boxArtCache.setObject(decoded, forKey: key)
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .GPAppListChanged, object: host)
            }
        }
        return nil
    }

    /// Lowercase, punctuation-stripped, whitespace-collapsed name
    /// used by every rule above.
    static func normalized(_ name: String) -> String {
        let lowered = name.lowercased()
        let scalars = lowered.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) {
                return Character(scalar)
            }
            return " "
        }
        return String(scalars).split(separator: " ").joined(separator: " ")
    }

    // MARK: - Favourites

    private static let favouritesKey = "GPFavouriteAppKeys"

    static func isFavourite(host: TemporaryHost, app: TemporaryApp) -> Bool {
        return favouriteKeys().contains(appKey(host: host, app: app))
    }

    static func setFavourite(_ favourite: Bool, host: TemporaryHost, app: TemporaryApp) {
        var keys = favouriteKeys()
        let key = appKey(host: host, app: app)
        if favourite {
            keys.insert(key)
        } else {
            keys.remove(key)
        }
        UserDefaults.standard.set(Array(keys), forKey: favouritesKey)
    }

    private static func favouriteKeys() -> Set<String> {
        let stored = UserDefaults.standard.stringArray(forKey: favouritesKey) ?? []
        return Set(stored)
    }
}
