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
import SwiftUI

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

    /// Whether the current asset is favorited.
    private(set) var isFavorite: Bool = false

    /// Per-album membership for the current asset.
    private(set) var memberships: [AlbumMembership] = []

    /// Recently-acted-on assets for undo of skip/delete.
    private(set) var lastAction: SortAction?

    /// When true, album taps don't auto-advance.
    var isMultiSelectActive: Bool = false

    /// Bulk sort mode: select multiple photos, then tap an album to add them all.
    private(set) var isBulkMode: Bool = false
    private(set) var bulkSelectedIDs: Set<String> = []

    /// Non-context albums selected via the "Other Albums" sheet for the current photo.
    private(set) var extraAlbumIDs: Set<String> = []

    /// Shown when the user tries to save with only extra (non-context) albums selected.
    var showExtraOnlyAlert: Bool = false

    /// Cached snapshot of the context's destination albums. Recomputed on
    /// queue rebuild (and on explicit refresh). Per-tap toggles patch this
    /// list locally so the album grid doesn't have to re-fetch from PhotoKit.
    private(set) var albumInfos: [AlbumInfo] = []

    /// Cached snapshot of extra (non-context) albums currently surfaced in
    /// the grid for the active asset.
    private(set) var extraAlbumInfos: [AlbumInfo] = []

    /// Cached snapshot of pinned (non-destination) albums. Always visible in
    /// the sort grid with reduced opacity.
    private(set) var pinnedAlbumInfos: [AlbumInfo] = []

    /// Per-album refresh versions. The album grid cell observes the version
    /// for its own album only — so a tap on one album doesn't force every
    /// other cell to reload its thumbnails.
    private(set) var albumRefreshVersions: [String: Int] = [:]

    enum SortAction {
        case sorted(localID: String, albumID: String)
        case sortedMulti(localID: String, adds: [String], removes: [String])
        case skipped(localID: String)
        case queuedDelete(localID: String)
        /// addedByAlbum: albumID -> [photoIDs added], removedByAlbum: albumID -> [photoIDs removed]
        case bulkSorted(addedByAlbum: [String: [String]], removedByAlbum: [String: [String]], removedFromQueue: [String])
        case bulkSkipped(localIDs: [String])
        case bulkDeleted(localIDs: [String])
    }

    var canUndo: Bool { lastAction != nil }

    /// Albums pending addition in multi-select mode (committed on deactivate).
    private(set) var multiSelectAdds: Set<String> = []
    /// Albums pending removal in multi-select mode (committed on deactivate).
    private(set) var multiSelectRemoves: Set<String> = []

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
        let newIDs = allAlbums.map(\.id)
        guard newIDs != context.albumLocalIDs else { return }
        context.albumLocalIDs = newIDs
        try? modelContext.save()
    }

    /// Recomputes the queue from PhotoKit + skip/pending-delete state.
    /// Full rebuild: invalidates evaluator cache, re-fetches source pool, and
    /// refreshes album metadata. Used on first load, context edit, and view
    /// reappear.
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

        let activeID = currentAssetID
        for id in allLocalIDs {
            if skipIDs.contains(id) || deleteIDs.contains(id) { continue }
            if !evaluator.isSatisfied(assetID: id, in: context) {
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

        // Refresh cached album metadata (counts, titles) — done here rather
        // than on every body recomputation so per-tap renders stay cheap.
        refreshAlbumInfos()
        refreshPinnedAlbumInfos()
        refreshExtraAlbumInfos()

        self.isLoading = false
        refreshCurrent()
    }

    /// Rebuilds the cached `albumInfos` from PhotoKit. Heavy — does one fetch
    /// per destination album to read its count — so it's only called on
    /// queue rebuild or after an external library change.
    private func refreshAlbumInfos() {
        let collections = AlbumService.collections(for: context.albumLocalIDs)
        let byID = Dictionary(uniqueKeysWithValues: collections.map {
            ($0.localIdentifier, AlbumInfo(collection: $0))
        })
        var infos = context.albumLocalIDs.compactMap { byID[$0] }
        if context.autoSortAlbumsByCount {
            infos.sort { $0.assetCount > $1.assetCount }
        }
        albumInfos = infos
    }

    private func refreshPinnedAlbumInfos() {
        let contextIDs = Set(context.albumLocalIDs)
        let ids = context.pinnedAlbumLocalIDs.filter { !contextIDs.contains($0) }
        guard !ids.isEmpty else {
            pinnedAlbumInfos = []
            return
        }
        let collections = AlbumService.collections(for: ids)
        let byID = Dictionary(uniqueKeysWithValues: collections.map {
            ($0.localIdentifier, AlbumInfo(collection: $0))
        })
        pinnedAlbumInfos = ids.compactMap { byID[$0] }
    }

    private func refreshExtraAlbumInfos() {
        guard !extraAlbumIDs.isEmpty else {
            extraAlbumInfos = []
            return
        }
        let collections = AlbumService.collections(for: Array(extraAlbumIDs))
        extraAlbumInfos = collections.map { AlbumInfo(collection: $0) }
    }

    // MARK: - Current asset

    private func refreshCurrent() {
        guard index < queue.count else {
            currentAsset = nil
            memberships = []
            extraAlbumIDs = []
            extraAlbumInfos = []
            multiSelectAdds = []
            multiSelectRemoves = []
            return
        }
        let id = queue[index]
        let newAsset = AlbumService.asset(for: id)
        if newAsset?.localIdentifier != currentAsset?.localIdentifier {
            extraAlbumIDs = []
            extraAlbumInfos = []
            multiSelectAdds = []
            multiSelectRemoves = []
        }
        currentAsset = newAsset
        isFavorite = newAsset?.isFavorite ?? false
        recomputeMemberships()
    }

    func recomputeMemberships() {
        guard let asset = currentAsset else {
            if !memberships.isEmpty { memberships = [] }
            return
        }
        var result = evaluator.albumMemberships(for: asset, in: context)
        var seen = Set(result.map(\.id))
        for albumID in context.pinnedAlbumLocalIDs where !seen.contains(albumID) {
            let isMember = evaluator.members(of: albumID).contains(asset.localIdentifier)
            result.append(AlbumMembership(id: albumID, isMember: isMember))
            seen.insert(albumID)
        }
        for albumID in extraAlbumIDs where !seen.contains(albumID) {
            let isMember = evaluator.members(of: albumID).contains(asset.localIdentifier)
            result.append(AlbumMembership(id: albumID, isMember: isMember))
        }
        if isMultiSelectActive {
            result = result.map { m in
                if multiSelectAdds.contains(m.id) {
                    return AlbumMembership(id: m.id, isMember: true)
                } else if multiSelectRemoves.contains(m.id) {
                    return AlbumMembership(id: m.id, isMember: false)
                }
                return m
            }
        }
        if result != memberships {
            memberships = result
        }
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

    // MARK: - Favorite

    func toggleFavorite() async {
        guard let asset = currentAsset else { return }
        let newValue = !isFavorite
        do {
            try await AlbumService.performFavorite(asset: asset, favorite: newValue)
            isFavorite = newValue
            Haptics.tap()
        } catch {
            Haptics.warning()
        }
    }

    // MARK: - Album toggling

    /// Toggle the current asset's membership in the given album.
    func toggleAlbum(_ albumLocalID: String) async {
        guard let asset = currentAsset else { return }

        if isMultiSelectActive {
            toggleAlbumPending(albumLocalID, asset: asset)
            return
        }

        guard let collection = AlbumService.collection(for: albumLocalID) else { return }
        let isMember = memberships.first { $0.id == albumLocalID }?.isMember
            ?? evaluator.members(of: albumLocalID).contains(asset.localIdentifier)
        let wasSatisfied = isSatisfied
        do {
            if isMember {
                try await AlbumService.remove(asset, from: collection, assumeMember: true)
                evaluator.noteRemoved(asset: asset.localIdentifier, from: albumLocalID)
                applyLocalMembershipChange(albumID: albumLocalID, delta: -1)
                recomputeMemberships()
                Haptics.tap()
            } else {
                try await AlbumService.add(asset, to: collection, assumeNotMember: true)
                evaluator.noteAdded(asset: asset.localIdentifier, to: albumLocalID)
                applyLocalMembershipChange(albumID: albumLocalID, delta: +1)
                if !wasSatisfied {
                    let newMemberships = evaluator.albumMemberships(for: asset, in: context)
                    if newMemberships.contains(where: \.isMember) {
                        lastAction = .sorted(localID: asset.localIdentifier, albumID: albumLocalID)
                        Haptics.tap()
                        advance(removingCurrent: true)
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

    /// In multi-select mode, toggle pending state without writing to PhotoKit.
    private func toggleAlbumPending(_ albumLocalID: String, asset: PHAsset) {
        let actuallyMember = evaluator.members(of: albumLocalID).contains(asset.localIdentifier)
        if actuallyMember {
            if multiSelectRemoves.contains(albumLocalID) {
                multiSelectRemoves.remove(albumLocalID)
            } else {
                multiSelectRemoves.insert(albumLocalID)
            }
        } else {
            if multiSelectAdds.contains(albumLocalID) {
                multiSelectAdds.remove(albumLocalID)
            } else {
                multiSelectAdds.insert(albumLocalID)
            }
        }
        recomputeMemberships()
        Haptics.tap()
    }

    /// Patch cached album metadata after a successful add/remove. Bumps the
    /// per-album refresh version (so only that one cell reloads thumbnails)
    /// and updates the cached count locally.
    private func applyLocalMembershipChange(albumID: String, delta: Int) {
        albumRefreshVersions[albumID, default: 0] &+= 1
        if let i = albumInfos.firstIndex(where: { $0.id == albumID }) {
            albumInfos[i] = albumInfos[i].adjustingCount(by: delta)
            if context.autoSortAlbumsByCount {
                albumInfos.sort { $0.assetCount > $1.assetCount }
            }
        }
        if let i = pinnedAlbumInfos.firstIndex(where: { $0.id == albumID }) {
            pinnedAlbumInfos[i] = pinnedAlbumInfos[i].adjustingCount(by: delta)
        }
        if let i = extraAlbumInfos.firstIndex(where: { $0.id == albumID }) {
            extraAlbumInfos[i] = extraAlbumInfos[i].adjustingCount(by: delta)
        }
    }

    func activateMultiSelect() {
        isMultiSelectActive = true
        let contextIDs = Set(context.albumLocalIDs)
        let pinnedIDs = Set(context.pinnedAlbumLocalIDs)
        let allAlbums = AlbumService.listUserAlbums()
        let nonContext = allAlbums.filter {
            !contextIDs.contains($0.id) && !pinnedIDs.contains($0.id)
        }
        for album in nonContext {
            extraAlbumIDs.insert(album.id)
        }
        extraAlbumInfos = nonContext
        recomputeMemberships()
    }

    func deactivateMultiSelect() async {
        if isBulkMode {
            await commitBulkMultiSelect()
            return
        }

        guard let asset = currentAsset else {
            multiSelectAdds = []
            multiSelectRemoves = []
            isMultiSelectActive = false
            extraAlbumIDs = []
            extraAlbumInfos = []
            return
        }

        let adds = multiSelectAdds
        let removes = multiSelectRemoves
        let hasChanges = !adds.isEmpty || !removes.isEmpty

        if hasChanges && isSatisfied && !isSatisfiedByContextAlbum {
            showExtraOnlyAlert = true
            return
        }

        // Commit all pending changes to PhotoKit.
        for albumID in adds {
            guard let collection = AlbumService.collection(for: albumID) else { continue }
            do {
                try await AlbumService.add(asset, to: collection, assumeNotMember: true)
                evaluator.noteAdded(asset: asset.localIdentifier, to: albumID)
                applyLocalMembershipChange(albumID: albumID, delta: +1)
            } catch {}
        }
        for albumID in removes {
            guard let collection = AlbumService.collection(for: albumID) else { continue }
            do {
                try await AlbumService.remove(asset, from: collection, assumeMember: true)
                evaluator.noteRemoved(asset: asset.localIdentifier, from: albumID)
                applyLocalMembershipChange(albumID: albumID, delta: -1)
            } catch {}
        }

        multiSelectAdds = []
        multiSelectRemoves = []
        isMultiSelectActive = false

        // Keep only extras the asset is actually a member of after commit.
        let assetID = asset.localIdentifier
        let contextIDs = Set(context.albumLocalIDs)
        extraAlbumIDs = extraAlbumIDs.filter { albumID in
            !contextIDs.contains(albumID) &&
            evaluator.members(of: albumID).contains(assetID)
        }
        refreshExtraAlbumInfos()
        recomputeMemberships()

        if hasChanges && isSatisfied {
            lastAction = .sortedMulti(
                localID: asset.localIdentifier,
                adds: Array(adds),
                removes: Array(removes)
            )
            Haptics.tap()
            advance(removingCurrent: true)
        }
    }

    private func commitBulkMultiSelect() async {
        let selected = bulkSelectedIDs
        let adds = multiSelectAdds
        let removes = multiSelectRemoves

        multiSelectAdds = []
        multiSelectRemoves = []
        isMultiSelectActive = false
        extraAlbumIDs = []
        extraAlbumInfos = []

        guard !selected.isEmpty, !adds.isEmpty || !removes.isEmpty else {
            recomputeMemberships()
            return
        }

        var addedByAlbum: [String: [String]] = [:]
        var removedByAlbum: [String: [String]] = [:]

        for albumID in adds {
            guard let collection = AlbumService.collection(for: albumID) else { continue }
            let members = evaluator.members(of: albumID)
            var added: [String] = []
            for photoID in selected {
                if members.contains(photoID) { continue }
                guard let asset = AlbumService.asset(for: photoID) else { continue }
                do {
                    try await AlbumService.add(asset, to: collection, assumeNotMember: true)
                    evaluator.noteAdded(asset: photoID, to: albumID)
                    added.append(photoID)
                } catch {}
            }
            if !added.isEmpty {
                addedByAlbum[albumID] = added
                applyLocalMembershipChange(albumID: albumID, delta: added.count)
            }
        }

        for albumID in removes {
            guard let collection = AlbumService.collection(for: albumID) else { continue }
            let members = evaluator.members(of: albumID)
            var removed: [String] = []
            for photoID in selected {
                if !members.contains(photoID) { continue }
                guard let asset = AlbumService.asset(for: photoID) else { continue }
                do {
                    try await AlbumService.remove(asset, from: collection, assumeMember: true)
                    evaluator.noteRemoved(asset: photoID, from: albumID)
                    removed.append(photoID)
                } catch {}
            }
            if !removed.isEmpty {
                removedByAlbum[albumID] = removed
                applyLocalMembershipChange(albumID: albumID, delta: -removed.count)
            }
        }

        var removedFromQueue: [String] = []
        for id in selected {
            if evaluator.isSatisfied(assetID: id, in: context) {
                removedFromQueue.append(id)
            }
        }

        if !removedFromQueue.isEmpty {
            let removedSet = Set(removedFromQueue)
            withAnimation(.easeInOut(duration: 0.3)) {
                queue.removeAll { removedSet.contains($0) }
            }
            if index >= queue.count { index = max(0, queue.count - 1) }
            bulkSelectedIDs.subtract(removedFromQueue)
        }

        lastAction = .bulkSorted(
            addedByAlbum: addedByAlbum,
            removedByAlbum: removedByAlbum,
            removedFromQueue: removedFromQueue
        )
        Haptics.success()
        recomputeMemberships()
        refreshCurrent()
    }

    func skipFromExtraOnlyAlert() async {
        showExtraOnlyAlert = false
        multiSelectAdds = []
        multiSelectRemoves = []
        isMultiSelectActive = false
        extraAlbumIDs = []
        extraAlbumInfos = []
        await skip()
    }

    func dismissExtraOnlyAlert() {
        showExtraOnlyAlert = false
    }

    // MARK: - Bulk sort mode

    func enterBulkMode() {
        if isMultiSelectActive {
            multiSelectAdds = []
            multiSelectRemoves = []
            isMultiSelectActive = false
            extraAlbumIDs = []
            extraAlbumInfos = []
        }
        isBulkMode = true
        bulkSelectedIDs = []
    }

    func exitBulkMode() {
        isBulkMode = false
        bulkSelectedIDs = []
        if isMultiSelectActive {
            multiSelectAdds = []
            multiSelectRemoves = []
            isMultiSelectActive = false
            extraAlbumIDs = []
            extraAlbumInfos = []
        }
        refreshCurrent()
    }

    func toggleBulkSelection(_ id: String) {
        if bulkSelectedIDs.contains(id) {
            bulkSelectedIDs.remove(id)
        } else {
            bulkSelectedIDs.insert(id)
        }
        Haptics.tap()
    }

    func bulkSortToAlbum(_ albumID: String) async {
        let selected = bulkSelectedIDs
        guard !selected.isEmpty else { return }
        guard let collection = AlbumService.collection(for: albumID) else { return }

        let members = evaluator.members(of: albumID)
        var addedIDs: [String] = []

        for id in selected {
            if members.contains(id) { continue }
            guard let asset = AlbumService.asset(for: id) else { continue }
            do {
                try await AlbumService.add(asset, to: collection, assumeNotMember: true)
                evaluator.noteAdded(asset: id, to: albumID)
                addedIDs.append(id)
            } catch {}
        }

        if !addedIDs.isEmpty {
            applyLocalMembershipChange(albumID: albumID, delta: addedIDs.count)
        }

        var removedIDs: [String] = []
        for id in selected {
            if evaluator.isSatisfied(assetID: id, in: context) {
                removedIDs.append(id)
            }
        }

        if !removedIDs.isEmpty {
            let removedSet = Set(removedIDs)
            withAnimation(.easeInOut(duration: 0.3)) {
                queue.removeAll { removedSet.contains($0) }
            }
            if index >= queue.count { index = max(0, queue.count - 1) }
        }

        bulkSelectedIDs.subtract(removedIDs)

        lastAction = .bulkSorted(
            addedByAlbum: addedIDs.isEmpty ? [:] : [albumID: addedIDs],
            removedByAlbum: [:],
            removedFromQueue: removedIDs
        )
        Haptics.success()
        refreshCurrent()
    }

    // MARK: - Bulk skip / delete / favorite

    func bulkSkip() async {
        let selected = Array(bulkSelectedIDs)
        guard !selected.isEmpty else { return }

        for id in selected {
            let skip = PhotoSkip(assetLocalID: id)
            skip.context = context
            modelContext.insert(skip)
        }
        try? modelContext.save()

        let removedSet = Set(selected)
        withAnimation(.easeInOut(duration: 0.3)) {
            queue.removeAll { removedSet.contains($0) }
        }
        if index >= queue.count { index = max(0, queue.count - 1) }
        bulkSelectedIDs = []

        lastAction = .bulkSkipped(localIDs: selected)
        Haptics.swipe()
        refreshCurrent()
    }

    func bulkQueueDelete() async {
        let selected = Array(bulkSelectedIDs)
        guard !selected.isEmpty else { return }

        for id in selected {
            let pd = PendingDelete(assetLocalID: id)
            pd.context = context
            modelContext.insert(pd)
        }
        try? modelContext.save()

        let removedSet = Set(selected)
        withAnimation(.easeInOut(duration: 0.3)) {
            queue.removeAll { removedSet.contains($0) }
        }
        if index >= queue.count { index = max(0, queue.count - 1) }
        bulkSelectedIDs = []

        lastAction = .bulkDeleted(localIDs: selected)
        Haptics.warning()
        refreshCurrent()
    }

    func bulkToggleFavorite() async {
        let selected = Array(bulkSelectedIDs)
        guard !selected.isEmpty else { return }
        let assets = AlbumService.assets(for: selected)
        let shouldFavorite = assets.contains { !$0.isFavorite }
        for asset in assets {
            do {
                try await AlbumService.performFavorite(asset: asset, favorite: shouldFavorite)
            } catch {}
        }
        Haptics.tap()
        refreshCurrent()
    }

    // MARK: - Bulk undo

    private func undoBulkSort() async {
        guard case .bulkSorted(let addedByAlbum, let removedByAlbum, let removedFromQueue) = lastAction else {
            return
        }

        for (albumID, photoIDs) in addedByAlbum {
            guard let collection = AlbumService.collection(for: albumID) else { continue }
            for id in photoIDs {
                guard let asset = AlbumService.asset(for: id) else { continue }
                do {
                    try await AlbumService.remove(asset, from: collection, assumeMember: true)
                    evaluator.noteRemoved(asset: id, from: albumID)
                } catch {}
            }
            applyLocalMembershipChange(albumID: albumID, delta: -photoIDs.count)
        }

        for (albumID, photoIDs) in removedByAlbum {
            guard let collection = AlbumService.collection(for: albumID) else { continue }
            for id in photoIDs {
                guard let asset = AlbumService.asset(for: id) else { continue }
                do {
                    try await AlbumService.add(asset, to: collection, assumeNotMember: true)
                    evaluator.noteAdded(asset: id, to: albumID)
                } catch {}
            }
            applyLocalMembershipChange(albumID: albumID, delta: photoIDs.count)
        }

        for id in removedFromQueue.reversed() where !queue.contains(id) {
            withAnimation(.easeInOut(duration: 0.3)) {
                queue.insert(id, at: min(index, queue.count))
            }
        }

        lastAction = nil
        refreshCurrent()
    }

    private func undoBulkSkip() async {
        guard case .bulkSkipped(let ids) = lastAction else { return }
        for id in ids {
            if let row = context.skips.first(where: { $0.assetLocalID == id }) {
                modelContext.delete(row)
            }
        }
        try? modelContext.save()

        for id in ids.reversed() where !queue.contains(id) {
            withAnimation(.easeInOut(duration: 0.3)) {
                queue.insert(id, at: min(index, queue.count))
            }
        }
        lastAction = nil
        refreshCurrent()
    }

    private func undoBulkDelete() async {
        guard case .bulkDeleted(let ids) = lastAction else { return }
        for id in ids {
            if let row = context.pendingDeletes.first(where: { $0.assetLocalID == id }) {
                modelContext.delete(row)
            }
        }
        try? modelContext.save()

        for id in ids.reversed() where !queue.contains(id) {
            withAnimation(.easeInOut(duration: 0.3)) {
                queue.insert(id, at: min(index, queue.count))
            }
        }
        lastAction = nil
        refreshCurrent()
    }

    // MARK: - Advance / back

    /// Advance to the next asset. Removes the current asset from the queue if
    /// `removeCurrent` is true (used after satisfy / skip / delete).
    /// Synchronous so callers' post-await state changes batch into one SwiftUI
    /// update instead of splitting across a suspension point.
    func advance(removingCurrent removeCurrent: Bool) {
        if removeCurrent && index < queue.count {
            queue.remove(at: index)
        } else {
            index += 1
        }
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
        advance(removingCurrent: true)
    }

    func undoSkip() async {
        guard case .skipped(let id) = lastAction else { return }
        if let row = context.skips.first(where: { $0.assetLocalID == id }) {
            modelContext.delete(row)
            try? modelContext.save()
        }
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
        advance(removingCurrent: true)
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

    // MARK: - Undo (sort)

    func undoSort() async {
        guard case .sorted(let id, let albumID) = lastAction else { return }
        guard let asset = AlbumService.asset(for: id),
              let collection = AlbumService.collection(for: albumID) else {
            lastAction = nil
            return
        }
        do {
            try await AlbumService.remove(asset, from: collection, assumeMember: true)
            evaluator.noteRemoved(asset: id, from: albumID)
            applyLocalMembershipChange(albumID: albumID, delta: -1)
        } catch {}
        queue.insert(id, at: index)
        lastAction = nil
        refreshCurrent()
    }

    func undoSortMulti() async {
        guard case .sortedMulti(let id, let adds, let removes) = lastAction else { return }
        guard let asset = AlbumService.asset(for: id) else {
            lastAction = nil
            return
        }
        for albumID in adds {
            guard let collection = AlbumService.collection(for: albumID) else { continue }
            do {
                try await AlbumService.remove(asset, from: collection, assumeMember: true)
                evaluator.noteRemoved(asset: id, from: albumID)
                applyLocalMembershipChange(albumID: albumID, delta: -1)
            } catch {}
        }
        for albumID in removes {
            guard let collection = AlbumService.collection(for: albumID) else { continue }
            do {
                try await AlbumService.add(asset, to: collection, assumeNotMember: true)
                evaluator.noteAdded(asset: id, to: albumID)
                applyLocalMembershipChange(albumID: albumID, delta: +1)
            } catch {}
        }
        queue.insert(id, at: index)
        lastAction = nil
        refreshCurrent()
    }

    func undo() async {
        switch lastAction {
        case .sorted: await undoSort()
        case .sortedMulti: await undoSortMulti()
        case .skipped: await undoSkip()
        case .queuedDelete: await undoQueueDelete()
        case .bulkSorted: await undoBulkSort()
        case .bulkSkipped: await undoBulkSkip()
        case .bulkDeleted: await undoBulkDelete()
        case nil: break
        }
    }

    // MARK: - PhotoKit change handling

    /// Called when the photo library reports a change via `changeTick`. During
    /// an active sort session the vast majority of these are self-write leaks
    /// (the `pendingSelfWrites` counter can't reliably suppress every PhotoKit
    /// callback). A full queue rebuild here would cost hundreds of milliseconds
    /// and stutter the UI, so we only refresh the current asset's metadata.
    /// Actual queue rebuilds are deferred to explicit user actions: first load
    /// (`start`), view reappear (`refreshAfterReappear`), and context edit
    /// dismiss (`rebuildQueue`).
    func handleLibraryChange() {
        refreshCurrent()
    }

    /// Updates the default context's album IDs without counting assets per
    /// album. Used on the lightweight rebuild path where album counts are
    /// already maintained locally by `applyLocalMembershipChange`.
    private func refreshDefaultAlbumsLight() {
        let newIDs = AlbumService.listUserAlbumIDs()
        guard newIDs != context.albumLocalIDs else { return }
        context.albumLocalIDs = newIDs
        try? modelContext.save()
    }

    // MARK: - Reappear

    /// Lighter rebuild for when the view reappears after being off-screen.
    /// Re-fetches the source pool and refreshes album metadata but keeps the
    /// evaluator cache warm — avoids the N-album membership re-fetch that
    /// dominates a full `rebuildQueue()`.
    func refreshAfterReappear() async {
        if context.isDefault {
            refreshDefaultAlbumsLight()
        }

        let pool = AssetSource.queue(for: context)

        totalAssetsInPool = pool.count

        let skipIDs = Set(context.skips.map(\.assetLocalID))
        let deleteIDs = Set(context.pendingDeletes.map(\.assetLocalID))

        var remaining: [String] = []
        remaining.reserveCapacity(pool.count)
        let allLocalIDs = pool.assetLocalIDs

        let activeID = currentAssetID
        for id in allLocalIDs {
            if skipIDs.contains(id) || deleteIDs.contains(id) { continue }
            if !evaluator.isSatisfied(assetID: id, in: context) {
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

        refreshAlbumInfos()
        refreshExtraAlbumInfos()
        refreshCurrent()
    }
}
