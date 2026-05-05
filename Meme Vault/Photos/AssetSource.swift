//
//  AssetSource.swift
//  Meme Vault
//
//  Resolves an `OrgContext` to the underlying ordered fetch of `PHAsset`s the
//  sort flow should iterate over. Filtering of "already satisfied / skipped /
//  pending-delete" assets is done lazily by `SortSessionViewModel` so this
//  layer stays cheap to build.
//

import Foundation
import Photos

/// Snapshot of a fetch result, exposed in a Swift-friendly way.
struct AssetQueue: Sendable {
    let assetLocalIDs: [String]

    var count: Int { assetLocalIDs.count }
    var isEmpty: Bool { assetLocalIDs.isEmpty }
}

enum AssetSource {

    /// Builds an ordered list of asset local IDs for the given context's source
    /// pool. Newest first by `creationDate`. Includes images and videos by
    /// default, excludes hidden and recently-deleted (PhotoKit excludes those
    /// by default).
    static func queue(for context: OrgContext) -> AssetQueue {
        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        // Default media types: images + videos. Audio is rarely in albums; skip.
        opts.predicate = NSPredicate(
            format: "mediaType == %d OR mediaType == %d",
            PHAssetMediaType.image.rawValue,
            PHAssetMediaType.video.rawValue
        )

        let fetch: PHFetchResult<PHAsset>
        switch context.sourceKind {
        case .allPhotos:
            fetch = PHAsset.fetchAssets(with: opts)
        case .album:
            guard
                let albumID = context.sourceAlbumLocalID,
                let collection = AlbumService.collection(for: albumID)
            else {
                return AssetQueue(assetLocalIDs: [])
            }
            fetch = PHAsset.fetchAssets(in: collection, options: opts)
        }

        var ids: [String] = []
        ids.reserveCapacity(fetch.count)
        fetch.enumerateObjects { a, _, _ in ids.append(a.localIdentifier) }
        return AssetQueue(assetLocalIDs: ids)
    }
}
