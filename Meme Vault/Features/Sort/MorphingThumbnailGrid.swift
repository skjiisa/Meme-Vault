//
//  MorphingThumbnailGrid.swift
//  Meme Vault
//
//  A single `UICollectionView` that morphs the *same* cells between a horizontal
//  strip (browse mode) and a vertical multi-select grid (bulk mode), driven by
//  `MorphController`.
//
//  This replaces the two SwiftUI containers (a `LazyHStack` strip + a `LazyVGrid`
//  grid) that previously shared a `matchedGeometryEffect` namespace to fake the
//  strip↔grid morph across a structural view swap. That approach cost ~1.5ms of
//  AttributeGraph work *per matched cell* on the transition frame, so it was
//  bounded to the first 25 cells and still couldn't scale.
//
//  Morphing cells inside one collection view via a custom `UICollectionViewLayout`
//  is GPU-composited and costs nothing in SwiftUI's graph, so it scales to any
//  number of cells.
//
//  On a mode toggle the current photo additionally performs a *hero zoom*: a
//  flight image view animates between the big carousel page frame and the current
//  asset's grid cell, so the hero appears to shrink into / expand out of the grid
//  while every other cell does the ordinary strip↔grid morph. The controller
//  borrows the hero's display image for the flight and signals back (via the
//  completion handler) when the carousel should reappear.
//
//  Owned directly by `SortSessionViewController` (no `UIViewRepresentable`
//  wrapper) so the flight frames live in the same UIKit coordinate space as the
//  carousel and album grid.
//

import UIKit
import UIKit.UIGestureRecognizerSubclass
import Photos

/// Drives the morphing strip/grid collection view. Created and owned by
/// `SortSessionViewController`, which adds `collectionView` into the media region
/// and supplies the transient `flightOverlay` (a transparent view above the
/// carousel) the hero-zoom flight draws into.
final class MorphController: NSObject, UICollectionViewDelegate, UICollectionViewDataSourcePrefetching {

    /// Height of the strip band at the bottom of the media region in browse mode.
    /// The carousel is sized to leave this much room below; it's also the hero
    /// flight's vertical extent.
    static let stripBandHeight: CGFloat = 44

    let collectionView: UICollectionView
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!

    /// Tap handler — toggles bulk selection or shows the asset, per the VC.
    var onTap: (String) -> Void = { _ in }
    /// Delivers the full target selection during a single-finger drag-select
    /// (bulk mode); the VC pushes it straight to the view model.
    var onDragSelectionChanged: (Set<String>) -> Void = { _ in }
    /// The flight overlay (above the carousel) the hero-zoom image is added to.
    weak var flightOverlay: UIView?
    /// Full-aspect display image of the current hero photo, used as the zoom
    /// flight image; the square thumbnails can't represent the letterboxed hero.
    var heroImage: UIImage?

    private(set) var assetIDs: [String] = []
    private(set) var selectedIDs: Set<String> = []
    private(set) var currentID: String?
    private(set) var isBulkMode = false
    var targetSize: CGSize = .zero

    /// Column count for the bulk multi-select grid (the browse strip is unaffected).
    var gridColumns = 5
    /// Bottom content inset applied in bulk so the last rows clear the floating
    /// photo-grid zoom bar that overlays the strip band.
    var gridBottomInset: CGFloat = 0

    /// Asset whose cell is hidden because the hero flight is currently drawing it
    /// as a floating image view; the cell reappears when the flight ends.
    private var flightHiddenID: String?
    private var flightView: UIImageView?
    /// Static copy of the current item's strip thumbnail that fades in/out in
    /// place (so it doesn't move while the real cell morphs strip↔grid).
    private var stripProxy: UIImageView?

