import SwiftUI
import Photos

struct UpcomingItemsView: View {
    let assetIDs: [String]
    let onSelect: (String) -> Void

    var body: some View {
        if !assetIDs.isEmpty {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 6) {
                    ForEach(assetIDs, id: \.self) { id in
                        Button { onSelect(id) } label: {
                            UpcomingThumbnail(assetID: id)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Upcoming photo")
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                    }
                }
                .padding(.horizontal)
                .animation(.easeInOut(duration: 0.3), value: assetIDs)
            }
            .scrollIndicators(.hidden)
            .frame(height: 48)
        }
    }
}
