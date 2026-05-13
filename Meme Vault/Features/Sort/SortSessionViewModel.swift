//
//  SortSessionViewModel.swift
//  Meme Vault
//
//  Drives the sort screen: holds the queue of unsorted assets for a context,
//  the current asset, applies user actions (toggle album, skip, delete), and
//  refreshes membership state.
//

import Foundation
import Photos
import SwiftData

@MainActor
@Observable
final class SortSessionViewModel {

    // MARK: - State

    private(set) var queue: [String] = []           // remaining asset localIDs
    private(set) var index: Int = 0                 // pointer into queue
    private(set) var totalAssetsInPool: Int = 0
    private(set) var isLoading: Bool = false

    /// Current asset (resolved from localID).
    private(set) var currentAsset: PHAsset?

    /// Per-album membership for the current asset.
    private(set) var memberships: [AlbumMembership] = []

    /// Recently-acted-on assets for undo of skip/delete.
    private(set) var lastAction: SortAction?

    /// When true, album taps don't auto-advance.
    var isMultiSelectActive: Bool = false

    /// Non-context albums selected via the "Other Albums" sheet for the current photo.
    var extraAlbumIDs: Set<String> = []

    /// Shown when the user tries to save with only extra (non-context) albums selected.
    var showExtraOnlyAlert: Bool = false

    enum SortAction {
        case skipped(localID: String)
        case queuedDelete(localID: String)
    }

    // MARK: - Dependencies

    let context: OrgContext
    private let modelContext: ModelContext
    private let evaluator = ContextEvaluator()

    init(context: OrgContext, modelContext: ModelContext) {
        self.context = context
        self.modelContext = modelContext
    }

    // MARK: - Lifecycle

    func start() async {
        // For the default context, refresh its album list from the full library.
        if context.isDefault {
            refreshDefaultAlbums()
        }
        await rebuildQueue()
    }

    /// Refreshes the default context's albumLocalIDs from all user albums.
    private func refreshDefaultAlbums() {
        let allAlbums = AlbumService.listUserAlbums()
        context.albumLocalIDs = allAlbums.map(\.id)
        try? modelContext.save()
    }

    /// Recomputes the queue from PhotoKit + skip/pending-delete state.
    func rebuildQueue() async {
        isLoading = true
        evaluator.invalidate()

        // Refresh default context albums on every rebuild (handles external changes).
        if context.isDefault {
            refreshDefaultAlbums()
        }

        let pool = AssetSource.queue(for: context)
        totalAssetsInPool = pool.count

        let skipIDs = Set(context.skips.map(\.assetLocalID))
        let deleteIDs = Set(context.pendingDeletes.map(\.assetLocalID))

        // Filter out already-satisfied / skipped / pending-delete assets.
        var remaining: [String] = []
        remaining.reserveCapacity(pool.count)
        let allLocalIDs = pool.assetLocalIDs

        // Resolve PHAssets in one fetch for efficiency.
        let assets = AlbumService.assets(for: allLocalIDs)
        let assetsByID = Dictionary(uniqueKeysWithValues: assets.map { ($0.localIdentifier, $0) })

        let activeID = currentAssetID
        for id in allLocalIDs {
            if skipIDs.contains(id) || deleteIDs.contains(id) { continue }
            guard let asset = assetsByID[id] else { continue }
            if !evaluator.isSatisfied(asset, in: context) {
                remaining.append(id)
            } else if isMultiSelectActive && id == activeID {
                remaining.append(id)
            }
        }

        self.queue = remaining
        if let activeID, let newIndex = remaining.firstIndex(of: activeID) {
            self.index = newIndex
        } else {
            self.index = 0
        }
        self.isLoading = false
        refreshCurrent()
    }

    // MARK: - Current asset

    private func refreshCurrent() {
        guard index < queue.count else {
            currentAsset = nil
            memberships = []
            extraAlbumIDs = []
            return
        }
        let id = queue[index]
        let newAsset = AlbumService.asset(for: id)
        if newAsset?.localIdentifier != currentAsset?.localIdentifier {
            extraAlbumIDs = []
        }
        currentAsset = newAsset
        recomputeMemberships()
    }

    func recomputeMemberships() {
        guard let asset = currentAsset else { memberships = []; return }
        var result = evaluator.albumMemberships(for: asset, in: context)
        for albumID in extraAlbumIDs {
            if let collection = AlbumService.collection(for: albumID) {
                let isMember = AlbumService.isAsset(asset, memberOf: collection)
                result.append(AlbumMembership(id: albumID, isMember: isMember))
            }
        }
        memberships = result
    }

    var isSatisfied: Bool {
        guard !memberships.isEmpty else { return false }
        return memberships.contains(where: \.isMember)
    }