    // MARK: Drag-select state
    private var selectPan: UIPanGestureRecognizer!
    /// Index where the active drag began; nil when no drag is in progress.
    private var dragAnchorIndex: Int?
    /// Whether the drag paints selection (true) or deselection (false), fixed at
    /// the anchor cell's pre-drag state — mirrors Photos.
    private var dragSelecting = false
    /// Selection as it was when the drag began, so cells leaving the swept range
    /// revert instead of sticking selected.
    private var preDragSelection: Set<String> = []
    /// Last item index the finger was over, to tick feedback once per crossed cell.
    private var dragLastIndex: Int?
    /// Finger position in the collection view's *viewport* (bounds) space, kept so
    /// edge auto-scroll can re-resolve the swept cell as content slides under it.
    private var dragViewportPoint: CGPoint = .zero
    private let selectionFeedback = UISelectionFeedbackGenerator()
    private var autoScrollLink: CADisplayLink?
    private var autoScrollStep: CGFloat = 0

    private static let flightDuration: TimeInterval = 0.3
    private static let revealFadeDuration: TimeInterval = 0.25
    private static let accent = UIColor(named: "AccentColor") ?? .systemBlue

    /// Movement-based animations (layout morph, hero zoom) are suppressed when the
    /// user has Reduce Motion on; cross-fades are still allowed.
    private var animationsEnabled: Bool { !UIAccessibility.isReduceMotionEnabled }

