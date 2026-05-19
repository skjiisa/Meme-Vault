import SwiftUI
import Photos

struct UpcomingThumbnail: View {
    let assetID: String

    @State private var thumbnail: UIImage?

    var body: some View {
        Color(.tertiarySystemFill)
            .frame(width: 36, height: 36)
            .overlay {
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipShape(.rect(cornerRadius: 6))
            .task(id: assetID) {
                guard let asset = AlbumService.asset(for: assetID) else { return }
                thumbnail = await ImageLoader.shared.loadThumbnail(
                    for: asset,
                    targetSize: CGSize(width: 88, height: 88)
                )
            }
    }
}
