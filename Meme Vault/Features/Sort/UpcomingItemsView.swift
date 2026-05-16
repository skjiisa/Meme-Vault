import SwiftUI
import Photos

struct QueuePreviewStrip: View {
    let assetIDs: [String]
    let currentID: String?
    let onSelect: (String) -> Void

    var body: some View {
        if !assetIDs.isEmpty {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 6) {
                        ForEach(assetIDs, id: \.self) { id in
                            Button { onSelect(id) } label: {
                                UpcomingThumbnail(assetID: id)
                                    .overlay {
                                        if id == currentID {
                                            RoundedRectangle(cornerRadius: 6)
                                                .stroke(Color.accentColor, lineWidth: 2.5)
                                        }
                                    }
                                    .opacity(id == currentID ? 1 : 0.6)
                            }
                            .buttonStyle(.plain)
                            .id(id)
                            .transition(.scale(scale: 0.5).combined(with: .opacity))
                        }
                    }
                    .padding(.horizontal)
                    .animation(.easeInOut(duration: 0.3), value: assetIDs)
                }
                .scrollIndicators(.hidden)
                .frame(height: 44)
                .onChange(of: currentID) { _, newID in
                    guard let newID else { return }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(newID, anchor: .center)
                    }
                }
                .onAppear {
                    if let currentID {
                        proxy.scrollTo(currentID, anchor: .center)
                    }
                }
            }
        }
    }
}
