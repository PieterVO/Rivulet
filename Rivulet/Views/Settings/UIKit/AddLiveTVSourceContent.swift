// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  AddLiveTVSourceContent.swift
//  Rivulet
//
//  Live TV add-source flow, as real pages in the UIKit Settings stack: a
//  picker (`.addLiveTVSource`) that pushes one form per kind (`.addXtream`,
//  `.addPlaylistURL`, `.addOwnServer`).
//
//  Every form works the same way, after tvOS Settings and Apple Account
//  sign-in: on arrival it asks for each required field on its own page, one
//  after another (`guide`), then lands on the form with focus on its button.
//  The form is the review: every value in one list, optional fields included,
//  and any row reopens its page.
//
//  Draft state lives in `AddSourceDraft`, created when the picker pushes a form
//  and released when the flow leaves. Nothing touches UserDefaults until a
//  source is actually added.
//

import Foundation
import UIKit

// MARK: - Draft state

/// Form state for the add-source pages. A reference type so `.textEntry`
/// closures read/write one shared instance across row rebuilds. Not persisted.
@MainActor
final class AddSourceDraft {
    var serverURL = ""
    var displayName = ""
    var username = ""
    var password = ""
    var channelProfile = ""
    var m3uURL = ""
    var epgURL = ""
    var status: Status = .idle
    /// The step-by-step entry has run for this draft; it runs once.
    var guided = false

    /// A failed check is not a state: it goes back to `.idle` and the cause
    /// shows in a popup (`SettingsContent.fail`).
    enum Status: Equatable {
        case idle
        case checking
    }
}

// MARK: - Entry steps

/// One field of a form: its row, and the page that asks for it.
@MainActor
struct EntryStep {
    let id: String
    /// Row title, page title and the keyboard's header: the field's name.
    let title: String
    /// One sentence on the entry page saying what to type, examples included.
    let message: String
    /// What the row shows while the field is empty.
    var placeholder = "Optional"
    var keyboard: UIKeyboardType = .default
    var contentType: UITextContentType?
    var isSecure = false
    var suggestions: [(label: String, value: String)] = []
    /// Asked for on arrival. Optional fields usually wait on the form.
    var asked = false
    var required = false
    let value: () -> String
    let set: (String) -> Void

    var row: SettingsRowItem {
        SettingsRowItem(id: id, title: title,
                        kind: .textEntry(value: value, placeholder: placeholder, hint: message,
                                         suggestions: suggestions, keyboardType: keyboard,
                                         isSecure: isSecure, contentType: contentType, set: set))
    }

    func entryPage(onCommit: @escaping (String) -> Void, onCancel: @escaping () -> Void) -> TextEntryViewController {
        TextEntryViewController(title: title, message: message, initialText: value(),
                                suggestions: suggestions, keyboardType: keyboard, isSecure: isSecure,
                                contentType: contentType, submitTitle: "Continue", allowsEmpty: !required,
                                onCommit: onCommit, onCancel: onCancel)
    }
}

// MARK: - Add-source pages

extension SettingsContent {

    /// The Live TV add-source draft: created when the picker pushes a form,
    /// cleared when the flow is entered or left. Static for the same reason
    /// `pendingSourceDetail` is: `SettingsPage` is `CaseIterable` and can't
    /// carry associated data.
    static var addSourceDraft: AddSourceDraft?

    // MARK: Picker

    /// Names things by what the user has, not by protocol. The app names on the
    /// "My Own Server" row are load-bearing: that's how someone running
    /// Threadfin recognises the row as theirs.
    static var addLiveTVSource: [SettingsRowItem] {
        var rows: [SettingsRowItem] = []

        if PlexAuthManager.shared.isAuthenticated {
            rows.append(SettingsRowItem(
                id: "addPlexLiveTV",
                title: plexRowTitle,
                kind: .action(destructive: false, handler: { vc in addPlexLiveTV(on: vc) })))
        }

        rows.append(SettingsRowItem(
            id: "addXtream", title: "Xtream Codes",
            kind: .navigationAction(.addXtream,
                                    value: { "Provider login" },
                                    prepare: { beginDraft(displayName: "") })))
        rows.append(SettingsRowItem(
            id: "addPlaylistURL", title: "Playlist URL",
            kind: .navigationAction(.addPlaylistURL,
                                    value: { "M3U link" },
                                    prepare: { beginDraft(displayName: "") })))
        rows.append(SettingsRowItem(
            id: "addOwnServer", title: "My Own Server",
            kind: .navigationAction(.addOwnServer,
                                    value: { "Dispatcharr, Threadfin" },
                                    prepare: { beginDraft(displayName: "") })))
        return rows
    }

