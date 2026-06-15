//
//  AlbumGridController.swift
//  Meme Vault
//
//  The scrollable destination-album grid (context albums, pinned albums, and
//  extras) as a UIKit compositional-layout collection view. Replaces the SwiftUI
//  `AlbumListView` + `AlbumGridCell`. Owned by `SortSessionViewController`, so its
//  cell frames live in the same coordinate space as the hero → album-slot flight.
//

import UIKit
import Photos

/// One preview thumbnail for an album cell.
struct AlbumThumbnail: Equatable {
    let id: String
    let image: UIImage
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

nonisolated enum AlbumGroup: Hashable, Sendable { case context, pinned, extra }

/// Stable identity for a grid item — the same album never appears in two groups
/// (pinned excludes context, extras exclude both), but the composite key keeps
/// the diffable data source unambiguous.
nonisolated struct AlbumItem: Hashable, Sendable {
    let id: String
    let group: AlbumGroup
}

final class AlbumGridController: NSObject, UICollectionViewDelegate {

    let collectionView: UICollectionView
    /// One flat section so every group (context, pinned, extras) flows inline in the
    /// same grid rather than each starting on its own row. Group identity lives on
    /// each `AlbumItem` (drives dimming + tap routing).
    private var dataSource: UICollectionViewDiffableDataSource<Int, AlbumItem>!

    /// 2…5, persisted per context by the VC.
    var columns: Int = 3

    /// Tap on an album cell — the VC routes by group/mode.
    var onTap: (AlbumGroup, String) -> Void = { _, _ in }
    /// Long-press → "View Contents".
    var onViewContents: (String, String) -> Void = { _, _ in }

    // Snapshot of model state the cells read, keyed by album id.
    private var infoByID: [String: AlbumInfo] = [:]
    private var groupOf: [String: AlbumGroup] = [:]
    private var memberIDs: Set<String> = []
    private var recentAdds: [String: [String]] = [:]
    private var bulkDirect = false
    /// Album whose first preview slot stays blank until an in-flight hero lands.
    private var flyingToAlbumID: String?
    private var flyingPhotoID: String?

    private let thumbTarget = CGSize(width: 200, height: 200)

    override init() {
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewLayout())
        super.init()
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.delegate = self
        collectionView.setCollectionViewLayout(makeLayout(), animated: false)

        let registration = UICollectionView.CellRegistration<AlbumCell, AlbumItem> { [weak self] cell, _, item in
            guard let self, let info = self.infoByID[item.id] else { return }
            let isMember = self.bulkDirect ? false : self.memberIDs.contains(item.id)
            let dimmed = (item.group == .pinned || item.group == .extra) && !isMember
            cell.configure(
                albumID: info.id,
                title: info.title,
                count: info.assetCount,
                isMember: isMember,
                recentIDs: self.recentAdds[info.id] ?? [],
                hiddenThumbID: self.flyingToAlbumID == info.id ? self.flyingPhotoID : nil,
                dimmed: dimmed,
                thumbTarget: self.thumbTarget
            )
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { cv, indexPath, item in
            cv.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: item)
        }
    }

    // MARK: - Layout

