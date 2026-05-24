import SwiftUI

/// A scrollable adaptive grid of square photo thumbnails with built-in
/// look-ahead prefetching: as each cell appears it decodes the next
/// `prefetchAheadCount` thumbnails into `ImageLoader`'s cache so they paint
/// instantly on arrival (the same approach as the sort bulk grid).
///
/// Callers supply the per-item cell so they can add their own buttons / context
/// menus; the grid owns the layout, the shared insertion/removal transition,
/// and the prefetch. Used by the full-screen photo grids (album contents,
/// trash, skipped), which all render `ThumbnailCell`.
struct PhotoGrid<Cell: View>: View {
    let assetIDs: [String]
    /// Edge length the cell renders at, in points — must match the size the
    /// cell requests (`ThumbnailCell`'s default is 130) so the prefetch and the
    /// per-cell load resolve to the same cache entry.
    var thumbnailPointSize: CGFloat = 130
    /// How many cells past a just-appeared cell to decode ahead.
    var prefetchAheadCount: Int = 30
    @ViewBuilder var cell: (String) -> Cell

    @Environment(\.displayScale) private var displayScale

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 8)]

    private var thumbTargetSize: CGSize {
        let side = thumbnailPointSize * displayScale
        return CGSize(width: side, height: side)
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(Array(assetIDs.enumerated()), id: \.element) { index, id in
                    cell(id)
                        .transition(.scale.combined(with: .opacity))
                        .onAppear { prefetchAhead(from: index) }
                }
            }
            .padding(12)
            .animation(.interactiveSpring(), value: assetIDs)
        }
    }

    /// Decode the cells just past `index` into the cache. Cheap to over-call:
    /// `prefetchThumbnails` skips anything already cached or in flight.
    private func prefetchAhead(from index: Int) {
        let lower = index + 1
        let upper = min(assetIDs.count, lower + prefetchAheadCount)
        guard lower < upper else { return }
        ImageLoader.shared.prefetchThumbnails(
            localIDs: Array(assetIDs[lower..<upper]),
            targetSize: thumbTargetSize
        )
    }
}
