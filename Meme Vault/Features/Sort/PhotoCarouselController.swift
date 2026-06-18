//
//  PhotoCarouselController.swift
//  Meme Vault
//
//  Horizontally paged carousel over the sort queue with peek of adjacent items.
//  A `UICollectionView` with a custom flow layout (page width = width − 2·margin,
//  10pt spacing) and `.fast` deceleration + a `targetContentOffset` snap, so it
//  pages with native physics (rubber-banding, deceleration, flick-through) and
//  realises only the cells near the viewport.
//
//  Replaces the SwiftUI `PhotoCardView` (ScrollView + LazyHStack). Owned by
//  `SortSessionViewController`, so its photo page rect lives in the same UIKit
//  coordinate space as the hero flights.
//

import UIKit
import Photos
import AVFoundation
import AVKit
import CoreImage.CIFilterBuiltins

final class PhotoCarouselController: NSObject, UICollectionViewDataSourcePrefetching, UICollectionViewDelegate {

    let collectionView: UICollectionView
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private let layout = PhotoCarouselLayout()

    static let margin: CGFloat = 24
    private let spacing: CGFloat = 10
    private let prefetchAhead = 3
    private let prefetchBehind = 1

    private(set) var assetIDs: [String] = []
    private(set) var currentID: String?
    /// Card is on-screen (browse); gates video playback so it doesn't run behind
    /// the bulk grid.
    var isForeground = true {
        didSet { guard isForeground != oldValue else { return }; refreshActiveCellPlayback() }
    }
    /// While true the active page hides its own photo so a hero-zoom flight owns
    /// it during a transition; the backdrop + peeking neighbors stay (and fade via
    /// the carousel's own alpha). Set false on the flight's completion.
    var suppressForeground = false {
        didSet { guard suppressForeground != oldValue else { return }; refreshActiveCellState() }
    }
    /// Page whose photo departed on a hero → album flight: that page hides its
    /// photo immediately and fades its backdrop out.
    var departedID: String? {
        didSet { guard departedID != oldValue else { return }; refreshAllVisibleState() }
    }
    /// Page whose photo is flying *in* (undo flight): hide only its foreground (the
    /// flight draws it) while keeping the blurred backdrop, so the blur fades in
    /// during the flight instead of after it lands.
    var suppressForegroundID: String? {
        didSet { guard suppressForegroundID != oldValue else { return }; refreshAllVisibleState() }
    }
    /// Image to seed a restored page's blurred backdrop with (the hero image kept
    /// when the photo was sorted), so the undo flight shows its blur immediately
    /// instead of a black gap while the full display image decodes.
    var restoreBackdropImage: (id: String, image: UIImage?)?

    /// Carousel → VM: the centered page *settled* on a new asset (commit).
    var onShowAsset: (String) -> Void = { _ in }
    /// Fired mid-drag the moment the scroll crosses the 50% mark to a new page.
    /// Used only to move the preview strip's selection — it does NOT commit the VM
    /// or scroll the carousel, so the user's drag is never interrupted.
    var onLivePageChange: (String) -> Void = { _ in }
    /// Reports the active page's asset id + decoded display image (nil while
    /// loading) for the hero flights.
    var onActiveImage: (String, UIImage?) -> Void = { _, _ in }
    /// Fired on every scroll change, so the owner can translate a hero-zoom snap-back
    /// still in flight to follow the carousel — the lifted copy then lands on its page's
    /// live (scrolled) position instead of a stale center.
    var onDidScroll: () -> Void = {}

    /// Host VC that video cells embed their `AVPlayerViewController` into (as a child
    /// VC, so native transport controls behave correctly). Set by the owning
    /// `SortSessionViewController`.
    weak var hostViewController: UIViewController?

    /// Last page reported to the strip live during a drag, so we only fire on a
    /// genuine page change.
    private var liveID: String?

    /// Guards the VM↔carousel feedback loop: true while we scroll programmatically
    /// so the resulting scroll callbacks don't echo back into `onShowAsset`.
    private var isProgrammaticScroll = false

    /// True while the undo-restore slide animation is in flight, so a layout pass
    /// (`updateLayoutMetrics`) doesn't snap the carousel to the target and cancel it.
    private var isRestoring = false

