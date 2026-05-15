import SwiftUI
import Photos

struct ThumbnailCell: View {
    let assetLocalID: String
    var showRestoreIndicator = false

    @State private var thumbnail: UIImage?

    var body: some View {
        Color(.tertiarySystemFill)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                        .font(.title2)
                }
            }
            .clipShape(.rect(cornerRadius: 8))
            .overlay(alignment: .topTrailing) {
                if showRestoreIndicator {
                    Label("Restore", systemImage: "arrow.uturn.backward")
                        .foregroundStyle(.white, Color(.systemGray3))
                        .font(.title3)
                        .labelStyle(.iconOnly)
                        .imageScale(.small)
                        .padding(4)
                        .background(Circle().fill(.fill))
                }
            }
            .task(id: assetLocalID) {
                guard let asset = AlbumService.asset(for: assetLocalID) else { return }
                thumbnail = await ImageLoader.shared.loadDisplayImage(
                    for: asset,
                    targetSize: CGSize(width: 200, height: 200)
                )
            }
    }
}
