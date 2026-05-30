//
//  MorphingThumbnailGrid.swift
//  Meme Vault
//
//  A single `UICollectionView` that morphs the *same* cells between a horizontal
//  strip (browse mode) and a vertical multi-select grid (bulk mode).
//
//  This replaces the two SwiftUI containers (a `LazyHStack` strip + a `LazyVGrid`
//  grid) that previously shared a `matchedGeometryEffect` namespace to fake the
//  strip↔grid morph across a structural view swap. That approach cost ~1.5ms of
//  AttributeGraph work *per matched cell* on the transition frame (the `AG::Graph::
//  UpdateState` spike in the Instruments traces), so it was bounded to the first
//  25 cells and still couldn't scale.
//
//  Morphing cells inside one collection view via a custom `UICollectionViewLayout`
//  is GPU-composited and costs nothing in SwiftUI's graph, so it scales to any
//  number of cells — and it unblocks the planned "tap a grid cell to focus it,
//  surrounding cells morph into the strip" feature, which needs an arbitrarily
//  large morph set.
//

import SwiftUI
import UIKit
import Photos

struct MorphingThumbnailGrid: UIViewRepresentable {
    let assetIDs: [String]
    let isBulkMode: Bool
    let currentID: String?
    let selectedIDs: Set<String>
    let onTap: (String) -> Void

    @Environment(\.displayScale) private var displayScale

    /// Height of the strip band at the bottom of the media region in browse mode.
    /// `MediaRegionView` sizes the `PhotoCardView` to leave this much room below.
    static let stripBandHeight: CGFloat = 44

    // Strip + grid cells request the same 80pt thumbnail so a cell keeps its
    // decoded image across the morph (one cache key per asset) instead of
    // re-decoding at a second size when it changes shape.
    private var targetSize: CGSize {
        let side = 80 * displayScale
        return CGSize(width: side, height: side)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onTap: onTap)
    }

    func makeUIView(context: Context) -> UICollectionView {
        let coord = context.coordinator
        coord.targetSize = targetSize
        coord.isBulkMode = isBulkMode
        coord.selectedIDs = selectedIDs
        coord.currentID = currentID
        coord.assetIDs = assetIDs

        let layout = MorphLayout()
        layout.mode = isBulkMode ? .grid : .strip

        let cv = UICollectionView(frame: .zero, collectionViewLayout: layout)
        cv.backgroundColor = .clear
        cv.showsHorizontalScrollIndicator = false
        cv.showsVerticalScrollIndicator = isBulkMode
        cv.alwaysBounceVertical = false
        cv.contentInsetAdjustmentBehavior = .never
        cv.delegate = coord
        cv.prefetchDataSource = coord

        let registration = UICollectionView.CellRegistration<ThumbCell, String> { [weak coord] cell, _, id in
            guard let coord else { return }
            cell.configure(
                localID: id,
                targetSize: coord.targetSize,
                isBulk: coord.isBulkMode,
                isSelected: coord.selectedIDs.contains(id),
                isCurrent: id == coord.currentID
            )
        }
        coord.dataSource = UICollectionViewDiffableDataSource(collectionView: cv) { cv, indexPath, id in
            cv.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
        }

        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(assetIDs)
        coord.dataSource.apply(snapshot, animatingDifferences: false)
        return cv
    }

    func updateUIView(_ cv: UICollectionView, context: Context) {
        let coord = context.coordinator
        coord.targetSize = targetSize
        coord.onTap = onTap

        let modeChanged = coord.isBulkMode != isBulkMode
        let prevSelected = coord.selectedIDs
        let prevCurrent = coord.currentID
        coord.isBulkMode = isBulkMode
        coord.selectedIDs = selectedIDs
        coord.currentID = currentID

        // Queue contents changed (sort/skip/delete): re-apply the snapshot. Animate
        // the diff only when we're not also morphing modes, so the two animations
        // don't fight.
        if coord.assetIDs != assetIDs {
            coord.assetIDs = assetIDs
            var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
            snapshot.appendSections([0])
            snapshot.appendItems(assetIDs)
            coord.dataSource.apply(snapshot, animatingDifferences: !modeChanged)
        }

        if modeChanged {
            cv.showsVerticalScrollIndicator = isBulkMode
            let layout = MorphLayout()
            layout.mode = isBulkMode ? .grid : .strip
            // Animated layout swap interpolates each visible cell's frame from its
            // old (strip/grid) attributes to its new ones — the morph.
            cv.setCollectionViewLayout(layout, animated: true)
            // Cells swap their overlay (strip current-border ↔ grid checkmark);
            // reconfigure keeps the decoded image and only re-runs configure().
            reconfigure(coord, ids: assetIDs)
            if isBulkMode {
                cv.setContentOffset(.zero, animated: false)
            } else {
                coord.scrollToCurrent(cv, animated: false)
            }
        } else {
            // Same mode: repaint only the cells whose selection / current state
            // flipped, so a single tap doesn't reconfigure the whole grid.
            var dirty = prevSelected.symmetricDifference(selectedIDs)
            if prevCurrent != currentID {
                if let p = prevCurrent { dirty.insert(p) }
                if let c = currentID { dirty.insert(c) }
            }
            let present = Set(assetIDs)
            reconfigure(coord, ids: dirty.filter(present.contains))
            if !isBulkMode, prevCurrent != currentID {
                coord.scrollToCurrent(cv, animated: true)
            }
        }
    }

    private func reconfigure(_ coord: Coordinator, ids: some Collection<String>) {
        guard !ids.isEmpty else { return }
        var snapshot = coord.dataSource.snapshot()
        snapshot.reconfigureItems(Array(ids))
        coord.dataSource.apply(snapshot, animatingDifferences: false)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UICollectionViewDelegate, UICollectionViewDataSourcePrefetching {
        var onTap: (String) -> Void
        var dataSource: UICollectionViewDiffableDataSource<Int, String>!
        var assetIDs: [String] = []
        var selectedIDs: Set<String> = []
        var currentID: String?
        var isBulkMode = false
        var targetSize: CGSize = .zero

        init(onTap: @escaping (String) -> Void) {
            self.onTap = onTap
        }

        func scrollToCurrent(_ cv: UICollectionView, animated: Bool) {
            guard !isBulkMode, let id = currentID,
                  let idx = assetIDs.firstIndex(of: id) else { return }
            cv.scrollToItem(at: IndexPath(item: idx, section: 0),
                            at: .centeredHorizontally, animated: animated)
        }

        func collectionView(_ cv: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            cv.deselectItem(at: indexPath, animated: false)
            guard let id = dataSource.itemIdentifier(for: indexPath) else { return }
            onTap(id)
        }

        func collectionView(_ cv: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
            let ids = indexPaths.compactMap { dataSource.itemIdentifier(for: $0) }
            guard !ids.isEmpty else { return }
            ImageLoader.shared.prefetchThumbnails(localIDs: ids, targetSize: targetSize)
        }
    }
}