    private func makeLayout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { [weak self] _, env in
            let columns = max(2, self?.columns ?? 3)
            let spacing: CGFloat = 12
            let inset: CGFloat = 16
            let available = env.container.effectiveContentSize.width - 2 * inset - spacing * CGFloat(columns - 1)
            let col = max(1, floor(available / CGFloat(columns)))
            let textHeight: CGFloat = 42
            let itemHeight = col + 6 + textHeight

            let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(
                widthDimension: .absolute(col), heightDimension: .absolute(itemHeight)))
            let group = NSCollectionLayoutGroup.horizontal(
                layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(itemHeight)),
                subitems: [item])
            group.interItemSpacing = .fixed(spacing)
            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = 8
            section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: inset, bottom: 0, trailing: inset)
            return section
        }
    }

    func setColumns(_ columns: Int, animated: Bool) {
        guard self.columns != columns else { return }
        self.columns = columns
        collectionView.setCollectionViewLayout(makeLayout(), animated: animated)
    }

    // MARK: - Update from VM

    func update(
        context: [AlbumInfo],
        pinned: [AlbumInfo],
        extras: [AlbumInfo],
        memberIDs: Set<String>,
        recentAdds: [String: [String]],
        bulkDirect: Bool,
        animated: Bool
    ) {
        // Cache lookups for the cell registration.
        var infos: [String: AlbumInfo] = [:]
        var groups: [String: AlbumGroup] = [:]
        for i in context { infos[i.id] = i; groups[i.id] = .context }
        for i in pinned { infos[i.id] = i; groups[i.id] = .pinned }
        for i in extras { infos[i.id] = i; groups[i.id] = .extra }

        let countsChanged = infos.mapValues(\.assetCount) != infoByID.mapValues(\.assetCount)
        let membersChanged = memberIDs != self.memberIDs
        let recentChanged = recentAdds != self.recentAdds
        let bulkChanged = bulkDirect != self.bulkDirect

        infoByID = infos
        groupOf = groups
        self.memberIDs = memberIDs
        self.recentAdds = recentAdds
        self.bulkDirect = bulkDirect

        var snapshot = NSDiffableDataSourceSnapshot<Int, AlbumItem>()
        snapshot.appendSections([0])
        snapshot.appendItems(context.map { AlbumItem(id: $0.id, group: .context) }, toSection: 0)
        snapshot.appendItems(pinned.map { AlbumItem(id: $0.id, group: .pinned) }, toSection: 0)
        snapshot.appendItems(extras.map { AlbumItem(id: $0.id, group: .extra) }, toSection: 0)

        let prevItems = Set(dataSource.snapshot().itemIdentifiers)
        let newItems = Set(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: animated && prevItems != newItems)

        // Repaint visible cells whose appearance (member/count/recent/bulk) changed
        // but whose identity didn't, so toggles don't require a full re-snapshot.
        if countsChanged || membersChanged || recentChanged || bulkChanged {
            var reconf = snapshot
            let stable = newItems.intersection(prevItems)
            reconf.reconfigureItems(Array(stable))
            if !stable.isEmpty { dataSource.apply(reconf, animatingDifferences: false) }
        }
    }

    func setBottomInset(_ inset: CGFloat) {
        if collectionView.contentInset.bottom != inset {
            collectionView.contentInset.bottom = inset
            collectionView.verticalScrollIndicatorInsets.bottom = inset
        }
    }

    // MARK: - Hero → album flight support

    func setFlight(albumID: String?, photoID: String?) {
        let prev = flyingToAlbumID
        flyingToAlbumID = albumID
        flyingPhotoID = photoID
        // Repaint the affected cell(s) so the destination's first slot blanks /
        // un-blanks without a full snapshot apply.
        var ids = Set<String>()
        if let prev { ids.insert(prev) }
        if let albumID { ids.insert(albumID) }
        reconfigure(ids)
    }

    private func reconfigure(_ albumIDs: Set<String>) {
        guard !albumIDs.isEmpty else { return }
        var snapshot = dataSource.snapshot()
        let items = snapshot.itemIdentifiers.filter { albumIDs.contains($0.id) }
        guard !items.isEmpty else { return }
        snapshot.reconfigureItems(items)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// The global frame (in `view`'s space) of an album cell's first preview slot,
    /// for the hero → album-slot flight. Returns nil if the cell isn't on screen.
    func firstSlotFrame(forAlbum albumID: String, in view: UIView) -> CGRect? {
        guard let group = groupOf[albumID],
              let indexPath = dataSource.indexPath(for: AlbumItem(id: albumID, group: group)),
              let cell = collectionView.cellForItem(at: indexPath) as? AlbumCell
        else { return nil }
        return cell.firstSlotFrame(in: view)
    }

    // MARK: - Delegate

    func collectionView(_ cv: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        cv.deselectItem(at: indexPath, animated: false)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        onTap(item.group, item.id)
    }

    func collectionView(_ cv: UICollectionView, contextMenuConfigurationForItemAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard let item = dataSource.itemIdentifier(for: indexPath), let info = infoByID[item.id] else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            let sort = UIAction(title: "Sort to Album", image: UIImage(systemName: "rectangle.portrait.and.arrow.forward")) { _ in
                self?.onTap(item.group, item.id)
            }
            let view = UIAction(title: "View Contents", image: UIImage(systemName: "photo.on.rectangle")) { _ in
                self?.onViewContents(info.id, info.title)
            }
            return UIMenu(children: [sort, view])
        }
    }
}

