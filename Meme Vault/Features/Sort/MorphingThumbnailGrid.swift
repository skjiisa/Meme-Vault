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
//  number of cells.
//
//  On a mode toggle the current photo additionally performs a *hero zoom*: a
//  flight image view animates between the big `PhotoCardView` frame and the
//  current asset's grid cell, so the hero appears to shrink into / expand out of
//  the grid while every other cell does the ordinary strip↔grid morph. The hero
//  itself stays a SwiftUI view (`PhotoCardView`); this view only borrows its
//  thumbnail and frame for the flight and signals back (`onExpandComplete`) when
//  the hero should reappear.
//

import SwiftUI
import UIKit
import Photos

/// A transparent, non-interactive UIKit layer that sits on top of the media
/// region and hosts the hero-zoom flight image view. It's separate from the grid
/// so the flying photo draws *above* the fading `PhotoCardView` (backdrop +
/// peeking neighbors) rather than being occluded by it. Shared by reference
/// between `MorphingThumbnailGrid` (which adds the flight view) and
/// `HeroFlightOverlay` (which mounts the layer in the SwiftUI hierarchy).
final class FlightLayer {
    let view: UIView = {
        let v = UIView()
        v.backgroundColor = .clear
        v.isUserInteractionEnabled = false   // never intercept taps/scrolls
        return v
    }()
}

/// Mounts a `FlightLayer`'s view as the topmost child of the media region.
struct HeroFlightOverlay: UIViewRepresentable {
    let layer: FlightLayer
    func makeUIView(context: Context) -> UIView { layer.view }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

/// Lets the toolbar ask the grid which photo is at the top of its current scroll
/// position, so exiting multi-select can open the carousel there instead of at
/// wherever it was left. The closure is installed by `MorphingThumbnailGrid`'s
/// coordinator; it returns nil when not in the grid or nothing is visible.
final class BulkGridAnchor {
    var topVisibleID: () -> String? = { nil }
}

struct MorphingThumbnailGrid: UIViewRepresentable {
    let assetIDs: [String]
    let isBulkMode: Bool
    let currentID: String?
    let selectedIDs: Set<String>
    /// Full-aspect display image of the current hero photo, used as the zoom
    /// flight image. The grid's own thumbnails are square-cropped, so they can't
    /// represent the hero's aspect-fit (letterboxed) appearance; this can.
    let heroImage: UIImage?
    /// Top overlay that hosts the flight image so it draws above the fading hero.
    let flightLayer: FlightLayer
    /// Reports the photo at the top of the grid's scroll position, so exiting
    /// multi-select can open the carousel there.
    let anchor: BulkGridAnchor
    let onTap: (String) -> Void
    /// Called when a flight finishes (the Bool is `entering` bulk), so the parent
    /// can hand the photo back to the carousel — unsuppressing its foreground for
    /// a seamless landing. Also called immediately when a flight is skipped (no
    /// current cell on screen), so the carousel is never left suppressed.
    var onFlightComplete: (Bool) -> Void = { _ in }

    @Environment(\.displayScale) private var displayScale

    /// Height of the strip band at the bottom of the media region in browse mode.
    /// `MediaRegionView` sizes the `PhotoCardView` to leave this much room below;
    /// it's also the hero flight's vertical extent.
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

