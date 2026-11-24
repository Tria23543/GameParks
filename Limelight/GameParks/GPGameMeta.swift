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

        if name.contains("grand theft auto v") || name == "gta v" || name == "gtav" {
            return GPGameMeta(coverResource: "cover_gta5", sourceTag: "Steam",
                              genreLine: "Open world · Rockstar Games", group: .big,
                              description: "Los Santos is yours — switch between three criminals, pull off daring heists and roam a huge open world.")
        }
        if name.contains("red dead redemption") {
            return GPGameMeta(coverResource: "cover_rdr2", sourceTag: "Steam",
                              genreLine: "Western · Rockstar Games", group: .big,
                              description: "America, 1899. The end of the Wild West era has begun. Run with Dutch's gang across a harsh, unforgiving heartland.")
        }
        if name.contains("last of us") {
            return GPGameMeta(coverResource: "cover_tlou", sourceTag: "Steam",
                              genreLine: "Action · Naughty Dog", group: .big,
                              description: "Twenty years after the outbreak, Joel is hired to smuggle Ellie across a brutal, post-pandemic America.")
        }
        if name.contains("mafia") {
            return GPGameMeta(coverResource: "cover_mafia", sourceTag: "Steam",
                              genreLine: "Crime saga · Hangar 13", group: .big,
                              description: "A Sicilian crime saga — rise through the ranks of the family in a story of loyalty, power and betrayal.")
        }
        if name.contains("vice city") {
            return GPGameMeta(coverResource: "cover_vicecity", sourceTag: "Your setup",
                              genreLine: "Open world · Rockstar Games", group: .classic,
                              description: "Welcome to Vice City, 1986 — neon, beaches and Tommy Vercetti's rise to the top of the criminal underworld.")
        }
        if name.contains("call of duty") {
            return GPGameMeta(coverResource: "cover_cod", sourceTag: "Your setup",
                              genreLine: "WWII shooter · Activision", group: .classic,
                              description: "The classic World War II campaigns — storm the beaches and fight across Europe and North Africa.")
        }
        if name.contains("tomb raider") {
            return GPGameMeta(coverResource: "cover_tombraider", sourceTag: "Your setup",
                              genreLine: "Adventure · Core Design", group: .classic,
                              description: "Lara Croft's original tomb-raiding adventures — ancient ruins, traps and dual pistols.")
        }
        if name.contains("most wanted") || name.contains("need for speed") {
            return GPGameMeta(coverResource: "cover_nfsmw", sourceTag: "Your setup",
                              genreLine: "Racing · EA", group: .classic,
                              description: "Race the Blacklist in Rockport — beat rivals, outrun the police and reclaim your BMW M3 GTR.")
        }
        if name == "desktop" {
            return GPGameMeta(coverResource: nil, sourceTag: "Your PC",
                              genreLine: "Full desktop · Sunshine", group: .other,
                              description: "Your whole PC desktop, streamed. Launch anything — Steam not required.")
        }
        return GPGameMeta(coverResource: nil, sourceTag: "Steam",
                          genreLine: "On your PC", group: .other, description: nil)
    }

    static func normalize(_ name: String) -> String {
        var result = name.lowercased()
        result = result.replacingOccurrences(of: "™", with: "")
        result = result.replacingOccurrences(of: "®", with: "")
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return result
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
