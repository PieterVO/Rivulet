//
//  MediaPerson.swift
//  Rivulet
//
//  Cast / crew member.
//

import Foundation

struct MediaPerson: Hashable, Identifiable, Sendable {
    let id: String
    let name: String
    let role: String?
    let imageURL: URL?
    var tagKey: String? = nil           // Discover person key (cast only)
    var originActorId: String? = nil    // origin-library actor id (fallback path)
    var originSectionKey: String? = nil // origin library section key (fallback path)
}
