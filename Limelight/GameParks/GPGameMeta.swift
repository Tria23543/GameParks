//
//  GPGameMeta.swift
//  GameParks
//
//  Presentation metadata for games: bundled cover art, source tag
//  ("Steam" / "Your setup"), genre line and library grouping.
//  The library itself always comes from the host's Sunshine app list;
//  this file only decides how a game looks once it is in that list.
//

import UIKit

enum GPGameGroup {
    case big
    case classic
    case other
}

struct GPGameMeta {
    let coverResource: String?   // bundled JPEG resource name, if we ship one
    let sourceTag: String        // "Steam" or "Your setup"
    let genreLine: String
    let group: GPGameGroup
    let description: String?

    static func meta(forAppName rawName: String) -> GPGameMeta {
        let name = GPGameMeta.normalize(rawName)

        // Order matters: specific titles match before broad series
        // names. "Grand Theft Auto: Vice City" must reach the Vice
        // City branch first — "grand theft auto v" is a prefix of
        // "grand theft auto vice city", so the GTA V test below
        // would otherwise claim it.
        if name.contains("vice city") {
            return GPGameMeta(coverResource: "cover_vicecity", sourceTag: "Your setup",
                              genreLine: "Open world · Rockstar Games", group: .classic,
                              description: "Welcome to Vice City, 1986 — neon, beaches and Tommy Vercetti's rise to the top of the criminal underworld.")
        }
        if name.contains("grand theft auto vi") || name == "gta vi" || name == "gta 6" || name == "gta6" {
            return GPGameMeta(coverResource: nil, sourceTag: "Steam",
                              genreLine: "Open world · Rockstar Games", group: .big,
                              description: nil)
        }
        if name.contains("grand theft auto v") || name.contains("grand theft auto 5") || name == "gta v" || name == "gtav" || name == "gta5" || name == "gta 5" {
            return GPGameMeta(coverResource: "cover_gta5", sourceTag: "Steam",
                              genreLine: "Open world · Rockstar Games", group: .big,
                              description: "Los Santos is yours — switch between three criminals, pull off daring heists and roam a huge open world.")
        }
        if name.contains("grand theft auto") || name.contains("san andreas") {
            return GPGameMeta(coverResource: nil, sourceTag: "Your setup",
                              genreLine: "Open world · Rockstar Games", group: .classic,
                              description: nil)
        }
        if name.contains("red dead redemption ii") || name.contains("red dead redemption 2") || name == "rdr2" || name == "rdr 2" {
            return GPGameMeta(coverResource: "cover_rdr2", sourceTag: "Steam",
                              genreLine: "Western · Rockstar Games", group: .big,
                              description: "America, 1899. The end of the Wild West era has begun. Run with Dutch's gang across a harsh, unforgiving heartland.")
        }
        if name.contains("red dead redemption") || name == "rdr" {
            return GPGameMeta(coverResource: nil, sourceTag: "Steam",
                              genreLine: "Western · Rockstar Games", group: .big,
                              description: "John Marston hunts down his old gang across the dying American frontier.")
        }
        if name.contains("last of us") && (name.contains("part ii") || name.contains("part 2")) {
            return GPGameMeta(coverResource: nil, sourceTag: "Steam",
                              genreLine: "Action · Naughty Dog", group: .big,
                              description: "Five years after their dangerous journey across the post-pandemic United States, Ellie and Joel have settled down in Jackson, Wyoming. When a violent event disrupts that peace, Ellie embarks on a relentless journey to carry out justice and find closure.")
        }
        if name.contains("last of us") {
            return GPGameMeta(coverResource: "cover_tlou", sourceTag: "Steam",
                              genreLine: "Action · Naughty Dog", group: .big,
                              description: "Twenty years after the outbreak, Joel is hired to smuggle Ellie across a brutal, post-pandemic America.")
        }
        if name.contains("mafia") {
            if name.contains("mafia ii") || name.contains("mafia 2") {
                return GPGameMeta(coverResource: nil, sourceTag: "Steam",
                                  genreLine: "Crime saga · 2K Czech", group: .big,
                                  description: nil)
            }
            if name.contains("mafia iii") || name.contains("mafia 3") {
                return GPGameMeta(coverResource: nil, sourceTag: "Steam",
                                  genreLine: "Crime saga · Hangar 13", group: .big,
                                  description: nil)
            }
            if name.contains("old country") || name.contains("definitive edition") {
                return GPGameMeta(coverResource: "cover_mafia", sourceTag: "Steam",
                                  genreLine: "Crime saga · Hangar 13", group: .big,
                                  description: "A Sicilian crime saga — rise through the ranks of the family in a story of loyalty, power and betrayal.")
            }
            return GPGameMeta(coverResource: nil, sourceTag: "Steam",
                              genreLine: "Crime saga · 2K", group: .big,
                              description: nil)
        }
        // Only the WWII-era entries are the classics; a modern
        // Call of Duty used to inherit the WWII cover and text.
        if name == "call of duty" || name == "call of duty 1" || name == "call of duty 2"
            || name.contains("united offensive") || name.contains("world at war") {
            return GPGameMeta(coverResource: "cover_cod", sourceTag: "Your setup",
                              genreLine: "WWII shooter · Activision", group: .classic,
                              description: "The classic World War II campaigns — storm the beaches and fight across Europe and North Africa.")
        }
        if name.contains("call of duty") || name.contains("modern warfare") || name.contains("black ops") || name.contains("warzone") {
            return GPGameMeta(coverResource: nil, sourceTag: "Steam",
                              genreLine: "Shooter · Activision", group: .big,
                              description: nil)
        }
        // Only Rise/Shadow are the reboot trilogy; every other
        // Tomb Raider title (the bare name included) stays with the
        // classic Core Design line.
        if name.contains("rise of the tomb raider") || name.contains("shadow of the tomb raider") {
            return GPGameMeta(coverResource: nil, sourceTag: "Steam",
                              genreLine: "Adventure · Crystal Dynamics", group: .big,
                              description: "Lara Croft's defining survival trilogy — raid tombs, brave the wilderness, and become the Tomb Raider.")
        }
        if name.contains("tomb raider") {
            return GPGameMeta(coverResource: "cover_tombraider", sourceTag: "Your setup",
                              genreLine: "Adventure · Core Design", group: .classic,
                              description: "Lara Croft's original tomb-raiding adventures — ancient ruins, traps and dual pistols.")
        }
        // The Most Wanted cover and text belong to Most Wanted
        // only; other Need for Speed entries get the plain line.
        if name.contains("most wanted") {
            return GPGameMeta(coverResource: "cover_nfsmw", sourceTag: "Your setup",
                              genreLine: "Racing · EA", group: .classic,
                              description: "Race the Blacklist in Rockport — beat rivals, outrun the police and reclaim your BMW M3 GTR.")
        }
        if name.contains("need for speed") || name == "nfs" || name.hasPrefix("nfs ") {
            return GPGameMeta(coverResource: nil, sourceTag: "Steam",
                              genreLine: "Racing · EA", group: .other,
                              description: nil)
        }
        if name == "desktop" {
            return GPGameMeta(coverResource: nil, sourceTag: "Your PC",
                              genreLine: "Full desktop · Sunshine", group: .other,
                              description: "Your whole PC desktop, streamed. Launch anything — Steam not required.")
        }
        return GPGameMeta(coverResource: nil, sourceTag: "Your PC",
                          genreLine: "On your PC", group: .other, description: nil)
    }