    override init() {
        let layout = MorphLayout()
        layout.mode = .strip
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init()

        collectionView.backgroundColor = .clear
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.showsVerticalScrollIndicator = false
        collectionView.alwaysBounceVertical = false
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.delegate = self
        collectionView.prefetchDataSource = self
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.clipsToBounds = false

        let registration = UICollectionView.CellRegistration<ThumbCell, String> { [weak self] cell, _, id in
            guard let self else { return }
            cell.configure(
                localID: id,
                targetSize: self.targetSize,
                isBulk: self.isBulkMode,
                isSelected: self.selectedIDs.contains(id),
                isCurrent: id == self.currentID,
                isHiddenForFlight: self.flightHiddenID == id
            )
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { cv, indexPath, id in
            cv.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
        }

        // Single-finger drag-to-select (bulk only): a horizontal-start pan selects a
        // run of photos and, dragged down, fills whole rows — like Photos. Vertical
        // starts fall through to the grid's own scroll. Disabled in browse, where a
        // horizontal pan scrolls the strip.
        let pan = HorizontalDragSelectGestureRecognizer(target: self, action: #selector(handleSelectPan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.isEnabled = false
        collectionView.addGestureRecognizer(pan)
        // The grid's vertical scroll yields to a committed horizontal drag-select.
        collectionView.panGestureRecognizer.require(toFail: pan)
        selectPan = pan
    }

    deinit { autoScrollLink?.invalidate() }

    // MARK: - Snapshot / state

    func applySnapshot(_ ids: [String], animated: Bool) {
        assetIDs = ids
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(ids)
        dataSource.apply(snapshot, animatingDifferences: animated)
    }

    func reconfigure(_ ids: some Collection<String>) {
        guard !ids.isEmpty else { return }
        let present = Set(assetIDs)
        let valid = ids.filter(present.contains)
        guard !valid.isEmpty else { return }
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems(Array(valid))
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// Repaint the cells whose selection state flipped (bulk mode).
    func updateSelection(_ new: Set<String>) {
        let dirty = selectedIDs.symmetricDifference(new)
        selectedIDs = new
        reconfigure(dirty)
    }

    /// Repaint the previous + new current cells; in browse, scroll to the new one.
    func updateCurrent(_ new: String?, animated: Bool = true) {
        let prev = currentID
        guard prev != new else { return }
        currentID = new
        var dirty = Set<String>()
        if let prev { dirty.insert(prev) }
        if let new { dirty.insert(new) }
        reconfigure(dirty)
        if !isBulkMode {
            scrollToCurrent(animated: animated)
        }
    }

    func setCurrentSilently(_ id: String?) { currentID = id }
    func setSelectedSilently(_ ids: Set<String>) { selectedIDs = ids }

    // MARK: - Insets / scrolling

    /// The asset at the top-left of the grid's visible area, skipping any row
    /// clipped at the top edge so it's the first *fully* visible cell. Used when
    /// exiting multi-select to open the carousel at the current scroll position.
    func topVisibleAssetID() -> String? {
        guard isBulkMode else { return nil }
        let cv = collectionView
        let top = cv.contentOffset.y + cv.adjustedContentInset.top
        return cv.indexPathsForVisibleItems
            .filter { (cv.layoutAttributesForItem(at: $0)?.frame.minY ?? -.greatestFiniteMagnitude) >= top - 1 }
            .min()
            .flatMap { dataSource.itemIdentifier(for: $0) }
    }

    func scrollToCurrent(animated: Bool) {
        guard !isBulkMode, let id = currentID,
              let idx = assetIDs.firstIndex(of: id) else { return }
        collectionView.scrollToItem(at: IndexPath(item: idx, section: 0),
                                    at: .centeredHorizontally, animated: animated)
    }

    /// Scroll the grid so the current item sits at the top — the position
    /// `topVisibleAssetID` reads on exit, so entering then exiting round-trips to
    /// the same photo, and the hero zoom flies into a visible cell.
    func scrollGridToCurrent() {
        guard let id = currentID, let idx = assetIDs.firstIndex(of: id) else {
            collectionView.setContentOffset(.zero, animated: false)
            return
        }
        collectionView.scrollToItem(at: IndexPath(item: idx, section: 0), at: .top, animated: false)
    }

    /// In bulk, extend the collection view up under the nav bar (negative top
    /// constraint, owned by the VC) and inset its content below the bar; reset in
    /// browse. `topConstraint` is the VC's `cv.top == container.top + constant`.
    func applyBulkInsets(topConstraint: NSLayoutConstraint?, topSafeInset: CGFloat, regionTopInset: CGFloat) {
        let topConstant = isBulkMode ? -regionTopInset : 0
        if topConstraint?.constant != topConstant {
            topConstraint?.constant = topConstant
            collectionView.superview?.layoutIfNeeded()
        }
        let inset = isBulkMode ? topSafeInset : 0
        if collectionView.contentInset.top != inset {
            collectionView.contentInset.top = inset
            collectionView.verticalScrollIndicatorInsets.top = inset
        }
        let bottom = isBulkMode ? gridBottomInset : 0
        if collectionView.contentInset.bottom != bottom {
            collectionView.contentInset.bottom = bottom
            collectionView.verticalScrollIndicatorInsets.bottom = bottom
        }
    }

    /// Re-layout the bulk grid at a new column count (mirrors the album grid's
    /// zoom). Stores the count so the next enter-bulk uses it; animates the change
    /// when the grid is currently visible.
    func setGridColumns(_ columns: Int, animated: Bool) {
        guard columns != gridColumns else { return }
        gridColumns = columns
        guard isBulkMode else { return }
        let layout = MorphLayout()
        layout.mode = .grid
        layout.columns = columns
        collectionView.setCollectionViewLayout(layout, animated: animated)
    }

    // MARK: - Mode transition

    /// Enter bulk: capture the current cell's strip position *before* morphing
    /// away from it, lay the grid out, then fly the hero down into it while the
    /// other cells morph strip→grid. The strip thumbnail fades out via a static
    /// proxy at that position (the real cell stays hidden as it morphs).
    func enterBulk(
        topConstraint: NSLayoutConstraint?,
        topSafeInset: CGFloat,
        regionTopInset: CGFloat,
        mediaRegionBounds: CGRect,
        onFlightComplete: @escaping (Bool) -> Void
    ) {
        isBulkMode = true
        selectPan.isEnabled = true
        collectionView.showsVerticalScrollIndicator = true
        // Clip the grid to its frame so scrolled rows stop at the media-region
        // bottom (above the drag handle) instead of bleeding over the destination
        // grid. Browse leaves clipping off so the strip/flight can overflow.
        collectionView.clipsToBounds = true
        let stripFrame = currentCellOnScreenFrame()
        applyBulkInsets(topConstraint: topConstraint, topSafeInset: topSafeInset, regionTopInset: regionTopInset)
        let layout = MorphLayout()
        layout.mode = .grid
        layout.columns = gridColumns
        collectionView.setCollectionViewLayout(layout, animated: animationsEnabled)
        scrollGridToCurrent()
        reconfigure(assetIDs)
        runHeroFlight(entering: true, mediaRegionBounds: mediaRegionBounds, onFlightComplete: onFlightComplete)
        fadeStripProxy(reveal: false, frame: stripFrame)
    }

    /// Exit bulk: capture the current cell's grid frame *before* morphing to the
    /// strip, fly it up to the hero, then morph the rest. The strip thumbnail
    /// fades in via a static proxy at its (post-morph) strip position.
    func exitBulk(
        topConstraint: NSLayoutConstraint?,
        topSafeInset: CGFloat,
        regionTopInset: CGFloat,
        mediaRegionBounds: CGRect,
        onFlightComplete: @escaping (Bool) -> Void
    ) {
        isBulkMode = false
        selectPan.isEnabled = false
        endDragSelect()
        collectionView.showsVerticalScrollIndicator = false
        collectionView.clipsToBounds = false
        runHeroFlight(entering: false, mediaRegionBounds: mediaRegionBounds, onFlightComplete: onFlightComplete)
        applyBulkInsets(topConstraint: topConstraint, topSafeInset: topSafeInset, regionTopInset: regionTopInset)
        let layout = MorphLayout()
        layout.mode = .strip
        collectionView.setCollectionViewLayout(layout, animated: animationsEnabled)
        reconfigure(assetIDs)
        scrollToCurrent(animated: false)
        let stripFrame = currentCellOnScreenFrame()
        fadeStripProxy(reveal: true, frame: stripFrame)
    }

    // MARK: - Hero flight

    /// Animate a floating copy of the current photo between the hero frame and its
    /// grid cell. `entering == true` shrinks hero→cell (bulk), `false` grows
    /// cell→hero (browse). Skips cleanly when there's no current cell on screen or
    /// no image to fly — still calling `onFlightComplete` so an expand never
    /// leaves the hero hidden.
    private func runHeroFlight(
        entering: Bool,
        mediaRegionBounds: CGRect,
        onFlightComplete: @escaping (Bool) -> Void
    ) {
        finishFlight()

        // Reduce Motion: skip the moving zoom flight; the layout swap repositions
        // cells instantly and the carousel is handed back immediately.
        guard animationsEnabled else {
            DispatchQueue.main.async { onFlightComplete(entering) }
            return
        }

        let flightImage = heroImage ?? ImageLoader.shared.cachedThumbnail(localID: currentID ?? "", targetSize: targetSize)

        guard let host = flightOverlay,
              let id = currentID,
              let idx = assetIDs.firstIndex(of: id),
              let image = flightImage,
              let attr = collectionView.layoutAttributesForItem(at: IndexPath(item: idx, section: 0))
        else {
            DispatchQueue.main.async { onFlightComplete(entering) }
            return
        }

        // Only fly when the destination/source cell is actually on screen.
        let visibleContent = CGRect(origin: collectionView.contentOffset, size: collectionView.bounds.size)
        guard attr.frame.intersects(visibleContent) else {
            DispatchQueue.main.async { onFlightComplete(entering) }
            return
        }

        let cellRect = collectionView.convert(attr.frame, to: host)
        // Match the carousel's page rect — full width inset by its horizontal
        // margin, top region above the strip band — so the flight lands exactly
        // where the carousel shows the photo (seamless handoff).
        let heroMargin: CGFloat = 24
        let heroRect = CGRect(x: heroMargin, y: 0,
                              width: mediaRegionBounds.width - 2 * heroMargin,
                              height: mediaRegionBounds.height - Self.stripBandHeight)
        // Hero shows the photo aspect-fit (letterboxed); the cell aspect-fill
        // (cropped square). Fly an aspectFill view between the photo's fitted rect
        // (fill == whole photo, no crop) and the square cell rect — as the frame
        // squares up, the fill crops in, morphing fit→fill. With only the cropped
        // thumbnail we can't do that, so fall back to the full hero rect.
        let heroFrame = heroImage != nil
            ? Self.aspectFitRect(for: image.size, in: heroRect)
            : heroRect

        // Snap-hide the real cell for the whole transition — it morphs invisibly.
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
        host.addSubview(fv)
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
                // Hand the photo back to the carousel first, then drop the flight a
                // runloop later so there's no gap where neither is visible.
                onFlightComplete(false)
                DispatchQueue.main.async { self.finishFlight() }
            }
        }
    }

    private func finishFlight() {
        flightView?.removeFromSuperview()
        flightView = nil
        removeStripProxy()
        if let id = flightHiddenID {
            flightHiddenID = nil
            reconfigure([id])
        }
    }

    // MARK: - Strip thumbnail proxy

    /// On-screen frame (in the flight overlay's space) of the current item's cell
    /// in whatever layout is active.
    private func currentCellOnScreenFrame() -> CGRect? {
        guard let host = flightOverlay, let id = currentID,
              let idx = assetIDs.firstIndex(of: id),
              let attr = collectionView.layoutAttributesForItem(at: IndexPath(item: idx, section: 0))
        else { return nil }
        return collectionView.convert(attr.frame, to: host)
    }

    /// Fade a static copy of the current item's strip thumbnail in/out at a fixed
    /// strip-position `frame`, so the strip representation doesn't appear to move
    /// while the real cell morphs (it stays hidden). A fade-out removes itself; a
    /// fade-in is removed by `finishFlight` once the real cell takes over.
    private func fadeStripProxy(reveal: Bool, frame: CGRect?) {
        guard let id = currentID, let frame, let host = flightOverlay,
              let image = ImageLoader.shared.cachedThumbnail(localID: id, targetSize: targetSize)
        else { return }
        let proxy = UIImageView(image: image)
        proxy.contentMode = .scaleAspectFill
        proxy.clipsToBounds = true
        proxy.layer.cornerRadius = 4
        proxy.layer.borderColor = Self.accent.cgColor
        proxy.layer.borderWidth = 2
        proxy.frame = frame
        proxy.alpha = reveal ? 0 : 1
        host.addSubview(proxy)
        stripProxy = proxy
        UIView.animate(withDuration: Self.revealFadeDuration) {
            proxy.alpha = reveal ? 1 : 0
        } completion: { [weak self] _ in
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

    /// The rect an `imageSize` photo occupies when aspect-fit (letterboxed) inside
    /// `bounds`, centered. An aspectFill view filling this rect shows the whole
    /// photo with no crop — matching the hero.
    private static func aspectFitRect(for imageSize: CGSize, in bounds: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return bounds }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let w = imageSize.width * scale
        let h = imageSize.height * scale
        return CGRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
    }

    // MARK: - Drag-select

    @objc private func handleSelectPan(_ g: UIPanGestureRecognizer) {
        let point = g.location(in: collectionView)
        switch g.state {
        case .began:   beginDragSelect(at: point)
        case .changed: updateDragSelect(at: point)
        case .ended, .cancelled, .failed: endDragSelect()
        default: break
        }
    }

    private func beginDragSelect(at contentPoint: CGPoint) {
        guard isBulkMode, let idx = itemIndex(at: contentPoint) else {
            dragAnchorIndex = nil
            return
        }
        dragAnchorIndex = idx
        // Start on an unselected cell → the drag selects; on a selected cell → it
        // deselects. Either way the swept range is forced to this mode.
        dragSelecting = !selectedIDs.contains(assetIDs[idx])
        preDragSelection = selectedIDs
        dragLastIndex = idx
        selectionFeedback.prepare()
        selectionFeedback.selectionChanged()
        applyRange(to: idx)
    }

    private func updateDragSelect(at contentPoint: CGPoint) {
        guard dragAnchorIndex != nil else { return }
        dragViewportPoint = CGPoint(x: contentPoint.x,
                                    y: contentPoint.y - collectionView.contentOffset.y)
        sweep(to: contentPoint)
        updateAutoScroll(viewportY: dragViewportPoint.y)
    }

    private func endDragSelect() {
        stopAutoScroll()
        dragAnchorIndex = nil
        dragLastIndex = nil
        preDragSelection = []
    }

    /// Resolve the cell under `contentPoint` and, if it changed, tick feedback and
    /// repaint the swept range.
    private func sweep(to contentPoint: CGPoint) {
        guard let idx = itemIndex(at: contentPoint) else { return }
        guard idx != dragLastIndex else { return }
        dragLastIndex = idx
        selectionFeedback.selectionChanged()
        applyRange(to: idx)
    }

    /// Force every cell between the anchor and `current` to the drag's paint mode,
    /// leaving all others at their pre-drag state, then push the result.
    private func applyRange(to current: Int) {
        guard let anchor = dragAnchorIndex else { return }
        let lo = min(anchor, current), hi = max(anchor, current)
        var target = preDragSelection
        for i in lo...hi where i < assetIDs.count {
            let id = assetIDs[i]
            if dragSelecting { target.insert(id) } else { target.remove(id) }
        }
        guard target != selectedIDs else { return }
        updateSelection(target)          // immediate repaint of the changed cells
        onDragSelectionChanged(target)   // view model = source of truth
    }

    private func itemIndex(at contentPoint: CGPoint) -> Int? {
        if let ip = collectionView.indexPathForItem(at: contentPoint) { return ip.item }
        return (collectionView.collectionViewLayout as? MorphLayout)?
            .gridItemIndex(atContentPoint: contentPoint, itemCount: assetIDs.count)
    }

    // MARK: - Drag-select auto-scroll

    /// Scroll the grid when the finger nears the top/bottom edge so a drag can
    /// extend selection beyond the visible rows. `viewportY` is measured from the
    /// collection view's top.
    private func updateAutoScroll(viewportY: CGFloat) {
        let edge: CGFloat = 80
        let maxStep: CGFloat = 14
        let top = collectionView.adjustedContentInset.top
        let bottom = collectionView.bounds.height - collectionView.adjustedContentInset.bottom
        var step: CGFloat = 0
        if viewportY < top + edge {
            step = -maxStep * min(1, (top + edge - viewportY) / edge)
        } else if viewportY > bottom - edge {
            step = maxStep * min(1, (viewportY - (bottom - edge)) / edge)
        }
        autoScrollStep = step
        if step == 0 {
            stopAutoScroll()
        } else if autoScrollLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(autoScrollTick))
            link.add(to: .main, forMode: .common)
            autoScrollLink = link
        }
    }

