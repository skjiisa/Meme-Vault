//
//  AlbumService.swift
//  Meme Vault
//
//  Read user albums and write album membership / new albums via PhotoKit.
//

import Foundation
import Photos

/// Lightweight, value-typed snapshot of a `PHAssetCollection` for use in views.
struct AlbumInfo: Identifiable, Hashable, Sendable {
    let id: String          // PHAssetCollection.localIdentifier
    let title: String
    let estimatedAssetCount: Int

    init(collection: PHAssetCollection) {
        self.id = collection.localIdentifier
        self.title = collection.localizedTitle ?? "Untitled Album"
        self.estimatedAssetCount = collection.estimatedAssetCount
    }
}

enum AlbumServiceError: LocalizedError {
    case albumNotFound(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .albumNotFound(let id): return "Album not found: \(id)"
        case .writeFailed(let msg): return "Write failed: \(msg)"
        }
    }
}

enum AlbumService {

    // MARK: - performChanges bridge

    /// async/throws bridge over `PHPhotoLibrary.performChanges(_:completionHandler:)`.
    private static func performChanges(_ block: @Sendable @escaping () -> Void) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges(block) { success, error in
                if success {
                    cont.resume()
                } else {
                    cont.resume(throwing: error ?? AlbumServiceError.writeFailed("Unknown PhotoKit error"))
                }
            }
        }
    }

    // MARK: - Listing

    /// Returns all user-created albums (no smart albums) sorted by title.
    static func listUserAlbums() -> [AlbumInfo] {
        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "localizedTitle", ascending: true)]
        let result = PHAssetCollection.fetchAssetCollections(
            with: .album,
            subtype: .albumRegular,
            options: opts
        )
        var albums: [AlbumInfo] = []
        albums.reserveCapacity(result.count)
        result.enumerateObjects { collection, _, _ in
            albums.append(AlbumInfo(collection: collection))
        }
        return albums
    }

    /// Resolves album local identifiers back to `PHAssetCollection`s. Missing
    /// IDs are silently dropped.
    static func collections(for localIDs: [String]) -> [PHAssetCollection] {
        guard !localIDs.isEmpty else { return [] }
        let result = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: localIDs,
            options: nil
        )
        var out: [PHAssetCollection] = []
        out.reserveCapacity(result.count)
        result.enumerateObjects { c, _, _ in out.append(c) }
        return out
    }

    static func collection(for localID: String) -> PHAssetCollection? {
        collections(for: [localID]).first
    }

    // MARK: - Membership

    /// True iff the asset is a member of the given album.
    static func isAsset(_ asset: PHAsset, memberOf collection: PHAssetCollection) -> Bool {
        let opts = PHFetchOptions()
        opts.predicate = NSPredicate(format: "localIdentifier == %@", asset.localIdentifier)
        opts.fetchLimit = 1
        let result = PHAsset.fetchAssets(in: collection, options: opts)
        return result.count > 0
    }

    /// Adds an asset to an album. No-op if already a member.
    static func add(_ asset: PHAsset, to collection: PHAssetCollection) async throws {
        if isAsset(asset, memberOf: collection) { return }
        try await performChanges {
            guard let req = PHAssetCollectionChangeRequest(for: collection) else {
                return
            }
            req.addAssets([asset] as NSArray)
        }
    }

    /// Removes an asset from an album. No-op if not a member.
    static func remove(_ asset: PHAsset, from collection: PHAssetCollection) async throws {
        guard isAsset(asset, memberOf: collection) else { return }
        try await performChanges {
            guard let req = PHAssetCollectionChangeRequest(for: collection) else {
                return
            }
            req.removeAssets([asset] as NSArray)
        }
    }

    // MARK: - Creation

    /// Creates a new user album with the given title and returns its local ID.
    static func createAlbum(named title: String) async throws -> String {
        // Use a class wrapper so the @Sendable closure can mutate it without
        // the compiler complaining about capturing `var placeholder`.
        final class Holder: @unchecked Sendable { var value: PHObjectPlaceholder? }
        let holder = Holder()
        try await performChanges {
            let req = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
            holder.value = req.placeholderForCreatedAssetCollection
        }
        guard let placeholder = holder.value else {
            throw AlbumServiceError.writeFailed("No placeholder returned for new album")
        }
        return placeholder.localIdentifier
    }

    // MARK: - Deletion

    /// Batch-deletes the given assets. Triggers the system confirmation prompt.
    static func deleteAssets(_ assets: [PHAsset]) async throws {
        guard !assets.isEmpty else { return }
        try await performChanges {
            PHAssetChangeRequest.deleteAssets(assets as NSArray)
        }
    }

    // MARK: - Asset lookup

    static func asset(for localID: String) -> PHAsset? {
        let result = PHAsset.fetchAssets(withLocalIdentifiers: [localID], options: nil)
        return result.firstObject
    }

    static func assets(for localIDs: [String]) -> [PHAsset] {
        guard !localIDs.isEmpty else { return [] }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: localIDs, options: nil)
        var out: [PHAsset] = []
        out.reserveCapacity(result.count)
        result.enumerateObjects { a, _, _ in out.append(a) }
        return out
    }
}
