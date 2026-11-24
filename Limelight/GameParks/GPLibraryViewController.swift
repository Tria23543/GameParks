//
//  GPLibraryViewController.swift
//  GameParks
//
//  The design's Library: the selected PC's full Sunshine app list
//  — Steam games and her own installs side by side — searchable,
//  with the All / Big games / Classics / Favourites chips. Every
//  state (no PC, unpaired, load failed, no matches) is explained
//  with a way forward.
//

import UIKit

final class GPLibraryViewController: GPBaseViewController {
    private var session: GPSessionController { GPSessionController.shared() }

    private enum Filter {
        case all, big, classics, favourites
    }

    private let subtitleLabel = gpLabel(nil, font: GPFont.body(14), color: GPColor.textSecondary, lines: 2)
    private let searchField = UITextField()
    private var filter: Filter = .all
    private var chips: [Filter: GPChipButton] = [:]
    private let dynamicStack = UIStackView()
    /// A-74: the host the visible rows were rendered for.
    private var renderingHost: TemporaryHost?
    /// A-73: pending debounced search rebuild.
    private var searchWorkItem: DispatchWorkItem?

    override func viewDidLoad() {
        super.viewDidLoad()

        let header = UIStackView()
        header.axis = .vertical
        header.spacing = 4
        header.addArrangedSubview(gpLabel("Library", font: GPFont.display(28, weight: .extrabold), color: GPColor.textPrimary, lines: 1))
        header.addArrangedSubview(subtitleLabel)
        contentStack.addArrangedSubview(header)

        // Search
        let searchContainer = UIView()
        searchContainer.backgroundColor = GPColor.panel
        searchContainer.layer.cornerRadius = 14
        searchField.attributedPlaceholder = NSAttributedString(
            string: "Search your games",
            attributes: [.foregroundColor: GPColor.textFaint])
        searchField.textColor = GPColor.textPrimary
        searchField.font = GPFont.body(15)
        searchField.autocorrectionType = .no
        searchField.autocapitalizationType = .none
        searchField.returnKeyType = .search
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.addTarget(self, action: #selector(searchChanged), for: .editingChanged)
        searchContainer.addSubview(searchField)
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: searchContainer.topAnchor, constant: 12),
            searchField.bottomAnchor.constraint(equalTo: searchContainer.bottomAnchor, constant: -12),
            searchField.leadingAnchor.constraint(equalTo: searchContainer.leadingAnchor, constant: 14),
            searchField.trailingAnchor.constraint(equalTo: searchContainer.trailingAnchor, constant: -14),
        ])
        contentStack.addArrangedSubview(searchContainer)

        // Filter chips
        let chipRow = UIStackView()
        chipRow.axis = .horizontal
        chipRow.spacing = 8
        for (value, title) in [(Filter.all, "All"), (Filter.big, "Big games"), (Filter.classics, "Classics"), (Filter.favourites, "Favourites")] {
            let chip = GPChipButton(title: title)
            chip.tag = filterTag(value)
            chip.addTarget(self, action: #selector(chipTapped(_:)), for: .touchUpInside)
            chips[value] = chip
            chipRow.addArrangedSubview(chip)
        }
        chipRow.addArrangedSubview(UIView())
        contentStack.addArrangedSubview(chipRow)

        dynamicStack.axis = .vertical
        dynamicStack.spacing = 10
        contentStack.addArrangedSubview(dynamicStack)

        NotificationCenter.default.addObserver(self, selector: #selector(stateChanged),
                                               name: .GPHostsChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(stateChanged),
                                               name: .GPAppListChanged, object: nil)
        refreshChips()
        // A-73: chips take the scroll-safe path too.
        requestContentRebuild()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // A-31: appearance goes through the scroll-safe path.
        requestContentRebuild()
    }

    @objc private func stateChanged() {
        requestContentRebuild()
    }

    @objc private func searchChanged() {
        // A-73: debounce keystrokes, then take the scroll-safe path.
        searchWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.requestContentRebuild() }
        searchWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// A-23: folded substring match, plus normalised matching so
    /// "pokemon" finds Pokémon, "spiderman" finds Spider-Man and
    /// "gta" finds Grand Theft Auto titles. The v2.5 mechanisms
    /// failed those last two headline cases, so v2.6 adds:
    /// (a) a spaces-removed comparison — "spiderman" is contained
    ///     in "spiderman" once "Spider-Man" is normalised and its
    ///     spaces removed;
    /// (b) initialism matching — the query, spaces removed, is a
    ///     prefix of the name's token initials ("gta" → "gtav"
    ///     from Grand Theft Auto V), or every query token is a
    ///     prefix of a name token.
    private func appMatches(_ app: TemporaryApp, query rawQuery: String) -> Bool {
        let name = app.name ?? ""
        let foldedName = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        let foldedQuery = rawQuery.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        if foldedName.contains(foldedQuery) { return true }
        let normalizedName = GPCatalog.normalized(name)
        let normalizedQuery = GPCatalog.normalized(rawQuery)
        if !normalizedQuery.isEmpty && normalizedName.contains(normalizedQuery) { return true }
        let nameTokens = normalizedName.split(separator: " ").map(String.init)
        let queryTokens = normalizedQuery.split(separator: " ").map(String.init)
        if !queryTokens.isEmpty && queryTokens.allSatisfy({ nameTokens.contains($0) }) { return true }
        // (a) spaces-removed comparison, both directions of containment
        // on the name side: the spaceless query inside the spaceless name.
        let spacelessName = nameTokens.joined()
        let spacelessQuery = queryTokens.joined()
        if !spacelessQuery.isEmpty && spacelessName.contains(spacelessQuery) { return true }
        // (b) initialism: "gta" prefixes the initials of
        // "grand theft auto v" ("gtav").
        // C-19: the name's initialism and the query's spaceless
        // form are both built with their trailing numeral
        // normalised roman ↔ arabic (V=5, II=2, …), so the
        // compound abbreviation+number queries A-23 still missed
        // — "gta 5" / "gta5" against "Grand Theft Auto V",
        // "cod 2" against "Call of Duty 2" — match too. The
        // discipline is unchanged: ≥2 characters, prefix-only,
        // no other path can match.
        // D-24/D-25/D-26: each form is a (letters, numeral) pair
        // with the numeral a normalised Int?, not a concatenated
        // string — when both sides carry a numeral the numerals
        // must match exactly, so "gta 5" no longer prefix-matches
        // Grand Theft Auto VI and "cod 2" no longer matches
        // Call of Duty 25; a numeral-less query keeps the prefix
        // behaviour against the name's full form ("gta" still
        // finds Grand Theft Auto V).
        if spacelessQuery.count >= 2 {
            let nameForms = Self.initialismForms(nameTokens: nameTokens,
                                                 rawNameTokens: Self.rawTokens(of: name))
            let queryForms = Self.spacelessQueryForms(queryTokens: queryTokens,
                                                      rawQueryTokens: Self.rawTokens(of: rawQuery),
                                                      spacelessQuery: spacelessQuery)
            if Self.initialismMatches(nameForms: nameForms, queryForms: queryForms) { return true }
        }
        // (b′) every query token prefixes some name token.
        return !queryTokens.isEmpty && queryTokens.allSatisfy { queryToken in
            nameTokens.contains { $0.hasPrefix(queryToken) }
        }
    }

    // MARK: - C-19 numeral normalisation for initialism matching

    /// Roman ↔ arabic for the trailing numerals of game titles
    /// (sequels rarely go past XX in this library).
    private static let romanToArabic: [String: String] = [
        "i": "1", "ii": "2", "iii": "3", "iv": "4", "v": "5",
        "vi": "6", "vii": "7", "viii": "8", "ix": "9", "x": "10",
        "xi": "11", "xii": "12", "xiii": "13", "xiv": "14", "xv": "15",
        "xvi": "16", "xvii": "17", "xviii": "18", "xix": "19", "xx": "20",
    ]
    private static let arabicToRoman: [String: String] = [
        "1": "i", "2": "ii", "3": "iii", "4": "iv", "5": "v",
        "6": "vi", "7": "vii", "8": "viii", "9": "ix", "10": "x",
        "11": "xi", "12": "xii", "13": "xiii", "14": "xiv", "15": "xv",
        "16": "xvi", "17": "xvii", "18": "xviii", "19": "xix", "20": "xx",
    ]

    /// The arabic form of a token that is wholly a numeral
    /// ("v" → "5", "2" → "2"), else nil.
    private static func arabicForm(of token: String) -> String? {
        if let roman = romanToArabic[token] { return roman }
        if !token.isEmpty, token.allSatisfy({ $0.isNumber }), let value = Int(token) {
            return String(value)
        }
        return nil
    }

    /// The roman form of a token that is wholly a numeral
    /// ("5" → "v", "ii" → "ii"), else nil.
    private static func romanForm(of token: String) -> String? {
        if romanToArabic[token] != nil { return token }
        if !token.isEmpty, token.allSatisfy({ $0.isNumber }), let value = Int(token) {
            return arabicToRoman[String(value)]
        }
        return nil
    }

    /// D-24: one initialism form — a letters part plus the
    /// trailing numeral as a normalised value (roman and arabic
    /// spellings of the same number are the same Int), or nil
    /// when the form carries no numeral.
    private struct InitialismForm {
        let letters: String
        let numeral: Int?
        /// GP v2.9 (E-10): set on query forms whose numeral was
        /// parsed out of a spaceless roman suffix — that parse
        /// also fires on ordinary word endings ("taxi", "max",
        /// "six"), so such a form may only match a name form
        /// whose letters EQUAL it, never one it merely prefixes.
        /// Forms from the token-aware and digit parses (a numeral
        /// the user actually typed, or a token of its own) keep
        /// the prefix behaviour.
        var requiresExactLetters: Bool = false
    }

    /// The normalised numeral value of a token that is wholly a
    /// numeral ("v" → 5, "07" → 7, "25" → 25), else nil. Built
    /// on arabicForm, so its leading-zero normalisation and the
    /// I–XX tables carry over; arabic values of any size parse.
    private static func numeralValue(of token: String) -> Int? {
        guard let arabic = arabicForm(of: token) else { return nil }
        return Int(arabic)
    }

    /// The tokens of a string in its original case, split the
    /// same way GPCatalog.normalized splits them, so index i
    /// here is token i of the normalised form. Used only to spot
    /// tokens that were abbreviations in the original spelling
    /// (D-25(i)).
    private static func rawTokens(of string: String) -> [String] {
        string.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    /// D-25(i): a token that is itself an abbreviation in the
    /// original spelling — at least two characters, all letters,
    /// and already fully uppercased ("GTA" in "GTA V").
    private static func isAbbreviation(_ rawToken: String) -> Bool {
        rawToken.count >= 2 && rawToken.allSatisfy({ $0.isLetter }) && rawToken == rawToken.uppercased()
    }

    /// The letters parts a token list can contribute to an
    /// initialism form: the joined tokens, the token initials,
    /// and — for each non-trailing token that is itself an
    /// abbreviation (D-25(i)) — the initials with that whole
    /// token kept ("GTA V" yields "gta" as well as "g").
    /// `includeSingleInitial` keeps the one-letter initial of a
    /// lone body token (the name side's A-23 form, "g" for
    /// "GTA V"); the query side omits it, so a query's letters
    /// are never shorter than one of its own tokens.
    private static func lettersVariants(bodyTokens: [String], rawBodyTokens: [String],
                                        includeSingleInitial: Bool,
                                        includeTrailingAbbreviation: Bool = false) -> [String] {
        var variants: [String] = []
        func add(_ letters: String) {
            if !letters.isEmpty && !variants.contains(letters) { variants.append(letters) }
        }
        add(bodyTokens.joined())
        let initials = bodyTokens.compactMap { $0.first }.map(String.init)
        if bodyTokens.count >= 2 || includeSingleInitial {
            add(initials.joined())
        }
        // Abbreviation alternates: a non-trailing token may stand
        // whole in place of its initial. In a numeral form the
        // trailing token is the numeral, already dropped, so the
        // caller passes includeTrailingAbbreviation and every
        // body token is eligible there.
        if rawBodyTokens.count == bodyTokens.count {
            let eligible = includeTrailingAbbreviation ? bodyTokens.indices : bodyTokens.indices.dropLast()
            for index in eligible where isAbbreviation(rawBodyTokens[index]) {
                add(bodyTokens.enumerated().map { $0.offset == index ? $0.element : String($0.element.first ?? Character(" ")) }.joined())
            }
        }
        return variants
    }

    /// D-24 matching: when the query form carries a numeral, the
    /// name form must carry the same numeral exactly and its
    /// letters must prefix-match; when it carries none, the
    /// query letters prefix the name's full form (letters plus
    /// its numeral in either system), preserving A-23's "gta"
    /// → Grand Theft Auto V.
    private static func initialismMatches(nameForms: [InitialismForm], queryForms: [InitialismForm]) -> Bool {
        for nameForm in nameForms {
            for queryForm in queryForms {
                if let queryNumeral = queryForm.numeral {
                    let lettersMatch = queryForm.requiresExactLetters
                        ? nameForm.letters == queryForm.letters
                        : nameForm.letters.hasPrefix(queryForm.letters)
                    if nameForm.numeral == queryNumeral && lettersMatch {
                        return true
                    }
                } else {
                    var fullForms = [nameForm.letters]
                    if let numeral = nameForm.numeral {
                        fullForms = [nameForm.letters + String(numeral)]
                        if let roman = arabicToRoman[String(numeral)] {
                            fullForms.append(nameForm.letters + roman)
                        }
                    }
                    if fullForms.contains(where: { $0.hasPrefix(queryForm.letters) }) { return true }
                }
            }
        }
        return false
    }

    /// The name's initialism forms: "grand theft auto v" →
    /// [("gta", 5), ("grandtheftauto", 5)], "call of duty 2" →
    /// [("cod", 2), ("callofduty", 2)]. A name with no trailing
    /// numeral keeps numeral-less forms ("grand theft auto" →
    /// [("gta", nil), …]), exactly the A-23 shape. D-26: a
    /// trailing numeral with no roman form (over 20, or 0)
    /// still yields its (letters, fullArabicValue) form — the
    /// plain first-character initialism is never emitted for a
    /// trailing-numeral name, so "Call of Duty 25" cannot
    /// collapse to "cod2". GP v2.9 (E-09): a numeral in a
    /// non-trailing position (an edition/subtitle suffix follows
    /// it) also yields its numeral forms — see below.
    private static func initialismForms(nameTokens: [String], rawNameTokens: [String]) -> [InitialismForm] {
        if nameTokens.count >= 2, let last = nameTokens.last, let numeral = numeralValue(of: last) {
            let body = Array(nameTokens.dropLast())
            let rawBody = rawNameTokens.count == nameTokens.count ? Array(rawNameTokens.dropLast()) : []
            return lettersVariants(bodyTokens: body, rawBodyTokens: rawBody,
                                   includeSingleInitial: true, includeTrailingAbbreviation: true)
                .map { InitialismForm(letters: $0, numeral: numeral) }
        }
        var forms = lettersVariants(bodyTokens: nameTokens, rawBodyTokens: rawNameTokens,
                                    includeSingleInitial: true)
            .map { InitialismForm(letters: $0, numeral: nil) }
        // GP v2.9 (E-09): the trailing branch above keys the
        // numeral forms off the LAST token only, so a title whose
        // numeral is followed by an edition or subtitle —
        // "Grand Theft Auto V (GOTY)", "The Witcher 3: Wild
        // Hunt", "Halo 5: Guardians" — lost them entirely and
        // "gta 5" / "tw3" / "h5" stopped matching (they matched
        // in v2.7). For each numeral token in a non-trailing
        // position, emit the (letters of the tokens before it,
        // that numeral) forms alongside the numeral-less forms.
        // The numeral still has to match exactly (D-24), so no
        // cross-sequel match opens: "gta 5" against
        // "Grand Theft Auto VI (GOTY)" still fails on 5 ≠ 6.
        for index in nameTokens.indices where index >= 1 && index < nameTokens.count - 1 {
            guard let numeral = numeralValue(of: nameTokens[index]) else { continue }
            let body = Array(nameTokens[..<index])
            let rawBody = rawNameTokens.count == nameTokens.count ? Array(rawNameTokens[..<index]) : []
            for letters in lettersVariants(bodyTokens: body, rawBodyTokens: rawBody,
                                           includeSingleInitial: true, includeTrailingAbbreviation: true) {
                if !forms.contains(where: { $0.letters == letters && $0.numeral == numeral }) {
                    forms.append(InitialismForm(letters: letters, numeral: numeral))
                }
            }
        }
        return forms
    }

    /// The query's initialism forms, built like the name's:
    /// "gta 5" (tokens) and "gta5" / "gtav" (one token) all
    /// yield ("gta", 5); "gta" yields ("gta", nil). D-25(ii):
    /// a multi-token query also yields its initials-based form,
    /// so "grand theft auto 5" and "call of duty ii" reach the
    /// same (letters, numeral) forms as their abbreviations.
    private static func spacelessQueryForms(queryTokens: [String], rawQueryTokens: [String],
                                            spacelessQuery: String) -> [InitialismForm] {
        var forms: [InitialismForm] = []
        func add(letters: String, numeral: Int?, exact: Bool = false) {
            guard !letters.isEmpty else { return }
            if let existing = forms.firstIndex(where: { $0.letters == letters && $0.numeral == numeral }) {
                // GP v2.9 (E-10): a non-exact twin — from the
                // token-aware or digit parse, which run before the
                // roman-suffix parse — is the wider form and wins;
                // an exact form never widens an exact twin.
                if forms[existing].requiresExactLetters && !exact {
                    forms[existing].requiresExactLetters = false
                }
                return
            }
            forms.append(InitialismForm(letters: letters, numeral: numeral, requiresExactLetters: exact))
        }
        var spacelessCarriesNumeral = false
        // Token-aware: "gta 5" / "gta v" — the numeral is its own
        // query token.
        if queryTokens.count >= 2, let last = queryTokens.last, let numeral = numeralValue(of: last) {
            let body = Array(queryTokens.dropLast())
            let rawBody = rawQueryTokens.count == queryTokens.count ? Array(rawQueryTokens.dropLast()) : []
            for letters in lettersVariants(bodyTokens: body, rawBodyTokens: rawBody,
                                           includeSingleInitial: false, includeTrailingAbbreviation: true) {
                add(letters: letters, numeral: numeral)
            }
            spacelessCarriesNumeral = true
        } else if queryTokens.count >= 2 {
            // Numeral-less multi-token query: the initials form
            // alongside the joined spaceless form below.
            for letters in lettersVariants(bodyTokens: queryTokens, rawBodyTokens: rawQueryTokens,
                                           includeSingleInitial: false) where letters != spacelessQuery {
                add(letters: letters, numeral: nil)
            }
        }
        // Spaceless trailing arabic digits: "gta5", "cod2".
        let digitCount = spacelessQuery.reversed().prefix(while: { $0.isNumber }).count
        if digitCount > 0 && digitCount < spacelessQuery.count {
            if let numeral = numeralValue(of: String(spacelessQuery.suffix(digitCount))) {
                add(letters: String(spacelessQuery.dropLast(digitCount)), numeral: numeral)
                spacelessCarriesNumeral = true
            }
        } else if digitCount == 0 {
            // Spaceless trailing roman numeral: "gtav", "codii" —
            // the longest roman suffix that is a whole numeral.
            let maxSuffix = min(5, spacelessQuery.count - 1)
            if maxSuffix >= 1 {
                for length in stride(from: maxSuffix, through: 1, by: -1) {
                    let suffix = String(spacelessQuery.suffix(length))
                    if let numeral = numeralValue(of: suffix) {
                        // GP v2.9 (E-10): this parse invents a
                        // numeral from any word ending that spells
                        // one ("taxi" → 11, "max" → 10, "six" → 9),
                        // so the form it adds is exact-letters: it
                        // may only match a name form whose letters
                        // equal the leftover, never a longer form
                        // it merely prefixes ("ta" ✗ "Tap Titans").
                        add(letters: String(spacelessQuery.dropLast(length)), numeral: numeral, exact: true)
                        spacelessCarriesNumeral = true
                        break
                    }
                }
            }
        }
        // The plain spaceless form stands only when no numeral
        // was parsed out of it — as a numeral-less form it would
        // prefix-match across numerals (D-24's "gtav" ⊂ "gtavi").
        if !spacelessCarriesNumeral {
            add(letters: spacelessQuery, numeral: nil)
        }
        return forms
    }

    /// B-13: entry point for Home's "See all" posters — each rail
    /// selects its matching filter here instead of landing on
    /// whatever filter Library was last left on.
    func showFilter(named name: String) {
        switch name {
        case "big": filter = .big
        case "classics": filter = .classics
        case "favourites": filter = .favourites
        default: filter = .all
        }
        // D-18: this is the external landing route (the Host
        // page's "View in Library" and Home's rails share it), so
        // clear any retained search too — the rebuild applies the
        // search field's text after the filter, and a stale query
        // would land the user on a subset of the filter's games,
        // or on "No games match". (Library's own chip taps do not
        // come through here and keep the search untouched.)
        searchWorkItem?.cancel()
        searchWorkItem = nil
        searchField.text = ""
        refreshChips()
        requestContentRebuild()
    }

    private func filterTag(_ value: Filter) -> Int {
        switch value {
        case .all: return 0
        case .big: return 1
        case .classics: return 2
        case .favourites: return 3
        }
    }

    @objc private func chipTapped(_ sender: GPChipButton) {
        switch sender.tag {
        case 1: filter = .big
        case 2: filter = .classics
        case 3: filter = .favourites
        default: filter = .all
        }
        refreshChips()
        // A-73: chips take the scroll-safe path too.
        requestContentRebuild()
    }

    private func refreshChips() {
        for (value, chip) in chips {
            chip.chipSelected = (value == filter)
        }
    }

    // MARK: - Rendering

    override func rebuildContent() {
        dynamicStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let session = GPSessionController.shared()

        guard let host = session.selectedHost ?? session.hosts.first else {
            renderingHost = nil
            subtitleLabel.text = "No PC yet"
            let message = GPMessageView()
            message.configure(title: "No PC found yet",
                              message: "Your games live on your PC. Once GameParks finds it on your network, they all appear here.",
                              actionTitle: "Go to Home")
            message.actionButton.addTarget(self, action: #selector(goHome), for: .touchUpInside)
            dynamicStack.addArrangedSubview(message)
            return
        }

        renderingHost = host
        let allApps = GPCatalog.sortedApps(for: host)

        if host.pairState != .paired {
            // A-72: this branch returns before the count assignment
            // below, so set the subtitle here — never leave a stale
            // count from a previous render over this state.
            subtitleLabel.text = nil
            let message = GPMessageView()
            message.configure(title: "Pair with your PC to see its games",
                              message: "Your library is read from Sunshine on the PC, and that needs the one-time pairing.",
                              actionTitle: "Open PC page")
            message.actionButton.addTarget(self, action: #selector(openHostPage), for: .touchUpInside)
            dynamicStack.addArrangedSubview(message)
            return
        }

        if allApps.isEmpty {
            // A-72: same early return — the empty list's true count.
            subtitleLabel.text = "0 games"
            let message = GPMessageView()
            if let error = session.appListError(for: host) {
                message.configure(title: "Couldn't load your games", message: error, actionTitle: "Try again")
            } else {
                message.configure(title: "No games found on this PC yet",
                                  message: "Games appear here once they're in Sunshine's app list on the PC.",
                                  actionTitle: "Check again")
            }
            message.actionButton.addTarget(self, action: #selector(retryAppList), for: .touchUpInside)
            dynamicStack.addArrangedSubview(message)
            return
        }

        // A-72/A-106: subtitle is set only once the list will
        // actually render, counts games only (not Desktop), drops
        // the unchecked provenance clause, and pluralises.
        let gameCount = allApps.filter { !GPCatalog.isDesktop($0) }.count
        subtitleLabel.text = gameCount == 1 ? "1 game" : "\(gameCount) games"

        var apps = allApps
        switch filter {
        case .all:
            break
        case .big:
            apps = apps.filter { !GPCatalog.info(for: $0).isClassic && !GPCatalog.isDesktop($0) }
        case .classics:
            apps = apps.filter { GPCatalog.info(for: $0).isClassic }
        case .favourites:
            apps = apps.filter { GPCatalog.isFavourite(host: host, app: $0) }
        }
        let query = (searchField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            apps = apps.filter { appMatches($0, query: query) }
        }

        if apps.isEmpty {
            // A-103: blame the search only when there is one.
            let emptyText: String
            if !query.isEmpty {
                emptyText = "No games match — try another search."
            } else if filter == .favourites {
                emptyText = "No favourites yet — open a game and turn on Favourite."
            } else {
                emptyText = "Nothing here yet."
            }
            dynamicStack.addArrangedSubview(gpLabel(emptyText,
                                                    font: GPFont.body(14), color: GPColor.textSecondary, lines: 0))
            return
        }

        for app in apps {
            let row = GPAppRow()
            let info = GPCatalog.info(for: app)
            row.configure(name: app.name ?? "",
                          subtitle: info.sourceTag,
                          cover: GPCatalog.coverImage(for: app, host: host))
            row.accessibilityIdentifier = GPCatalog.appKey(host: host, app: app)
            row.appKey = GPCatalog.appKey(host: host, app: app)
            row.addTarget(self, action: #selector(appRowTapped(_:)), for: .touchUpInside)
            dynamicStack.addArrangedSubview(row)
        }
    }

    // MARK: - Actions — navigation first

    @objc private func appRowTapped(_ sender: GPAppRow) {
        // A-74: resolve against the rendering host, via the row's
        // dedicated appKey (A-27).
        guard let host = renderingHost ?? GPSessionController.shared().selectedHost ?? GPSessionController.shared().hosts.first,
              let key = sender.appKey,
              let app = GPCatalog.sortedApps(for: host).first(where: { GPCatalog.appKey(host: host, app: $0) == key })
        else { return }
        navigationController?.pushViewController(GPGameViewController(host: host, app: app), animated: true)
    }

    @objc private func goHome() {
        if let tabBar = navigationController?.viewControllers.first as? GPTabBarController {
            tabBar.selectedIndex = 0
        }
    }

    @objc private func openHostPage() {
        // B-16: resolve against the rendering host (A-74), not the
        // session's possibly since-changed selection.
        guard let host = renderingHost ?? GPSessionController.shared().selectedHost ?? GPSessionController.shared().hosts.first else { return }
        navigationController?.pushViewController(GPHostViewController(host: host), animated: true)
    }

    @objc private func retryAppList() {
        // B-16: rendering host first, as in openHostPage.
        guard let host = renderingHost ?? GPSessionController.shared().selectedHost ?? GPSessionController.shared().hosts.first else { return }
        GPSessionController.shared().fetchAppList(for: host)
    }
}