    override init() {
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = spacing
        layout.minimumInteritemSpacing = 0
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init()

        collectionView.backgroundColor = .clear
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.decelerationRate = .fast
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.delegate = self
        collectionView.prefetchDataSource = self
        collectionView.translatesAutoresizingMaskIntoConstraints = false

        let registration = UICollectionView.CellRegistration<PhotoPageCell, String> { [weak self] cell, _, id in
            guard let self else { return }
            cell.delegate = self
            cell.hostViewController = self.hostViewController
            cell.configure(
                assetID: id,
                targetSize: self.pixelTargetSize,
                isActive: id == self.currentID,
                isForeground: self.isForeground,
                suppressForeground: self.suppressForeground || id == self.suppressForegroundID,
                isDeparted: id == self.departedID
            )
            if let seed = self.restoreBackdropImage, seed.id == id, let image = seed.image {
                cell.seedBackdrop(image)
            }
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { cv, indexPath, id in
            cv.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
        }
    }

    // MARK: - Geometry

    var pageWidth: CGFloat { max(1, collectionView.bounds.width - 2 * Self.margin) }
    private var pageStride: CGFloat { pageWidth + spacing }

    /// On-screen rect of the centered hero page (where the photo is shown), in
    /// `target`'s coordinate space. Independent of the current scroll position —
    /// the centered page always sits at the same place — so it's the landing rect
    /// for the undo flight even before the carousel jumps to the restored item.
    func heroPageRect(in target: UIView) -> CGRect {
        let rect = CGRect(x: collectionView.contentOffset.x + Self.margin, y: 0,
                          width: pageWidth, height: collectionView.bounds.height)
        return collectionView.convert(rect, to: target)
    }

    /// Tallest the hero page can become (set by the owner). Display images are decoded
    /// for this height rather than the current one, so shrinking the hero and swiping
    /// doesn't cache soft, low-res frames that then look blurry once it's enlarged.
    var maxPageHeight: CGFloat = 0

    private var pixelTargetSize: CGSize {
        let scale = collectionView.traitCollection.displayScale > 0 ? collectionView.traitCollection.displayScale : 2
        let height = max(collectionView.bounds.height, maxPageHeight)
        return CGSize(width: pageWidth * scale, height: height * scale)
    }

    /// Apply the page metrics to the layout; call from the VC's layout pass.
    func updateLayoutMetrics() {
        let target = CGSize(width: pageWidth, height: collectionView.bounds.height)
        if layout.itemSize != target {
            layout.itemSize = target
            layout.invalidateLayout()
        }
        layout.sectionInset = UIEdgeInsets(top: 0, left: Self.margin, bottom: 0, right: Self.margin)
        // Keep the current page centered after a bounds/inset change — but not while
        // an undo-restore slide is animating, or it would snap straight to the target.
        if !isRestoring { scrollToCurrent(animated: false) }
    }

    // MARK: - Snapshot / binding

    func applySnapshot(_ ids: [String], animated: Bool) {
        assetIDs = ids
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(ids)
        dataSource.apply(snapshot, animatingDifferences: animated)
        updatePrefetchWindow()
    }

    /// Restore an undone item into the carousel. When it lands immediately before
    /// the page we're showing (the common "undo right after sorting" case), hold
    /// the viewport exactly on that page and let the *animated insert* do the work:
    /// the restored item fades in at center while the page we were on — and only
    /// the pages to its right — slide one slot right. The viewport never scrolls,
    /// so pages to the left stay put. This is the mirror of the sort's animated
    /// delete (which collapses the slot and slides the next page left into place).
    /// Otherwise jump straight to it, avoiding a long whip-scroll from far away.
    func applyRestore(_ ids: [String], restoredID: String, animated: Bool) {
        let shownID = currentID
        let oldShownIdx = shownID.flatMap { assetIDs.firstIndex(of: $0) }   // pre-insert
        let newRestoredIdx = ids.firstIndex(of: restoredID)
        let newShownIdx = shownID.flatMap { ids.firstIndex(of: $0) }
        let adjacent = animated && pageStride > 0
            && !UIAccessibility.isReduceMotionEnabled
            && oldShownIdx != nil && newRestoredIdx != nil
            && newShownIdx == (newRestoredIdx ?? -2) + 1

        if adjacent {
            // Insert structurally without animation, force the viewport onto the
            // restored page's slot (overriding UIKit's compensate-scroll), then slide
            // only the pages *right* of the insert one slot over: each starts shifted
            // a stride left (its pre-insert on-screen spot) and animates home. The
            // restored page sits still at center (its foreground flies in, its blur
            // fades in), the page to the left never moves, and the viewport doesn't
            // scroll — the mirror of the sort's collapse-and-slide-left.
            let restoredIdx = newRestoredIdx!
            let restoredX = CGFloat(restoredIdx) * pageStride
            isProgrammaticScroll = true
            applySnapshot(ids, animated: false)
            currentID = restoredID
            collectionView.setContentOffset(CGPoint(x: restoredX, y: 0), animated: false)
            collectionView.layoutIfNeeded()
            isProgrammaticScroll = false
            refreshAllVisibleState()

            var shifted: [UICollectionViewCell] = []
            for cell in collectionView.visibleCells {
                guard let ip = collectionView.indexPath(for: cell), ip.item > restoredIdx else { continue }
                cell.transform = CGAffineTransform(translationX: -pageStride, y: 0)
                // Keep the sliding page above the restored (center) page while it
                // covers and then uncovers it — cell z-order isn't index order.
                cell.layer.zPosition = 2
                shifted.append(cell)
            }
            isRestoring = true
            UIView.animate(withDuration: 0.3, delay: 0, options: [.curveEaseInOut]) {
                for cell in shifted { cell.transform = .identity }
            } completion: { [weak self] _ in
                self?.isRestoring = false
                for cell in shifted { cell.layer.zPosition = 0 }
            }
        } else {
            applySnapshot(ids, animated: false)
            currentID = restoredID
            updatePrefetchWindow()
            collectionView.layoutIfNeeded()
            refreshAllVisibleState()
            if pageStride > 0, let restoredIdx = assetIDs.firstIndex(of: restoredID) {
                collectionView.setContentOffset(CGPoint(x: CGFloat(restoredIdx) * pageStride, y: 0), animated: false)
            }
        }
    }

    /// VM → carousel: jump to a page. Non-animated for the scroll-anchored bulk
    /// exit (the page is decoded behind the grid before the carousel reappears).
    func setCurrent(_ id: String?, animated: Bool) {
        guard currentID != id else { return }
        currentID = id
        liveID = id
        // Never scroll the carousel while the user is interacting with it — a
        // programmatic offset change would fight their drag.
        if !collectionView.isTracking, !collectionView.isDragging, !collectionView.isDecelerating {
            scrollToCurrent(animated: animated)
        }
        updatePrefetchWindow()
        refreshAllVisibleState()
    }

    private func scrollToCurrent(animated: Bool) {
        guard let id = currentID, let idx = assetIDs.firstIndex(of: id),
              collectionView.bounds.width > 0 else { return }
        let offset = CGPoint(x: CGFloat(idx) * pageStride, y: 0)
        guard abs(collectionView.contentOffset.x - offset.x) > 0.5 else { return }
        isProgrammaticScroll = true
        collectionView.setContentOffset(offset, animated: animated)
        if !animated { isProgrammaticScroll = false }
    }

    private func centeredIndex() -> Int {
        guard pageStride > 0 else { return 0 }
        let raw = (collectionView.contentOffset.x) / pageStride
        return max(0, min(assetIDs.count - 1, Int(raw.rounded())))
    }

    /// Commit the settled page to the VM (called when the scroll comes to rest).
    private func commitPage() {
        guard !assetIDs.isEmpty else { return }
        let id = assetIDs[centeredIndex()]
        liveID = id
        guard id != currentID else {
            // Settled back on the committed page (e.g. a half-swipe that snapped
            // back): just make sure its playback is active.
            refreshAllVisibleState()
            return
        }
        currentID = id
        updatePrefetchWindow()
        // The newly-centered page becomes active: refresh visible cells so it
        // starts video/GIF playback and reports its display image for the flights.
        refreshAllVisibleState()
        onShowAsset(id)
    }

    /// Settle on the currently-centered (most-visible) page and commit it to the
    /// VM now. Call before an action that operates on "the current photo" while a
    /// scroll may still be decelerating, so it acts on what the user actually sees
    /// rather than the last fully-settled page.
    func commitVisiblePage() {
        guard !assetIDs.isEmpty, pageStride > 0 else { return }
        let idx = centeredIndex()
        // Halt any in-flight deceleration, snapping to that page.
        if collectionView.isDecelerating || collectionView.isDragging || collectionView.isTracking {
            isProgrammaticScroll = true
            collectionView.setContentOffset(CGPoint(x: CGFloat(idx) * pageStride, y: 0), animated: false)
            isProgrammaticScroll = false
        }
        let id = assetIDs[idx]
        liveID = id
        guard id != currentID else { return }
        currentID = id
        updatePrefetchWindow()
        refreshAllVisibleState()
        onShowAsset(id)
    }

    // MARK: - Active cell state

    private func activeCell() -> PhotoPageCell? {
        guard let id = currentID, let idx = assetIDs.firstIndex(of: id) else { return nil }
        return collectionView.cellForItem(at: IndexPath(item: idx, section: 0)) as? PhotoPageCell
    }

    private func refreshActiveCellPlayback() { refreshAllVisibleState() }
    private func refreshActiveCellState() { refreshAllVisibleState() }

    private func refreshAllVisibleState() {
        for case let cell as PhotoPageCell in collectionView.visibleCells {
            guard let idx = collectionView.indexPath(for: cell)?.item, idx < assetIDs.count else { continue }
            let id = assetIDs[idx]
            cell.updateState(
                isActive: id == currentID,
                isForeground: isForeground,
                suppressForeground: suppressForeground || id == suppressForegroundID,
                isDeparted: id == departedID
            )
        }
    }

    // MARK: - Prefetch window

    private func updatePrefetchWindow(center: String? = nil) {
        guard let id = center ?? currentID, let i = assetIDs.firstIndex(of: id) else {
            ImageLoader.shared.setCacheWindow(assetIDs: [], targetSize: pixelTargetSize)
            return
        }
        let lower = max(0, i - prefetchBehind)
        let upper = min(assetIDs.count - 1, i + prefetchAhead)
        ImageLoader.shared.setCacheWindow(assetIDs: Array(assetIDs[lower...upper]), targetSize: pixelTargetSize)
    }

    func collectionView(_ cv: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        // The display-window prefetch is driven by setCacheWindow; nothing extra.
    }

    /// A cell left the screen — scrolled away, or its item was sorted/removed. Stop
    /// its playback now: an `AVPlayer` keeps playing audio even with no visible view,
    /// so without this a sorted video's sound lingers from an orphaned player.
    func collectionView(_ cv: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        (cell as? PhotoPageCell)?.endDisplaying()
    }

    // MARK: - Paging snap

    /// Snap to the nearest page, reproducing `.scrollTargetBehavior(.viewAligned)`.
    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        guard pageStride > 0 else { return }
        let proposed = targetContentOffset.pointee.x
        var page = (proposed / pageStride).rounded()
        // Bias toward the flicked direction so a quick swipe advances one page.
        if abs(velocity.x) > 0.2 {
            let current = (scrollView.contentOffset.x / pageStride).rounded()
            page = velocity.x > 0 ? max(page, current + 1) : min(page, current - 1)
        }
        page = max(0, min(CGFloat(assetIDs.count - 1), page))
        targetContentOffset.pointee = CGPoint(x: page * pageStride, y: 0)
    }