// MARK: - Morphing layout

/// Positions cells either as a horizontal strip pinned to the bottom band (browse)
/// or a vertical N-column grid filling from the top (bulk). The collection view
/// scrolls in whichever axis its content overflows — horizontal for the strip,
/// vertical for the grid — so no `scrollDirection` flip is needed. Swapping one
/// configured instance for another via `setCollectionViewLayout(_:animated:)`
/// animates every cell between the two states.
final class MorphLayout: UICollectionViewLayout {
    enum Mode { case strip, grid }

    var mode: Mode = .strip

    private let columns = 5
    private let gridSpacing: CGFloat = 3
    private let stripSpacing: CGFloat = 6
    private let stripCell: CGFloat = 36
    private let horizontalPadding: CGFloat = 16
    private let stripBandHeight = MorphingThumbnailGrid.stripBandHeight
    /// Clearance at the top of the grid so the first row clears the floating
    /// "N selected" capsule that `MediaRegionView` overlays in bulk mode.
    private let gridTopInset: CGFloat = 38

    private var attributes: [UICollectionViewLayoutAttributes] = []
    private var contentSize: CGSize = .zero

    override func prepare() {
        super.prepare()
        guard let cv = collectionView else { return }
        attributes.removeAll(keepingCapacity: true)

        let count = cv.numberOfItems(inSection: 0)
        let width = cv.bounds.width
        let height = cv.bounds.height

        switch mode {
        case .grid:
            let usable = width - 2 * horizontalPadding - CGFloat(columns - 1) * gridSpacing
            let cell = max(1, floor(usable / CGFloat(columns)))
            let top = gridTopInset + gridSpacing
            for i in 0..<count {
                let col = i % columns
                let row = i / columns
                let x = horizontalPadding + CGFloat(col) * (cell + gridSpacing)
                let y = top + CGFloat(row) * (cell + gridSpacing)
                let attr = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: i, section: 0))
                attr.frame = CGRect(x: x, y: y, width: cell, height: cell)
                attributes.append(attr)
            }
            let rows = Int(ceil(Double(count) / Double(columns)))
            let contentHeight = top + CGFloat(rows) * (cell + gridSpacing)
            contentSize = CGSize(width: width, height: max(contentHeight, height))

