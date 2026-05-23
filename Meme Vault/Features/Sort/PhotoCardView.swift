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
import AVFoundation

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
                        PhotoPage(assetID: id, isCurrent: id == currentID, targetSize: pixelSize)
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
    let isCurrent: Bool
    let targetSize: CGSize

    @State private var image: UIImage?
    @State private var phase: Phase = .loading
    @State private var isVideo = false
    @State private var player: AVPlayer?
    @State private var isPlaying = false

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
                }

                if let player {
                    PlayerView(player: player)
                        .onTapGesture {
                            guard isPlaying else { return }
                            player.pause()
                            isPlaying = false
                        }
                } else if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                }

                if isVideo && !isPlaying {
                    Button {
                        if let player {
                            player.play()
                            isPlaying = true
                        } else {
                            Task { await startPlayback() }
                        }
                    } label: {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 64))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.white)
                            .shadow(radius: 4)
                    }
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
        .onChange(of: isCurrent) { _, current in
            if !current {
                player?.pause()
                player = nil
                isPlaying = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { notification in
            guard let item = notification.object as? AVPlayerItem,
                  item == player?.currentItem else { return }
            isPlaying = false
            player?.seek(to: .zero)
        }
        .task(id: assetID) {
            player?.pause()
            player = nil
            image = nil
            phase = .loading
            isVideo = false
            isPlaying = false
            guard let asset = AlbumService.asset(for: assetID) else {
                phase = .missing
                return
            }
            isVideo = asset.mediaType == .video
            let loaded = await ImageLoader.shared.loadDisplayImage(for: asset, targetSize: targetSize)
            guard !Task.isCancelled else { return }
            image = loaded
            phase = (loaded == nil) ? .missing : .loaded
        }
    }

    private func startPlayback() async {
        guard let asset = AlbumService.asset(for: assetID) else { return }
        guard let item = await requestPlayerItem(for: asset) else { return }
        let avPlayer = AVPlayer(playerItem: item)
        player = avPlayer
        avPlayer.play()
        isPlaying = true
    }

    private func requestPlayerItem(for asset: PHAsset) async -> AVPlayerItem? {
        await withCheckedContinuation { cont in
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .automatic
            PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { item, _ in
                cont.resume(returning: item)
            }
        }
    }
}

// MARK: - Lightweight AVPlayerLayer wrapper

private struct PlayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ uiView: PlayerUIView, context: Context) {
        uiView.playerLayer.player = player
    }

    final class PlayerUIView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