    /// Live page tracking: the moment the scroll crosses the 50% mark toward the
    /// next page (`centeredIndex` rounds at the halfway point), move *only* the
    /// preview strip's selection — without committing the VM or scrolling the
    /// carousel, so the drag is never interrupted. The commit happens on settle.
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // Fired for every offset change (including the unguarded cases below) so a
        // hero-zoom snap-back can ride the scroll.
        onDidScroll()
        guard !isProgrammaticScroll,
              scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating,
              !assetIDs.isEmpty else { return }
        let id = assetIDs[centeredIndex()]
        guard id != liveID else { return }
        liveID = id
        updatePrefetchWindow(center: id)
        onLivePageChange(id)
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        commitPage()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { commitPage() }
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        isProgrammaticScroll = false
    }
}

// MARK: - Active image reporting

extension PhotoCarouselController: PhotoPageCellDelegate {
    func photoPageCell(_ cell: PhotoPageCell, didProvideActiveImage image: UIImage?, for assetID: String) {
        guard assetID == currentID else { return }
        onActiveImage(assetID, image)
    }
}

// MARK: - Layout

/// Flow layout whose item is a single page; the section insets give the peek and
/// the spacing separates neighbors. Paging snap is done in the controller's
/// `scrollViewWillEndDragging`.
final class PhotoCarouselLayout: UICollectionViewFlowLayout {
    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        collectionView?.bounds.size != newBounds.size
    }
}

