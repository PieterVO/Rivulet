//
//  InputConfig.swift
//  Rivulet
//
//  Shared constants for remote/controller/keyboard input behavior.
//

import Foundation

enum InputConfig {
    static let holdThreshold: TimeInterval = 0.4
    static let seekCoalesceInterval: TimeInterval = 0.05
    static let actionDedupeWindow: TimeInterval = 0.08
    static let blockDismissTimeout: TimeInterval = 0.3

    static let tapSeekSeconds: TimeInterval = 10
    static let jumpSeekSeconds: TimeInterval = 30

    static let dpadThreshold: Float = 0.3
    static let joystickDeadzone: Float = 0.2

    static let wheelRotationThreshold: Float = 0.3
    static let wheelRadiusThreshold: Float = 0.7
    static let wheelSecondsPerRadian: TimeInterval = 10
}
