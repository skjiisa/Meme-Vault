import SwiftUI
import Photos

struct AlbumThumbnail: Equatable {
    let id: String
    let image: UIImage

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

struct AlbumGridCell: View {
    let albumID: String
    let title: String
    let count: Int
    var isMember: Bool = false
    var refreshTrigger: Int = 0

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
                    Grid(horizontalSpacing: 2, verticalSpacing: 2) {
                        ForEach(0..<2, id: \.self) { row in
                            GridRow {
                                ForEach(0..<2, id: \.self) { col in
                                    let index = row * 2 + col
                                    if index < thumbnails.count {
                                        Image(uiImage: thumbnails[index].image)
                                            .resizable()
                                            .scaledToFill()
                                            .frame(minWidth: 0, maxWidth: .infinity,
                                                   minHeight: 0, maxHeight: .infinity)
                                            .clipped()
                                            .id(thumbnails[index].id)
                                            .transition(.scale(scale: 0.8).combined(with: .opacity))
                                    } else {
                                        Color(.tertiarySystemFill)
                                    }
                                }
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
        .onChange(of: refreshTrigger) {
            Task {
                let updated = await loadThumbnails()
                withAnimation(.easeInOut(duration: 0.35)) {
                    thumbnails = updated
                }
            }
        }
    }

    private func loadThumbnails() async -> [AlbumThumbnail] {
        guard let collection = AlbumService.collection(for: albumID) else { return [] }
        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        opts.fetchLimit = 4
        let result = PHAsset.fetchAssets(in: collection, options: opts)
        var items: [AlbumThumbnail] = []
        for i in 0..<result.count {
            let asset = result.object(at: i)
            if let image = await ImageLoader.shared.loadDisplayImage(
                for: asset,
                targetSize: CGSize(width: 200, height: 200)
            ) {
                items.append(AlbumThumbnail(id: asset.localIdentifier, image: image))
            }
        }
        return items
    }
}
