//
//  ContextEditorView.swift
//  Meme Vault
//
//  Create or edit an OrgContext: name, source pool, and destination albums.
//

import SwiftUI
import SwiftData
import Photos

struct ContextEditorView: View {
    enum Mode {
        case create
        case edit(OrgContext)
    }

    let mode: Mode

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    // Working copies (so cancel really cancels in create mode)
    @State private var name: String = ""
    @State private var sourceKind: SourceKind = .allPhotos
    @State private var sourceAlbumLocalID: String?
    @State private var albumSelection: Set<String> = []

    @State private var showingSourcePicker = false
    @State private var showingAlbumPicker = false
    @State private var lastAutoName: String = ""

    /// Whether the context being edited is the default context.
    private var isDefaultContext: Bool {
        if case .edit(let ctx) = mode { return ctx.isDefault }
        return false
    }

    var body: some View {
        NavigationStack {
            Form {
                if isDefaultContext {
                    defaultContextSections
                } else {
                    editableSections
                }
            }
            .onChange(of: sourceAlbumLocalID) { _, newValue in
                guard case .create = mode, sourceKind == .album else { return }
                if let id = newValue,
                   let title = AlbumService.collection(for: id)?.localizedTitle {
                    if name.isEmpty || name == lastAutoName {
                        name = title
                        lastAutoName = title
                    }
                }
            }
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        if case .create = mode {
                            // Draft context was not yet created — nothing to delete.
                        }
                        dismiss()
                    }
                }
                if !isDefaultContext {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Save") { save() }
                            .disabled(!isValid)
                    }
                }
            }
            .sheet(isPresented: $showingSourcePicker) {
                AlbumPicker(
                    title: "Source Album",
                    mode: .single(Binding(
                        get: { sourceAlbumLocalID },
                        set: { sourceAlbumLocalID = $0 }
                    ))
                )
            }
            .sheet(isPresented: $showingAlbumPicker) {
                AlbumPicker(
                    title: "Destination Albums",
                    mode: .multi($albumSelection)
                )
            }
            .onAppear(perform: setup)
        }
    }

    // MARK: - Default context (read-only)

    @ViewBuilder
    private var defaultContextSections: some View {
        Section("Name") {
            Text("Unsorted")
                .foregroundStyle(.secondary)
        }
        Section("Source") {
            Label("All Photos", systemImage: "photo.on.rectangle.angled")
                .foregroundStyle(.secondary)
        }
        Section {
            Label("All albums in your library", systemImage: "rectangle.stack")
                .foregroundStyle(.secondary)
        } header: {
            Text("Destination Albums")
        } footer: {
            Text("This context automatically includes all albums and updates when albums are created or deleted.")
        }
    }

    // MARK: - Editable sections

    @ViewBuilder
    private var editableSections: some View {
        Section("Source") {
            Picker("Photos to sort", selection: $sourceKind) {
                Text("All Photos").tag(SourceKind.allPhotos)
                Text("Specific Album").tag(SourceKind.album)
            }
            if sourceKind == .album {
                Button {
                    showingSourcePicker = true
                } label: {
                    HStack {
                        Text(sourceAlbumName)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        Section("Name") {
            TextField("Context name", text: $name)
        }
        Section {
            if !albumSelection.isEmpty {
                ForEach(selectedAlbumInfos, id: \.id) { info in
                    HStack {
                        Image(systemName: "rectangle.stack")
                            .foregroundStyle(.secondary)
                        Text(info.title)
                        Spacer()
                        Button {
                            albumSelection.remove(info.id)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Button {
                showingAlbumPicker = true
            } label: {
                Label("Choose Albums", systemImage: "plus")
            }
        } header: {
            Text("Destination Albums")
        } footer: {
            Text("A photo is sorted when it belongs to at least one of these albums.")
        }
    }

    // MARK: - Setup

    private func setup() {
        switch mode {
        case .create:
            break
        case .edit(let ctx):
            name = ctx.name
            sourceKind = ctx.sourceKind
            sourceAlbumLocalID = ctx.sourceAlbumLocalID
            albumSelection = Set(ctx.albumLocalIDs)
        }
    }

    private var navTitle: String {
        if isDefaultContext { return "Default Context" }
        switch mode {
        case .create: return "New Context"
        case .edit:   return "Edit Context"
        }
    }

    private var sourceAlbumName: String {
        guard let id = sourceAlbumLocalID,
              let title = AlbumService.collection(for: id)?.localizedTitle
        else { return "Choose an Album…" }
        return title
    }

    private var isValid: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if sourceKind == .album && sourceAlbumLocalID == nil { return false }
        return !albumSelection.isEmpty
    }

    private var selectedAlbumInfos: [AlbumInfo] {
        let collections = AlbumService.collections(for: Array(albumSelection))
        let byID = Dictionary(uniqueKeysWithValues: collections.map {
            ($0.localIdentifier, AlbumInfo(collection: $0))
        })
        return Array(albumSelection).compactMap { byID[$0] }
    }

    // MARK: - Save

    private func save() {
        switch mode {
        case .create:
            let ctx = OrgContext(
                name: name.trimmingCharacters(in: .whitespaces),
                sourceKind: sourceKind,
                sourceAlbumLocalID: sourceKind == .album ? sourceAlbumLocalID : nil
            )
            ctx.albumLocalIDs = Array(albumSelection)
            modelContext.insert(ctx)
        case .edit(let ctx):
            ctx.name = name.trimmingCharacters(in: .whitespaces)
            ctx.sourceKind = sourceKind
            ctx.sourceAlbumLocalID = sourceKind == .album ? sourceAlbumLocalID : nil
            ctx.albumLocalIDs = Array(albumSelection)
        }
        try? modelContext.save()
        dismiss()
    }
}
