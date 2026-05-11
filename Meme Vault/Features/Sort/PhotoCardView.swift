//
//  PhotoCardView.swift
//  Meme Vault
//
//  Horizontally paged carousel over the sort queue. Backed by a SwiftUI
//  `ScrollView` with view-aligned paging, so it scrolls with native physics
//  (rubber-banding, deceleration, flick-through) and only realises the pages
//  near the viewport via `LazyHStack` — fine for a queue of thousands. The
//  centred page is two-way-bound to the view model through `currentID`.
//

import SwiftUI
import Photos
import UIKit

struct PhotoCardView: View {
    /// All asset local IDs in the queue, in display order.
    let assetIDs: [String]
    /// Local ID of the page currently centred. User swipes write to it;
    /// programmatic changes (Next / Back buttons, undo) scroll the carousel.
    @Binding var currentID: String?

    @Environment(\.displayScale) private var displayScale

    /// How many neighbours on each side of the visible page to keep pre-decoded.
    private let prefetchAhead = 3
    private let prefetchBehind = 1

    var body: some View {
        GeometryReader { geo in
            let pageSize = geo.size
            let pixelSize = CGSize(width: pageSize.width * displayScale,
                                   height: pageSize.height * displayScale)

            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(assetIDs, id: \.self) { id in
                        PhotoPage(assetID: id, targetSize: pixelSize)
                            .frame(width: pageSize.width, height: pageSize.height)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $currentID)
            .scrollIndicators(.hidden)
            .onAppear { updatePrefetchWindow(targetSize: pixelSize) }
            .onChange(of: currentID) { _, _ in updatePrefetchWindow(targetSize: pixelSize) }
            .onChange(of: assetIDs) { _, _ in updatePrefetchWindow(targetSize: pixelSize) }
            .onDisappear { ImageLoader.shared.reset() }
        }
    }

    private func updatePrefetchWindow(targetSize: CGSize) {
        guard let id = currentID, let i = assetIDs.firstIndex(of: id) else {
            ImageLoader.shared.setCacheWindow([], targetSize: targetSize)
            return
        }
        let lower = max(0, i - prefetchBehind)
        let upper = min(assetIDs.count - 1, i + prefetchAhead)
        let windowIDs = Array(assetIDs[lower...upper])
        ImageLoader.shared.setCacheWindow(AlbumService.assets(for: windowIDs), targetSize: targetSize)
    }
}

// MARK: - Single page

/// One page of the carousel: resolves its `PHAsset` lazily, then loads a
/// display-quality image. Sizing is owned by the parent.
private struct PhotoPage: View {
    let assetID: String
    let targetSize: CGSize

    @State private var image: UIImage?
    @State private var phase: Phase = .loading

    private enum Phase { case loading, loaded, missing }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.secondarySystemBackground))

            switch phase {
            case .loaded:
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }
            case .loading:
                ProgressView()
            case .missing:
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 4)   // a hair of gutter between adjacent cards mid-swipe
        .task(id: assetID) {
            image = nil
            phase = .loading
            guard let asset = AlbumService.asset(for: assetID) else {
                phase = .missing
                return
            }
            let loaded = await ImageLoader.shared.loadDisplayImage(for: asset, targetSize: targetSize)
            guard !Task.isCancelled else { return }
            image = loaded
            phase = (loaded == nil) ? .missing : .loaded
        }
    }
}
