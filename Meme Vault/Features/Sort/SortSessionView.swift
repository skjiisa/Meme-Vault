//
//  SortSessionView.swift
//  Meme Vault
//
//  Main sort screen: photo card on top, flat album list with checkmarks,
//  bottom toolbar.
//

import SwiftUI
import SwiftData
import Photos

struct SortSessionView: View {
    let context: OrgContext

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var library: PhotoLibrary

    @State private var vm: SortSessionViewModel?
    @State private var showUnsatisfiedConfirm = false
    @State private var showUndoToast = false
    @State private var undoTimer: Task<Void, Never>?

    var body: some View {
        Group {
            if let vm {
                content(vm: vm)
            } else {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(context.name.isEmpty ? "Sort" : context.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if vm == nil {
                vm = SortSessionViewModel(context: context, modelContext: modelContext)
                await vm?.start()
            }
        }
        .task(id: library.changeTick) {
            // External Photos changes — only act after first load.
            guard let vm, library.changeTick > 0 else { return }
            await vm.handleLibraryChange()
        }
    }

    @ViewBuilder
    private func content(vm: SortSessionViewModel) -> some View {
        if vm.isLoading {
            ProgressView("Scanning library…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if vm.queue.isEmpty {
            allDoneView
        } else if vm.currentAsset != nil {
            sortContent(vm: vm)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Done state

    private var allDoneView: some View {
        ContentUnavailableView {
            Label("All Sorted!", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
        } description: {
            Text("Every photo in this context belongs to at least one destination album.")
        }
    }

    // MARK: - Sort content

    @ViewBuilder
    private func sortContent(vm: SortSessionViewModel) -> some View {
        VStack(spacing: 12) {
            // Progress
            HStack {
                Text(vm.progressText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if vm.isSatisfied {
                    Label("Sorted", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                }
            }
            .padding(.horizontal)

            // Photo carousel
            PhotoCardView(
                assetIDs: vm.queue,
                currentID: Binding(
                    get: { vm.currentAssetID },
                    set: { id in if let id { vm.showAsset(id: id) } }
                )
            )
            .frame(height: 360)
            .padding(.horizontal)

            // Album list
            albumList(vm: vm)

            // Bottom toolbar
            bottomBar(vm: vm)
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            if showUndoToast, let action = vm.lastAction {
                undoToast(action: action, vm: vm)
                    .padding(.bottom, 70)
            }
        }
        .alert("Photo not sorted", isPresented: $showUnsatisfiedConfirm) {
            Button("Skip Anyway", role: .destructive) {
                Task { await vm.advance(removingCurrent: false) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This photo isn't sorted into any album yet.")
        }
    }

    // MARK: - Flat album list

    @ViewBuilder
    private func albumList(vm: SortSessionViewModel) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(albumInfos, id: \.id) { info in
                    let membership = vm.memberships.first { $0.id == info.id }
                    let isMember = membership?.isMember ?? false
                    albumRow(info: info, isMember: isMember, vm: vm)
                }
            }
            .padding(.horizontal)
        }
        .frame(maxHeight: 280)
    }

    private var albumInfos: [AlbumInfo] {
        let collections = AlbumService.collections(for: context.albumLocalIDs)
        let byID = Dictionary(uniqueKeysWithValues: collections.map {
            ($0.localIdentifier, AlbumInfo(collection: $0))
        })
        return context.albumLocalIDs.compactMap { byID[$0] }
    }

    private func albumRow(info: AlbumInfo, isMember: Bool, vm: SortSessionViewModel) -> some View {
        Button {
            Task { await vm.toggleAlbum(info.id) }
        } label: {
            HStack {
                Image(systemName: isMember ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isMember ? Color.accentColor : Color.secondary)
                Text(info.title)
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isMember
                          ? Color.accentColor.opacity(0.12)
                          : Color(.tertiarySystemFill))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Bottom bar

    private func bottomBar(vm: SortSessionViewModel) -> some View {
        HStack(spacing: 16) {
            Button {
                Task { await vm.back() }
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .frame(width: 44, height: 44)
            }
            .disabled(vm.index == 0)

            Button {
                Task { await vm.queueDelete(); showToast() }
            } label: {
                Image(systemName: "trash")
                    .frame(width: 44, height: 44)
                    .foregroundStyle(.red)
            }

            Button {
                Task { await vm.skip(); showToast() }
            } label: {
                Image(systemName: "arrow.right.to.line")
                    .frame(width: 44, height: 44)
            }

            Spacer()

            Button {
                if vm.isSatisfied {
                    Task { await vm.nextPressed(force: false) }
                } else {
                    showUnsatisfiedConfirm = true
                }
            } label: {
                Label("Next", systemImage: "chevron.right")
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(vm.isSatisfied ? .green : .orange)
        }
        .padding(.horizontal)
    }

    // MARK: - Undo toast

    private func showToast() {
        showUndoToast = true
        undoTimer?.cancel()
        undoTimer = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled {
                showUndoToast = false
            }
        }
    }

    private func undoToast(action: SortSessionViewModel.SortAction, vm: SortSessionViewModel) -> some View {
        let label: String = {
            switch action {
            case .skipped: return "Skipped"
            case .queuedDelete: return "Queued for deletion"
            }
        }()
        return HStack {
            Text(label)
            Spacer()
            Button("Undo") {
                Task {
                    switch action {
                    case .skipped: await vm.undoSkip()
                    case .queuedDelete: await vm.undoQueueDelete()
                    }
                    showUndoToast = false
                }
            }
            .bold()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.horizontal, 24)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