    static func normalize(_ name: String) -> String {
        var result = name.lowercased()
        for token in ["™", "®", "©"] {
            result = result.replacingOccurrences(of: token, with: "")
        }
        for token in [":", "-", "_"] {
            result = result.replacingOccurrences(of: token, with: " ")
        }
        // Collapse whitespace runs (double spaces in store names,
        // gaps left by stripped punctuation) so the exact-name
        // checks above hold.
        return result.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

enum GPCoverArt {
    private static var cache: [String: UIImage] = [:]

    /// Bundled cover for a game, if GameParks ships one for it.
    static func bundledCover(forAppName name: String) -> UIImage? {
        guard let resource = GPGameMeta.meta(forAppName: name).coverResource else {
            return nil
        }
        return image(named: resource)
    }

    static func image(named resource: String) -> UIImage? {
        if let cached = cache[resource] {
            return cached
        }
        guard let url = Bundle.main.url(forResource: resource, withExtension: "jpg"),
              let image = UIImage(contentsOfFile: url.path) else {
            return nil
        }
        cache[resource] = image
        return image
    }

    /// The cover to show for a game: the bundled JPEG when GameParks
    /// ships one for it, otherwise nil (the cell draws a title tile).
    static func cover(for app: TemporaryApp) -> UIImage? {
        return bundledCover(forAppName: app.name ?? "")
    }
}
