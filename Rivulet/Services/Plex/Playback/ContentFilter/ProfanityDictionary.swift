// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ProfanityDictionary.swift
//  Rivulet
//
//  Categorized word/phrase list used to mute language directly from the
//  subtitle track — the same idea as cleanvid and the Kodi "mute profanity"
//  add-on, but applied live instead of re-encoding the file. The lists are
//  intentionally compact and easy to edit; they are a starting point, not an
//  exhaustive dictionary.
//

import Foundation

/// A single dictionary entry: a lowercased word or phrase, its category, and
/// how strong it is.
struct ProfanityEntry: Sendable {
    let term: String
    let category: FilterCategory
    let severity: FilterSeverity
}

/// The bundled language dictionary plus the matcher that decides whether a
/// subtitle line should be muted for the user's enabled categories.
enum ProfanityDictionary {

    // MARK: - Matching

    /// Whether `text` should be muted, given the enabled categories and the
    /// minimum profanity severity the user wants filtered.
    ///
    /// - Single words match on whole-word boundaries so "class" never trips
    ///   "ass"; masked spellings (f***, sh!t) are matched too.
    /// - Multi-word phrases (e.g. "god damn") match on the normalized line.
    static func shouldMute(text: String,
                           enabledCategories: Set<FilterCategory>,
                           profanityThreshold: FilterSeverity) -> Bool {
        guard !text.isEmpty, !enabledCategories.isEmpty else { return false }
        let normalized = normalize(text)
        guard !normalized.isEmpty else { return false }

        // Phrase pass (multi-word terms) on the normalized line with masking
        // characters stripped, so "God damn!" still ends in a word boundary.
        let phraseLine = normalized
            .filter { !maskingCharacters.contains($0) }
            .split(separator: " ").joined(separator: " ")
        let paddedLine = " \(phraseLine) "
        for entry in phraseEntries where enabledCategories.contains(entry.category) {
            guard passesThreshold(entry, threshold: profanityThreshold) else { continue }
            if paddedLine.contains(" \(entry.term) ") { return true }
        }

        // Word pass: tokenize once, test each token's candidate spellings
        // against the single-word set.
        let tokens = normalized.split(separator: " ").map(String.init)
        for token in tokens {
            for candidate in candidateForms(token) {
                if let entry = wordIndex[candidate],
                   enabledCategories.contains(entry.category),
                   passesThreshold(entry, threshold: profanityThreshold) {
                    return true
                }
            }
        }
        return false
    }

    /// Profanity honors the user's strength threshold; every other language
    /// category (slurs, blasphemy, crude/sexual) is all-or-nothing.
    private static func passesThreshold(_ entry: ProfanityEntry, threshold: FilterSeverity) -> Bool {
        guard entry.category == .profanity else { return true }
        return entry.severity >= threshold
    }

    // MARK: - Normalization

    /// Lowercase, strip subtitle formatting punctuation, and collapse
    /// whitespace so word/phrase matching is stable. Keeps apostrophes and
    /// common masking characters (* ! @ $) so "f***" and "b@stard" survive to
    /// the masking pass.
    private static func normalize(_ text: String) -> String {
        let lowered = text.lowercased()
        var out = String()
        out.reserveCapacity(lowered.count)
        for ch in lowered {
            if ch == "'" || ch == "’" {
                out.append("'")  // curly → straight so phrase terms match
            } else if ch.isLetter || ch.isNumber {
                out.append(ch)
            } else if maskingCharacters.contains(ch) {
                out.append(ch)
            } else {
                out.append(" ")
            }
        }
        return out.split(separator: " ").joined(separator: " ")
    }

    private static let maskingCharacters: Set<Character> = ["*", "!", "@", "$", "#", "%", "&"]

    /// Candidate spellings for a token, in lookup order. Masking characters are
    /// ambiguous — "sh!t" uses "!" as a letter, "shit!" uses it as punctuation —
    /// so both readings are tried: dropped entirely, and leet-substituted.
    /// Known short residues of fully-masked words ("f***" → "f") expand via
    /// `maskedStubs`.
    private static func candidateForms(_ token: String) -> [String] {
        // Stub expansion ("f" → "fuck") only makes sense when the token was
        // actually masked with a censor glyph; without this guard, innocent
        // short tokens ("B1") would expand into hits.
        let wasMasked = token.contains { censorGlyphs.contains($0) }
        var forms: [String] = []
        func add(_ raw: String) {
            guard !raw.isEmpty else { return }
            let form = (wasMasked ? maskedStubs[raw] : nil) ?? raw
            if !forms.contains(form) { forms.append(form) }
        }
        // Apostrophes never carry meaning for the lookup; strip them once.
        let base = token.filter { $0 != "'" && $0 != "’" }
        // Reading 1: masking characters are punctuation — drop them.
        // ("shit!" → "shit", "f***" → "f" → stub)
        add(base.filter { !maskingCharacters.contains($0) })
        // Reading 2: masking characters stand in for letters — substitute.
        // ("sh!t" → "shit", "b@stard" → "bastard", "sh1t" → "shit")
        var substituted = String()
        substituted.reserveCapacity(base.count)
        for ch in base {
            switch ch {
            case "@": substituted.append("a")
            case "$": substituted.append("s")
            case "!", "1": substituted.append("i")
            case "0": substituted.append("o")
            case "*", "#", "%", "&": break
            default: substituted.append(ch)
            }
        }
        add(substituted)
        return forms
    }