    /// Picker-local status for the Plex row (the Plex path has no form, so it
    /// can't use the draft). Reset by `resetAddSourceFlow()` on entry so a
    /// previous visit's state never greets the next one.
    static var plexStatus: AddSourceDraft.Status = .idle

    /// Clears everything the flow holds. Called when the picker page loads, so
    /// entering the flow always starts blank.
    static func resetAddSourceFlow() {
        plexStatus = .idle
        addSourceDraft = nil
    }

    private static var plexRowTitle: String {
        plexStatus == .checking ? "Checking…" : "Plex Live TV"
    }

    private static func beginDraft(displayName: String) {
        let draft = AddSourceDraft()
        draft.displayName = displayName
        addSourceDraft = draft
    }

    /// Single press: check, add, load, pop. No confirm page.
    private static func addPlexLiveTV(on vc: UIViewController) {
        guard plexStatus != .checking else { return }
        let request: LiveTVSourceConnector.PlexRequest
        do {
            request = try LiveTVSourceConnector.plexRequest()
        } catch {
            plexStatus = .idle
            fail(nil, page: vc as? SettingsPageViewController, error: error)
            return
        }

        plexStatus = .checking
        let page = vc as? SettingsPageViewController
        page?.reloadRows()

        Task { @MainActor in
            do {
                try await LiveTVSourceConnector().connect(request)
            } catch {
                plexStatus = .idle
                fail(nil, page: page, error: error)
                return
            }
            plexStatus = .idle
            addSourceDraft = nil
            page?.onPop?()  // the picker itself: one level to the list
        }
    }

    // MARK: Step-by-step entry

    /// Runs each form's step-by-step entry the first time it appears.
    static func pageDidAppear(_ page: SettingsPage, on vc: SettingsPageViewController) {
        guard let draft = addSourceDraft, !draft.guided else { return }
        let steps: [EntryStep]
        let button: String
        switch page {
        case .addXtream: (steps, button) = (xtreamSteps(draft), "addSourceConfirm")
        case .addPlaylistURL: (steps, button) = (playlistSteps(draft), "addSourceConfirm")
        case .addOwnServer: (steps, button) = (ownServerSteps(draft), "addSourceConfirm")
        case .jellyfin where JellyfinSession.account == nil: (steps, button) = (jellyfinSteps(draft), "jellyfinSignIn")
        default: return
        }
        draft.guided = true
        guide(steps, from: 0, on: vc, finishOn: button)
    }

    /// Presents the next asked step that is still empty, starting at `start`.
    /// Menu before anything is typed leaves the form; later it stops on the
    /// form with what was entered so far.
    private static func guide(_ steps: [EntryStep], from start: Int, on page: SettingsPageViewController,
                              finishOn button: String) {
        guard let index = steps.indices.first(where: { $0 >= start && steps[$0].asked && steps[$0].value().isEmpty })
        else {
            page.reloadRows()
            page.focusRow(id: button)
            return
        }
        let step = steps[index]
        let entry = step.entryPage(onCommit: { text in
            step.set(text)
            page.reloadRows()
            guide(steps, from: index + 1, on: page, finishOn: button)
        }, onCancel: {
            if steps.allSatisfy({ $0.value().isEmpty }) {
                page.onPop?()
            } else {
                page.reloadRows()
            }
        })
        page.present(entry, animated: true)
    }

    // MARK: Xtream Codes

    static var addXtream: [SettingsRowItem] {
        guard let draft = addSourceDraft else { return [] }
        return xtreamSteps(draft).map(\.row) + [addButton(draft) { saveXtream(draft, on: $0) }]
    }

