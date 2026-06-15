//
//  ContextListView.swift
//  Meme Vault
//
//  Context management screen: list of OrgContexts with create/edit/delete.
//  Presented as a sheet from RootView. The default context is pinned at the
//  top and cannot be deleted.
//

import SwiftUI
import SwiftData
import Photos

struct ContextListView: View {
    var onSelect: (OrgContext) -> Void = { _ in }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(PhotoLibrary.self) private var library

    @Query(sort: \OrgContext.createdAt, order: .reverse)
    private var contexts: [OrgContext]

    @State private var showingNewContext = false
    @State private var editingContext: OrgContext?

    @AppStorage("startupContextUUID") private var startupContextUUID = ""

    /// The default context, pinned at top.
    private var defaultContext: OrgContext? {
        contexts.first { $0.isDefault }
    }

    /// User-created contexts (everything except the default).
    private var userContexts: [OrgContext] {
        contexts.filter { !$0.isDefault }
    }

    var body: some View {
        NavigationStack {
            Group {
                if contexts.isEmpty {
                    ContentUnavailableView {
                        Label("No Contexts", systemImage: "square.stack.3d.up")
                    } description: {
                        Text("Create a context to organize photos by a specific set of albums.")
                    }
                } else {
                    contextList
                }
            }
            .navigationTitle("Contexts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingNewContext = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New Context")
                }
            }
            .sheet(isPresented: $showingNewContext) {
                ContextEditorView(mode: .create)
            }
            .sheet(item: $editingContext) { ctx in
                ContextEditorView(mode: .edit(ctx))
            }
        }
    }

    // MARK: - List

    private var contextList: some View {
        List {
            // Default context pinned at top
            if let defaultCtx = defaultContext {
                Section {
                    ContextRow(context: defaultCtx)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            onSelect(defaultCtx)
                        }
                        .swipeActions(edge: .trailing) {
                            Button {
                                editingContext = defaultCtx
                            } label: {
                                Label("Info", systemImage: "info.circle")
                            }
                            .tint(.blue)
                        }
                }
            }

            // User-created contexts
            if !userContexts.isEmpty {
                Section {
                    ForEach(userContexts) { ctx in
                        ContextRow(context: ctx)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                onSelect(ctx)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    if ctx.uuid.uuidString == startupContextUUID {
                                        startupContextUUID = defaultContext?.uuid.uuidString ?? ""
                                    }
                                    modelContext.delete(ctx)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                Button {
                                    editingContext = ctx
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                                .tint(.blue)
                            }
                    }
                }
            }

            Section {
                Picker("Open at Launch", selection: $startupContextUUID) {
                    ForEach(contexts) { ctx in
                        Text(ctx.name.isEmpty ? "Untitled" : ctx.name)
                            .tag(ctx.uuid.uuidString)
                    }
                    Text("Last Used").tag("lastUsed")
                }
            } footer: {
                Text("Choose which context to show when the app opens.")
            }
        }
    }
}

// MARK: - Row

private struct ContextRow: View {
    let context: OrgContext

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(context.name.isEmpty ? "Untitled" : context.name)
                .font(.headline)
            HStack(spacing: 8) {
                Label(sourceLabel, systemImage: sourceIcon)
                Text("·")
                Text(albumsLabel)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var sourceLabel: String {
        switch context.sourceKind {
        case .allPhotos: return "All Photos"
        case .album:
            if let id = context.sourceAlbumLocalID,
               let title = AlbumService.collection(for: id)?.localizedTitle {
                return title
            }
            return "Album"
        }
    }

    private var sourceIcon: String {
        switch context.sourceKind {
        case .allPhotos: return "photo.on.rectangle.angled"
        case .album:     return "rectangle.stack"
        }
    }

    private var albumsLabel: String {
        if context.isDefault {
            return "All Albums"
        }
        let count = context.albumLocalIDs.count
        return "\(count) album\(count == 1 ? "" : "s")"
    }
}
