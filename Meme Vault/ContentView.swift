//
//  ContentView.swift
//  Meme Vault
//
//  SwiftUI preview entry point.
//

import SwiftUI
import SwiftData

#Preview {
    RootView()
        .environment(PhotoLibrary.shared)
        .modelContainer(for: AppSchema.models, inMemory: true)
}
