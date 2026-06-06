//
//  PhotoCollectionView.swift
//  Meme Vault
//
//  Shared grid view for browsing a photo collection. Three modes:
//  trashed photos, skipped photos (both SwiftData-backed), and the contents
//  of a Photos album (loaded asynchronously from the Photos library).
//  Supports tap-to-restore with confirmation, context-menu actions, and
//  animated removal.
//

import SwiftUI
import SwiftData
import Photos

struct AlbumSheetItem: Identifiable {
    let id: String
    let title: String
}

struct PhotoCollectionView: View {
    enum Mode: Identifiable {
        case trash
        case skipped(OrgContext)
        case album(AlbumSheetItem)

        var id: String {
            switch self {
            case .trash: "trash"
            case .skipped(let ctx): "skipped-\(ctx.uuid.uuidString)"
            case .album(let item): "album-\(item.id)"
            }
        }

        var isTrash: Bool {
            if case .trash = self { true } else { false }
        }

        var isAlbum: Bool {
            if case .album = self { true } else { false }
        }
    }

    let mode: Mode
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \PendingDelete.queuedAt, order: .reverse)
    private var pendingDeletes: [PendingDelete]

    @Query(sort: \PhotoSkip.skippedAt, order: .reverse)
    private var skips: [PhotoSkip]

    /// Asset IDs for `.album` mode, loaded off-main in `loadAlbumAssets()`.
    /// Unused by the SwiftData-backed modes.
    @State private var albumAssetIDs: [String] = []

    @State private var showRestoreAlert = false
    @State private var restoreAssetID: String?
    @State private var showRemoveAlert = false
    @State private var removeAssetID: String?
    @State private var isDeleting = false
    @State private var showError = false
    @State private var errorMessage: String?

    init(mode: Mode) {
        self.mode = mode
        if case .skipped(let context) = mode {
            let contextID = context.persistentModelID
            _skips = Query(
                filter: #Predicate { $0.context?.persistentModelID == contextID },
                sort: \PhotoSkip.skippedAt,
                order: .reverse
            )
        }
    }

    // MARK: - Derived state

    private var assetIDs: [String] {
        switch mode {
        case .trash: pendingDeletes.map(\.assetLocalID)
        case .skipped: skips.map(\.assetLocalID)
        case .album: albumAssetIDs
        }
    }

    private var navigationTitle: String {
        switch mode {
        case .trash: "Trash"
        case .skipped(let ctx): "\(ctx.name) - Skipped"
        case .album(let item): item.title
        }
    }

    private var emptyTitle: String {
        switch mode {
        case .trash: "Trash is Empty"
        case .skipped: "No Skipped Photos"
        case .album: "Empty Album"
        }
    }

    private var emptyIcon: String {
        switch mode {
        case .trash: "trash.slash"
        case .skipped: "checkmark"
        case .album: "photo.on.rectangle"
        }
    }

    private var emptyDescription: String {
        switch mode {
        case .trash: "Photos you queue for deletion will appear here."
        case .skipped: "Photos you skip in the sort queue will appear here."
        case .album: "This album has no photos."
        }
    }

    private var restoreLabel: String {
        mode.isTrash ? "Restore" : "Unskip"
    }

    // MARK: - Body

    var body: some View {
        // All modes are presented as sheets, so each provides its own
        // navigation chrome.
        NavigationStack { content }
    }

    @ViewBuilder
    private var content: some View {
        Group {
            if assetIDs.isEmpty {
                ContentUnavailableView(
                    emptyTitle,
                    systemImage: emptyIcon,
                    description: Text(emptyDescription)
                )
            } else {
                grid
            }
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done", action: dismiss.callAsFunction)
            }
            if mode.isTrash, !pendingDeletes.isEmpty {
                ToolbarItem(placement: .topBarLeading) {
                    Button(role: .destructive) {
                        Task { await emptyTrash() }
                    } label: {
                        if isDeleting { ProgressView() }
                        else { Text("Empty Trash") }
                    }
                    .disabled(isDeleting)
                }
            }
        }
        .task {
            if mode.isAlbum { await loadAlbumAssets() }
        }
        .alert(
            mode.isTrash ? "Restore Photo?" : "Unskip Photo?",
            isPresented: $showRestoreAlert
        ) {
            Button(restoreLabel) {
                if let id = restoreAssetID {
                    restore(assetID: id)
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(mode.isTrash
                 ? "This photo will be removed from the trash."
                 : "This photo will return to the sort queue.")
        }
        .alert("Remove from Album?", isPresented: $showRemoveAlert) {
            Button("Remove", role: .destructive) {
                if let id = removeAssetID {
                    Task { await removeFromAlbum(assetID: id) }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This photo will be removed from \"\(navigationTitle)\". It won't be deleted from your library.")
        }
        .alert(mode.isAlbum ? "Error" : "Couldn't delete", isPresented: $showError) { } message: {
            Text(errorMessage ?? "")
        }
    }

    private var grid: some View {
        PhotoGrid(assetIDs: assetIDs) { assetID in
            Button {
                primaryTap(assetID: assetID)
            } label: {
                ThumbnailCell(assetLocalID: assetID, showRestoreIndicator: mode.isTrash)
            }
            .buttonStyle(.plain)
            .contextMenu { menuItems(for: assetID) }
        }
    }

    /// The default tap action: remove-from-album for albums, restore for
    /// trash/skipped. Both surface a confirmation alert.
    private func primaryTap(assetID: String) {
        if mode.isAlbum {
            removeAssetID = assetID
            showRemoveAlert = true
        } else {
            restoreAssetID = assetID
            showRestoreAlert = true
        }
    }

    @ViewBuilder
    private func menuItems(for assetID: String) -> some View {
        if mode.isAlbum {
            Button("Remove from Album", systemImage: "minus.circle", role: .destructive) {
                removeAssetID = assetID
                showRemoveAlert = true
            }
            Button("Delete", systemImage: "trash", role: .destructive) {
                Task { await deletePhoto(assetID: assetID) }
            }
        } else {
            Button(restoreLabel, systemImage: "arrow.uturn.backward") {
                restore(assetID: assetID)
            }
            Button("Delete", systemImage: "trash", role: .destructive) {
                deleteItem(assetID: assetID)
            }
        }
    }

    // MARK: - Actions

    private func restore(assetID: String) {
        switch mode {
        case .trash:
            if let pd = pendingDeletes.first(where: { $0.assetLocalID == assetID }) {
                modelContext.delete(pd)
            }
        case .skipped:
            if let skip = skips.first(where: { $0.assetLocalID == assetID }) {
                modelContext.delete(skip)
            }
        case .album:
            break
        }
    }

    private func deleteItem(assetID: String) {
        switch mode {
        case .trash:
            if let pd = pendingDeletes.first(where: { $0.assetLocalID == assetID }) {
                Task { await permanentlyDelete(pd) }
            }
        case .skipped(let context):
            if let skip = skips.first(where: { $0.assetLocalID == assetID }) {
                let pd = PendingDelete(assetLocalID: skip.assetLocalID)
                pd.context = context
                modelContext.insert(pd)
                modelContext.delete(skip)
            }
        case .album:
            break
        }
    }

    private func permanentlyDelete(_ pd: PendingDelete) async {
        let assets = AlbumService.assets(for: [pd.assetLocalID])
        guard !assets.isEmpty else {
            modelContext.delete(pd)
            return
        }
        do {
            try await AlbumService.deleteAssets(assets)
            modelContext.delete(pd)
            try? modelContext.save()
        } catch {
            let nsErr = error as NSError
            if nsErr.code == 3072 { return }
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func emptyTrash() async {
        isDeleting = true
        defer { isDeleting = false }

        let ids = pendingDeletes.map(\.assetLocalID)
        let assets = AlbumService.assets(for: ids)
        guard !assets.isEmpty else {
            withAnimation {
                for pd in pendingDeletes { modelContext.delete(pd) }
            }
            try? modelContext.save()
            return
        }

        do {
            try await AlbumService.deleteAssets(assets)
            withAnimation {
                let deletedIDs = Set(assets.map(\.localIdentifier))
                for pd in pendingDeletes where deletedIDs.contains(pd.assetLocalID) {
                    modelContext.delete(pd)
                }
                let liveIDs = Set(assets.map(\.localIdentifier))
                for pd in pendingDeletes where !liveIDs.contains(pd.assetLocalID) {
                    modelContext.delete(pd)
                }
            }
            try? modelContext.save()
            Haptics.success()
        } catch {
            let nsErr = error as NSError
            if nsErr.code == 3072 { return }
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func loadAlbumAssets() async {
        guard case .album(let item) = mode else { return }
        // Enumerating a large album synchronously on the main actor freezes the
        // sheet on open (≈100–200 ms on a big library), so do it off-main and
        // hand back the plain (Sendable) IDs.
        let albumID = item.id
        let ids = await Task.detached(priority: .userInitiated) { () -> [String] in
            guard let collection = AlbumService.collection(for: albumID) else { return [] }
            let opts = PHFetchOptions()
            opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            let result = PHAsset.fetchAssets(in: collection, options: opts)
            var ids: [String] = []
            ids.reserveCapacity(result.count)
            result.enumerateObjects { asset, _, _ in
                ids.append(asset.localIdentifier)
            }
            return ids
        }.value
        albumAssetIDs = ids
    }

    /// Permanently delete an album photo from the Photos library. The OS
    /// presents its own delete confirmation, so no custom alert is needed
    /// (matching the trash/skipped delete path).
    private func deletePhoto(assetID: String) async {
        let assets = AlbumService.assets(for: [assetID])
        guard !assets.isEmpty else {
            withAnimation { albumAssetIDs.removeAll { $0 == assetID } }
            return
        }
        do {
            try await AlbumService.deleteAssets(assets)
            withAnimation { albumAssetIDs.removeAll { $0 == assetID } }
        } catch {
            let nsErr = error as NSError
            if nsErr.code == 3072 { return }  // user cancelled the system delete dialog
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func removeFromAlbum(assetID: String) async {
        guard case .album(let item) = mode,
              let asset = AlbumService.asset(for: assetID),
              let collection = AlbumService.collection(for: item.id) else { return }
        do {
            try await AlbumService.remove(asset, from: collection)
            withAnimation {
                albumAssetIDs.removeAll { $0 == assetID }
            }
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}
