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

    /// Options for fast thumbnail requests — accepts the first result PhotoKit
    /// returns (including degraded) so grid cells and strips populate instantly.
    private let thumbnailOptions: PHImageRequestOptions = {
        let o = PHImageRequestOptions()
        o.deliveryMode = .opportunistic
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

    // MARK: - Thumbnail request

    /// Fast thumbnail for grid cells, queue strips, and other small previews.
    /// Accepts the first image PhotoKit delivers (including degraded) so cells
    /// populate immediately rather than waiting for a full-quality decode.
    func loadThumbnail(
        for asset: PHAsset,
        targetSize: CGSize
    ) async -> UIImage? {
        await withCheckedContinuation { (cont: CheckedContinuation<UIImage?, Never>) in
            final class Box: @unchecked Sendable { var resumed = false }
            let box = Box()

            manager.requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFill,
                options: thumbnailOptions
            ) { image, _ in
                guard !box.resumed else { return }
                box.resumed = true
                cont.resume(returning: image)
            }
        }
    }

    /// Progressive thumbnail delivery for grid and strip cells. Yields the fast
    /// (possibly degraded) result first so a cell populates instantly, then the
    /// sharp full-quality result when PhotoKit finishes decoding it. Unlike
    /// `loadThumbnail`, this does not get stuck on the degraded pass.
    ///
    /// Returns the stream plus a `cancel` handle. Callers should drive the stream
    /// inside `withTaskCancellationHandler` and call `cancel` from `onCancel`: an
    /// `AsyncStream` does not finish on its own when the consuming task is
    /// cancelled, so without this the PhotoKit request would run to completion
    /// even after the cell scrolled away. Cancelling finishes the stream, which
    /// (via `onTermination`) cancels the request — so fast scrolling stops piling
    /// up orphaned full-resolution decodes that would otherwise stutter it.
    func thumbnailStream(
        for asset: PHAsset,
        targetSize: CGSize
    ) -> (stream: AsyncStream<UIImage>, cancel: @Sendable () -> Void) {
        final class Holder: @unchecked Sendable {
            nonisolated(unsafe) var continuation: AsyncStream<UIImage>.Continuation?
        }
        let holder = Holder()

        let stream = AsyncStream<UIImage> { continuation in
            holder.continuation = continuation
            let id = manager.requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFill,
                options: thumbnailOptions
            ) { image, info in
                if let image { continuation.yield(image) }
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                let isCancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                let hasError = info?[PHImageErrorKey] != nil
                // A non-degraded image is the final, sharp result; cancellation
                // or error means nothing more is coming. Either way we're done.
                if !isDegraded || isCancelled || hasError {
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in
                Task { @MainActor in ImageLoader.shared.manager.cancelImageRequest(id) }
            }
        }

        return (stream, { holder.continuation?.finish() })
    }

    // MARK: - Prefetch window

    /// Declare the exact set of asset IDs that should be kept warm right now.
    /// Reuses already-cached `PHAsset` objects and only fetches newcomers from
    /// PhotoKit, so a typical 1-page swipe resolves just 1 asset instead of the
    /// entire window.
    func setCacheWindow(assetIDs: [String], targetSize: CGSize) {
        guard targetSize.width > 0, targetSize.height > 0 else { return }

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

        let wantedIDs = Set(assetIDs)

        let dropped = cachedWindow.compactMap { wantedIDs.contains($0.key) ? nil : $0.value }
        if !dropped.isEmpty {
            manager.stopCachingImages(for: dropped, targetSize: targetSize, contentMode: .aspectFit, options: options)
            for asset in dropped { cachedWindow[asset.localIdentifier] = nil }
        }

        let newIDs = assetIDs.filter { cachedWindow[$0] == nil }
        if !newIDs.isEmpty {
            let fetched = AlbumService.assets(for: newIDs)
            manager.startCachingImages(for: fetched, targetSize: targetSize, contentMode: .aspectFit, options: options)
            for asset in fetched { cachedWindow[asset.localIdentifier] = asset }
        }
    }

    /// Drop the entire cache. Call when leaving the sort flow.
    func reset() {
        manager.stopCachingImagesForAllAssets()
        cachedWindow.removeAll(keepingCapacity: false)
        cacheTargetSize = .zero
    }
}