// MARK: - Cell

final class AlbumCell: UICollectionViewCell {
    private let previewContainer = UIView()
    private let placeholder = UIImageView()
    private let checkmark = UIImageView()
    private let titleLabel = UILabel()
    private let countLabel = UILabel()
    /// Gray backgrounds for the four 2×2 slots (shown for empty slots when there
    /// is at least one thumbnail), and the per-photo thumbnail views, keyed by
    /// asset id so they can animate to a new slot when the order changes.
    private var slotBackgrounds: [UIView] = []
    private var thumbViews: [String: UIImageView] = [:]
    private var lastPreviewWidth: CGFloat = 0

    private var albumID: String?
    private var count: Int = 0
    private var recentIDs: [String] = []
    private var hiddenThumbID: String?
    private var thumbTarget = CGSize(width: 200, height: 200)
    private var thumbnails: [AlbumThumbnail] = []
    private var loadTask: Task<Void, Never>?

    override init(frame: CGRect) {
        super.init(frame: frame)

        previewContainer.layer.cornerRadius = 12
        previewContainer.clipsToBounds = true
        previewContainer.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(previewContainer)

        // Slot backgrounds (manually framed) sit at the bottom; thumbnail views are
        // inserted above them so they can slide between slots.
        for _ in 0..<4 {
            let bg = UIView()
            bg.backgroundColor = .tertiarySystemFill
            bg.isHidden = true
            previewContainer.addSubview(bg)
            slotBackgrounds.append(bg)
        }

        placeholder.image = UIImage(systemName: "photo.on.rectangle")
        placeholder.tintColor = .tertiaryLabel
        placeholder.contentMode = .center
        placeholder.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .title2)
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.addSubview(placeholder)

        checkmark.image = UIImage(systemName: "checkmark.circle.fill")?
            .applyingSymbolConfiguration(UIImage.SymbolConfiguration(textStyle: .title3))
        checkmark.preferredSymbolConfiguration = UIImage.SymbolConfiguration(paletteColors: [.white, UIColor(named: "AccentColor") ?? .systemBlue])
        checkmark.translatesAutoresizingMaskIntoConstraints = false
        checkmark.isHidden = true
        contentView.addSubview(checkmark)

