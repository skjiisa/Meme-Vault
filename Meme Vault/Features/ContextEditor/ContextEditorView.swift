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
    @State private var albumOrder: [String] = []
    @State private var autoSortByCount: Bool = false

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
                    mode: .multi(albumSelectionBinding)
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
            Toggle("Sort by Album Size", isOn: $autoSortByCount)
                .onChange(of: autoSortByCount) { _, newValue in
                    if case .edit(let ctx) = mode {
                        ctx.autoSortAlbumsByCount = newValue
                        try? modelContext.save()
                    }
                }
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
            Toggle("Sort by Album Size", isOn: $autoSortByCount)
        } header: {
            Text("Destination Albums")
        }
        Section {
            if !albumOrder.isEmpty {
                ForEach(selectedAlbumInfos, id: \.id) { info in
                    HStack {
                        if !autoSortByCount {
                            Image(systemName: "line.3.horizontal")
                                .foregroundStyle(.tertiary)
                                .font(.subheadline)
                        }
                        Image(systemName: "rectangle.stack")
                            .foregroundStyle(.secondary)
                        Text(info.title)
                        Spacer()
                        if autoSortByCount, info.estimatedAssetCount != NSNotFound {
                            Text("^[\(info.estimatedAssetCount) photo](inflect: true)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in
                    let infos = selectedAlbumInfos
                    for index in offsets {
                        albumOrder.removeAll { $0 == infos[index].id }
                    }
                }
                .onMove { from, to in
                    albumOrder.move(fromOffsets: from, toOffset: to)
                }
                .moveDisabled(autoSortByCount)
                .deleteDisabled(autoSortByCount)
            }
            Button {
                showingAlbumPicker = true
            } label: {
                Label("Choose Albums", systemImage: "plus")
            }
        } footer: {
            Text(autoSortByCount
                 ? "Albums are sorted by item count, most first."
                 : "Hold and drag to reorder. Swipe to remove.")
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
            albumOrder = ctx.albumLocalIDs
            autoSortByCount = ctx.autoSortAlbumsByCount
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
        return !albumOrder.isEmpty
    }

    private var albumSelectionBinding: Binding<Set<String>> {
        Binding(
            get: { Set(albumOrder) },
            set: { newSet in
                albumOrder.removeAll { !newSet.contains($0) }
                for id in newSet where !albumOrder.contains(id) {
                    albumOrder.append(id)
                }
            }
        )
    }

    private var selectedAlbumInfos: [AlbumInfo] {
        let collections = AlbumService.collections(for: albumOrder)
        let byID = Dictionary(uniqueKeysWithValues: collections.map {
            ($0.localIdentifier, AlbumInfo(collection: $0))
        })
        var infos = albumOrder.compactMap { byID[$0] }
        if autoSortByCount {
            infos.sort { lhs, rhs in
                let lCount = lhs.estimatedAssetCount == NSNotFound ? 0 : lhs.estimatedAssetCount
                let rCount = rhs.estimatedAssetCount == NSNotFound ? 0 : rhs.estimatedAssetCount
                return lCount > rCount
            }
        }
        return infos
    }

    // MARK: - Save

    private func save() {
        let orderedIDs: [String]
        if autoSortByCount {
            orderedIDs = selectedAlbumInfos.map(\.id)
        } else {
            orderedIDs = albumOrder
        }

        switch mode {
        case .create:
            let ctx = OrgContext(
                name: name.trimmingCharacters(in: .whitespaces),
                sourceKind: sourceKind,
                sourceAlbumLocalID: sourceKind == .album ? sourceAlbumLocalID : nil
            )
            ctx.albumLocalIDs = orderedIDs
            ctx.autoSortAlbumsByCount = autoSortByCount
            modelContext.insert(ctx)
        case .edit(let ctx):
            ctx.name = name.trimmingCharacters(in: .whitespaces)
            ctx.sourceKind = sourceKind
            ctx.sourceAlbumLocalID = sourceKind == .album ? sourceAlbumLocalID : nil
            ctx.albumLocalIDs = orderedIDs
            ctx.autoSortAlbumsByCount = autoSortByCount
        }
        try? modelContext.save()
        dismiss()
    }
}
