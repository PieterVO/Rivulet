// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  NoFocusEffectButtonStyle.swift
//  Rivulet
//
//  Button style that strips the tvOS default focus ring and press effects,
//  for buttons that paint their own focused appearance.
//

import SwiftUI

struct NoFocusEffectButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}