    @objc private func autoScrollTick() {
        let minY = -collectionView.adjustedContentInset.top
        let maxY = max(minY, collectionView.contentSize.height
                       - collectionView.bounds.height + collectionView.adjustedContentInset.bottom)
        let newY = min(maxY, max(minY, collectionView.contentOffset.y + autoScrollStep))
        guard newY != collectionView.contentOffset.y else { return }   // hit the end
        collectionView.contentOffset.y = newY
        // The finger is stationary in the viewport; re-resolve the cell now under it.
        sweep(to: CGPoint(x: dragViewportPoint.x, y: dragViewportPoint.y + newY))
    }

    private func stopAutoScroll() {
        autoScrollLink?.invalidate()
        autoScrollLink = nil
        autoScrollStep = 0
    }

    // MARK: - Delegate

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

// MARK: - Morphing layout

/// Positions cells either as a horizontal strip pinned to the bottom band (browse)
/// or a vertical N-column grid filling from the top (bulk). The collection view
/// scrolls in whichever axis its content overflows. Swapping one configured
/// instance for another via `setCollectionViewLayout(_:animated:)` animates every
/// cell between the two states.
final class MorphLayout: UICollectionViewLayout {
    enum Mode { case strip, grid }

    var mode: Mode = .strip

    var columns = 5
    private let gridSpacing: CGFloat = 3
    private let stripSpacing: CGFloat = 6
    private let stripCell: CGFloat = 36
    private let horizontalPadding: CGFloat = 16
    private let stripBandHeight = MorphController.stripBandHeight
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

