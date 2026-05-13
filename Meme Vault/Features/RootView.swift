//
//  RootView.swift
//  Meme Vault
//
//  The app's primary view. Shows the sort session for the default context
//  (or first available context) as the landing screen. Provides navigation
//  to the full context list, trash, and debug tools.
//

import SwiftUI
import SwiftData
import Photos

struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var library: PhotoLibrary

    @Query(sort: \OrgContext.createdAt, order: .reverse)
    private var contexts: [OrgContext]

    @Query private var pendingDeletes: [PendingDelete]

    @State private var showingContextList = false
    @State private var showingDebugConfirm = false
    @State private var debugMessage: String?
    @State private var selectedContext: OrgContext?
    @State private var pendingContext: OrgContext?

    /// The primary context to show: default first, otherwise the first available.
    private var primaryContext: OrgContext? {
        contexts.first { $0.isDefault } ?? contexts.first
    }

    /// The context currently on screen: explicit selection, or the primary default.
    private var displayedContext: OrgContext? {
        if let selected = selectedContext,
           contexts.contains(where: { $0.persistentModelID == selected.persistentModelID }) {
            return selected
        }
        return primaryContext
    }

    var body: some View {
        NavigationStack {
            Group {
                if !library.isAuthorized {
                    AuthorizationGateView()
                } else if let ctx = displayedContext {
                    SortSessionView(context: ctx)
                        .id(ctx.persistentModelID)
                } else {
                    // No contexts yet — will be created momentarily by .task
                    ProgressView("Setting up…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 12) {
                        Button {
                            showingContextList = true
                        } label: {
                            Image(systemName: "list.bullet")
                        }
                        NavigationLink {
                            PendingDeletesView()
                        } label: {
                            let count = pendingDeletes.count
                            Label("Trash\(count > 0 ? " (\(count))" : "")",
                                  systemImage: "trash")
                        }
                        .disabled(pendingDeletes.isEmpty)
                    }
                }
                #if DEBUG
                ToolbarItem(placement: .topBarTrailing) {
                    if isSimulator {
                        Menu {
                            Button(role: .destructive) {
                                showingDebugConfirm = true
                            } label: {
                                Label("Remove All Photos from Albums", systemImage: "xmark.bin")
                            }
                        } label: {
                            Image(systemName: "ladybug")
                                .foregroundStyle(.orange)
                        }
                    }
                }
                #endif
            }
            .sheet(isPresented: $showingContextList, onDismiss: {
                if let pending = pendingContext {
                    selectedContext = pending
                    pendingContext = nil
                }
            }) {
                ContextListView(onSelect: { context in
                    pendingContext = context
                    showingContextList = false
                })
            }
            .alert("Debug: Clear Album Membership", isPresented: $showingDebugConfirm) {
                Button("Remove All", role: .destructive) {
                    Task { await debugClearAlbums() }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This will remove every photo from every album and clear all skipped photos. Photos will NOT be deleted. This cannot be undone.")
            }
            .overlay {
                if let msg = debugMessage {
                    Text(msg)
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .transition(.opacity)
                }
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
            let allAlbums = AlbumService.listUserAlbums()
            ctx.albumLocalIDs = allAlbums.map(\.id)
            modelContext.insert(ctx)
            try? modelContext.save()
        }
    }

    // MARK: - Debug

    #if DEBUG
    private var isSimulator: Bool {
        ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] != nil
    }

    private func debugClearAlbums() async {
        do {
            try await AlbumService.debugRemoveAllAssetsFromAllAlbums()
            // Also clear all skips across all contexts
            for context in contexts {
                for skip in context.skips {
                    modelContext.delete(skip)
                }
            }
            try? modelContext.save()
            debugMessage = "Album memberships & skips cleared"
        } catch {
            debugMessage = "Failed: \(error.localizedDescription)"
        }
        // Auto-dismiss after 2 seconds
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        debugMessage = nil
    }
    #endif
}

// MARK: - Authorization gate (reusable)

private struct AuthorizationGateView: View {
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
