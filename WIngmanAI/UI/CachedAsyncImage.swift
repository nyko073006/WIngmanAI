import SwiftUI
import CryptoKit

// MARK: - In-memory and Disk Image Cache

final class ImageCache {
    static let shared = ImageCache()
    private let memCache = NSCache<NSString, UIImage>()
    private let fileManager = FileManager.default
    private let cacheDir: URL

    private init() {
        memCache.countLimit = 200
        memCache.totalCostLimit = 100 * 1024 * 1024 // 100 MB
        
        // Setup disk cache
        let urls = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)
        cacheDir = urls[0].appendingPathComponent("WingmanImageCache")
        if !fileManager.fileExists(atPath: cacheDir.path) {
            try? fileManager.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        }
    }
    
    private func cacheKey(for url: URL) -> String {
        let hash = Insecure.MD5.hash(data: url.absoluteString.data(using: .utf8) ?? Data())
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    func get(_ url: URL) -> UIImage? { 
        let key = cacheKey(for: url)
        
        // 1. Memory check
        if let memImpl = memCache.object(forKey: key as NSString) {
            return memImpl
        }
        
        // 2. Disk check
        let fileUrl = cacheDir.appendingPathComponent(key)
        if let data = try? Data(contentsOf: fileUrl), let img = UIImage(data: data) {
            memCache.setObject(img, forKey: key as NSString)
            return img
        }
        
        return nil
    }
    
    func set(_ image: UIImage, data: Data, for url: URL) { 
        let key = cacheKey(for: url)
        memCache.setObject(image, forKey: key as NSString)
        
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self = self else { return }
            let fileUrl = self.cacheDir.appendingPathComponent(key)
            try? data.write(to: fileUrl)
        }
    }

    /// Preloads and caches an image if not already cached.
    @MainActor
    func preload(_ url: URL) async {
        if get(url) != nil { return }

        guard let (data, response) = try? await URLSession.shared.data(from: url),
              let code = (response as? HTTPURLResponse)?.statusCode, code >= 200 && code < 300,
              let loaded = UIImage(data: data) else {
            return
        }

        set(loaded, data: data, for: url)
    }
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
                    .transition(.opacity)
            } else if failed {
                content(.failure)
            } else {
                content(.empty)
            }
        }
        .animation(.easeIn(duration: 0.15), value: uiImage != nil)
        .task(id: url) { await load() }
    }

    @MainActor
    private func load() async {
        uiImage = nil
        failed = false
        guard let url else { failed = true; return }
        
        // Quick local check without await if possible
        if let cached = ImageCache.shared.get(url) { 
            uiImage = cached
            return 
        }
        
        let loadedImg: UIImage?
        if let (data, response) = try? await URLSession.shared.data(from: url),
           let code = (response as? HTTPURLResponse)?.statusCode, code >= 200 && code < 300,
           let loaded = UIImage(data: data) {
            ImageCache.shared.set(loaded, data: data, for: url)
            loadedImg = loaded
        } else {
            loadedImg = nil
        }
        
        if let img = loadedImg {
            uiImage = img
        } else {
            failed = true
        }
    }
}
