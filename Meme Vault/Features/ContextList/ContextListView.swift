//
//  ContextListView.swift
//  Meme Vault
//
//  Root view: list of OrgContexts, plus entry to Trash and a "+" button to
//  create a new context. Gates everything behind PhotoKit authorization.
//  The default "Unsorted" context is auto-created and pinned at the top.
//

import SwiftUI
import SwiftData
import Photos

struct ContextListView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var library: PhotoLibrary

    @Query(sort: \OrgContext.createdAt, order: .reverse)
    private var contexts: [OrgContext]

    @Query private var pendingDeletes: [PendingDelete]

    @State private var showingNewContext = false
    @State private var editingContext: OrgContext?

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
                if !library.isAuthorized {
                    AuthorizationGate()
                } else if contexts.isEmpty {
                    EmptyStateView { showingNewContext = true }
                } else {
                    contextList
                }
            }
            .navigationTitle("Meme Vault")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        PendingDeletesView()
                    } label: {
                        let count = pendingDeletes.count
                        Label("Trash\(count > 0 ? " (\(count))" : "")",
                              systemImage: "trash")
                    }
                    .disabled(pendingDeletes.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingNewContext = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(!library.isAuthorized)
                }
            }
            .sheet(isPresented: $showingNewContext) {
                ContextEditorView(mode: .create)
            }
            .sheet(item: $editingContext) { ctx in
                ContextEditorView(mode: .edit(ctx))
            }
        }
        .task {
            await library.requestAuthorization()
            ensureDefaultContext()
        }
    }

    // MARK: - Default context auto-creation

    private func ensureDefaultContext() {
        guard library.isAuthorized else { return }
        if !contexts.contains(where: { $0.isDefault }) {
            let ctx = OrgContext(name: "Unsorted", sourceKind: .allPhotos, isDefault: true)
            // Populate album list from all user albums.
            let allAlbums = AlbumService.listUserAlbums()
            ctx.albumLocalIDs = allAlbums.map(\.id)
            modelContext.insert(ctx)
            try? modelContext.save()
        }
    }

    // MARK: - List

    private var contextList: some View {
        List {
            // Default context pinned at top
            if let defaultCtx = defaultContext {
                Section {
                    NavigationLink {
                        SortSessionView(context: defaultCtx)
                    } label: {
                        ContextRow(context: defaultCtx)
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
                        NavigationLink {
                            SortSessionView(context: ctx)
                        } label: {
                            ContextRow(context: ctx)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
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

// MARK: - Empty state

private struct EmptyStateView: View {
    let onCreate: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("No Contexts Yet", systemImage: "square.stack.3d.up")
        } description: {
            Text("Create a context to start sorting photos into albums.")
        } actions: {
            Button("Create Context", action: onCreate)
                .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - Authorization gate

private struct AuthorizationGate: View {
    @EnvironmentObject private var library: PhotoLibrary

    var body: some View {
        ContentUnavailableView {
            Label("Photo Access Needed", systemImage: "photo.badge.exclamationmark")
        } description: {
            Text("Meme Vault needs access to your photo library to organize your photos.")
        } actions: {
            switch library.authorization {
            case .notDetermined:
                Button("Grant Access") {
                    Task { await library.requestAuthorization() }
                }
                .buttonStyle(.borderedProminent)
            case .denied, .restricted:
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)
            default:
                EmptyView()
            }
        }
    }
}
