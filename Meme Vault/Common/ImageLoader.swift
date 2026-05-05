//
//  ImageLoader.swift
//  Meme Vault
//
//  Wrapper around `PHCachingImageManager` for the sort view. Supports both a
//  display-quality request for the current photo and prefetching upcoming
//  photos so swipes feel instant.
//

import Foundation
import Photos
import UIKit

@MainActor
final class ImageLoader {
    static let shared = ImageLoader()

    private let manager = PHCachingImageManager()
    private var prefetched: Set<String> = []

    /// Request a display-quality image for the asset. Returns the highest-
    /// quality image available; the completion may be called multiple times
    /// (low-quality first, then high-quality). The closure receives only the
    /// final/most-recent image to keep the API simple.
    func loadDisplayImage(
        for asset: PHAsset,
        targetSize: CGSize
    ) async -> UIImage? {
        await withCheckedContinuation { (cont: CheckedContinuation<UIImage?, Never>) in
            let opts = PHImageRequestOptions()
            opts.deliveryMode = .highQualityFormat
            opts.resizeMode = .fast
            opts.isNetworkAccessAllowed = true
            opts.isSynchronous = false

            // Track if we've already resumed (PhotoKit can call back twice).
            final class Box: @unchecked Sendable { var resumed = false }
            let box = Box()

            manager.requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFit,
                options: opts
            ) { image, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                guard !isDegraded else { return }
                if !box.resumed {
                    box.resumed = true
                    cont.resume(returning: image)
                }
            }
        }
    }

    /// Begin caching the next batch of assets so the next swipe is instant.
    func prefetch(_ assets: [PHAsset], targetSize: CGSize) {
        let new = assets.filter { !prefetched.contains($0.localIdentifier) }
        guard !new.isEmpty else { return }
        new.forEach { prefetched.insert($0.localIdentifier) }

        let opts = PHImageRequestOptions()
        opts.deliveryMode = .highQualityFormat
        opts.resizeMode = .fast
        opts.isNetworkAccessAllowed = true
        manager.startCachingImages(
            for: new,
            targetSize: targetSize,
            contentMode: .aspectFit,
            options: opts
        )
    }

    /// Drop the cache when leaving the sort flow.
    func reset() {
        manager.stopCachingImagesForAllAssets()
        prefetched.removeAll(keepingCapacity: false)
    }
}
