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
    @Environment(PhotoLibrary.self) private var library
    @Environment(\.scenePhase) private var scenePhase

    @Query(sort: \OrgContext.createdAt, order: .reverse)
    private var contexts: [OrgContext]

    @State private var showingContextList = false
    @State private var photoMode: PhotoCollectionView.Mode?
    @State private var showingDebugConfirm = false
    @State private var debugMessage: String?
    @State private var sessionResetTick = 0
    @State private var selectedContext: OrgContext?
    @State private var pendingContext: OrgContext?

    @AppStorage("startupContextUUID") private var startupContextUUID = ""
    @AppStorage("lastUsedContextUUID") private var lastUsedContextUUID = ""

    private var fallbackContext: OrgContext? {
        contexts.first { $0.isDefault } ?? contexts.first
    }

    /// The primary context to show, respecting the user's startup preference.
    private var primaryContext: OrgContext? {
        if startupContextUUID == "lastUsed" {
            return contexts.first { $0.uuid.uuidString == lastUsedContextUUID } ?? fallbackContext
        }
        if !startupContextUUID.isEmpty {
            return contexts.first { $0.uuid.uuidString == startupContextUUID } ?? fallbackContext
        }
        return fallbackContext
    }

    /// Debug "clear albums" action surfaced in the UIKit nav bar — only on the
    /// simulator in DEBUG builds, nil otherwise.
    private var debugClearAction: (() -> Void)? {
        #if DEBUG
        if ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] != nil {
            return { showingDebugConfirm = true }
        }
        #endif
        return nil
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
                    SortSessionView(
                        context: ctx,
                        onShowContextList: { showingContextList = true },
                        onShowTrash: { photoMode = .trash },
                        onShowSkipped: { photoMode = .skipped(ctx) },
                        onDebugClear: debugClearAction
                    )
                    .id("\(ctx.uuid.uuidString)-\(sessionResetTick)")
                } else {
                    // No contexts yet — will be created momentarily by .task
                    ProgressView("Setting up…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .toolbar {
                ToolbarBadges(
                    context: displayedContext,
                    onShowContextList: { showingContextList = true },
                    onSelectMode: { photoMode = $0 }
                )
                
                #if DEBUG
                ToolbarItem(placement: .topBarLeading) {
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
            .sheet(item: $photoMode) { mode in
                PhotoCollectionView(mode: mode)
            }
            .alert("Debug: Clear Album Membership", isPresented: $showingDebugConfirm) {
                #if DEBUG
                Button("Remove All", role: .destructive) {
                    Task { await debugClearAlbums() }
                }
                #endif
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
        .onChange(of: displayedContext?.uuid, initial: true) { _, newUUID in
            if let uuid = newUUID {
                lastUsedContextUUID = uuid.uuidString
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // Pick up an access change made in Settings (e.g. Limited → Full) when
            // the user returns, so the gate clears without a relaunch.
            if phase == .active {
                library.refreshAuthorizationStatus()
                ensureDefaultContext()
            }
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
            startupContextUUID = ctx.uuid.uuidString
        } else if startupContextUUID.isEmpty {
            if let defaultCtx = contexts.first(where: { $0.isDefault }) {
                startupContextUUID = defaultCtx.uuid.uuidString
            }
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
            sessionResetTick += 1
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

// MARK: - Toolbar badges (isolated from RootView to avoid @Query churn)

private struct ToolbarBadges: ToolbarContent {
    let context: OrgContext?
    let onShowContextList: () -> Void
    let onSelectMode: (PhotoCollectionView.Mode) -> Void

    @Query private var pendingDeletes: [PendingDelete]

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { onShowContextList() } label: {
                Image(systemName: "list.bullet")
            }
            .accessibilityLabel("Contexts")
        }

        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Button {
                    onSelectMode(.trash)
                } label: {
                    let count = pendingDeletes.count
                    Label("Trash\(count > 0 ? " (\(count))" : "")",
                          systemImage: "trash")
                }
                .disabled(pendingDeletes.isEmpty)

                Button {
                    if let context {
                        onSelectMode(.skipped(context))
                    }
                } label: {
                    let count = context?.skips.count ?? 0
                    Label("Skipped\(count > 0 ? " (\(count))" : "")",
                          systemImage: "checkmark.circle")
                }
                .disabled(context?.skips.isEmpty ?? true)
            } label: {
                Label("More", systemImage: "ellipsis")
            }
        }
    }
}

// MARK: - Authorization gate (reusable)

private struct AuthorizationGateView: View {
    @Environment(PhotoLibrary.self) private var library

    /// Why access is needed, tailored to the current status. Full access is
    /// required because sorting into existing albums means the app must be able to
    /// see every album — limited access exposes only hand-picked photos and no albums.
    private var explanation: String {
        switch library.authorization {
        case .limited:
            return "Meme Vault sorts your photos into your existing albums, so it needs to see your whole library. “Limited” access hides your albums, so the app can't work. Please choose Full Access in Settings."
        case .denied, .restricted:
            return "Meme Vault sorts your photos into your existing albums, so it needs full access to your photo library. Please allow Full Access in Settings."
        default:
            return "Meme Vault sorts your photos into your existing albums, so it needs full access to your photo library."
        }
    }

    var body: some View {
        ContentUnavailableView {
            Label("Full Photo Access Needed", systemImage: "photo.badge.exclamationmark")
        } description: {
            VStack(spacing: 14) {
                Text(explanation)
                Label {
                    Text("Your photos never leave your device. Meme Vault doesn't collect, upload, or share any of your photos or data.")
                } icon: {
                    Image(systemName: "lock.fill")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
        } actions: {
            switch library.authorization {
            case .notDetermined:
                Button("Grant Access") {
                    Task { await library.requestAuthorization() }
                }
                .buttonStyle(.borderedProminent)
            case .limited, .denied, .restricted:
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