    /// Characters that mark a token as deliberately censored ("f***", "s#it").
    private static let censorGlyphs: Set<Character> = ["*", "#", "%", "&"]

    /// Short residues of masked strong words → canonical term.
    private static let maskedStubs: [String: String] = [
        "f": "fuck",
        "fk": "fuck",
        "fck": "fuck",
        "sh": "shit",
        "sht": "shit",
        "b": "bitch"
    ]

    // MARK: - Dictionary

    /// Single-word entries indexed for O(1) lookup.
    private static let wordIndex: [String: ProfanityEntry] = {
        var index: [String: ProfanityEntry] = [:]
        for entry in wordEntries { index[entry.term] = entry }
        return index
    }()

    /// Single-word terms. Kept deliberately small and legible; extend as needed.
    private static let wordEntries: [ProfanityEntry] = [
        // Profanity — mild
        .init(term: "damn", category: .profanity, severity: .mild),
        .init(term: "damned", category: .profanity, severity: .mild),
        .init(term: "hell", category: .profanity, severity: .mild),
        .init(term: "crap", category: .profanity, severity: .mild),
        .init(term: "bloody", category: .profanity, severity: .mild),
        .init(term: "piss", category: .profanity, severity: .mild),
        .init(term: "pissed", category: .profanity, severity: .mild),
        .init(term: "bugger", category: .profanity, severity: .mild),
        .init(term: "git", category: .profanity, severity: .mild),
        // Profanity — moderate
        .init(term: "ass", category: .profanity, severity: .moderate),
        .init(term: "arse", category: .profanity, severity: .moderate),
        .init(term: "asshole", category: .profanity, severity: .moderate),
        .init(term: "arsehole", category: .profanity, severity: .moderate),
        .init(term: "bastard", category: .profanity, severity: .moderate),
        .init(term: "bitch", category: .profanity, severity: .moderate),
        .init(term: "bitches", category: .profanity, severity: .moderate),
        .init(term: "dick", category: .profanity, severity: .moderate),
        .init(term: "prick", category: .profanity, severity: .moderate),
        .init(term: "douche", category: .profanity, severity: .moderate),
        .init(term: "douchebag", category: .profanity, severity: .moderate),
        .init(term: "bollocks", category: .profanity, severity: .moderate),
        .init(term: "wanker", category: .profanity, severity: .moderate),
        // Profanity — strong
        .init(term: "fuck", category: .profanity, severity: .strong),
        .init(term: "fucker", category: .profanity, severity: .strong),
        .init(term: "fucking", category: .profanity, severity: .strong),
        .init(term: "fucked", category: .profanity, severity: .strong),
        .init(term: "motherfucker", category: .profanity, severity: .strong),
        .init(term: "shit", category: .profanity, severity: .strong),
        .init(term: "shitty", category: .profanity, severity: .strong),
        .init(term: "bullshit", category: .profanity, severity: .strong),
        // Crude & sexual language
        .init(term: "cock", category: .sexualLanguage, severity: .strong),
        .init(term: "pussy", category: .sexualLanguage, severity: .strong),
        .init(term: "cunt", category: .sexualLanguage, severity: .strong),
        .init(term: "twat", category: .sexualLanguage, severity: .strong),
        .init(term: "whore", category: .sexualLanguage, severity: .moderate),
        .init(term: "slut", category: .sexualLanguage, severity: .moderate),
        .init(term: "boobs", category: .sexualLanguage, severity: .mild),
        .init(term: "tits", category: .sexualLanguage, severity: .moderate),
        .init(term: "horny", category: .sexualLanguage, severity: .moderate),
        // Blasphemy (single word)
        .init(term: "goddamn", category: .blasphemy, severity: .moderate),
        .init(term: "goddammit", category: .blasphemy, severity: .moderate),
        .init(term: "goddamnit", category: .blasphemy, severity: .moderate)
    ]

    /// Multi-word phrases. Matched against the normalized line, so word order
    /// and boundaries are respected. Blasphemy is phrase-led on purpose so the
    /// word "god" alone never mutes ordinary dialogue.
    private static let phraseEntries: [ProfanityEntry] = [
        .init(term: "god damn", category: .blasphemy, severity: .moderate),
        .init(term: "god damn it", category: .blasphemy, severity: .moderate),
        .init(term: "goddamn it", category: .blasphemy, severity: .moderate),
        .init(term: "jesus christ", category: .blasphemy, severity: .moderate),
        .init(term: "christ almighty", category: .blasphemy, severity: .moderate),
        .init(term: "for christ's sake", category: .blasphemy, severity: .moderate),
        .init(term: "for god's sake", category: .blasphemy, severity: .mild),
        .init(term: "son of a bitch", category: .profanity, severity: .strong),
        .init(term: "piss off", category: .profanity, severity: .moderate),
        .init(term: "dumb ass", category: .profanity, severity: .moderate),
        .init(term: "jack ass", category: .profanity, severity: .moderate)
    ]
}