// MARK: - Page cell

protocol PhotoPageCellDelegate: AnyObject {
    func photoPageCell(_ cell: PhotoPageCell, didProvideActiveImage image: UIImage?, for assetID: String)
}

final class PhotoPageCell: UICollectionViewCell {
    weak var delegate: PhotoPageCellDelegate?

    private let card = UIView()
    private let backdropBlack = UIView()
    private let backdropImageView = UIImageView()
    private let foregroundImageView = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    // Missing / load-failure state: icon + message, plus a Retry button for the
    // common "iCloud asset, offline" case (network access is allowed, so a retry
    // once back online succeeds).
    private let missingStack = UIStackView()
    private let missingIcon = UIImageView()
    private let missingLabel = UILabel()
    private let missingRetryButton = UIButton(type: .system)
    private var playerVC: AVPlayerViewController?
    /// Host VC the `AVPlayerViewController` is added to as a child (set from the
    /// controller). Lets the native video controls behave correctly.
    weak var hostViewController: UIViewController?

    private enum MediaKind { case image, gif, video }
    private enum Phase { case loading, loaded, missing }

    private var assetID: String?
    private var targetSize: CGSize = .zero
    private var kind: MediaKind = .image
    private var phase: Phase = .loading
    private var image: UIImage?

    private var isActive = false
    private var isForeground = true
    private var suppressForeground = false
    private var isDeparted = false

