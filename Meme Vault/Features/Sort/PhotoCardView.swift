//
//  PhotoCardView.swift
//  Meme Vault
//
//  Horizontally paged carousel over the sort queue with peek of adjacent items.
//  Backed by a SwiftUI ScrollView with view-aligned paging, so it scrolls with
//  native physics (rubber-banding, deceleration, flick-through) and only realises
//  the pages near the viewport via LazyHStack.
//

import SwiftUI
import Photos

struct PhotoCardView: View {
    let assetIDs: [String]
    @Binding var currentID: String?

    @Environment(\.displayScale) private var displayScale

    private let margin: Double = 24
    private let spacing: Double = 10
    private let prefetchAhead = 3
    private let prefetchBehind = 1

    var body: some View {
        GeometryReader { geo in
            let pageWidth = geo.size.width - 2 * margin
            let pageHeight = geo.size.height
            let pixelSize = CGSize(width: pageWidth * displayScale,
                                   height: pageHeight * displayScale)

            ScrollView(.horizontal) {
                LazyHStack(spacing: spacing) {
                    ForEach(assetIDs, id: \.self) { id in
                        PhotoPage(assetID: id, targetSize: pixelSize)
                            .frame(width: pageWidth, height: pageHeight)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $currentID)
            .scrollIndicators(.hidden)
            .contentMargins(.horizontal, margin)
            .onAppear { updatePrefetchWindow(targetSize: pixelSize) }
            .onChange(of: currentID) { _, _ in updatePrefetchWindow(targetSize: pixelSize) }
            .onChange(of: assetIDs) { _, _ in updatePrefetchWindow(targetSize: pixelSize) }
            .onDisappear { ImageLoader.shared.reset() }
        }
    }

    private func updatePrefetchWindow(targetSize: CGSize) {
        guard let id = currentID, let i = assetIDs.firstIndex(of: id) else {
            ImageLoader.shared.setCacheWindow(assetIDs: [], targetSize: targetSize)
            return
        }
        let lower = max(0, i - prefetchBehind)
        let upper = min(assetIDs.count - 1, i + prefetchAhead)
        let windowIDs = Array(assetIDs[lower...upper])
        ImageLoader.shared.setCacheWindow(assetIDs: windowIDs, targetSize: targetSize)
    }
}

// MARK: - Single page

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
                    Color.black
                        .overlay {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                        }
                        .clipped()
                        .blur(radius: 20)
                        .opacity(0.8)

                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                }
            case .loading:
                ProgressView()
            case .missing:
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .contextMenu {
            Button("Show in Photos", systemImage: "photo") {
                openInPhotosApp(assetID: assetID)
            }
        } preview: {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 300, maxHeight: 400)
            } else {
                ProgressView()
                    .frame(width: 200, height: 200)
            }
        }
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

    private func openInPhotosApp(assetID: String) {
        let encoded = assetID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? assetID
        guard let url = URL(string: "photos-redirect://asset?id=\(encoded)") else { return }
        UIApplication.shared.open(url) { success in
            if !success, let fallback = URL(string: "photos-redirect://") {
                UIApplication.shared.open(fallback)
            }
        }
    }
}
