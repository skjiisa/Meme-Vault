//
//  AlbumPicker.swift
//  Meme Vault
//
//  Reusable album picker. Two modes: single-select (returns one local ID) or
//  multi-select (returns a Set of local IDs). Supports creating a new album
//  inline.
//

import SwiftUI
import Photos

struct AlbumPicker: View {
    enum Mode {
        case single(Binding<String?>)
        case multi(Binding<Set<String>>)
    }

    let title: String
    let mode: Mode

    @Environment(\.dismiss) private var dismiss
    @Environment(PhotoLibrary.self) private var library

    @State private var albums: [AlbumInfo] = []
    @State private var search = ""
    @State private var showingCreate = false
    @State private var newAlbumName = ""
    @State private var creating = false

    var body: some View {
        NavigationStack {
            List {
                if !albums.isEmpty {
                    Section {
                        ForEach(filteredAlbums) { album in
                            row(for: album)
                        }
                    }
                }
                Section {
                    Button {
                        showingCreate = true
                    } label: {
                        Label("Create New Album", systemImage: "plus.rectangle.on.rectangle")
                    }
                }
            }
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always))
            .overlay {
                if albums.isEmpty {
                    ContentUnavailableView(
                        "No Albums",
                        systemImage: "rectangle.stack",
                        description: Text("Create an album in the Photos app or tap below to make one.")
                    )
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("New Album", isPresented: $showingCreate) {
                TextField("Album name", text: $newAlbumName)
                Button("Cancel", role: .cancel) { newAlbumName = "" }
                Button("Create") {
                    Task { await createAlbum() }
                }
            } message: {
                Text("This will create a new album in your Photos library.")
            }
            .task(id: library.changeTick) { reload() }
            .onAppear { reload() }
        }
    }

    private var filteredAlbums: [AlbumInfo] {
        guard !search.isEmpty else { return albums }
        let s = search.lowercased()
        return albums.filter { $0.title.lowercased().contains(s) }
    }

    @ViewBuilder
    private func row(for album: AlbumInfo) -> some View {
        switch mode {
        case .single(let binding):
            Button {
                binding.wrappedValue = album.id
                dismiss()
            } label: {
                HStack {
                    rowLabel(album)
                    Spacer()
                    if binding.wrappedValue == album.id {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.tint)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

        case .multi(let binding):
            Button {
                if binding.wrappedValue.contains(album.id) {
                    binding.wrappedValue.remove(album.id)
                } else {
                    binding.wrappedValue.insert(album.id)
                }
            } label: {
                HStack {
                    Image(systemName: binding.wrappedValue.contains(album.id)
                          ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(binding.wrappedValue.contains(album.id) ? Color.accentColor : Color.secondary)
                    rowLabel(album)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func rowLabel(_ album: AlbumInfo) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(album.title)
            if album.assetCount > 0 {
                Text("^[\(album.assetCount) item](inflect: true)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func reload() {
        albums = AlbumService.listUserAlbums()
    }

    private func createAlbum() async {
        let name = newAlbumName.trimmingCharacters(in: .whitespacesAndNewlines)
        newAlbumName = ""
        guard !name.isEmpty else { return }
        creating = true
        defer { creating = false }
        do {
            let id = try await AlbumService.createAlbum(named: name)
            reload()
            switch mode {
            case .single(let binding):
                binding.wrappedValue = id
                dismiss()
            case .multi(let binding):
                binding.wrappedValue.insert(id)
            }
        } catch {
            // Silent fail for v1; could surface via alert.
            print("Create album failed: \(error)")
        }
    }
}