    private var loadTask: Task<Void, Never>?
    private var playbackTask: Task<Void, Never>?
    private var player: AVPlayer?
    private var loopToken: NSObjectProtocol?
    private var muteObservation: NSKeyValueObservation?

    private var shouldPlay: Bool { isActive && isForeground && !suppressForeground }

    override init(frame: CGRect) {
        super.init(frame: frame)

        card.backgroundColor = UIColor.secondarySystemBackground
        card.layer.cornerRadius = 16
        card.clipsToBounds = true
        card.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(card)

        backdropBlack.backgroundColor = .black
        backdropBlack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(backdropBlack)

        backdropImageView.contentMode = .scaleAspectFill
        backdropImageView.clipsToBounds = true
        backdropImageView.alpha = 0.8
        backdropImageView.translatesAutoresizingMaskIntoConstraints = false
        backdropBlack.addSubview(backdropImageView)

        foregroundImageView.contentMode = .scaleAspectFit
        foregroundImageView.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(foregroundImageView)

        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(spinner)

        missingIcon.tintColor = .secondaryLabel
        missingIcon.contentMode = .center
        missingIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .largeTitle)

        missingLabel.font = .preferredFont(forTextStyle: .subheadline)
        missingLabel.adjustsFontForContentSizeCategory = true
        missingLabel.textColor = .secondaryLabel
        missingLabel.textAlignment = .center
        missingLabel.numberOfLines = 0

        var retryConfig = UIButton.Configuration.tinted()
        retryConfig.title = "Retry"
        retryConfig.image = UIImage(systemName: "arrow.clockwise")
        retryConfig.imagePadding = 4
        retryConfig.buttonSize = .small
        missingRetryButton.configuration = retryConfig
        missingRetryButton.addAction(UIAction { [weak self] _ in self?.retryLoad() }, for: .touchUpInside)

        missingStack.axis = .vertical
        missingStack.alignment = .center
        missingStack.spacing = 8
        missingStack.isHidden = true
        missingStack.translatesAutoresizingMaskIntoConstraints = false
        missingStack.addArrangedSubview(missingIcon)
        missingStack.addArrangedSubview(missingLabel)
        missingStack.setCustomSpacing(12, after: missingLabel)
        missingStack.addArrangedSubview(missingRetryButton)
        card.addSubview(missingStack)

        isAccessibilityElement = true
        accessibilityTraits = .image

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            card.topAnchor.constraint(equalTo: contentView.topAnchor),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            backdropBlack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            backdropBlack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            backdropBlack.topAnchor.constraint(equalTo: card.topAnchor),
            backdropBlack.bottomAnchor.constraint(equalTo: card.bottomAnchor),

            backdropImageView.leadingAnchor.constraint(equalTo: backdropBlack.leadingAnchor),
            backdropImageView.trailingAnchor.constraint(equalTo: backdropBlack.trailingAnchor),
            backdropImageView.topAnchor.constraint(equalTo: backdropBlack.topAnchor),
            backdropImageView.bottomAnchor.constraint(equalTo: backdropBlack.bottomAnchor),

