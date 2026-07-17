// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  CountdownRing.swift
//  Rivulet
//
//  Animated circular countdown timer for post-video autoplay
//

import SwiftUI

struct CountdownRing: View {
    let totalSeconds: Int
    let remainingSeconds: Int
    let isPaused: Bool

    private var progress: Double {
        guard totalSeconds > 0 else { return 0 }
        return Double(remainingSeconds) / Double(totalSeconds)
    }

    var body: some View {
        ZStack {
            // Background ring
            Circle()
                .stroke(Color.white.opacity(0.2), lineWidth: 6)

            // Progress ring
            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    isPaused ? Color.gray : Color.white,
                    style: StrokeStyle(lineWidth: 6, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 1), value: remainingSeconds)

            // Countdown number
            Text("\(remainingSeconds)")
                .font(.system(size: 48, weight: .bold, design: .rounded))
                .foregroundStyle(isPaused ? .gray : .white)
                .contentTransition(.numericText())
                .animation(.spring(response: 0.2, dampingFraction: 0.6), value: remainingSeconds)
        }
        .frame(width: 100, height: 100)
    }
}

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        HStack(spacing: 40) {
            CountdownRing(totalSeconds: 10, remainingSeconds: 7, isPaused: false)
            CountdownRing(totalSeconds: 10, remainingSeconds: 3, isPaused: false)
            CountdownRing(totalSeconds: 10, remainingSeconds: 5, isPaused: true)
        }
    }
}
