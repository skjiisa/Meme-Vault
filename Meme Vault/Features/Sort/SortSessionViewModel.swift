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

    /// Undo history stack (most recent action last). Capped at 50 entries.
    private(set) var undoStack: [SortAction] = []

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

    /// Photos added to each album during this app run, most recent first.
    /// Album preview grids show these at the front regardless of creation
    /// date; the next launch falls back to natural (creation-date) order.
    private(set) var recentAddsByAlbum: [String: [String]] = [:]

    /// App-lifetime backing for `recentAddsByAlbum`, shared across sort
    /// sessions so re-entering the screen keeps the session's ordering.
    private static var sessionRecentAdds: [String: [String]] = [:]

    /// Destination-album order per context, frozen for the app run so sorting
    /// items doesn't reshuffle the grid mid-flow. The next launch re-evaluates
    /// counts from scratch.
    private static var frozenAlbumOrder: [PersistentIdentifier: [String]] = [:]

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

    var canUndo: Bool { !undoStack.isEmpty }

    private func pushUndo(_ action: SortAction) {
        undoStack.append(action)
        if undoStack.count > 50 { undoStack.removeFirst() }
    }

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
        self.recentAddsByAlbum = Self.sessionRecentAdds
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

        // Read the SwiftData-backed inputs on the main actor, then run the
        // (potentially huge) pool enumeration off it so it doesn't freeze the UI.
        let sourceKind = context.sourceKind
        let sourceAlbumLocalID = context.sourceAlbumLocalID
        let pool = await Task.detached(priority: .userInitiated) {
            AssetSource.queue(sourceKind: sourceKind, sourceAlbumLocalID: sourceAlbumLocalID)
        }.value

        totalAssetsInPool = pool.count

        // Warm the membership cache off the main actor before the satisfaction
        // loop below, so each album isn't fetched synchronously on first touch.
        await evaluator.prewarm(albumIDs: context.albumLocalIDs + context.pinnedAlbumLocalIDs)

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
            infos = Self.frozenCountOrder(infos, contextID: context.persistentModelID)
        }
        albumInfos = infos
    }

    /// Sort by count (most to least), but freeze the result per context for
    /// the app run: re-sorting mid-session would shuffle albums under the
    /// user's fingers while they sort. Albums that join the context later are
    /// slotted in by count and then frozen too.
    private static func frozenCountOrder(_ infos: [AlbumInfo], contextID: PersistentIdentifier) -> [AlbumInfo] {
        guard let order = frozenAlbumOrder[contextID] else {
            let sorted = infos.sorted { $0.assetCount > $1.assetCount }
            frozenAlbumOrder[contextID] = sorted.map(\.id)
            return sorted
        }
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        let sorted = infos.sorted { a, b in
            switch (rank[a.id], rank[b.id]) {
            case let (ra?, rb?): ra < rb
            case (.some, nil): true
            case (nil, .some): false
            case (nil, nil): a.assetCount > b.assetCount
            }
        }
        frozenAlbumOrder[contextID] = sorted.map(\.id)
        return sorted
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
                noteSessionRemovals([asset.localIdentifier], albumID: albumLocalID)
                applyLocalMembershipChange(albumID: albumLocalID, delta: -1)
                recomputeMemberships()
                Haptics.tap()
            } else {
                try await AlbumService.add(asset, to: collection, assumeNotMember: true)
                evaluator.noteAdded(asset: asset.localIdentifier, to: albumLocalID)
                noteSessionAdds([asset.localIdentifier], albumID: albumLocalID)
                applyLocalMembershipChange(albumID: albumLocalID, delta: +1)
                if !wasSatisfied {
                    let newMemberships = evaluator.albumMemberships(for: asset, in: context)
                    if newMemberships.contains(where: \.isMember) {
                        pushUndo(.sorted(localID: asset.localIdentifier, albumID: albumLocalID))
                        Haptics.tap()
                        advance(removingCurrent: true)
                        return
                    }
                }
                // Not advancing — the photo stays current, so its hero image
                // must come back once the in-progress flight lands.
                if heroDepartedID == asset.localIdentifier { heroDepartedID = nil }
                recomputeMemberships()
                Haptics.tap()
            }
        } catch {
            if heroDepartedID == asset.localIdentifier { heroDepartedID = nil }
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

    private func applyLocalMembershipChange(albumID: String, delta: Int) {
        if let i = albumInfos.firstIndex(where: { $0.id == albumID }) {
            albumInfos[i] = albumInfos[i].adjustingCount(by: delta)
        }
        if let i = pinnedAlbumInfos.firstIndex(where: { $0.id == albumID }) {
            pinnedAlbumInfos[i] = pinnedAlbumInfos[i].adjustingCount(by: delta)
        }
        if let i = extraAlbumInfos.firstIndex(where: { $0.id == albumID }) {
            extraAlbumInfos[i] = extraAlbumInfos[i].adjustingCount(by: delta)
        }
    }

    /// Record photos added to an album this session so its preview grid can
    /// surface them first, ahead of the natural creation-date order.
    private func noteSessionAdds(_ ids: [String], albumID: String) {
        guard !ids.isEmpty else { return }
        var list = Self.sessionRecentAdds[albumID] ?? []
        list.removeAll { ids.contains($0) }
        list.insert(contentsOf: ids, at: 0)
        Self.sessionRecentAdds[albumID] = list
        recentAddsByAlbum = Self.sessionRecentAdds
    }

    private func noteSessionRemovals(_ ids: [String], albumID: String) {
        guard !ids.isEmpty, var list = Self.sessionRecentAdds[albumID] else { return }
        list.removeAll { ids.contains($0) }
        Self.sessionRecentAdds[albumID] = list
        recentAddsByAlbum = Self.sessionRecentAdds
    }

    func activateMultiSelect() async {
        // Flip the mode immediately for instant UI feedback; the non-context
        // album list populates a beat later once the (off-main) fetch returns.
        isMultiSelectActive = true
        let contextIDs = Set(context.albumLocalIDs)
        let pinnedIDs = Set(context.pinnedAlbumLocalIDs)
        let allAlbums = await Task.detached(priority: .userInitiated) {
            AlbumService.listUserAlbums()
        }.value
        // Bail if multi-select was toggled back off while we were fetching.
        guard isMultiSelectActive else { return }
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
                noteSessionAdds([asset.localIdentifier], albumID: albumID)
                applyLocalMembershipChange(albumID: albumID, delta: +1)
            } catch {}
        }
        for albumID in removes {
            guard let collection = AlbumService.collection(for: albumID) else { continue }
            do {
                try await AlbumService.remove(asset, from: collection, assumeMember: true)
                evaluator.noteRemoved(asset: asset.localIdentifier, from: albumID)
                noteSessionRemovals([asset.localIdentifier], albumID: albumID)
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
            pushUndo(.sortedMulti(
                localID: asset.localIdentifier,
                adds: Array(adds),
                removes: Array(removes)
            ))
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
                noteSessionAdds(added, albumID: albumID)
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
                noteSessionRemovals(removed, albumID: albumID)
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

        pushUndo(.bulkSorted(
            addedByAlbum: addedByAlbum,
            removedByAlbum: removedByAlbum,
            removedFromQueue: removedFromQueue
        ))
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

    /// An album tap in bulk mode. With photos selected it sorts them straight to
    /// the album; with nothing selected yet it enters destination multi-select and
    /// pends the album, so you can pick destinations first, then the photos.
    func bulkAlbumTap(_ albumID: String) async {
        if !isMultiSelectActive && bulkSelectedIDs.isEmpty {
            await activateMultiSelect()
        }
        if isMultiSelectActive {
            await toggleAlbum(albumID)
        } else {
            await bulkSortToAlbum(albumID)
        }
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
            noteSessionAdds(addedIDs, albumID: albumID)
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

        pushUndo(.bulkSorted(
            addedByAlbum: addedIDs.isEmpty ? [:] : [albumID: addedIDs],
            removedByAlbum: [:],
            removedFromQueue: removedIDs
        ))
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

        pushUndo(.bulkSkipped(localIDs: selected))
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

        pushUndo(.bulkDeleted(localIDs: selected))
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

    private func undoBulkSort(addedByAlbum: [String: [String]], removedByAlbum: [String: [String]], removedFromQueue: [String]) async {
        for (albumID, photoIDs) in addedByAlbum {
            guard let collection = AlbumService.collection(for: albumID) else { continue }
            for id in photoIDs {
                guard let asset = AlbumService.asset(for: id) else { continue }
                do {
                    try await AlbumService.remove(asset, from: collection, assumeMember: true)
                    evaluator.noteRemoved(asset: id, from: albumID)
                } catch {}
            }
            noteSessionRemovals(photoIDs, albumID: albumID)
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
            noteSessionAdds(photoIDs, albumID: albumID)
            applyLocalMembershipChange(albumID: albumID, delta: photoIDs.count)
        }

        for id in removedFromQueue.reversed() where !queue.contains(id) {
            withAnimation(.easeInOut(duration: 0.3)) {
                queue.insert(id, at: min(index, queue.count))
            }
        }

        refreshCurrent()
    }

    private func undoBulkSkip(ids: [String]) async {
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
        refreshCurrent()
    }

    private func undoBulkDelete(ids: [String]) async {
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
        refreshCurrent()
    }

    // MARK: - Advance / back

    /// Photo whose hero image departed on a flight to an album cell. Its
    /// carousel page hides the photo (the flight draws it) and fades the rest
    /// of the card, staying blank through its removal transition — so the
    /// photo never shows twice. Cleared wherever the photo stays current
    /// instead (no advance, failed write, undo).
    private(set) var heroDepartedID: String?

    /// Called when an album flight launches with the current photo, just
    /// before the album toggle that will advance past it.
    func noteHeroFlightDeparture(_ id: String?) {
        heroDepartedID = id
    }

    /// Advance past the current asset. When `removeCurrent` is true (used
    /// after satisfy / skip / delete) the item is removed in an animated
    /// transaction: its carousel page fades out in place while the next photo
    /// slides over to take its spot, and the thumbnail strip diffs the same
    /// way. Synchronous so callers' post-await state changes batch into one
    /// SwiftUI update instead of splitting across a suspension point.
    func advance(removingCurrent removeCurrent: Bool) {
        guard removeCurrent, index < queue.count else {
            index += 1
            refreshCurrent()
            return
        }
        let removedID = queue[index]
        withAnimation(.interactiveSpring(duration: 0.25)) {
            queue.remove(at: index)
            refreshCurrent()
        }
        // Keep the departed page blank while its removal transition runs, so
        // the photo can't flash back once the album flight lands.
        guard heroDepartedID == removedID else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard let self, self.heroDepartedID == removedID else { return }
            self.heroDepartedID = nil
        }
    }

    // MARK: - Skip

    func skip() async {
        guard let asset = currentAsset else { return }
        let id = asset.localIdentifier
        let skip = PhotoSkip(assetLocalID: id)
        skip.context = context
        modelContext.insert(skip)
        try? modelContext.save()
        pushUndo(.skipped(localID: id))
        Haptics.swipe()
        advance(removingCurrent: true)
    }

    private func undoSkip(id: String) async {
        if let row = context.skips.first(where: { $0.assetLocalID == id }) {
            modelContext.delete(row)
            try? modelContext.save()
        }
        restoreToQueue(id)
    }

    /// Bring an undone asset back as the current photo, guarding against a
    /// duplicate insert if it somehow never left the queue.
    private func restoreToQueue(_ id: String) {
        if heroDepartedID == id { heroDepartedID = nil }
        if !queue.contains(id) {
            queue.insert(id, at: min(index, queue.count))
        }
        if let i = queue.firstIndex(of: id) { index = i }
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
        pushUndo(.queuedDelete(localID: id))
        Haptics.warning()
        advance(removingCurrent: true)
    }

    private func undoQueueDelete(id: String) async {
        if let row = context.pendingDeletes.first(where: { $0.assetLocalID == id }) {
            modelContext.delete(row)
            try? modelContext.save()
        }
        restoreToQueue(id)
    }

    // MARK: - Undo (sort)

    private func undoSort(id: String, albumID: String) async {
        guard let asset = AlbumService.asset(for: id),
              let collection = AlbumService.collection(for: albumID) else { return }
        do {
            try await AlbumService.remove(asset, from: collection, assumeMember: true)
            evaluator.noteRemoved(asset: id, from: albumID)
            noteSessionRemovals([id], albumID: albumID)
            applyLocalMembershipChange(albumID: albumID, delta: -1)
        } catch {}
        restoreToQueue(id)
    }

    private func undoSortMulti(id: String, adds: [String], removes: [String]) async {
        guard let asset = AlbumService.asset(for: id) else { return }
        for albumID in adds {
            guard let collection = AlbumService.collection(for: albumID) else { continue }
            do {
                try await AlbumService.remove(asset, from: collection, assumeMember: true)
                evaluator.noteRemoved(asset: id, from: albumID)
                noteSessionRemovals([id], albumID: albumID)
                applyLocalMembershipChange(albumID: albumID, delta: -1)
            } catch {}
        }
        for albumID in removes {
            guard let collection = AlbumService.collection(for: albumID) else { continue }
            do {
                try await AlbumService.add(asset, to: collection, assumeNotMember: true)
                evaluator.noteAdded(asset: id, to: albumID)
                noteSessionAdds([id], albumID: albumID)
                applyLocalMembershipChange(albumID: albumID, delta: +1)
            } catch {}
        }
        restoreToQueue(id)
    }

    func undo() async {
        guard let action = undoStack.popLast() else { return }
        switch action {
        case .sorted(let id, let albumID):
            await undoSort(id: id, albumID: albumID)
        case .sortedMulti(let id, let adds, let removes):
            await undoSortMulti(id: id, adds: adds, removes: removes)
        case .skipped(let id):
            await undoSkip(id: id)
        case .queuedDelete(let id):
            await undoQueueDelete(id: id)
        case .bulkSorted(let added, let removed, let removedFromQueue):
            await undoBulkSort(addedByAlbum: added, removedByAlbum: removed, removedFromQueue: removedFromQueue)
        case .bulkSkipped(let ids):
            await undoBulkSkip(ids: ids)
        case .bulkDeleted(let ids):
            await undoBulkDelete(ids: ids)
        }
    }

    // MARK: - PhotoKit change handling

    /// Called when the photo library reports a change via `changeTick`. During
    /// an active sort session the vast majority of these are self-write leaks
    /// (the `pendingSelfWrites` counter can't reliably suppress every PhotoKit
    /// callback). A full queue rebuild here would cost hundreds of milliseconds
    /// and stutter the UI, so we only refresh the current asset's metadata and
    /// schedule a coalesced album-count refresh. Actual queue rebuilds are
    /// deferred to explicit user actions: first load (`start`), view reappear
    /// (`refreshAfterReappear`), and context edit dismiss (`rebuildQueue`).
    func handleLibraryChange() {
        refreshCurrent()
        scheduleAlbumCountRefresh()
    }

    private var albumCountRefreshPending = false

    /// Coalesces bursts of change notifications — on large libraries (iCloud
    /// sync, launch indexing) PhotoKit can fire many per second, and doing a
    /// fetch per tick would hammer it. At most one refresh per window, with
    /// the PhotoKit work off the main actor.
    private func scheduleAlbumCountRefresh() {
        guard !albumCountRefreshPending else { return }
        albumCountRefreshPending = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self else { return }
            self.albumCountRefreshPending = false
            await self.refreshAlbumCountsNow()
        }
    }

    /// Re-reads counts for the cached album snapshots in place — order is
    /// preserved, so the frozen sort order is untouched. Cheap: one collection
    /// fetch (off-main) using estimated counts, no per-album asset
    /// enumeration. Covers changes that bypass the local count patching:
    /// external library edits and removals made in the album-contents sheet
    /// (whose self-writes don't bump `changeTick`, so the sheet's dismiss
    /// calls `refreshAlbumCounts()` directly).
    func refreshAlbumCounts() {
        Task { await refreshAlbumCountsNow() }
    }

    private func refreshAlbumCountsNow() async {
        let ids = (albumInfos + pinnedAlbumInfos + extraAlbumInfos).map(\.id)
        guard !ids.isEmpty else { return }
        let infos: [AlbumInfo] = await Task.detached(priority: .utility) {
            AlbumService.collections(for: ids).map { AlbumInfo(collection: $0) }
        }.value
        let byID = Dictionary(infos.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        albumInfos = albumInfos.map { byID[$0.id] ?? $0 }
        pinnedAlbumInfos = pinnedAlbumInfos.map { byID[$0.id] ?? $0 }
        extraAlbumInfos = extraAlbumInfos.map { byID[$0.id] ?? $0 }
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

        let sourceKind = context.sourceKind
        let sourceAlbumLocalID = context.sourceAlbumLocalID
        let pool = await Task.detached(priority: .userInitiated) {
            AssetSource.queue(sourceKind: sourceKind, sourceAlbumLocalID: sourceAlbumLocalID)
        }.value

        totalAssetsInPool = pool.count

        await evaluator.prewarm(albumIDs: context.albumLocalIDs + context.pinnedAlbumLocalIDs)

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
