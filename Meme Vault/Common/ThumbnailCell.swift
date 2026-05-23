import SwiftUI
import Photos

struct ThumbnailCell: View {
    let assetLocalID: String
    var showRestoreIndicator = false
    /// Rendered edge length in points; the request is sized to this × the
    /// display scale so the thumbnail is sharp instead of upscaled. Defaults to
    /// the adaptive grid's typical cell size.
    var displayPointSize: CGFloat = 130

    @Environment(\.displayScale) private var displayScale
    @State private var thumbnail: UIImage?

    private var targetSize: CGSize {
        let side = displayPointSize * displayScale
        return CGSize(width: side, height: side)
    }

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
                let (stream, cancel) = ImageLoader.shared.thumbnailStream(for: asset, targetSize: targetSize)
                await withTaskCancellationHandler {
                    for await image in stream { thumbnail = image }
                } onCancel: {
                    cancel()
                }
            }
    }
}