    private static func xtreamSteps(_ draft: AddSourceDraft) -> [EntryStep] {
        [
            EntryStep(id: "xtreamServerField", title: "Server Address",
                      message: "Enter the server address from your provider, with its port, "
                          + "for example http://provider.example:8080. You can also paste a link "
                          + "that includes your username and password.",
                      placeholder: "Required", keyboard: .URL, contentType: .URL, asked: true, required: true,
                      value: { draft.serverURL },
                      set: { text in
                          // A pasted get.php link carries the login: split it out.
                          let parsed = XtreamService.parseAddress(text)
                          if let username = parsed.username, let password = parsed.password {
                              draft.serverURL = parsed.server
                              draft.username = username
                              draft.password = password
                          } else {
                              draft.serverURL = text
                          }
                          draft.status = .idle
                      }),
            EntryStep(id: "xtreamUsernameField", title: "Username",
                      message: "Enter the username your provider gave you for this server.",
                      placeholder: "Required", keyboard: .asciiCapable, contentType: .username,
                      asked: true, required: true,
                      value: { draft.username }, set: { draft.username = $0; draft.status = .idle }),
            EntryStep(id: "xtreamPasswordField", title: "Password",
                      message: "Enter the password your provider gave you for this server.",
                      placeholder: "Required", keyboard: .asciiCapable, contentType: .password, isSecure: true,
                      asked: true, required: true,
                      value: { draft.password }, set: { draft.password = $0; draft.status = .idle }),
            nameStep(draft, fallback: xtreamDefaultName(draft))
        ]
    }

    private static func xtreamDefaultName(_ draft: AddSourceDraft) -> String {
        URL(string: XtreamService.parseAddress(draft.serverURL).server)?.host ?? LiveTVSourceConnector.defaultPlaylistName
    }

    private static func saveXtream(_ draft: AddSourceDraft, on vc: UIViewController) {
        let connector = LiveTVSourceConnector()
        save(draft, on: vc,
             request: { try connector.xtreamRequest(address: draft.serverURL, username: draft.username,
                                                    password: draft.password) },
             connect: { try await connector.connect($0, name: draft.displayName.isEmpty
                                                        ? xtreamDefaultName(draft) : draft.displayName) })
    }

    // MARK: Playlist URL

    static var addPlaylistURL: [SettingsRowItem] {
        guard let draft = addSourceDraft else { return [] }
        return playlistSteps(draft).map(\.row) + [addButton(draft) { savePlaylist(draft, on: $0) }]
    }

    private static func playlistSteps(_ draft: AddSourceDraft) -> [EntryStep] {
        [
            EntryStep(id: "m3uURLField", title: "Playlist URL",
                      message: "Enter the M3U playlist link from your provider, "
                          + "for example http://provider.example/playlist.m3u.",
                      placeholder: "Required", keyboard: .URL, contentType: .URL, asked: true, required: true,
                      value: { draft.m3uURL }, set: { draft.m3uURL = $0; draft.status = .idle }),
            EntryStep(id: "epgURLField", title: "Guide URL",
                      message: "If your provider gave you a guide link (XMLTV), enter it. "
                          + "Otherwise leave this empty: Rivulet uses the guide the playlist names, if it has one.",
                      keyboard: .URL, contentType: .URL, asked: true,
                      value: { draft.epgURL }, set: { draft.epgURL = $0; draft.status = .idle }),
            nameStep(draft, fallback: LiveTVSourceConnector.defaultPlaylistName)
        ]
    }

    private static func savePlaylist(_ draft: AddSourceDraft, on vc: UIViewController) {
        let connector = LiveTVSourceConnector()
        save(draft, on: vc,
             request: { try LiveTVSourceConnector.playlistRequest(m3uURL: draft.m3uURL, epgURL: draft.epgURL) },
             connect: { try await connector.connect($0, name: draft.displayName) })
    }

    // MARK: My Own Server

    static var addOwnServer: [SettingsRowItem] {
        guard let draft = addSourceDraft else { return [] }
        return ownServerSteps(draft).map(\.row) + [addButton(draft) { saveOwnServer(draft, on: $0) }]
    }

