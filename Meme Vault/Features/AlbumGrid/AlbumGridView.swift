import SwiftUI
import Photos

struct AlbumThumbnail: Equatable {
    let id: String
    let image: UIImage

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

struct AlbumGridCell: View {
    private static let gridColumns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
    ]

    let albumID: String
    let title: String
    let count: Int
    var isMember: Bool = false
    /// Photos sorted into this album during this app run, most recent first.
    /// Shown at the front of the preview regardless of creation-date order;
    /// the next launch reverts to the natural order.
    var recentIDs: [String] = []
    /// Thumbnail to render invisible (layout preserved) while the hero-flight
    /// image is still travelling toward this cell — its slot stays blank until
    /// the flight lands, instead of showing a duplicate under the flight.
    var hiddenThumbID: String? = nil
    /// Reports the global frame of the preview's first (top-left) slot, so
    /// the sort screen can fly the hero image into it.
    var onFirstSlotFrame: ((CGRect) -> Void)? = nil

    @State private var thumbnails: [AlbumThumbnail] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(isMember
                          ? Color.accentColor.opacity(0.12)
                          : Color(.tertiarySystemFill))

                if thumbnails.isEmpty {
                    Image(systemName: "photo.on.rectangle")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                        .transition(.opacity)
                } else {
                    GeometryReader { proxy in
                        let cellSize = max(0, (proxy.size.width - 2) / 2)
                        LazyVGrid(columns: Self.gridColumns, spacing: 2) {
                            ForEach(Array(thumbnails.prefix(4)), id: \.id) { thumb in
                                Image(uiImage: thumb.image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: cellSize, height: cellSize)
                                    .clipped()
                                    .opacity(thumb.id == hiddenThumbID ? 0 : 1)
                                    .transition(.scale(scale: 0.8).combined(with: .opacity))
                            }
                            ForEach(min(thumbnails.count, 4)..<4, id: \.self) { _ in
                                Color(.tertiarySystemFill)
                                    .frame(width: cellSize, height: cellSize)
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .transition(.opacity)
                }

                if isMember {
                    VStack {
                        HStack {
                            Spacer()
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.white, Color.accentColor)
                                .font(.title3)
                                .shadow(radius: 2)
                                .padding(6)
                        }
                        Spacer()
                    }
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                guard let onFirstSlotFrame else { return }
                let slot = max(0, (frame.width - 2) / 2)
                onFirstSlotFrame(CGRect(x: frame.minX, y: frame.minY, width: slot, height: slot))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)

                Text("^[\(count) photo](inflect: true)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .task {
            if thumbnails.isEmpty {
                thumbnails = await loadThumbnails()
            }
        }
        .onChange(of: count) { reloadThumbnails() }
        .onChange(of: recentIDs) { reloadThumbnails() }
    }

    /// Animated reload for membership changes: the incoming thumbnail scales
    /// in while the existing ones shift to their new slots.
    private func reloadThumbnails() {
        Task {
            let new = await loadThumbnails()
            guard new != thumbnails else { return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                thumbnails = new
            }
        }
    }

    private func loadThumbnails() async -> [AlbumThumbnail] {
        let albumID = self.albumID
        let recentIDs = Array(self.recentIDs.prefix(4))
        let targetSize = CGSize(width: 200, height: 200)
        let loader = ImageLoader.shared

        // Session adds lead the preview (most recent first); the remaining
        // slots fill with the album's newest assets by creation date.
        let assets: [PHAsset] = await Task.detached(priority: .userInitiated) {
            var out: [PHAsset] = []
            if !recentIDs.isEmpty {
                let fetched = PHAsset.fetchAssets(withLocalIdentifiers: recentIDs, options: nil)
                var byID: [String: PHAsset] = [:]
                fetched.enumerateObjects { asset, _, _ in byID[asset.localIdentifier] = asset }
                // A session add can be removed again (album-contents sheet,
                // Photos app) — keep only photos still in the album.
                out = recentIDs.compactMap { byID[$0] }.filter { asset in
                    var inAlbum = false
                    let containing = PHAssetCollection.fetchAssetCollectionsContaining(
                        asset, with: .album, options: nil
                    )
                    containing.enumerateObjects { collection, _, stop in
                        if collection.localIdentifier == albumID {
                            inAlbum = true
                            stop.pointee = true
                        }
                    }
                    return inAlbum
                }
            }
            if out.count < 4 {
                guard let collection = AlbumService.collection(for: albumID) else { return out }
                let opts = PHFetchOptions()
                opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
                opts.fetchLimit = 4 + out.count
                let result = PHAsset.fetchAssets(in: collection, options: opts)
                let seen = Set(out.map(\.localIdentifier))
                for i in 0..<result.count where out.count < 4 {
                    let asset = result.object(at: i)
                    if !seen.contains(asset.localIdentifier) { out.append(asset) }
                }
            }
            return out
        }.value

        guard !Task.isCancelled, !assets.isEmpty else { return [] }

        return await withTaskGroup(of: (Int, AlbumThumbnail?).self) { group in
            for (index, asset) in assets.enumerated() {
                group.addTask {
                    guard let image = await loader.loadCachedThumbnail(
                        for: asset, targetSize: targetSize
                    ) else { return (index, nil) }
                    return (index, AlbumThumbnail(id: asset.localIdentifier, image: image))
                }
            }
            var indexed: [(Int, AlbumThumbnail)] = []
            for await (index, thumb) in group {
                if let thumb { indexed.append((index, thumb)) }
            }
            return indexed.sorted(by: { $0.0 < $1.0 }).map(\.1)
        }
    }
}
