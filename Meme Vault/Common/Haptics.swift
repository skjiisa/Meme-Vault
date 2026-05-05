//
//  Haptics.swift
//  Meme Vault
//

import UIKit

enum Haptics {
    static func tap() {
        let g = UIImpactFeedbackGenerator(style: .light)
        g.impactOccurred()
    }

    static func success() {
        let g = UINotificationFeedbackGenerator()
        g.notificationOccurred(.success)
    }

    static func warning() {
        let g = UINotificationFeedbackGenerator()
        g.notificationOccurred(.warning)
    }

    static func swipe() {
        let g = UIImpactFeedbackGenerator(style: .medium)
        g.impactOccurred()
    }
}
