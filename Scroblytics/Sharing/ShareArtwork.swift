import AppKit
import Foundation

/// Loads the pictures a card draws. An image renderer draws a single frame, so every picture has to be in memory before it starts:
/// file URLs (your own images and the ones saved on this Mac) are read directly, remote ones only when online
/// (Offline mode never asks the network, and the card draws its placeholder).
enum ShareArtwork {
    @MainActor
    static func load(_ urls: [String?]) async -> [String: NSImage] {
        let unique = Array(Set(urls.compactMap { $0 }.filter { !$0.isEmpty }))
        let datas = await withTaskGroup(of: (String, Data)?.self) { group in
            for raw in unique {
                guard let url = URL(string: raw) else { continue }
                group.addTask {
                    do {
                        if url.isFileURL { return (raw, try Data(contentsOf: url)) }
                        try ConnectivityGate.check(host: url.host)
                        return (raw, try await URLSession.shared.data(from: url).0)
                    } catch {
                        return nil
                    }
                }
            }
            var values: [(String, Data)] = []
            for await value in group { if let value { values.append(value) } }
            return values
        }
        var images: [String: NSImage] = [:]
        for (raw, data) in datas {
            if let image = NSImage(data: data) { images[raw] = image }
        }
        return images
    }
}