        case .strip:
            // Centre the cells in the bottom band; the top of the region shows the
            // PhotoCardView, which MediaRegionView overlays.
            let y = height - stripBandHeight + (stripBandHeight - stripCell) / 2
            for i in 0..<count {
                let x = horizontalPadding + CGFloat(i) * (stripCell + stripSpacing)
                let attr = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: i, section: 0))
                attr.frame = CGRect(x: x, y: y, width: stripCell, height: stripCell)
                attributes.append(attr)
            }
            let contentWidth = 2 * horizontalPadding
                + CGFloat(count) * stripCell
                + CGFloat(max(0, count - 1)) * stripSpacing
            contentSize = CGSize(width: max(contentWidth, width), height: height)
        }
    }

    override var collectionViewContentSize: CGSize { contentSize }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        attributes.filter { $0.frame.intersects(rect) }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard indexPath.item < attributes.count else { return nil }
        return attributes[indexPath.item]
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        collectionView?.bounds.size != newBounds.size
    }
}

// MARK: - Cell

final class ThumbCell: UICollectionViewCell {
    private let imageView = UIImageView()
    private let borderView = UIView()
    private let checkmark = UIImageView()
    private var boundID: String?
    private var imageTask: Task<Void, Never>?

    private static let accent = UIColor(named: "AccentColor") ?? .systemBlue

    override init(frame: CGRect) {
        super.init(frame: frame)

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.backgroundColor = .tertiarySystemFill
        imageView.layer.cornerRadius = 4
        imageView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(imageView)

        borderView.layer.borderColor = Self.accent.cgColor
        borderView.layer.borderWidth = 2
        borderView.layer.cornerRadius = 4
        borderView.isUserInteractionEnabled = false
        borderView.isHidden = true
        borderView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(borderView)

        checkmark.contentMode = .center
        checkmark.isHidden = true
        checkmark.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(checkmark)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            borderView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            borderView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            borderView.topAnchor.constraint(equalTo: contentView.topAnchor),
            borderView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            checkmark.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -3),
            checkmark.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -3),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(localID: String, targetSize: CGSize, isBulk: Bool, isSelected: Bool, isCurrent: Bool) {
        if isBulk {
            checkmark.isHidden = false
            let name = isSelected ? "checkmark.circle.fill" : "circle"
            let palette: [UIColor] = isSelected
                ? [.white, Self.accent]
                : [UIColor.white.withAlphaComponent(0.7), UIColor.black.withAlphaComponent(0.3)]
            let cfg = UIImage.SymbolConfiguration(paletteColors: palette)
                .applying(UIImage.SymbolConfiguration(textStyle: .callout))
            checkmark.image = UIImage(systemName: name, withConfiguration: cfg)
            borderView.isHidden = !isSelected
            contentView.alpha = 1
        } else {
            checkmark.isHidden = true
            borderView.isHidden = !isCurrent
            contentView.alpha = isCurrent ? 1 : 0.6
        }

        // Only (re)load the image when the cell binds to a different asset — a
        // selection/current repaint reuses the decoded image already shown.
        if boundID != localID {
            boundID = localID
            loadImage(localID: localID, targetSize: targetSize)
        }
    }

    private func loadImage(localID: String, targetSize: CGSize) {
        imageTask?.cancel()
        // Paint synchronously if the thumbnail is already decoded (prefetched or
        // shown before) so there's no placeholder flash on appear.
        if let cached = ImageLoader.shared.cachedThumbnail(localID: localID, targetSize: targetSize) {
            imageView.image = cached
            imageTask = nil
            return
        }
        imageView.image = nil
        let (stream, cancel) = ImageLoader.shared.thumbnailStream(forLocalID: localID, targetSize: targetSize)
        imageTask = Task { @MainActor [weak self] in
            await withTaskCancellationHandler {
                for await image in stream {
                    guard let self, self.boundID == localID else { break }
                    self.imageView.image = image
                }
            } onCancel: {
                cancel()
            }
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        imageTask?.cancel()
        imageTask = nil
        boundID = nil
        imageView.image = nil
        contentView.alpha = 1
        borderView.isHidden = true
        checkmark.isHidden = true
    }
}
