import SwiftUI
import Photos

struct AlbumGridCell: View {
    let albumID: String
    let title: String
    let count: Int
    var isMember: Bool = false
    var refreshTrigger: Int = 0

    @State private var thumbnails: [UIImage] = []

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
                } else {
                    Grid(horizontalSpacing: 2, verticalSpacing: 2) {
                        ForEach(0..<2, id: \.self) { row in
                            GridRow {
                                ForEach(0..<2, id: \.self) { col in
                                    let index = row * 2 + col
                                    if index < thumbnails.count {
                                        Image(uiImage: thumbnails[index])
                                            .resizable()
                                            .scaledToFill()
                                            .frame(minWidth: 0, maxWidth: .infinity,
                                                   minHeight: 0, maxHeight: .infinity)
                                            .clipped()
                                    } else {
                                        Color(.tertiarySystemFill)
                                    }
                                }
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12))
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
                thumbnails = await loadThumbnails()
            }
        }
    }

    private func loadThumbnails() async -> [UIImage] {
        guard let collection = AlbumService.collection(for: albumID) else { return [] }
        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        opts.fetchLimit = 4
        let result = PHAsset.fetchAssets(in: collection, options: opts)
        var images: [UIImage] = []
        for i in 0..<result.count {
            if let image = await ImageLoader.shared.loadDisplayImage(
                for: result.object(at: i),
                targetSize: CGSize(width: 200, height: 200)
            ) {
                images.append(image)
            }
        }
        return images
    }
}