    private static func ownServerSteps(_ draft: AddSourceDraft) -> [EntryStep] {
        [
            EntryStep(id: "serverURL", title: "Server Address",
                      message: "Enter the address of the server on your network, with its port. "
                          + "Pick your app below to fill in its usual address.",
                      placeholder: "Required", keyboard: .URL, contentType: .URL,
                      suggestions: serverSuggestions, asked: true, required: true,
                      value: { draft.serverURL }, set: { draft.serverURL = $0; draft.status = .idle }),
            EntryStep(id: "usernameField", title: "Username",
                      message: "Your Dispatcharr username. Only needed to record; leave it empty to just watch.",
                      keyboard: .asciiCapable, contentType: .username,
                      value: { draft.username }, set: { draft.username = $0; draft.status = .idle }),
            EntryStep(id: "passwordField", title: "Password",
                      message: "Your Dispatcharr password. Only needed to record; leave it empty to just watch.",
                      keyboard: .asciiCapable, contentType: .password, isSecure: true,
                      value: { draft.password }, set: { draft.password = $0; draft.status = .idle }),
            EntryStep(id: "channelProfileField", title: "Channel Profile",
                      message: "The name of a Dispatcharr channel profile, to show only its channels. "
                          + "Leave it empty for every channel.",
                      placeholder: "All Channels", keyboard: .asciiCapable,
                      value: { draft.channelProfile }, set: { draft.channelProfile = $0; draft.status = .idle }),
            nameStep(draft, fallback: LiveTVSourceConnector.defaultServerName)
        ]
    }

    private static var serverSuggestions: [(label: String, value: String)] {
        LiveTVSourceConnector.serverSuggestions(host: LiveTVSourceConnector.suggestedHost)
    }

    /// Verify-then-save as one operation: the server is added only if the
    /// check passed. Failure stays on the page with a real cause.
    private static func saveOwnServer(_ draft: AddSourceDraft, on vc: UIViewController) {
        let connector = LiveTVSourceConnector()
        save(draft, on: vc,
             request: { try connector.serverRequest(address: draft.serverURL, username: draft.username,
                                                    password: draft.password, channelProfile: draft.channelProfile) },
             connect: { try await connector.connect($0, name: draft.displayName) })
    }

    // MARK: Shared form pieces

    private static func nameStep(_ draft: AddSourceDraft, fallback: String) -> EntryStep {
        EntryStep(id: "displayNameField", title: "Name",
                  message: "How this source appears in Live TV. Leave it empty to use \u{201C}\(fallback)\u{201D}.",
                  placeholder: fallback,
                  value: { draft.displayName }, set: { draft.displayName = $0 })
    }

    private static func addButton(_ draft: AddSourceDraft, action: @escaping (UIViewController) -> Void) -> SettingsRowItem {
        SettingsRowItem(id: "addSourceConfirm", title: draft.status == .checking ? "Checking…" : "Add Source",
                        kind: .action(destructive: false, handler: action))
    }

    /// The form check runs first so a bad field fails before the busy state.
    private static func save<Request>(_ draft: AddSourceDraft, on vc: UIViewController,
                                      request makeRequest: () throws -> Request,
                                      connect: @escaping (Request) async throws -> Void) {
        guard draft.status != .checking else { return }
        let page = vc as? SettingsPageViewController
        let request: Request
        do {
            request = try makeRequest()
        } catch {
            fail(draft, page: page, error: error)
            return
        }

        draft.status = .checking
        page?.reloadRows()

        Task { @MainActor in
            do {
                try await connect(request)
                if addSourceDraft === draft { addSourceDraft = nil }
                // Back past the picker to the source list, which now shows it.
                page?.onPopTwo?()
            } catch {
                fail(draft, page: page, error: error)
            }
        }
    }

    /// A form check failed: put the button back to idle and say why in the
    /// app's popup card, with one OK button. What the user typed stays put.
    static func fail(_ draft: AddSourceDraft?, page: SettingsPageViewController?, title: String, message: String) {
        draft?.status = .idle
        page?.reloadRows()
        guard let page else { return }
        page.present(ConfirmationPopupViewController(title: title, message: message, confirmTitle: "OK",
                                                     cancelTitle: nil, onConfirm: {}),
                     animated: true)
    }

    /// `fail` with the connector error's own title and copy.
    private static func fail(_ draft: AddSourceDraft?, page: SettingsPageViewController?, error: Error) {
        let connect = error as? LiveTVConnectError ?? .source(LiveTVSourceConnector.failureCopy(for: error))
        fail(draft, page: page, title: connect.title, message: connect.message)
    }

    /// Drop the draft and pop the form. This runs after a network call, so the
    /// user may have left the form and started another: only this form's own
    /// draft is dropped, and the container ignores the pop unless the form is
    /// still on screen.
    static func finish(_ page: SettingsPageViewController?, draft: AddSourceDraft) {
        if addSourceDraft === draft { addSourceDraft = nil }
        page?.onPop?()
    }
}
