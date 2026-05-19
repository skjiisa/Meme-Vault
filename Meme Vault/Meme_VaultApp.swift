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
    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(PhotoLibrary.shared)
        }
        .modelContainer(for: [
            OrgContext.self,
            PhotoSkip.self,
            PendingDelete.self,
        ])
    }
}
