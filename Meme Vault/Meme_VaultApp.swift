//
//  Meme_VaultApp.swift
//  Meme Vault
//
//  Created by Elaine Lyons on 5/4/26.
//

import SwiftUI
import SwiftData

@main
struct Meme_VaultApp: App {
    @StateObject private var library = PhotoLibrary.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(library)
        }
        .modelContainer(for: [
            OrgContext.self,
            PhotoSkip.self,
            PendingDelete.self,
        ])
    }
}
