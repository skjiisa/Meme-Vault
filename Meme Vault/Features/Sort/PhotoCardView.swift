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
import AVKit

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
                        PhotoPage(assetID: id, targetSize: pixelSize, isActive: id == currentID)
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
    /// True only for the page centered in the viewport. Gates the relatively
    /// expensive video/GIF playback so adjacent (prefetched) pages stay still.
    let isActive: Bool

    @State private var image: UIImage?
    @State private var backdrop: UIImage?
    @State private var kind: MediaKind = .image
    @State private var animatedImage: UIImage?
    @State private var player: AVPlayer?
    @State private var loopToken: NSObjectProtocol?
    @State private var muteObservation: NSKeyValueObservation?
    @State private var phase: Phase = .loading

    private enum Phase { case loading, loaded, missing }
    private enum MediaKind { case image, gif, video }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.secondarySystemBackground))

            switch phase {
            case .loaded:
                if let image {
                    // Blurred fill behind the letterboxed photo. At radius 20 the
                    // source detail is gone anyway, so we blur a tiny downsampled
                    // copy — same look, a fraction of the per-frame composite cost.
                    if let backdrop {
                        Color.black
                            .overlay {
                                Image(uiImage: backdrop)
                                    .resizable()
                                    .scaledToFill()
                            }
                            .clipped()
                            .blur(radius: 20)
                            .opacity(0.8)
                    }

                    foreground(stillImage: image)
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
        .task(id: assetID) { await loadStill() }
        .task(id: isActive) { await managePlayback() }
        .onDisappear { teardownPlayer() }
    }

    /// The animating overlay for the active page, falling back to the still
    /// frame until the animated content is ready (or for plain images).
    @ViewBuilder
    private func foreground(stillImage: UIImage) -> some View {
        switch kind {
        case .video:
            if let player {
                VideoPlayer(player: player)
            } else {
                still(stillImage)
            }
        case .gif:
            if let animatedImage {
                AnimatedImageView(image: animatedImage)
            } else {
                still(stillImage)
            }
        case .image:
            still(stillImage)
        }
    }

    private func still(_ image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
    }

    /// A small copy of the page image used only as the blurred fill. A 60pt
    /// longest edge is well below what a radius-20 blur can resolve, so the
    /// blur composites over a handful of pixels instead of the full rendition.
    private static func downsampledBackdrop(from image: UIImage) -> UIImage {
        let maxDimension: CGFloat = 60
        let longest = max(image.size.width, image.size.height)
        guard longest > maxDimension else { return image }
        let scale = maxDimension / longest
        let newSize = CGSize(width: image.size.width * scale,
                             height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: newSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    private static func activatePlaybackAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
    }

    // MARK: - Loading

    private func loadStill() async {
        image = nil
        backdrop = nil
        animatedImage = nil
        phase = .loading
        guard let asset = AlbumService.asset(for: assetID) else {
            phase = .missing
            return
        }
        kind = Self.mediaKind(for: asset)
        let loaded = await ImageLoader.shared.loadDisplayImage(for: asset, targetSize: targetSize)
        guard !Task.isCancelled else { return }
        image = loaded
        phase = (loaded == nil) ? .missing : .loaded
        if let loaded {
            backdrop = Self.downsampledBackdrop(from: loaded)
        }
    }

    private func managePlayback() async {
        guard isActive else {
            teardownPlayer()
            return
        }
        guard let asset = AlbumService.asset(for: assetID) else { return }
        switch Self.mediaKind(for: asset) {
        case .image:
            break
        case .gif:
            guard animatedImage == nil else { return }
            let decoded = await ImageLoader.shared.loadAnimatedImage(for: asset)
            guard !Task.isCancelled else { return }
            animatedImage = decoded
        case .video:
            guard let item = await ImageLoader.shared.loadPlayerItem(for: asset) else { return }
            guard !Task.isCancelled else { return }
            setupPlayer(item: item)
        }
    }

    private static func mediaKind(for asset: PHAsset) -> MediaKind {
        if asset.mediaType == .video { return .video }
        return asset.playbackStyle == .imageAnimated ? .gif : .image
    }

    // MARK: - Video player lifecycle

    private func setupPlayer(item: AVPlayerItem) {
        teardownPlayer()
        let p = AVPlayer(playerItem: item)
        p.actionAtItemEnd = .none
        p.isMuted = true
        // The native player control toggles `isMuted` but not the audio session.
        // Watch for an unmute and switch to .playback so sound comes through
        // with the ringer off.
        muteObservation = p.observe(\.isMuted, options: [.new]) { player, _ in
            guard !player.isMuted else { return }
            Self.activatePlaybackAudioSession()
        }
        loopToken = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak p] _ in
            p?.seek(to: .zero)
            p?.play()
        }
        player = p
        p.play()
    }

    private func teardownPlayer() {
        player?.pause()
        if let loopToken {
            NotificationCenter.default.removeObserver(loopToken)
        }
        loopToken = nil
        muteObservation?.invalidate()
        muteObservation = nil
        player = nil
    }
}

// MARK: - Animated image host

/// Hosts a `UIImageView` so animated `UIImage`s (decoded GIFs) actually play —
/// SwiftUI's `Image` renders only the first frame.
private struct AnimatedImageView: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.contentMode = .scaleAspectFit
        view.clipsToBounds = true
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        view.image = image
        view.startAnimating()
        return view
    }

    func updateUIView(_ uiView: UIImageView, context: Context) {
        guard uiView.image !== image else { return }
        uiView.image = image
        uiView.startAnimating()
    }
}
