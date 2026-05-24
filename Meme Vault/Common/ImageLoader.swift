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

    // PhotoKit's caching manager is `Sendable` and serialises internally, so the
    // off-main thumbnail path (`thumbnailStream`) can use it directly alongside
    // the main-actor methods here.
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
    nonisolated(unsafe) private let thumbnailOptions: PHImageRequestOptions = {
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

    /// In-memory cache of *decoded* thumbnail images, keyed by local ID + pixel
    /// size. Lets a cell paint a previously-loaded (or prefetched) thumbnail
    /// synchronously on appear instead of going through the async request and
    /// flashing a placeholder. Thread-safe, so usable from the off-main paths.
    nonisolated(unsafe) private let thumbnailCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 500
        return cache
    }()
    /// Thumbnail keys currently being resolved/decoded by a prefetch, so the
    /// same asset isn't requested twice while it's in flight.
    private var thumbInFlight: Set<String> = []

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
    /// Takes a local identifier rather than a resolved `PHAsset`: the asset
    /// lookup (`PHAsset.fetchAssets`, which hits the Photos store over XPC) is
    /// done on a background task alongside the image request, so the per-cell
    /// resolution no longer blocks the main thread while scrolling.
    ///
    /// Returns the stream plus a `cancel` handle. Callers should drive the stream
    /// inside `withTaskCancellationHandler` and call `cancel` from `onCancel`: an
    /// `AsyncStream` does not finish on its own when the consuming task is
    /// cancelled, so without this the PhotoKit request would run to completion
    /// even after the cell scrolled away. Cancelling finishes the stream and
    /// cancels the request — so fast scrolling stops piling up orphaned decodes.
    nonisolated func thumbnailStream(
        forLocalID localID: String,
        targetSize: CGSize
    ) -> (stream: AsyncStream<UIImage>, cancel: @Sendable () -> Void) {
        // Shared mutable state across the build closure, the background resolve,
        // the PhotoKit callback, and the cancel handle. PhotoKit serialises its
        // own callbacks and the residual races here are benign (worst case: one
        // request briefly outlives a cancel), matching this file's existing
        // `@unchecked Sendable` boxing for the same kind of bridge.
        final class Holder: @unchecked Sendable {
            var continuation: AsyncStream<UIImage>.Continuation?
            var requestID: PHImageRequestID?
            var cancelled = false
        }
        let holder = Holder()
        // Capture the Sendable manager locally so the @Sendable closures below
        // don't have to reach back through the main-actor `ImageLoader.shared`.
        let manager = self.manager

        let stream = AsyncStream<UIImage> { continuation in
            holder.continuation = continuation
            Task.detached(priority: .userInitiated) { [self] in
                guard !holder.cancelled, let asset = AlbumService.asset(for: localID) else {
                    continuation.finish()
                    return
                }
                let id = manager.requestImage(
                    for: asset,
                    targetSize: targetSize,
                    contentMode: .aspectFill,
                    options: thumbnailOptions
                ) { image, info in
                    let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                    if let image {
                        continuation.yield(image)
                        // Cache the sharp result so the cell (or a later re-appear)
                        // can paint it synchronously next time, without a request.
                        if !isDegraded {
                            self.thumbnailCache.setObject(image, forKey: Self.thumbKey(localID, targetSize))
                        }
                    }
                    let isCancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                    let hasError = info?[PHImageErrorKey] != nil
                    // A non-degraded image is the final, sharp result; cancellation
                    // or error means nothing more is coming. Either way we're done.
                    if !isDegraded || isCancelled || hasError {
                        continuation.finish()
                    }
                }
                holder.requestID = id
                // Cancelled between kicking this off and getting the id back.
                if holder.cancelled { manager.cancelImageRequest(id) }
            }
            continuation.onTermination = { _ in
                if let id = holder.requestID {
                    manager.cancelImageRequest(id)
                }
            }
        }

        return (stream, {
            holder.cancelled = true
            holder.continuation?.finish()
        })
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

    // MARK: - Thumbnail cache + prefetch

    nonisolated static func thumbKey(_ localID: String, _ size: CGSize) -> NSString {
        // Square thumbnails, so the width pixel size identifies the variant.
        "\(localID)@\(Int(size.width))" as NSString
    }

    /// Returns the decoded thumbnail for this asset+size if it's already in the
    /// in-memory cache — synchronous, so a cell can paint it on first render
    /// without a request and without flashing a placeholder.
    nonisolated func cachedThumbnail(localID: String, targetSize: CGSize) -> UIImage? {
        thumbnailCache.object(forKey: Self.thumbKey(localID, targetSize))
    }

    /// Eagerly decode the given thumbnails into the in-memory cache so upcoming
    /// cells can paint synchronously. Skips anything already cached or in flight;
    /// asset resolution and decoding run off the main actor. Unlike PhotoKit's
    /// `startCachingImages` (which only pre-warms the decode), this produces the
    /// actual `UIImage` the cell needs, so no per-cell request/placeholder.
    func prefetchThumbnails(localIDs: [String], targetSize: CGSize) {
        guard targetSize.width > 0, targetSize.height > 0 else { return }

        let toLoad = localIDs.filter { id in
            let key = Self.thumbKey(id, targetSize) as String
            return thumbnailCache.object(forKey: key as NSString) == nil && !thumbInFlight.contains(key)
        }
        guard !toLoad.isEmpty else { return }
        for id in toLoad { thumbInFlight.insert(Self.thumbKey(id, targetSize) as String) }

        let manager = self.manager
        Task.detached(priority: .utility) { [self] in
            let assets = AlbumService.assets(for: toLoad)
            let resolvedIDs = Set(assets.map(\.localIdentifier))
            // Release in-flight markers for IDs that didn't resolve to an asset.
            await MainActor.run {
                for id in toLoad where !resolvedIDs.contains(id) {
                    thumbInFlight.remove(Self.thumbKey(id, targetSize) as String)
                }
            }
            for asset in assets {
                // Keep the key as a Sendable String; convert to NSString only at
                // the NSCache call so the @Sendable callback captures nothing else.
                let keyString = Self.thumbKey(asset.localIdentifier, targetSize) as String
                manager.requestImage(
                    for: asset,
                    targetSize: targetSize,
                    contentMode: .aspectFill,
                    options: thumbnailOptions
                ) { image, info in
                    let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                    if let image, !isDegraded {
                        self.thumbnailCache.setObject(image, forKey: keyString as NSString)
                    }
                    let isCancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                    let hasError = info?[PHImageErrorKey] != nil
                    if !isDegraded || isCancelled || hasError {
                        Task { @MainActor in self.thumbInFlight.remove(keyString) }
                    }
                }
            }
        }
    }

    /// Drop the entire cache. Call when leaving the sort flow.
    func reset() {
        manager.stopCachingImagesForAllAssets()
        cachedWindow.removeAll(keepingCapacity: false)
        cacheTargetSize = .zero
        thumbnailCache.removeAllObjects()
        thumbInFlight.removeAll(keepingCapacity: false)
    }
}
