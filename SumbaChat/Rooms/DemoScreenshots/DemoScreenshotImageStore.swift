//
// SPDX-FileCopyrightText: 2026 Peter Zakharov
// SPDX-License-Identifier: GPL-3.0-or-later
//

import UIKit

#if DEMO_SCREENSHOTS

/// Downloads and caches staging photos from test.sumba.travel for screenshot avatars and chat previews.
enum DemoScreenshotImageStore {

    private static let cacheFolderName = "DemoScreenshotAssets"
    private static let authCredential = "staginguser:m0nsters"

    private static var roomAvatarPaths: [String: String] = [:]
    private static var previewPaths: [String: String] = [:]

    static func prepareAssets(completion: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let specs: [(key: String, url: String, filename: String)] = [
                ("room:demo-infra", "https://test.sumba.travel/wp-content/uploads/2026/04/sumba-island-cattle-grazing-savanna-768x512.webp", "room-demo-infra.webp"),
                ("room:demo-site", "https://test.sumba.travel/wp-content/uploads/2026/02/Rumah_adat_Sumba_Uma_Bbatangu-768x513.jpg", "room-demo-site.jpg"),
                ("room:demo-villa", "https://test.sumba.travel/wp-content/uploads/2026/05/the_menara_villa__pool_6-768x512.jpg", "room-demo-villa.jpg"),
                ("room:demo-partners", "https://test.sumba.travel/wp-content/uploads/2026/05/boku_bani_heritage_village_2_graves_surrounding_the_village-768x422.webp", "room-demo-partners.webp"),
                ("room:demo-field", "https://test.sumba.travel/wp-content/uploads/2026/06/scuba-diver-underwater-camera-sumba-island-768x446.webp", "room-demo-field.webp"),
                ("room:demo-env", "https://test.sumba.travel/wp-content/uploads/2026/03/sumba-island-rice-terraces-waterfall-768x518.webp", "room-demo-env.webp"),
                ("room:demo-guest", "https://test.sumba.travel/wp-content/uploads/2026/05/lelewatu_resort_1_the_signage_for_lelewatu_resort_at_the_main_street-640x420.jpg", "room-demo-guest.jpg"),
                ("file:demo-file-solar", "https://test.sumba.travel/wp-content/uploads/2026/04/sumba-hero-poster-1200x675.jpg", "file-solar.jpg"),
                ("file:demo-file-water", "https://test.sumba.travel/wp-content/uploads/2026/03/sumba-island-lagoon-turquoise-water-768x1152.webp", "file-water.webp")
            ]

            for spec in specs {
                guard let path = downloadIfNeeded(urlString: spec.url, filename: spec.filename) else { continue }
                if spec.key.hasPrefix("room:") {
                    let token = String(spec.key.dropFirst("room:".count))
                    roomAvatarPaths[token] = path
                } else if spec.key.hasPrefix("file:") {
                    let fileId = String(spec.key.dropFirst("file:".count))
                    previewPaths[fileId] = path
                }
            }

            DispatchQueue.main.async(execute: completion)
        }
    }

    static func roomAvatar(forToken token: String, style: UIUserInterfaceStyle) -> UIImage? {
        guard let path = roomAvatarPaths[token], let image = UIImage(contentsOfFile: path) else { return nil }
        return circularAvatar(from: image, diameter: 128, style: style)
    }

    static func previewImage(forFileId fileId: String) -> UIImage? {
        guard let path = previewPaths[fileId] else { return nil }
        return UIImage(contentsOfFile: path)
    }

    private static func cacheDirectory() -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let folder = base.appendingPathComponent(cacheFolderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @discardableResult
    private static func downloadIfNeeded(urlString: String, filename: String) -> String? {
        guard let folder = cacheDirectory() else { return nil }
        let destination = folder.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: destination.path) {
            return destination.path
        }
        guard let url = URL(string: urlString) else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        if let data = authCredential.data(using: .utf8) {
            request.setValue("Basic \(data.base64EncodedString())", forHTTPHeaderField: "Authorization")
        }

        let semaphore = DispatchSemaphore(value: 0)
        var savedPath: String?
        URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { semaphore.signal() }
            guard let data, !data.isEmpty,
                  let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else { return }
            try? data.write(to: destination, options: .atomic)
            savedPath = destination.path
        }.resume()
        _ = semaphore.wait(timeout: .now() + 25)
        return savedPath ?? (FileManager.default.fileExists(atPath: destination.path) ? destination.path : nil)
    }

    private static func circularAvatar(from image: UIImage, diameter: CGFloat, style: UIUserInterfaceStyle) -> UIImage {
        let size = CGSize(width: diameter, height: diameter)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            let rect = CGRect(origin: .zero, size: size)
            UIBezierPath(ovalIn: rect).addClip()
            image.draw(in: rect)

            if style == .dark {
                UIColor.black.withAlphaComponent(0.12).setFill()
                UIBezierPath(ovalIn: rect).fill()
            }
        }
    }
}

#endif
