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
    let modelContainer: ModelContainer

    init() {
        do {
            let schema = Schema(versionedSchema: SchemaV1.self)
            let configuration = ModelConfiguration(schema: schema)
            modelContainer = try ModelContainer(
                for: schema,
                migrationPlan: MemeVaultMigrationPlan.self,
                configurations: configuration
            )
        } catch {
            // An unopenable store is unrecoverable; surface it loudly in dev.
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(PhotoLibrary.shared)
        }
        .modelContainer(modelContainer)
    }
}
