//
//  Logging.swift
//  Meme Vault
//
//  Shared os.Logger for diagnostics. Replaces stray print() calls so failures
//  are visible in Console.app / unified logging rather than the Xcode console
//  only, and are stripped of any sensitive content by default.
//

import Foundation
import os

extension Logger {
    /// App-wide logger. Use category-specific loggers for noisy subsystems.
    static let app = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.lyons.Meme-Vault",
        category: "app"
    )
}
