//
//  PhotoCollectionView.swift
//  Meme Vault
//
//  Shared grid view for browsing trashed or skipped photos. Supports
//  tap-to-restore with confirmation, context-menu actions, and animated removal.
//

import SwiftUI
import SwiftData
import Photos

struct PhotoCollectionView: View {
    enum Mode {
        case trash
        case skipped(OrgContext)

        var isTrash: Bool {
            if case .trash = self { true } else { false }
        }
    }

    let mode: Mode
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \PendingDelete.queuedAt, order: .reverse)
    private var pendingDeletes: [PendingDelete]

    @Query(sort: \PhotoSkip.skippedAt, order: .reverse)
    private var skips: [PhotoSkip]

    @State private var showRestoreAlert = false
    @State private var restoreAssetID: String?
    @State private var isDeleting = false
    @State private var showError = false
    @State private var errorMessage: String?

    init(mode: Mode) {
        self.mode = mode
        if case .skipped(let context) = mode {
            let contextID = context.persistentModelID
            _skips = Query(
                filter: #Predicate { $0.context?.persistentModelID == contextID },
                sort: \PhotoSkip.skippedAt,
                order: .reverse
            )
        }
    }

    // MARK: - Derived state

    private var assetIDs: [String] {
        switch mode {
        case .trash: pendingDeletes.map(\.assetLocalID)
        case .skipped: skips.map(\.assetLocalID)
        }
    }

    private var navigationTitle: String {
        switch mode {
        case .trash: "Trash"
        case .skipped(let ctx): "\(ctx.name) - Skipped"
        }
    }

    private var emptyTitle: String {
        mode.isTrash ? "Trash is Empty" : "No Skipped Photos"
    }

    private var emptyIcon: String {
        mode.isTrash ? "trash.slash" : "checkmark"
    }

    private var emptyDescription: String {
        mode.isTrash
            ? "Photos you queue for deletion will appear here."
            : "Photos you skip in the sort queue will appear here."
    }

    private var restoreLabel: String {
        mode.isTrash ? "Restore" : "Unskip"
    }

    // MARK: - Body

    var body: some View {
        Group {
            if assetIDs.isEmpty {
                ContentUnavailableView(
                    emptyTitle,
                    systemImage: emptyIcon,
                    description: Text(emptyDescription)
                )
            } else {
                grid
            }
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if mode.isTrash, !pendingDeletes.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        Task { await emptyTrash() }
                    } label: {
                        if isDeleting { ProgressView() }
                        else { Text("Empty Trash") }
                    }
                    .disabled(isDeleting)
                }
            }
        }
        .alert(
            mode.isTrash ? "Restore Photo?" : "Unskip Photo?",
            isPresented: $showRestoreAlert
        ) {
            Button(restoreLabel) {
                if let id = restoreAssetID {
                    restore(assetID: id)
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(mode.isTrash
                 ? "This photo will be removed from the trash."
                 : "This photo will return to the sort queue.")
        }
        .alert("Couldn't delete", isPresented: $showError) { } message: {
            Text(errorMessage ?? "")
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [.init(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
                ForEach(assetIDs, id: \.self) { assetID in
                    Button {
                        restoreAssetID = assetID
                        showRestoreAlert = true
                    } label: {
                        ThumbnailCell(assetLocalID: assetID, showRestoreIndicator: mode.isTrash)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(restoreLabel, systemImage: "arrow.uturn.backward") {
                            restore(assetID: assetID)
                        }
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            deleteItem(assetID: assetID)
                        }
                    }
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(12)
            .animation(.interactiveSpring(), value: assetIDs)
        }
    }

    // MARK: - Actions

    private func restore(assetID: String) {
        switch mode {
        case .trash:
            if let pd = pendingDeletes.first(where: { $0.assetLocalID == assetID }) {
                modelContext.delete(pd)
            }
        case .skipped:
            if let skip = skips.first(where: { $0.assetLocalID == assetID }) {
                modelContext.delete(skip)
            }
        }
    }

    private func deleteItem(assetID: String) {
        switch mode {
        case .trash:
            if let pd = pendingDeletes.first(where: { $0.assetLocalID == assetID }) {
                Task { await permanentlyDelete(pd) }
            }
        case .skipped(let context):
            if let skip = skips.first(where: { $0.assetLocalID == assetID }) {
                let pd = PendingDelete(assetLocalID: skip.assetLocalID)
                pd.context = context
                modelContext.insert(pd)
                modelContext.delete(skip)
            }
        }
    }

    private func permanentlyDelete(_ pd: PendingDelete) async {
        let assets = AlbumService.assets(for: [pd.assetLocalID])
        guard !assets.isEmpty else {
            modelContext.delete(pd)
            return
        }
        do {
            try await AlbumService.deleteAssets(assets)
            modelContext.delete(pd)
            try? modelContext.save()
        } catch {
            let nsErr = error as NSError
            if nsErr.code == 3072 { return }
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func emptyTrash() async {
        isDeleting = true
        defer { isDeleting = false }

        let ids = pendingDeletes.map(\.assetLocalID)
        let assets = AlbumService.assets(for: ids)
        guard !assets.isEmpty else {
            withAnimation {
                for pd in pendingDeletes { modelContext.delete(pd) }
            }
            try? modelContext.save()
            return
        }

        do {
            try await AlbumService.deleteAssets(assets)
            withAnimation {
                let deletedIDs = Set(assets.map(\.localIdentifier))
                for pd in pendingDeletes where deletedIDs.contains(pd.assetLocalID) {
                    modelContext.delete(pd)
                }
                let liveIDs = Set(assets.map(\.localIdentifier))
                for pd in pendingDeletes where !liveIDs.contains(pd.assetLocalID) {
                    modelContext.delete(pd)
                }
            }
            try? modelContext.save()
            Haptics.success()
        } catch {
            let nsErr = error as NSError
            if nsErr.code == 3072 { return }
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}
