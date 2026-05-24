import SwiftUI
import Photos

struct AlbumSheetItem: Identifiable {
    let id: String
    let title: String
}

struct AlbumContentsView: View {
    let album: AlbumSheetItem

    @Environment(\.dismiss) private var dismiss
    @State private var assetIDs: [String] = []
    @State private var removeAssetID: String?
    @State private var showRemoveAlert = false
    @State private var showError = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if assetIDs.isEmpty {
                    ContentUnavailableView(
                        "Empty Album",
                        systemImage: "photo.on.rectangle",
                        description: Text("This album has no photos.")
                    )
                } else {
                    grid
                }
            }
            .navigationTitle(album.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: dismiss.callAsFunction)
                }
            }
        }
        .task { await loadAssets() }
        .alert("Remove from Album?", isPresented: $showRemoveAlert) {
            Button("Remove", role: .destructive) {
                if let id = removeAssetID {
                    Task { await removeFromAlbum(assetID: id) }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This photo will be removed from \"\(album.title)\". It won't be deleted from your library.")
        }
        .alert("Error", isPresented: $showError) { } message: {
            Text(errorMessage ?? "An unknown error occurred.")
        }
    }

    private var grid: some View {
        PhotoGrid(assetIDs: assetIDs) { assetID in
            ThumbnailCell(assetLocalID: assetID)
                .contextMenu {
                    Button("Remove from Album", systemImage: "minus.circle", role: .destructive) {
                        removeAssetID = assetID
                        showRemoveAlert = true
                    }
                }
        }
    }

    private func loadAssets() async {
        // Enumerating a large album synchronously on the main actor freezes the
        // sheet on open (≈100–200 ms on a big library), so do it off-main and
        // hand back the plain (Sendable) IDs.
        let albumID = album.id
        let ids = await Task.detached(priority: .userInitiated) { () -> [String] in
            guard let collection = AlbumService.collection(for: albumID) else { return [] }
            let opts = PHFetchOptions()
            opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            let result = PHAsset.fetchAssets(in: collection, options: opts)
            var ids: [String] = []
            ids.reserveCapacity(result.count)
            result.enumerateObjects { asset, _, _ in
                ids.append(asset.localIdentifier)
            }
            return ids
        }.value
        assetIDs = ids
    }

    private func removeFromAlbum(assetID: String) async {
        guard let asset = AlbumService.asset(for: assetID),
              let collection = AlbumService.collection(for: album.id) else { return }
        do {
            try await AlbumService.remove(asset, from: collection)
            withAnimation {
                assetIDs.removeAll { $0 == assetID }
            }
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}
