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
                                    .transition(.opacity)
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
        .onChange(of: count) {
            Task { thumbnails = await loadThumbnails() }
        }
    }

    private func loadThumbnails() async -> [AlbumThumbnail] {
        let albumID = self.albumID
        let targetSize = CGSize(width: 200, height: 200)
        let loader = ImageLoader.shared

        let assets: [PHAsset] = await Task.detached(priority: .userInitiated) {
            guard let collection = AlbumService.collection(for: albumID) else { return [] }
            let opts = PHFetchOptions()
            opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            opts.fetchLimit = 4
            let result = PHAsset.fetchAssets(in: collection, options: opts)
            var out: [PHAsset] = []
            for i in 0..<result.count { out.append(result.object(at: i)) }
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
