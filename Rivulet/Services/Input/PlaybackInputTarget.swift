//
//  PlaybackInputTarget.swift
//  Rivulet
//
//  Protocol implemented by playback surfaces that consume normalized input actions.
//

import Foundation

@MainActor
protocol PlaybackInputTarget: AnyObject {
    var isScrubbingForInput: Bool { get }
    func handleInputAction(_ action: PlaybackInputAction, source: PlaybackInputSource)
}
