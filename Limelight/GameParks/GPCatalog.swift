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

        // GP v2.6 (B-22): Vice City Stories is a different game —
        // it must not fall into the Vice City rule below; it falls
        // through to the generic GTA branch (no bundled cover).
        if hasPhrase("vice city") && !hasPhrase("vice city stories") {
            return GPGameInfo(coverImageName: "cover_vicecity", isClassic: true,
                              sourceTag: "Your setup", detailLine: "Open world · Rockstar Games")
        }
        // GP v2.6 (A-08/B-23): cover_tombraider is the true 1996
        // cover, so it is restricted to name forms that can only be
        // the 1996 game. Every other classic Tomb Raider keeps its
        // classic flag, tag and developer credit but gets NO bundled
        // cover — the 1996 art on Legend/Anniversary/Underworld was
        // the exact defect A-08 cited. The plain name "Tomb Raider"
        // is ambiguous (the 2013 game carries it too), so it also
        // gets no bundled cover and no developer credit: host art
        // (priority 1) decides what it looks like.
        if norm == "tomb raider 1" || norm == "tomb raider i" || norm == "tomb raider 1996" {
            return GPGameInfo(coverImageName: "cover_tombraider", isClassic: true,
                              sourceTag: "Your setup", detailLine: "Adventure · Core Design")
        }
        if hasPhrase("tomb raider i iii remastered") || hasPhrase("tomb raider iv vi remastered") {
            return GPGameInfo(coverImageName: nil, isClassic: true,
                              sourceTag: "Your setup", detailLine: "Adventure · Core Design")
        }
        // Core Design era classics other than the 1996 original.
        if hasPhrase("tomb raider ii") || hasPhrase("tomb raider iii")
            || hasPhrase("tomb raider the last revelation") || hasPhrase("tomb raider chronicles")
            || hasPhrase("tomb raider the angel of darkness") {
            return GPGameInfo(coverImageName: nil, isClassic: true,
                              sourceTag: "Your setup", detailLine: "Adventure · Core Design")
        }
        // Crystal Dynamics era classics.
        if hasPhrase("tomb raider legend") || hasPhrase("tomb raider anniversary")
            || hasPhrase("tomb raider underworld") {
            return GPGameInfo(coverImageName: nil, isClassic: true,
                              sourceTag: "Your setup", detailLine: "Adventure · Crystal Dynamics")
        }
        if norm == "tomb raider" {
            return GPGameInfo(coverImageName: nil, isClassic: true,
                              sourceTag: "Your setup", detailLine: "Adventure")
        }
        // United Offensive is CoD 1's expansion (Gray Matter), so it
        // shares the first game's cover; CoD 2 does not — it has its
        // own coverless classic branch below.
        if hasPhrase("call of duty united offensive") {
            return GPGameInfo(coverImageName: "cover_cod", isClassic: true,
                              sourceTag: "Your setup", detailLine: "WWII shooter · Gray Matter")
        }
        if norm == "call of duty" || norm == "call of duty 1" || hasPhrase("call of duty 2003") {
            return GPGameInfo(coverImageName: "cover_cod", isClassic: true,
                              sourceTag: "Your setup", detailLine: "WWII shooter · Infinity Ward")
        }
        // GP v2.6 (B-22): CoD 2 is one of her own setup installs, so
        // it shelves with the classics — but it has no bundled cover
        // (A-69: it must not take CoD 1's art).
        if hasPhrase("call of duty 2") || hasPhrase("call of duty ii") {
            return GPGameInfo(coverImageName: nil, isClassic: true,
                              sourceTag: "Your setup", detailLine: "WWII shooter · Infinity Ward")
        }
        // GP v2.6 (B-22): Cricket 07 — her own setup install, with
        // its bundled cover (prepared 600x900 art, cover_cricket07).
        if hasPhrase("cricket 07") || hasPhrase("cricket 2007") {
            return GPGameInfo(coverImageName: "cover_cricket07", isClassic: true,
                              sourceTag: "Your setup", detailLine: "Cricket · EA Sports")
        }
        if hasPhrase("most wanted") && (hasPhrase("need for speed") || hasPhrase("nfs")) {
            // The 2005 cover is earned only by a 2005-era marker in
            // the name ("2005", "Black Edition"): a bare "Most
            // Wanted" is just as likely the 2012 game, so it keeps
            // the classic treatment but gets no bundled cover rather
            // than the wrong game's art.
            if hasPhrase("2005") || hasPhrase("black edition") {
                return GPGameInfo(coverImageName: "cover_nfsmw", isClassic: true,
                                  sourceTag: "Your setup", detailLine: "Racing · Electronic Arts")
            }
            return GPGameInfo(coverImageName: nil, isClassic: true,
                              sourceTag: "Your setup", detailLine: "Racing · Electronic Arts")
        }

        // --- Big games (Steam shelf) ---

        // Exclusions ahead of the GTA V prefix rules: San Andreas
        // and IV must never be read as V (Vice City is already
        // handled by the classics rule above).
        if hasPhrase("san andreas") || tokens == ["grand", "theft", "auto", "iv"]
            || tokens == ["gta", "iv"] || norm == "grand theft auto 4" || norm == "gta4" {
            return GPGameInfo(coverImageName: nil, isClassic: false,
                              sourceTag: "Steam", detailLine: "Open world · Rockstar Games")
        }
        if tokens.starts(with: ["grand", "theft", "auto", "v"]) || tokens.starts(with: ["gta", "v"])
            || norm == "grand theft auto 5" || norm == "gta5" || norm == "gtav"
            || tokens == ["gta", "5"] {
            // GP v2.6 (B-22): tokens == ["gta", "5"] is the spaced
            // "GTA 5" form; it sits after the GTA IV exclusion above,
            // so it cannot swallow IV.
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
            // GP v2.6 (B-36): there is no bundled Mafia cover any
            // more. The shipped cover_mafia was a centre-crop of
            // square Old Country key art that cut the game's own
            // title in half ("MAFI... / ...E OLD COUNT..."), and no
            // sound 600x900 source exists in the prepared set — so
            // per the standing principle the title tile beats
            // mutilated art, for Old Country and every other Mafia
            // title alike (A-07's restriction is preserved: no Mafia
            // title shows another Mafia game's art).
            if hasPhrase("old country") {
                return GPGameInfo(coverImageName: nil, isClassic: false,
                                  sourceTag: "Steam", detailLine: "Crime saga · Hangar 13")
            }
            if hasPhrase("mafia ii") || hasPhrase("mafia 2") {
                return GPGameInfo(coverImageName: nil, isClassic: false,
                                  sourceTag: "Steam", detailLine: "Crime saga · 2K Czech")
            }
            if norm == "mafia" || hasPhrase("city of lost heaven") {
                return GPGameInfo(coverImageName: nil, isClassic: false,
                                  sourceTag: "Steam", detailLine: "Crime saga · Illusion Softworks")
            }
            return GPGameInfo(coverImageName: nil, isClassic: false,
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
        // Plain / Remastered Last of Us — the same game Part I
        // remakes, so it shares that cover. Ordered after Part II.
        if norm == "the last of us" || hasPhrase("the last of us remastered") {
            return GPGameInfo(coverImageName: "cover_tlou", isClassic: false,
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
    static func coverImage(for app: TemporaryApp, host: TemporaryHost) -> UIImage? {
        if let art = hostBoxArt(for: app, host: host) {
            return art
        }
        guard let name = info(for: app).coverImageName else { return nil }
        return UIImage(named: name)
    }

    // MARK: - Host box art

    private static let boxArtCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()
    private static let boxArtDecodeQueue = DispatchQueue(label: "com.gameparks.boxart", qos: .userInitiated, attributes: .concurrent)
    /// Keys whose decode is currently in flight (main-thread
    /// confined: coverImage is only ever called from screen
    /// rebuilds). A key is inserted when its decode starts and
    /// removed when that decode completes, success or failure — so
    /// an NSCache eviction or one failed decode can always be
    /// retried by a later rebuild.
    private static var boxArtRequested = Set<NSString>()
    /// The on-disk modification date each decoded entry was read
    /// from (main-thread confined, like boxArtRequested). If the
    /// file's date no longer matches, the entry is stale — the
    /// host-side cover was replaced — and is dropped for a re-decode.
    private static var boxArtFileDates: [NSString: Date] = [:]

    /// The decoded host box art for an app, or nil if it isn't
    /// decoded yet. The PNG itself is fetched from the host by
    /// AppAssetManager (driven by GPSessionController after each
    /// app-list load) into the on-disk cache; here it is only read
    /// and decoded — off the main thread, force-decoded, so a
    /// scrolling list never pays the decode cost. When a decode
    /// lands, the normal app-list notification re-renders the
    /// screens and they pick the image up from the memory cache.
    static func hostBoxArt(for app: TemporaryApp, host: TemporaryHost) -> UIImage? {
        // GP v2.7 (B-21): the host is explicit, exactly as on the
        // write side — the path and the key's UUID derive from the
        // host the caller is rendering, never from app.host, which
        // may be nil or point at a divergent instance while the
        // missing-art check (which already used the explicit host)
        // sees the file present and never re-triggers.
        guard let uuid = host.uuid, let appID = app.id else { return nil }
        // The app name is part of the key (not just host UUID + app
        // id): if Sunshine renumbers its app ids, a renamed app must
        // not inherit the previous game's decoded cover.
        let key = "\(uuid)/\(appID)/\(app.name ?? "")" as NSString
        let path = AppAssetManager.boxArtPath(for: app, host: host)
        let fileDate = path.flatMap { p in
            (try? FileManager.default.attributesOfItem(atPath: p))?[.modificationDate] as? Date
        }
        if let cached = boxArtCache.object(forKey: key) {
            if let recorded = boxArtFileDates[key], let current = fileDate {
                if recorded == current {
                    return cached
                }
                // The file changed under the cached image: drop the
                // stale entry and re-decode below.
                boxArtCache.removeObject(forKey: key)
                boxArtFileDates.removeValue(forKey: key)
            } else if path.map({ FileManager.default.fileExists(atPath: $0) }) ?? false {
                // GP v2.6 (B-11): the entry is cached but has no
                // recorded date, or the file's date cannot be read
                // right now. Dropping it here looped forever (drop ->
                // re-decode -> cached dateless -> drop, posting
                // GPAppListChanged every cycle). Trust it for this
                // generation; a real mtime change is still caught
                // above whenever both dates are readable.
                return cached
            } else {
                // GP v2.7 (C-06): the trust branch above still
                // requires the file to exist. An unreadable date
                // because the file is GONE (e.g. a B-03 signature-
                // change deletion whose refetch found no art) must
                // not serve the cached image for the rest of the
                // session: drop the entry and its recorded date and
                // return nil — the existence guard below agrees.
                boxArtCache.removeObject(forKey: key)
                boxArtFileDates.removeValue(forKey: key)
                return nil
            }
        }
        guard let path = path,
              FileManager.default.fileExists(atPath: path),
              !boxArtRequested.contains(key) else { return nil }
        boxArtRequested.insert(key)
        let decodedDate = fileDate
        boxArtDecodeQueue.async {
            var decoded: UIImage?
            var cost = 0
            var decodeFailed = false
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path)), !data.isEmpty {
                if let image = UIImage(data: data) {
                    // GP v2.6 (B-11): an image whose own cost meets
                    // the whole 48 MB cache limit can never be
                    // retained by NSCache, which looped the same way
                    // the dateless entry did. Downscale oversize
                    // host art before caching (cap ~10 MP, keeping
                    // the aspect ratio).
                    var drawSize = image.size
                    let pixels = drawSize.width * drawSize.height
                    if pixels > 10_000_000 {
                        let factor = (10_000_000 / pixels).squareRoot()
                        drawSize = CGSize(width: (drawSize.width * factor).rounded(),
                                          height: (drawSize.height * factor).rounded())
                    }
                    // GP v2.7 (C-04): UIImage(data:) is lazy — a
                    // header-valid but truncated file returns a
                    // non-nil image whose raster was never decoded,
                    // and caching a draw of it can cache blank or
                    // partial pixels as a permanent cover. Force the
                    // source's full raster to decode by drawing it
                    // into a bitmap context at its (B-11-capped)
                    // natural size, and confirm something actually
                    // rasterised; a draw that leaves the buffer
                    // entirely zero produced no pixels and is a
                    // decode failure, feeding the deletion below.
                    var rasterised = false
                    let probeWidth = max(1, Int(drawSize.width.rounded()))
                    let probeHeight = max(1, Int(drawSize.height.rounded()))
                    if let probe = CGContext(data: nil, width: probeWidth, height: probeHeight,
                                             bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                        UIGraphicsPushContext(probe)
                        image.draw(in: CGRect(x: 0, y: 0, width: probeWidth, height: probeHeight))
                        UIGraphicsPopContext()
                        if let buffer = probe.data {
                            let byteCount = probe.bytesPerRow * probe.height
                            let bytes = buffer.bindMemory(to: UInt8.self, capacity: byteCount)
                            var index = 0
                            while index < byteCount {
                                if bytes[index] != 0 { rasterised = true; break }
                                index += 1
                            }
                        }
                    }
                    if rasterised {
                        // Force the decode here, on this queue, by drawing
                        // the image once (the same trick upstream's
                        // loadBoxArtForCaching uses against scroll jank) —
                        // at scale 1, so the cached copy holds the source's
                        // pixels, not a 2–3× screen-scale rendering of them.
                        let format = UIGraphicsImageRendererFormat()
                        format.scale = 1
                        let renderer = UIGraphicsImageRenderer(size: drawSize, format: format)
                        decoded = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: drawSize)) }
                        if let decoded = decoded {
                            cost = Int(decoded.size.width * decoded.size.height * 4)
                        }
                    } else {
                        decodeFailed = true
                    }
                } else {
                    decodeFailed = true
                }
            } else {
                // GP v2.7 (C-03): the file existed when this decode
                // was queued (the guard above checked), so a failed
                // read or an empty file is a decode failure too —
                // otherwise a 0-byte or unreadable file is never
                // deleted, never re-fetched, and re-decoded on
                // every rebuild as a permanent stuck tile.
                decodeFailed = true
            }
            if decodeFailed {
                // GP v2.6 (B-02): bytes on disk that do not decode
                // as an image are not a cover — delete the file so
                // the next retrieve trigger re-fetches it, instead of
                // every existence check treating it as valid art
                // forever.
                // GP v2.7 (C-07): re-stat before deleting — a
                // refetch may have atomically replaced the file
                // while this decode was queued/running, and deleting
                // then would remove the new good file. Delete only
                // when the file's current date still equals the
                // date captured before the decode.
                let currentDate = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
                if currentDate == decodedDate {
                    try? FileManager.default.removeItem(atPath: path)
                }
            }
            DispatchQueue.main.async {
                // The decode is no longer in flight, whatever its
                // outcome: the key leaves the set so a failure (or a
                // later cache eviction) can be retried on a rebuild.
                boxArtRequested.remove(key)
                guard let decoded = decoded else { return }
                boxArtCache.setObject(decoded, forKey: key, cost: cost)
                // GP v2.7 (C-11): record ONLY the date captured
                // before the decode. The v2.6 re-stat fallback bound
                // a newer file's date to these older pixels when
                // decodedDate was nil (file replaced mid-decode),
                // masking the real change from every later rebuild.
                // With no recorded date, the B-11 trust branch
                // serves this entry for the generation and a later
                // readable mtime comparison still re-checks it.
                if let decodedDate = decodedDate {
                    boxArtFileDates[key] = decodedDate
                }
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
