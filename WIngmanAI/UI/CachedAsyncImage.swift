import SwiftUI

// MARK: - In-memory image cache

private final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSURL, UIImage>()
    private init() {
        cache.countLimit = 200
        cache.totalCostLimit = 50 * 1024 * 1024 // 50 MB
    }
    func get(_ url: URL) -> UIImage? { cache.object(forKey: url as NSURL) }
    func set(_ image: UIImage, for url: URL) { cache.setObject(image, forKey: url as NSURL) }
}

// MARK: - Phase

enum CachedImagePhase {
    case empty
    case success(Image)
    case failure
}

// MARK: - CachedAsyncImage

struct CachedAsyncImage<Content: View>: View {
    let url: URL?
    @ViewBuilder let content: (CachedImagePhase) -> Content

    @State private var uiImage: UIImage? = nil
    @State private var failed = false

    var body: some View {
        ZStack {
            if let uiImage {
                content(.success(Image(uiImage: uiImage)))
            } else if failed {
                content(.failure)
            } else {
                content(.empty)
            }
        }
        .task(id: url) { await load() }
    }

    @MainActor
    private func load() async {
        uiImage = nil
        failed = false
        guard let url else { failed = true; return }
        if let cached = ImageCache.shared.get(url) { uiImage = cached; return }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let loaded = UIImage(data: data) else {
            failed = true; return
        }
        ImageCache.shared.set(loaded, for: url)
        uiImage = loaded
    }
}