    private var isSatisfiedByContextAlbum: Bool {
        let contextIDs = Set(context.albumLocalIDs)
        return memberships.contains { contextIDs.contains($0.id) && $0.isMember }
    }

    /// Local ID of the asset currently shown — drives the carousel's page.
    var currentAssetID: String? {
        index < queue.count ? queue[index] : nil
    }

    /// Jump to the asset with the given local ID. Called when the user pages
    /// the carousel; no-op if the ID isn't in the queue or is already current.
    func showAsset(id: String) {
        guard let target = queue.firstIndex(of: id), target != index else { return }
        index = target
        refreshCurrent()
    }

    var progressText: String {
        let done = max(0, totalAssetsInPool - queue.count + index)
        return "\(done + 1) of \(totalAssetsInPool)"
    }

    // MARK: - Album toggling

    /// Toggle the current asset's membership in the given album.
    func toggleAlbum(_ albumLocalID: String) async {
        guard let asset = currentAsset,
              let collection = AlbumService.collection(for: albumLocalID) else { return }
        let isMember = AlbumService.isAsset(asset, memberOf: collection)
        let wasSatisfied = isSatisfied
        do {
            if isMember {
                try await AlbumService.remove(asset, from: collection)
                evaluator.noteRemoved(asset: asset.localIdentifier, from: albumLocalID)
                recomputeMemberships()
                Haptics.tap()
            } else {
                try await AlbumService.add(asset, to: collection)
                evaluator.noteAdded(asset: asset.localIdentifier, to: albumLocalID)
                if !isMultiSelectActive && !wasSatisfied {
                    let newMemberships = evaluator.albumMemberships(for: asset, in: context)
                    if newMemberships.contains(where: \.isMember) {
                        Haptics.tap()
                        await advance(removingCurrent: true)
                        return
                    }
                }
                recomputeMemberships()
                Haptics.tap()
            }
        } catch {
            Haptics.warning()
            print("toggleAlbum failed: \(error)")
        }
    }

    func deactivateMultiSelect() async {
        if isSatisfied && !isSatisfiedByContextAlbum {
            showExtraOnlyAlert = true
            return
        }
        isMultiSelectActive = false
        if isSatisfied {
            await advance(removingCurrent: true)
        }
    }

    func skipFromExtraOnlyAlert() async {
        showExtraOnlyAlert = false
        isMultiSelectActive = false
        await skip()
    }

    func dismissExtraOnlyAlert() {
        showExtraOnlyAlert = false
    }

    // MARK: - Advance / back

    /// Advance to the next asset. Removes the current asset from the queue if
    /// `removeCurrent` is true (used after satisfy / skip / delete).
    func advance(removingCurrent removeCurrent: Bool) async {
        if removeCurrent && index < queue.count {
            queue.remove(at: index)
            // index now points at the next asset (if any) — no increment needed.
        } else {
            index += 1
        }
        refreshCurrent()
    }

    func back() async {
        guard index > 0 else { return }
        index -= 1
        refreshCurrent()
    }

    // MARK: - Skip

    func skip() async {
        guard let asset = currentAsset else { return }
        let id = asset.localIdentifier
        let skip = PhotoSkip(assetLocalID: id)
        skip.context = context
        modelContext.insert(skip)
        try? modelContext.save()
        lastAction = .skipped(localID: id)
        Haptics.swipe()
        await advance(removingCurrent: true)
    }

    func undoSkip() async {
        guard case .skipped(let id) = lastAction else { return }
        // Find the matching PhotoSkip and delete it.
        if let row = context.skips.first(where: { $0.assetLocalID == id }) {
            modelContext.delete(row)
            try? modelContext.save()
        }
        // Put it back in the queue at the current index.
        queue.insert(id, at: index)
        lastAction = nil
        refreshCurrent()
    }

    // MARK: - Delete (queue)

    func queueDelete() async {
        guard let asset = currentAsset else { return }
        let id = asset.localIdentifier
        let pd = PendingDelete(assetLocalID: id)
        pd.context = context
        modelContext.insert(pd)
        try? modelContext.save()
        lastAction = .queuedDelete(localID: id)
        Haptics.warning()
        await advance(removingCurrent: true)
    }

    func undoQueueDelete() async {
        guard case .queuedDelete(let id) = lastAction else { return }
        if let row = context.pendingDeletes.first(where: { $0.assetLocalID == id }) {
            modelContext.delete(row)
            try? modelContext.save()
        }
        queue.insert(id, at: index)
        lastAction = nil
        refreshCurrent()
    }

    // MARK: - PhotoKit change handling

    /// Called when the photo library reports external changes. Rebuilds queue.
    func handleLibraryChange() async {
        await rebuildQueue()
    }
}