            foregroundImageView.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            foregroundImageView.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            foregroundImageView.topAnchor.constraint(equalTo: card.topAnchor),
            foregroundImageView.bottomAnchor.constraint(equalTo: card.bottomAnchor),

            spinner.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            missingStack.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            missingStack.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            missingStack.leadingAnchor.constraint(greaterThanOrEqualTo: card.leadingAnchor, constant: 20),
            missingStack.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -20),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Configure

    func configure(assetID: String, targetSize: CGSize, isActive: Bool, isForeground: Bool, suppressForeground: Bool, isDeparted: Bool) {
        let assetChanged = self.assetID != assetID
        self.assetID = assetID
        self.targetSize = targetSize
        self.isActive = isActive
        self.isForeground = isForeground
        self.suppressForeground = suppressForeground
        self.isDeparted = isDeparted

        if assetChanged {
            loadStill()
        } else if isActive {
            delegate?.photoPageCell(self, didProvideActiveImage: image, for: assetID)
        }
        applyVisibility()
        syncPlayback()
    }

    /// Seed the blurred backdrop from an image supplied by the controller (the
    /// hero image kept when this photo was sorted), so a restored page shows its
    /// blur immediately during the undo flight rather than a black gap while the
    /// full display image decodes. No-op once a backdrop is already present.
    func seedBackdrop(_ source: UIImage) {
        guard backdropImageView.image == nil else { return }
        let id = assetID
        Task.detached(priority: .userInitiated) {
            let blurred = Self.blurredBackdrop(from: source)
            await MainActor.run { [weak self] in
                guard let self, self.assetID == id, self.backdropImageView.image == nil else { return }
                self.backdropImageView.alpha = 0
                self.backdropImageView.image = blurred
                UIView.animate(withDuration: 0.2) { self.backdropImageView.alpha = 0.8 }
            }
        }
    }

    /// Lightweight state update (active/foreground/suppress/departed) without
    /// reloading the still.
    func updateState(isActive: Bool, isForeground: Bool, suppressForeground: Bool, isDeparted: Bool) {
        let wasActive = self.isActive
        self.isActive = isActive
        self.isForeground = isForeground
        self.suppressForeground = suppressForeground
        self.isDeparted = isDeparted
        if isActive, !wasActive, let assetID {
            delegate?.photoPageCell(self, didProvideActiveImage: image, for: assetID)
        }
        applyVisibility()
        syncPlayback()
    }

    private func applyVisibility() {
        // Suppressed on the active page during a hero-zoom flight: the flight draws
        // the photo. Hidden outright when departed (the album flight draws it).
        let hideForeground = (suppressForeground && isActive) || isDeparted
        foregroundImageView.alpha = hideForeground ? 0 : 1
        playerVC?.view.alpha = hideForeground ? 0 : 1

        // Fade card + backdrop when the photo departs on a flight, so no remnant
        // lingers where the photo was.
        UIView.animate(withDuration: 0.15) {
            self.card.backgroundColor = self.isDeparted
                ? UIColor.secondarySystemBackground.withAlphaComponent(0)
                : UIColor.secondarySystemBackground
            self.backdropBlack.alpha = self.isDeparted ? 0 : 1
        }
    }

    // MARK: Loading

    private func loadStill() {
        loadTask?.cancel()
        teardownPlayer()
        image = nil
        backdropImageView.image = nil
        foregroundImageView.image = nil
        foregroundImageView.animationImages = nil
        foregroundImageView.stopAnimating()
        phase = .loading
        missingStack.isHidden = true
        spinner.startAnimating()
        accessibilityLabel = "Loading photo"

        let id = assetID ?? ""
        let size = targetSize
        loadTask = Task { @MainActor [weak self] in
            let asset = await Task.detached(priority: .userInitiated) { AlbumService.asset(for: id) }.value
            guard let self, !Task.isCancelled, self.assetID == id else { return }
            guard let asset else {
                // Asset itself is gone (deleted / removed from the library) — a
                // retry can't recover it.
                self.phase = .missing
                self.spinner.stopAnimating()
                self.showMissing(retryable: false)
                return
            }
            self.kind = Self.mediaKind(for: asset)
            let loaded = await ImageLoader.shared.loadDisplayImage(for: asset, targetSize: size)
            guard !Task.isCancelled, self.assetID == id else { return }
            self.spinner.stopAnimating()
            self.image = loaded
            self.phase = loaded == nil ? .missing : .loaded
            if loaded == nil {
                // The asset exists but its image couldn't be loaded — almost always
                // an iCloud original that isn't downloaded and no connection. Offer
                // a retry.
                self.showMissing(retryable: true)
            } else {
                self.missingStack.isHidden = true
                self.accessibilityLabel = self.kind == .video ? "Video" : "Photo"
            }
            if let loaded {
                self.foregroundImageView.image = loaded
                // Real Gaussian blur, computed off-main (Core Image) so the decode
                // hand-off stays smooth, then applied if the page is still bound.
                Task.detached(priority: .utility) {
                    let blurred = Self.blurredBackdrop(from: loaded)
                    await MainActor.run { [weak self] in
                        guard let self, self.assetID == id else { return }
                        // When the foreground is suppressed for an in-flight photo
                        // (undo flight), fade the blur in so it appears during the
                        // flight rather than popping in after it lands.
                        if self.suppressForeground, self.backdropImageView.image == nil {
                            // Not seeded — fade the blur in during the flight.
                            self.backdropImageView.alpha = 0
                            self.backdropImageView.image = blurred
                            UIView.animate(withDuration: 0.25) { self.backdropImageView.alpha = 0.8 }
                        } else {
                            // Already visible (seeded or steady state) — upgrade the
                            // image in place without re-flashing the alpha.
                            self.backdropImageView.image = blurred
                        }
                    }
                }
            }
            self.applyVisibility()
            if self.isActive {
                self.delegate?.photoPageCell(self, didProvideActiveImage: loaded, for: id)
            }
            self.syncPlayback()
        }
    }

    /// Configure and show the missing/failure state. `retryable` distinguishes a
    /// transient load failure (asset exists, e.g. iCloud + offline → show Retry)
    /// from a permanently-gone asset (no Retry).
    private func showMissing(retryable: Bool) {
        missingIcon.image = UIImage(systemName: retryable ? "icloud.slash" : "photo.badge.exclamationmark")
        missingLabel.text = retryable
            ? "Couldn't load this photo.\nCheck your connection and try again."
            : "This photo is no longer available."
        missingRetryButton.isHidden = !retryable
        missingStack.isHidden = false
        accessibilityLabel = retryable ? "Couldn't load photo" : "Photo unavailable"
        accessibilityHint = retryable ? "Double tap Retry to try loading again" : nil
    }

    private func retryLoad() {
        missingStack.isHidden = true
        loadStill()
    }

    // MARK: Playback

    private func syncPlayback() {
        guard shouldPlay, phase == .loaded else {
            playbackTask?.cancel()
            playbackTask = nil
            teardownPlayer()
            if kind == .gif { foregroundImageView.stopAnimating() }
            return
        }
        let id = assetID ?? ""
        playbackTask?.cancel()
        playbackTask = Task { @MainActor [weak self] in
            guard let self, let asset = AlbumService.asset(for: id) else { return }
            switch Self.mediaKind(for: asset) {
            case .image:
                break
            case .gif:
                if self.foregroundImageView.animationImages == nil {
                    let decoded = await ImageLoader.shared.loadAnimatedImage(for: asset)
                    guard !Task.isCancelled, self.assetID == id, let decoded else { return }
                    self.foregroundImageView.animationImages = decoded.images
                    self.foregroundImageView.animationDuration = decoded.duration
                }
                self.foregroundImageView.startAnimating()
            case .video:
                guard let item = await ImageLoader.shared.loadPlayerItem(for: asset) else { return }
                guard !Task.isCancelled, self.assetID == id else { return }
                self.setupPlayer(item: item)
            }
        }
    }

    private func setupPlayer(item: AVPlayerItem) {
        teardownPlayer()
        let p = AVPlayer(playerItem: item)
        p.actionAtItemEnd = .none
        p.isMuted = true
        // The user unmutes via the native control's speaker button; switch the audio
        // session to .playback then so sound comes through even with the ringer off.
        muteObservation = p.observe(\.isMuted, options: [.new]) { player, _ in
            guard !player.isMuted else { return }
            Self.activatePlaybackAudioSession()
        }
        loopToken = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak p] _ in
            p?.seek(to: .zero)
            p?.play()
        }

        // An AVPlayerViewController (not a bare AVPlayerLayer) so the video has native
        // transport controls on tap and a mute toggle, and — being an Auto Layout
        // view pinned to the card — resizes in lockstep with the grabber drag rather
        // than lagging behind on its own implicit animation.
        let vc = AVPlayerViewController()
        vc.player = p
        vc.showsPlaybackControls = true
        vc.videoGravity = .resizeAspect
        vc.allowsPictureInPicturePlayback = false
        vc.updatesNowPlayingInfoCenter = false
        vc.view.backgroundColor = .clear
        vc.view.translatesAutoresizingMaskIntoConstraints = false

        hostViewController?.addChild(vc)
        card.addSubview(vc.view)
        NSLayoutConstraint.activate([
            vc.view.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            vc.view.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            vc.view.topAnchor.constraint(equalTo: card.topAnchor),
            vc.view.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        if hostViewController != nil { vc.didMove(toParent: hostViewController) }

        playerVC = vc
        player = p
        applyVisibility()
        p.play()
    }

    private func teardownPlayer() {
        player?.pause()
        if let loopToken { NotificationCenter.default.removeObserver(loopToken) }
        loopToken = nil
        muteObservation?.invalidate()
        muteObservation = nil
        player = nil
        if let vc = playerVC {
            vc.willMove(toParent: nil)
            vc.view.removeFromSuperview()
            vc.removeFromParent()
        }
        playerVC = nil
    }

    /// Stop all playback because the cell has left the screen (without resetting the
    /// loaded still — it stays bound for a quick re-display). Called from the
    /// controller's `didEndDisplaying`, so a removed/scrolled-away video's audio
    /// can't keep playing from an orphaned player. If the cell becomes active again,
    /// `syncPlayback` rebuilds the player.
    func endDisplaying() {
        playbackTask?.cancel()
        playbackTask = nil
        teardownPlayer()
        if kind == .gif { foregroundImageView.stopAnimating() }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadTask?.cancel(); loadTask = nil
        playbackTask?.cancel(); playbackTask = nil
        teardownPlayer()
        assetID = nil
        image = nil
        foregroundImageView.image = nil
        foregroundImageView.animationImages = nil
        foregroundImageView.stopAnimating()
        backdropImageView.image = nil
        backdropImageView.alpha = 0.8
        foregroundImageView.alpha = 1
        backdropBlack.alpha = 1
        card.backgroundColor = .secondarySystemBackground
        missingStack.isHidden = true
        accessibilityHint = nil
        spinner.stopAnimating()
    }

    // MARK: Helpers

    private static func mediaKind(for asset: PHAsset) -> MediaKind {
        if asset.mediaType == .video { return .video }
        return asset.playbackStyle == .imageAnimated ? .gif : .image
    }

    nonisolated private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// A properly blurred copy of the page image for the carousel's fill. The
    /// source is downsampled (the blur erases fine detail anyway) and run through a
    /// real Core Image Gaussian blur, then clamped to its extent so the edges don't
    /// fade to transparent — a genuine frosted blur rather than an upscaled copy.
    nonisolated private static func blurredBackdrop(from image: UIImage) -> UIImage {
        let maxDimension: CGFloat = 160
        let longest = max(image.size.width, image.size.height)
        let scale = longest > maxDimension ? maxDimension / longest : 1
        let newSize = CGSize(width: max(1, image.size.width * scale), height: max(1, image.size.height * scale))
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        format.opaque = true
        let small = UIGraphicsImageRenderer(size: newSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }

        guard let input = CIImage(image: small) else { return small }
        let filter = CIFilter.gaussianBlur()
        filter.inputImage = input.clampedToExtent()
        filter.radius = 18
        guard let output = filter.outputImage,
              let cg = ciContext.createCGImage(output, from: input.extent) else { return small }
        return UIImage(cgImage: cg)
    }

    /// Serial queue for audio-session configuration. `setCategory`/`setActive` are
    /// synchronous and can block, so they must run off the main thread (UIKit warns
    /// otherwise); serialising keeps overlapping unmute events from racing.
    private static let audioSessionQueue = DispatchQueue(label: "com.memevault.audioSession")

    private static func activatePlaybackAudioSession() {
        audioSessionQueue.async {
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .moviePlayback)
            try? session.setActive(true)
        }
    }
}