        titleLabel.font = .preferredFont(forTextStyle: .subheadline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 1
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(titleLabel)

        countLabel.font = .preferredFont(forTextStyle: .caption2)
        countLabel.textColor = .secondaryLabel
        countLabel.adjustsFontForContentSizeCategory = true
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(countLabel)

        isAccessibilityElement = true
        accessibilityTraits = .button

        NSLayoutConstraint.activate([
            previewContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            previewContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            previewContainer.topAnchor.constraint(equalTo: contentView.topAnchor),
            previewContainer.heightAnchor.constraint(equalTo: previewContainer.widthAnchor),

            placeholder.centerXAnchor.constraint(equalTo: previewContainer.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: previewContainer.centerYAnchor),

            checkmark.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor, constant: -6),
            checkmark.topAnchor.constraint(equalTo: previewContainer.topAnchor, constant: 6),

            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            titleLabel.topAnchor.constraint(equalTo: previewContainer.bottomAnchor, constant: 6),

            countLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            countLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            countLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Reposition slot backgrounds + thumbnails only when the preview is resized
        // (reuse / column change), so a running reorder spring isn't interrupted.
        let width = previewContainer.bounds.width
        if width != lastPreviewWidth {
            lastPreviewWidth = width
            for (i, bg) in slotBackgrounds.enumerated() { bg.frame = slotFrame(i) }
            for (i, thumb) in thumbnails.prefix(4).enumerated() {
                thumbViews[thumb.id]?.frame = slotFrame(i)
            }
        }
    }

    /// Frame of slot `i` (row-major, 0 = top-left) within the square preview.
    private func slotFrame(_ i: Int) -> CGRect {
        let side = previewContainer.bounds.width
        guard side > 0 else { return .zero }
        let s = (side - 2) / 2
        let col = CGFloat(i % 2), row = CGFloat(i / 2)
        return CGRect(x: col * (s + 2), y: row * (s + 2), width: s, height: s)
    }

    func configure(albumID: String, title: String, count: Int, isMember: Bool, recentIDs: [String], hiddenThumbID: String?, dimmed: Bool, thumbTarget: CGSize) {
        let albumChanged = self.albumID != albumID
        let needsReload = albumChanged || self.count != count || self.recentIDs != recentIDs
        self.albumID = albumID
        self.count = count
        self.recentIDs = recentIDs
        self.hiddenThumbID = hiddenThumbID
        self.thumbTarget = thumbTarget

        titleLabel.text = title
        countLabel.text = count == 1 ? "1 photo" : "\(count) photos"
        previewContainer.backgroundColor = isMember
            ? (UIColor(named: "AccentColor") ?? .systemBlue).withAlphaComponent(0.12)
            : .tertiarySystemFill
        checkmark.isHidden = !isMember
        contentView.alpha = dimmed ? 0.6 : 1

        accessibilityLabel = title
        accessibilityValue = (count == 1 ? "1 photo" : "\(count) photos")
            + (isMember ? ", contains the current photo" : "")
        accessibilityTraits = isMember ? [.button, .selected] : .button

        if needsReload {
            // A brand-new album loads without animation; a membership / recent-add
            // change on the same album animates the reorder.
            reloadThumbnails(animated: !albumChanged)
        } else {
            applyHiddenThumb()
        }
    }

    /// The first preview slot's frame converted into `view`'s coordinate space.
    func firstSlotFrame(in view: UIView) -> CGRect {
        layoutIfNeeded()
        return previewContainer.convert(slotFrame(0), to: view)
    }

    /// Diff the thumbnails against what's shown and animate: existing photos spring
    /// to their new slot, incoming ones scale + fade in, departing ones fade out.
    private func setThumbnails(_ new: [AlbumThumbnail], animated: Bool) {
        thumbnails = new
        let shown = Array(new.prefix(4))
        let newIDs = Set(shown.map(\.id))
        let doAnimate = animated && previewContainer.bounds.width > 0 && !UIAccessibility.isReduceMotionEnabled

        for (id, iv) in thumbViews where !newIDs.contains(id) {
            thumbViews[id] = nil
            if doAnimate {
                UIView.animate(withDuration: 0.35, delay: 0, options: [.curveEaseInOut]) {
                    iv.alpha = 0
                    iv.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)
                } completion: { _ in iv.removeFromSuperview() }
            } else {
                iv.removeFromSuperview()
            }
        }

        for (i, thumb) in shown.enumerated() {
            let target = slotFrame(i)
            if let iv = thumbViews[thumb.id] {
                iv.image = thumb.image
                if doAnimate {
                    UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.8,
                                   initialSpringVelocity: 0, options: [.beginFromCurrentState]) {
                        iv.frame = target
                    }
                } else {
                    iv.frame = target
                }
            } else {
                let iv = UIImageView(image: thumb.image)
                iv.contentMode = .scaleAspectFill
                iv.clipsToBounds = true
                iv.frame = target
                previewContainer.insertSubview(iv, aboveSubview: slotBackgrounds[slotBackgrounds.count - 1])
                thumbViews[thumb.id] = iv
                if doAnimate {
                    iv.alpha = 0
                    iv.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)
                    UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.8,
                                   initialSpringVelocity: 0, options: []) {
                        iv.alpha = 1
                        iv.transform = .identity
                    }
                }
            }
        }

        for (i, bg) in slotBackgrounds.enumerated() {
            bg.frame = slotFrame(i)
            bg.isHidden = shown.isEmpty || i < shown.count
        }
        placeholder.isHidden = !shown.isEmpty
        if let hidden = hiddenThumbID { thumbViews[hidden]?.alpha = 0 }
    }

    private func applyHiddenThumb() {
        for (id, iv) in thumbViews { iv.alpha = (id == hiddenThumbID) ? 0 : 1 }
    }

    private func reloadThumbnails(animated: Bool) {
        loadTask?.cancel()
        let albumID = self.albumID ?? ""
        let recentIDs = Array(self.recentIDs.prefix(4))
        let target = thumbTarget
        loadTask = Task { @MainActor [weak self] in
            let new = await Self.loadThumbnails(albumID: albumID, recentIDs: recentIDs, targetSize: target)
            guard let self, !Task.isCancelled, self.albumID == albumID else { return }
            guard new != self.thumbnails else { return }
            self.setThumbnails(new, animated: animated)
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadTask?.cancel(); loadTask = nil
        thumbnails = []
        albumID = nil
        for (_, iv) in thumbViews { iv.removeFromSuperview() }
        thumbViews.removeAll()
        for bg in slotBackgrounds { bg.isHidden = true }
        placeholder.isHidden = false
        checkmark.isHidden = true
        contentView.alpha = 1
    }

    // MARK: Thumbnail fetch (ported from the SwiftUI AlbumGridCell)

    private static func loadThumbnails(albumID: String, recentIDs: [String], targetSize: CGSize) async -> [AlbumThumbnail] {
        let loader = ImageLoader.shared
        let assets: [PHAsset] = await Task.detached(priority: .userInitiated) {
            var out: [PHAsset] = []
            if !recentIDs.isEmpty {
                let fetched = PHAsset.fetchAssets(withLocalIdentifiers: recentIDs, options: nil)
                var byID: [String: PHAsset] = [:]
                fetched.enumerateObjects { asset, _, _ in byID[asset.localIdentifier] = asset }
                out = recentIDs.compactMap { byID[$0] }.filter { asset in
                    var inAlbum = false
                    let containing = PHAssetCollection.fetchAssetCollectionsContaining(asset, with: .album, options: nil)
                    containing.enumerateObjects { collection, _, stop in
                        if collection.localIdentifier == albumID { inAlbum = true; stop.pointee = true }
                    }
                    return inAlbum
                }
            }
            if out.count < 4 {
                guard let collection = AlbumService.collection(for: albumID) else { return out }
                let opts = PHFetchOptions()
                opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
                opts.fetchLimit = 4 + out.count
                let result = PHAsset.fetchAssets(in: collection, options: opts)
                let seen = Set(out.map(\.localIdentifier))
                for i in 0..<result.count where out.count < 4 {
                    let asset = result.object(at: i)
                    if !seen.contains(asset.localIdentifier) { out.append(asset) }
                }
            }
            return out
        }.value

        guard !Task.isCancelled, !assets.isEmpty else { return [] }

        return await withTaskGroup(of: (Int, AlbumThumbnail?).self) { group in
            for (index, asset) in assets.enumerated() {
                group.addTask {
                    guard let image = await loader.loadCachedThumbnail(for: asset, targetSize: targetSize) else { return (index, nil) }
                    return (index, AlbumThumbnail(id: asset.localIdentifier, image: image))
                }
            }
            var indexed: [(Int, AlbumThumbnail)] = []
            for await (index, thumb) in group {
                if let thumb { indexed.append((index, thumb)) }
            }
            return indexed.sorted(by: { $0.0 < $1.0 }).map(\.1)
        }
    }
}
