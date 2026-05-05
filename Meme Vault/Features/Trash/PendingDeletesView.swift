//
//  PendingDeletesView.swift
//  Meme Vault
//
//  Review queued deletions and confirm them in a single batch via PhotoKit.
//

import SwiftUI
import SwiftData
import Photos

struct PendingDeletesView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \PendingDelete.queuedAt, order: .reverse)
    private var pendingDeletes: [PendingDelete]

    @State private var isDeleting = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if pendingDeletes.isEmpty {
                ContentUnavailableView(
                    "Trash is Empty",
                    systemImage: "trash.slash",
                    description: Text("Photos you queue for deletion will appear here.")
                )
            } else {
                list
            }
        }
        .navigationTitle("Trash")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !pendingDeletes.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        Task { await confirmAll() }
                    } label: {
                        if isDeleting {
                            ProgressView()
                        } else {
                            Text("Empty Trash")
                        }
                    }
                    .disabled(isDeleting)
                }
            }
        }
        .alert("Couldn't delete", isPresented: .init(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var list: some View {
        List {
            Section {
                ForEach(pendingDeletes) { pd in
                    PendingDeleteRow(pendingDelete: pd) {
                        modelContext.delete(pd)
                    }
                }
            } footer: {
                Text("Tapping Empty Trash will ask iOS to delete \(pendingDeletes.count) photo\(pendingDeletes.count == 1 ? "" : "s") in one confirmation.")
            }
        }
    }

    private func confirmAll() async {
        isDeleting = true
        defer { isDeleting = false }

        let ids = pendingDeletes.map(\.assetLocalID)
        let assets = AlbumService.assets(for: ids)
        guard !assets.isEmpty else {
            // No live assets — clear stale rows.
            for pd in pendingDeletes { modelContext.delete(pd) }
            try? modelContext.save()
            return
        }

        do {
            try await AlbumService.deleteAssets(assets)
            // Successful — drop the matching rows.
            let deletedIDs = Set(assets.map(\.localIdentifier))
            for pd in pendingDeletes where deletedIDs.contains(pd.assetLocalID) {
                modelContext.delete(pd)
            }
            // Also drop rows that pointed to assets that no longer exist.
            let liveIDs = Set(assets.map(\.localIdentifier))
            for pd in pendingDeletes where !liveIDs.contains(pd.assetLocalID) {
                modelContext.delete(pd)
            }
            try? modelContext.save()
            Haptics.success()
        } catch {
            // PhotoKit returns an error if the user cancels the system prompt;
            // in that case we just leave the queue alone.
            let nsErr = error as NSError
            if nsErr.code == 3072 /* user cancelled */ {
                return
            }
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Row

private struct PendingDeleteRow: View {
    let pendingDelete: PendingDelete
    let onRemove: () -> Void

    @State private var thumbnail: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.tertiarySystemFill))
                    .frame(width: 56, height: 56)
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(pendingDelete.context?.name ?? "Unknown context")
                    .font(.subheadline.weight(.medium))
                Text(pendingDelete.queuedAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                onRemove()
            } label: {
                Image(systemName: "arrow.uturn.backward.circle")
                    .font(.title2)
                    .foregroundStyle(.tint)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Restore")
        }
        .task(id: pendingDelete.assetLocalID) {
            guard let asset = AlbumService.asset(for: pendingDelete.assetLocalID) else { return }
            thumbnail = await ImageLoader.shared.loadDisplayImage(
                for: asset,
                targetSize: CGSize(width: 112, height: 112)
            )
        }
    }
}
