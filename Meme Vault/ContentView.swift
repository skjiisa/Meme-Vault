//
//  ContentView.swift
//  Meme Vault
//
//  The root view for Meme Vault is `ContextListView` — see Features/ContextList/.
//  This file is kept as a SwiftUI preview entry point.
//

import SwiftUI
import SwiftData

#Preview {
    ContextListView()
        .environmentObject(PhotoLibrary.shared)
        .modelContainer(for: AppSchema.models, inMemory: true)
}
