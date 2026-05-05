//
//  ContextEvaluator.swift
//  Meme Vault
//
//  Pure logic that determines whether a `PHAsset` satisfies an `OrgContext`.
//  Satisfaction = "the asset is in at least one album in context.albumLocalIDs".
//  Skips and pending-deletes are NOT considered satisfaction; they're handled
//  at the queueing layer.
//

import Foundation
import Photos
import SwiftData

/// Per-album membership result for the sort UI.
struct AlbumMembership: Identifiable, Hashable {
    let id: String          // album localIdentifier
    let isMember: Bool
}

/// Cache that lets us answer "is this asset in this album?" once per session
/// without re-fetching for every asset/album pair we look at.
@MainActor
final class ContextEvaluator {
    /// Album localID -> set of asset localIDs known to be members.
    private var membersByAlbum: [String: Set<String>] = [:]

    func invalidate() {
        membersByAlbum.removeAll(keepingCapacity: true)
    }

    /// Returns the set of asset localIDs that are members of the album with the
    /// given local ID. Cached per evaluator instance.
    func members(of albumLocalID: String) -> Set<String> {
        if let cached = membersByAlbum[albumLocalID] { return cached }
        guard let collection = AlbumService.collection(for: albumLocalID) else {
            membersByAlbum[albumLocalID] = []
            return []
        }
        let assets = PHAsset.fetchAssets(in: collection, options: nil)
        var ids = Set<String>()
        ids.reserveCapacity(assets.count)
        assets.enumerateObjects { a, _, _ in ids.insert(a.localIdentifier) }
        membersByAlbum[albumLocalID] = ids
        return ids
    }

    /// Toggling membership outside the evaluator should also patch the cache so
    /// the UI doesn't see a stale state until the next full refresh.
    func noteAdded(asset assetLocalID: String, to albumLocalID: String) {
        membersByAlbum[albumLocalID, default: []].insert(assetLocalID)
    }

    func noteRemoved(asset assetLocalID: String, from albumLocalID: String) {
        membersByAlbum[albumLocalID]?.remove(assetLocalID)
    }

    // MARK: - Per-context queries

    /// Returns an `AlbumMembership` for each album in the context, indicating
    /// whether the asset is a member.
    func albumMemberships(for asset: PHAsset, in context: OrgContext) -> [AlbumMembership] {
        context.albumLocalIDs.map { albumID in
            AlbumMembership(
                id: albumID,
                isMember: members(of: albumID).contains(asset.localIdentifier)
            )
        }
    }

    /// True if the asset satisfies the context (is in at least one destination
    /// album). A context with no albums is trivially satisfied.
    func isSatisfied(_ asset: PHAsset, in context: OrgContext) -> Bool {
        if context.albumLocalIDs.isEmpty { return true }
        return context.albumLocalIDs.contains { albumID in
            members(of: albumID).contains(asset.localIdentifier)
        }
    }
}