    /// Map a content-space point to an item index in grid mode, clamping into the
    /// grid so a drag in the padding, inter-cell gaps, or past the last row still
    /// resolves to a row + column. Used by drag-select where `indexPathForItem`
    /// returns nil. Nil in strip mode or when empty.
    func gridItemIndex(atContentPoint point: CGPoint, itemCount: Int) -> Int? {
        guard mode == .grid, itemCount > 0, let cv = collectionView else { return nil }
        let usable = cv.bounds.width - 2 * horizontalPadding - CGFloat(columns - 1) * gridSpacing
        let cell = max(1, floor(usable / CGFloat(columns)))
        let stride = cell + gridSpacing
        let top = gridTopInset + gridSpacing
        let col = min(columns - 1, max(0, Int(floor((point.x - horizontalPadding) / stride))))
        let row = max(0, Int(floor((point.y - top) / stride)))
        return min(itemCount - 1, max(0, row * columns + col))
    }
}

// MARK: - Drag-select gesture

/// A single-finger pan that commits only when the initial movement is clearly
/// horizontal; a vertical-dominant start fails the recognizer so the collection
/// view's own vertical scroll takes over. This lets a horizontal swipe begin a
/// Photos-style drag-to-select while ordinary vertical drags still scroll.
final class HorizontalDragSelectGestureRecognizer: UIPanGestureRecognizer {
    /// Points of travel before the horizontal-vs-vertical decision is made. Also
    /// the dead zone before a vertical scroll engages (the grid's scroll waits for
    /// this recognizer to fail), so keep it small.
    private let decisionThreshold: CGFloat = 10
    private var startLocation: CGPoint = .zero
    private var decided = false

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        startLocation = touches.first?.location(in: view) ?? .zero
        decided = false
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        // Until the direction is decided, withhold the base recognizer so it can't
        // begin on a vertical drag; decide once enough travel accumulates.
        if !decided, let p = touches.first?.location(in: view) {
            let dx = p.x - startLocation.x, dy = p.y - startLocation.y
            guard abs(dx) + abs(dy) >= decisionThreshold else { return }
            decided = true
            if abs(dy) > abs(dx) {
                state = .failed          // vertical → hand off to the grid's scroll
                return
            }
            // horizontal → let the base recognizer drive into .began below
        }
        super.touchesMoved(touches, with: event)
    }

    override func reset() {
        super.reset()
        decided = false
        startLocation = .zero
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

        contentView.alpha = isHiddenForFlight ? 0 : baseAlpha

        isAccessibilityElement = true
        accessibilityLabel = "Photo"
        if isBulk {
            accessibilityTraits = isSelected ? [.button, .selected] : .button
            accessibilityHint = isSelected ? "Double tap to deselect" : "Double tap to select"
        } else {
            accessibilityTraits = isCurrent ? [.image, .selected] : .image
            accessibilityHint = isCurrent ? nil : "Double tap to view"
        }

        if boundID != localID {
            boundID = localID
            loadImage(localID: localID, targetSize: targetSize)
        }
    }

    private func loadImage(localID: String, targetSize: CGSize) {
        imageTask?.cancel()
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
