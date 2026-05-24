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

    // Only the first N items participate in the strip↔grid morph. That's enough
    // to reshape the visible top rows when toggling modes; matching every one of
    // (potentially thousands of) cells makes each publish its frame on every
    // layout pass — and can force a lazy container to resolve off-screen matched
    // cells — which dominated the bulk-mode transition/scroll cost in profiling.
    // Bounding it to a fixed prefix caps that cost regardless of queue size.
    private static let morphPrefixCount = 25
    private var morphIDs: Set<String> { Set(assetIDs.prefix(Self.morphPrefixCount)) }

    var body: some View {
        if isBulkMode {
            let morphIDs = morphIDs
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
                        .matchedGeometry(id: id, in: namespace, active: morphIDs.contains(id))
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
            let morphIDs = morphIDs
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
                            .matchedGeometry(id: id, in: namespace, active: morphIDs.contains(id))
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
                let (stream, cancel) = ImageLoader.shared.thumbnailStream(forLocalID: assetID, targetSize: targetSize)
                await withTaskCancellationHandler {
                    for await image in stream { thumbnail = image }
                } onCancel: {
                    cancel()
                }
            }
    }
}

private extension View {
    /// Applies `matchedGeometryEffect` only when `active`. The active/inactive
    /// decision is stable for a given cell while scrolling (it's keyed on the
    /// item's fixed position in the queue), so this doesn't churn identity
    /// mid-scroll — it only flips if the queue itself changes.
    @ViewBuilder
    func matchedGeometry(id: String, in namespace: Namespace.ID, active: Bool) -> some View {
        if active {
            matchedGeometryEffect(id: id, in: namespace)
        } else {
            self
        }
    }
}
