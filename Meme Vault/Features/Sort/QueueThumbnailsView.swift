import SwiftUI
import Photos

struct QueueThumbnailsView: View {
    let assetIDs: [String]
    let isBulkMode: Bool
    let currentID: String?
    let selectedIDs: Set<String>
    let onTap: (String) -> Void
    var namespace: Namespace.ID

    private let gridColumns = Array(repeating: GridItem(.flexible(), spacing: 3), count: 5)

    var body: some View {
        if isBulkMode {
            ScrollView {
                LazyVGrid(columns: gridColumns, spacing: 3) {
                    ForEach(assetIDs, id: \.self) { id in
                        let isSelected = selectedIDs.contains(id)
                        Button { onTap(id) } label: {
                            QueueThumbnail(assetID: id)
                                .aspectRatio(1, contentMode: .fit)
                                .overlay(alignment: .bottomTrailing) {
                                    Image(systemName: isSelected
                                          ? "checkmark.circle.fill" : "circle")
                                        .font(.callout)
                                        .foregroundStyle(
                                            isSelected ? .white : .white.opacity(0.7),
                                            isSelected ? Color.accentColor : .black.opacity(0.3)
                                        )
                                        .padding(3)
                                }
                                .overlay {
                                    if isSelected {
                                        RoundedRectangle(cornerRadius: 4)
                                            .stroke(Color.accentColor, lineWidth: 2)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .matchedGeometryEffect(id: id, in: namespace)
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.8).combined(with: .opacity),
                            removal: .scale(scale: 0.5).combined(with: .opacity)
                        ))
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 2)
                .animation(.easeInOut(duration: 0.3), value: assetIDs)
            }
        } else if !assetIDs.isEmpty {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 6) {
                        ForEach(assetIDs, id: \.self) { id in
                            Button { onTap(id) } label: {
                                QueueThumbnail(assetID: id, displayPointSize: 36)
                                    .frame(width: 36, height: 36)
                                    .overlay {
                                        if id == currentID {
                                            RoundedRectangle(cornerRadius: 4)
                                                .stroke(Color.accentColor, lineWidth: 2.5)
                                        }
                                    }
                                    .opacity(id == currentID ? 1 : 0.6)
                            }
                            .buttonStyle(.plain)
                            .id(id)
                            .matchedGeometryEffect(id: id, in: namespace)
                            .transition(.scale(scale: 0.5).combined(with: .opacity))
                        }
                    }
                    .padding(.horizontal)
                    .animation(.easeInOut(duration: 0.3), value: assetIDs)
                }
                .scrollIndicators(.hidden)
                .frame(height: 44)
                .onChange(of: currentID) { _, newID in
                    guard let newID else { return }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(newID, anchor: .center)
                    }
                }
                .onAppear {
                    if let currentID {
                        proxy.scrollTo(currentID, anchor: .center)
                    }
                }
            }
        }
    }
}

struct QueueThumbnail: View {
    let assetID: String
    /// Rendered edge length in points; the PhotoKit request is sized to this ×
    /// the display scale so the thumbnail is sharp and we don't over-fetch (the
    /// 36pt strip previously decoded a 200px image per cell).
    var displayPointSize: CGFloat = 80

    @Environment(\.displayScale) private var displayScale
    @State private var thumbnail: UIImage?

    private var targetSize: CGSize {
        let side = displayPointSize * displayScale
        return CGSize(width: side, height: side)
    }

    var body: some View {
        Color(.tertiarySystemFill)
            .overlay {
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipped()
            .clipShape(.rect(cornerRadius: 4))
            .task(id: assetID) {
                guard let asset = AlbumService.asset(for: assetID) else { return }
                let (stream, cancel) = ImageLoader.shared.thumbnailStream(for: asset, targetSize: targetSize)
                await withTaskCancellationHandler {
                    for await image in stream { thumbnail = image }
                } onCancel: {
                    cancel()
                }
            }
    }
}