    func makeUIView(context: Context) -> UIView {
        let coord = context.coordinator
        coord.targetSize = targetSize
        coord.isBulkMode = isBulkMode
        coord.selectedIDs = selectedIDs
        coord.currentID = currentID
        coord.assetIDs = assetIDs
        coord.heroImage = heroImage

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
        cv.translatesAutoresizingMaskIntoConstraints = false

        let registration = UICollectionView.CellRegistration<ThumbCell, String> { [weak coord] cell, _, id in
            guard let coord else { return }
            cell.configure(
                localID: id,
                targetSize: coord.targetSize,
                isBulk: coord.isBulkMode,
                isSelected: coord.selectedIDs.contains(id),
                isCurrent: id == coord.currentID,
                isHiddenForFlight: coord.flightHiddenID == id
            )
        }
        coord.dataSource = UICollectionViewDiffableDataSource(collectionView: cv) { cv, indexPath, id in
            cv.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
        }

        // A plain container so the transient flight image view can sit above the
        // collection view without scrolling with its content.
        let container = UIView()
        container.backgroundColor = .clear
        container.addSubview(cv)
        NSLayoutConstraint.activate([
            cv.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            cv.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            cv.topAnchor.constraint(equalTo: container.topAnchor),
            cv.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        coord.collectionView = cv
        coord.container = container
        coord.flightContainer = flightLayer.view
        anchor.topVisibleID = { [weak coord] in coord?.topVisibleAssetID() }

        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(assetIDs)
        coord.dataSource.apply(snapshot, animatingDifferences: false)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        let coord = context.coordinator
        guard let cv = coord.collectionView else { return }
        coord.targetSize = targetSize
        coord.onTap = onTap
        coord.heroImage = heroImage

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
            if isBulkMode {
                // Shrink: capture the current cell's strip position *before* morphing
                // away from it, lay the grid out, then fly the hero down into it
                // while the other cells morph strip→grid. The current item's strip
                // thumbnail fades out in place via a static proxy at that position
                // (the real cell stays hidden as it morphs to the grid).
                let stripFrame = coord.currentCellOnScreenFrame(currentID: currentID)
                let layout = MorphLayout()
                layout.mode = .grid
                cv.setCollectionViewLayout(layout, animated: true)
                coord.scrollGridToCurrent(cv)
                coord.reconfigure(assetIDs)
                coord.runHeroFlight(
                    entering: true,
                    currentID: currentID,
                    targetSize: targetSize,
                    stripBandHeight: Self.stripBandHeight,
                    onFlightComplete: onFlightComplete
                )
                coord.fadeStripProxy(reveal: false, id: currentID, targetSize: targetSize, frame: stripFrame)
            } else {
                // Expand: capture the current cell's grid frame *before* morphing
                // to the strip, fly it up to the hero, then morph the rest. The
                // current item's strip thumbnail fades in place via a static proxy
                // at its (post-morph) strip position.
                coord.runHeroFlight(
                    entering: false,
                    currentID: currentID,
                    targetSize: targetSize,
                    stripBandHeight: Self.stripBandHeight,
                    onFlightComplete: onFlightComplete
                )
                let layout = MorphLayout()
                layout.mode = .strip
                cv.setCollectionViewLayout(layout, animated: true)
                coord.reconfigure(assetIDs)
                coord.scrollToCurrent(cv, animated: false)
                let stripFrame = coord.currentCellOnScreenFrame(currentID: currentID)
                coord.fadeStripProxy(reveal: true, id: currentID, targetSize: targetSize, frame: stripFrame)
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
            coord.reconfigure(dirty.filter(present.contains))
            if !isBulkMode, prevCurrent != currentID {
                coord.scrollToCurrent(cv, animated: true)
            }
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UICollectionViewDelegate, UICollectionViewDataSourcePrefetching {
        var onTap: (String) -> Void
        var dataSource: UICollectionViewDiffableDataSource<Int, String>!
        weak var collectionView: UICollectionView?
        weak var container: UIView?
        /// Top overlay the flight image is added to (above the fading hero).
        weak var flightContainer: UIView?
        var assetIDs: [String] = []
        var selectedIDs: Set<String> = []
        var currentID: String?
        var isBulkMode = false
        var targetSize: CGSize = .zero
        var heroImage: UIImage?

        /// Asset whose cell is hidden because the hero flight is currently drawing
        /// it as a floating image view; the cell reappears when the flight ends.
        var flightHiddenID: String?
        private var flightView: UIImageView?
        /// Static copy of the current item's strip thumbnail that fades in/out in
        /// place (so it doesn't move while the real cell morphs strip↔grid).
        private var stripProxy: UIImageView?

        private static let flightDuration: TimeInterval = 0.3
        /// Fade for the strip's current-item thumbnail proxy as the flight runs.
        private static let revealFadeDuration: TimeInterval = 0.25
        private static let accent = UIColor(named: "AccentColor") ?? .systemBlue

        init(onTap: @escaping (String) -> Void) {
            self.onTap = onTap
        }

        func reconfigure(_ ids: some Collection<String>) {
            guard !ids.isEmpty else { return }
            var snapshot = dataSource.snapshot()
            snapshot.reconfigureItems(Array(ids))
            dataSource.apply(snapshot, animatingDifferences: false)
        }

        /// The asset at the top-left of the grid's visible area, skipping any row
        /// clipped at the top edge so it's the first *fully* visible cell. Used when
        /// exiting multi-select to open the carousel at the current scroll position.
        func topVisibleAssetID() -> String? {
            guard isBulkMode, let cv = collectionView else { return nil }
            let top = cv.contentOffset.y
            return cv.indexPathsForVisibleItems
                .filter { (cv.layoutAttributesForItem(at: $0)?.frame.minY ?? -.greatestFiniteMagnitude) >= top - 1 }
                .min()
                .flatMap { dataSource.itemIdentifier(for: $0) }
        }

        func scrollToCurrent(_ cv: UICollectionView, animated: Bool) {
            guard !isBulkMode, let id = currentID,
                  let idx = assetIDs.firstIndex(of: id) else { return }
            cv.scrollToItem(at: IndexPath(item: idx, section: 0),
                            at: .centeredHorizontally, animated: animated)
        }

        /// Scroll the grid so the current item sits at the top — the position
        /// `topVisibleAssetID` reads on exit, so entering then exiting round-trips
        /// to the same photo, and the hero zoom flies into a visible cell.
        func scrollGridToCurrent(_ cv: UICollectionView) {
            guard let id = currentID, let idx = assetIDs.firstIndex(of: id) else {
                cv.setContentOffset(.zero, animated: false)
                return
            }
            cv.scrollToItem(at: IndexPath(item: idx, section: 0), at: .top, animated: false)
        }

        // MARK: Hero flight

        /// Animate a floating copy of the current photo between the hero frame and
        /// its grid cell. `entering == true` shrinks hero→cell (bulk), `false`
        /// grows cell→hero (browse). Skips cleanly when there's no current cell on
        /// screen or no cached thumbnail to fly — calling `onExpandComplete` so an
        /// expand never leaves the hero hidden.
        func runHeroFlight(
            entering: Bool,
            currentID: String?,
            targetSize: CGSize,
            stripBandHeight: CGFloat,
            onFlightComplete: @escaping (Bool) -> Void
        ) {
            finishFlight()

            // Prefer the hero's full-aspect display image; fall back to the square
            // thumbnail (which can only do a fill→fill zoom) if it hasn't loaded.
            let flightImage = heroImage ?? ImageLoader.shared.cachedThumbnail(localID: currentID ?? "", targetSize: targetSize)

            guard let container, let cv = collectionView,
                  let id = currentID,
                  let idx = assetIDs.firstIndex(of: id),
                  let image = flightImage,
                  let attr = cv.layoutAttributesForItem(at: IndexPath(item: idx, section: 0))
            else {
                onFlightComplete(entering)
                return
            }

            // Only fly when the destination/source cell is actually on screen;
            // otherwise the photo would zoom toward an off-screen point.
            let visibleContent = CGRect(origin: cv.contentOffset, size: cv.bounds.size)
            guard attr.frame.intersects(visibleContent) else {
                onFlightComplete(entering)
                return
            }

            let cellRect = attr.frame.offsetBy(dx: -cv.contentOffset.x, dy: -cv.contentOffset.y)
            // Match PhotoCardView's page rect — full width inset by its horizontal
            // margin, top region above the strip band — so the flight lands exactly
            // where the carousel shows the photo (seamless handoff).
            let heroMargin: CGFloat = 24
            let heroRect = CGRect(x: heroMargin, y: 0,
                                  width: container.bounds.width - 2 * heroMargin,
                                  height: container.bounds.height - stripBandHeight)
            // The hero shows the photo aspect-fit (letterboxed); the cell shows it
            // aspect-fill (cropped square). Fly an aspectFill image view between the
            // photo's *fitted* rect (where fill == the whole photo, no crop) and the
            // square cell rect — as the frame squares up, the fill crops in, so the
            // sizing morphs fit→fill. With only the cropped thumbnail we can't do
            // that, so fall back to the full hero rect (fill→fill).
            let heroFrame = heroImage != nil
                ? Self.aspectFitRect(for: image.size, in: heroRect)
                : heroRect

            // Snap-hide the real cell for the whole transition — it morphs between
            // strip and grid invisibly. The visible strip thumbnail is a static
            // proxy (see fadeStripProxy) and the big photo is the flight; the real
            // cell is revealed once both have settled.
            flightHiddenID = id
            reconfigure([id])

            let fromRect = entering ? heroFrame : cellRect
            let toRect = entering ? cellRect : heroFrame
            let fromRadius: CGFloat = entering ? 0 : 4
            let toRadius: CGFloat = entering ? 4 : 0

            let fv = UIImageView(image: image)
            fv.contentMode = .scaleAspectFill
            fv.clipsToBounds = true
            fv.layer.cornerRadius = fromRadius
            fv.frame = fromRect
            // Add to the top overlay (coincident with the grid's bounds) so the
            // flying photo is above the fading PhotoCardView; fall back to the
            // grid container if the overlay isn't wired up.
            (flightContainer ?? container).addSubview(fv)
            flightView = fv

            let corner = CABasicAnimation(keyPath: "cornerRadius")
            corner.fromValue = fromRadius
            corner.toValue = toRadius
            corner.duration = Self.flightDuration
            corner.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            fv.layer.add(corner, forKey: "cornerRadius")
            fv.layer.cornerRadius = toRadius

            UIView.animate(withDuration: Self.flightDuration, delay: 0, options: [.curveEaseInOut]) {
                fv.frame = toRect
            } completion: { [weak self] _ in
                guard let self else { return }
                if entering {
                    self.finishFlight()
                    onFlightComplete(true)
                } else {
                    // Hand the photo back to the carousel first (unsuppress its
                    // foreground where the flight just landed), then drop the flight
                    // a runloop later so there's no gap where neither is visible.
                    onFlightComplete(false)
                    DispatchQueue.main.async { self.finishFlight() }
                }
            }
        }

        private func finishFlight() {
            flightView?.removeFromSuperview()
            flightView = nil
            // Hand the strip thumbnail back from the faded-in proxy to the real
            // cell (both static, same position) and reveal the cell wherever it
            // settled (grid cell under the flight, or strip slot under the proxy).
            removeStripProxy()
            if let id = flightHiddenID {
                flightHiddenID = nil
                reconfigure([id])
            }
        }

        // MARK: Strip thumbnail proxy

        /// On-screen frame of the current item's cell in whatever layout is active.
        /// Captured while the *strip* layout is active so the proxy can fade in/out
        /// at the strip position without moving.
        func currentCellOnScreenFrame(currentID: String?) -> CGRect? {
            guard let cv = collectionView, let id = currentID,
                  let idx = assetIDs.firstIndex(of: id),
                  let attr = cv.layoutAttributesForItem(at: IndexPath(item: idx, section: 0))
            else { return nil }
            return attr.frame.offsetBy(dx: -cv.contentOffset.x, dy: -cv.contentOffset.y)
        }

        /// Fades a static copy of the current item's strip thumbnail in or out at a
        /// fixed strip-position `frame`, so the strip representation doesn't appear
        /// to move while the real cell morphs between strip and grid (it stays
        /// hidden). A fade-out removes itself; a fade-in is removed by `finishFlight`
        /// once the real cell takes over.
        func fadeStripProxy(reveal: Bool, id: String?, targetSize: CGSize, frame: CGRect?) {
            guard let id, let frame,
                  let host = flightContainer ?? container,
                  let image = ImageLoader.shared.cachedThumbnail(localID: id, targetSize: targetSize)
            else { return }
            let proxy = UIImageView(image: image)
            proxy.contentMode = .scaleAspectFill
            proxy.clipsToBounds = true
            proxy.layer.cornerRadius = 4
            proxy.layer.borderColor = Self.accent.cgColor   // current item: accent border
            proxy.layer.borderWidth = 2
            proxy.frame = frame
            proxy.alpha = reveal ? 0 : 1
            host.addSubview(proxy)
            stripProxy = proxy
            UIView.animate(withDuration: Self.revealFadeDuration) {
                proxy.alpha = reveal ? 1 : 0
            } completion: { [weak self] _ in
                // Fade-out: gone, drop it. Fade-in: keep until finishFlight hands
                // off to the real cell.
                if !reveal { self?.removeStripProxy(proxy) }
            }
        }

        private func removeStripProxy(_ specific: UIImageView? = nil) {
            if let specific, specific !== stripProxy {
                specific.removeFromSuperview()
                return
            }
            stripProxy?.removeFromSuperview()
            stripProxy = nil
        }

        /// The rect an `imageSize` photo occupies when aspect-fit (letterboxed)
        /// inside `bounds`, centered. An aspectFill image view filling this rect
        /// shows the whole photo with no crop — matching the hero.
        private static func aspectFitRect(for imageSize: CGSize, in bounds: CGRect) -> CGRect {
            guard imageSize.width > 0, imageSize.height > 0 else { return bounds }
            let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
            let w = imageSize.width * scale
            let h = imageSize.height * scale
            return CGRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
        }

        // MARK: Delegate

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
    /// Small breathing room above the first grid row (the selection count now
    /// lives in the header above the region, not floating over the grid).
    private let gridTopInset: CGFloat = 6

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
    /// The cell's resting opacity (1, or 0.6 for a non-current strip cell), applied
    /// unless the cell is snap-hidden during a hero-zoom flight.
    private var baseAlpha: CGFloat = 1

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

    func configure(localID: String, targetSize: CGSize, isBulk: Bool, isSelected: Bool, isCurrent: Bool, isHiddenForFlight: Bool) {
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
            baseAlpha = 1
        } else {
            checkmark.isHidden = true
            borderView.isHidden = !isCurrent
            baseAlpha = isCurrent ? 1 : 0.6
        }

        // Hidden (alpha 0) while the hero flight draws this asset as a floating
        // image view; otherwise sit at the resting opacity.
        contentView.alpha = isHiddenForFlight ? 0 : baseAlpha

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
