//
//  ImageLoader.swift
//  Meme Vault
//
//  Wrapper around `PHCachingImageManager` for the sort flow. Serves a
//  display-quality image for any asset and keeps a *bounded* window of nearby
//  assets pre-decoded so paging the carousel stays smooth even with a queue of
//  thousands of photos. The window is diffed on every move, so the caching
//  manager never holds more than a handful of renditions.
//

import Foundation
import Photos
import UIKit

@MainActor
final class ImageLoader {
    static let shared = ImageLoader()

    private let manager = PHCachingImageManager()

    /// Shared request options for both display requests and the prefetch window.
    /// Stored so that the `startCachingImages` / `stopCachingImages` pair always
    /// passes identical parameters.
    private let options: PHImageRequestOptions = {
        let o = PHImageRequestOptions()
        o.deliveryMode = .highQualityFormat
        o.resizeMode = .fast
        o.isNetworkAccessAllowed = true
        o.isSynchronous = false
        return o
    }()

    /// Assets currently registered with the caching manager, keyed by localID.
    private var cachedWindow: [String: PHAsset] = [:]
    private var cacheTargetSize: CGSize = .zero

    // MARK: - Display request

    /// Request a display-quality image for the asset. Returns the highest-
    /// quality image available. PhotoKit may invoke its callback more than once
    /// (a fast low-res pass, then the full-res image); the continuation is
    /// resumed only on the first non-degraded result.
    func loadDisplayImage(
        for asset: PHAsset,
        targetSize: CGSize
    ) async -> UIImage? {
        await withCheckedContinuation { (cont: CheckedContinuation<UIImage?, Never>) in
            // Track if we've already resumed (PhotoKit can call back twice).
            final class Box: @unchecked Sendable { var resumed = false }
            let box = Box()

            manager.requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                guard !isDegraded else { return }
                guard !box.resumed else { return }
                box.resumed = true
                cont.resume(returning: image)
            }
        }
    }

    // MARK: - Prefetch window

    /// Declare the exact set of assets that should be kept warm right now.
    /// Diffs against the previous window: newcomers begin caching, assets that
    /// fell out stop caching. Keeps memory bounded regardless of queue size.
    /// Pass `[]` to clear the window without tearing down the manager.
    func setCacheWindow(_ assets: [PHAsset], targetSize: CGSize) {
        guard targetSize.width > 0, targetSize.height > 0 else { return }

        // A different page size means the cached renditions are the wrong
        // resolution — drop them all and rebuild at the new size.
        if cacheTargetSize != targetSize, !cachedWindow.isEmpty {
            manager.stopCachingImages(
                for: Array(cachedWindow.values),
                targetSize: cacheTargetSize,
                contentMode: .aspectFit,
                options: options
            )
            cachedWindow.removeAll(keepingCapacity: true)
        }
        cacheTargetSize = targetSize

        let wantedIDs = Set(assets.map(\.localIdentifier))

        let dropped = cachedWindow.compactMap { wantedIDs.contains($0.key) ? nil : $0.value }
        if !dropped.isEmpty {
            manager.stopCachingImages(for: dropped, targetSize: targetSize, contentMode: .aspectFit, options: options)
            for asset in dropped { cachedWindow[asset.localIdentifier] = nil }
        }

        let added = assets.filter { cachedWindow[$0.localIdentifier] == nil }
        if !added.isEmpty {
            manager.startCachingImages(for: added, targetSize: targetSize, contentMode: .aspectFit, options: options)
            for asset in added { cachedWindow[asset.localIdentifier] = asset }
        }
    }

    /// Drop the entire cache. Call when leaving the sort flow.
    func reset() {
        manager.stopCachingImagesForAllAssets()
        cachedWindow.removeAll(keepingCapacity: false)
        cacheTargetSize = .zero
    }
}
