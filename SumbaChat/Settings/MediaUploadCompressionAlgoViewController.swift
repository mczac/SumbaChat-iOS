//
// SPDX-FileCopyrightText: 2026 Ivan Cursoroff and Peter Zakharov
// SPDX-License-Identifier: GPL-3.0-or-later
//

import UIKit

/// Debug reference: how SumbaChat media compression chooses engines, rates, and batching.
final class MediaUploadCompressionAlgoViewController: UIViewController {

    private let textView: UITextView = {
        let view = UITextView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isEditable = false
        view.isSelectable = true
        view.alwaysBounceVertical = true
        view.textContainerInset = UIEdgeInsets(top: 16, left: 14, bottom: 24, right: 14)
        view.adjustsFontForContentSizeCategory = false
        return view
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = NSLocalizedString("Compression rules", comment: "Debug screen explaining media compression")
        NCAppBranding.styleViewController(self)
        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        reloadDocument()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) else { return }
        reloadDocument()
    }

    private func reloadDocument() {
        let colors = DebugAlgoCodeDocument.colors(for: traitCollection)
        view.backgroundColor = colors.background
        textView.backgroundColor = colors.background
        textView.attributedText = DebugAlgoCodeDocument.highlighted(Self.source, colors: colors)
    }

    private static let source = #"""
    // COMPRESSION ALGO
    // SumbaChat — readable summary of the live compression path

    // MARK: - Modes (Settings → Compression)

    enum Mode {
        case none        // Upload originals (no re-encode)
        case automatic   // Per file: mildest level under max file size
        case manual      // User chips: None / Low / Medium / High
    }

    // Levels = aggressiveness (not Apple preset names)
    enum Level {
        case low     // milder shrink, better quality
        case medium  // balanced default
        case high    // stronger shrink, smaller files
    }

    // Automatic margins (Debug): photo 20%, video 10%


    // MARK: - Video engines
    // Debug → Media Compression Settings → Video engine

    // 1) Bitrate — AVAssetWriter [default]
    //    target TOTAL Mbps (video+audio); video ≈ rate×1e6 − 128 kbps
    //    scales to videoMaxEdge (+ batch edgeCap); uses videoFPS
    //    estimate ≈ rateMbps × duration; Writer fail → ExportSession once

    // 2) Presets — AVAssetExportSession
    //    Apple preset per level (720p / 540p / LowQuality)
    //    estimate from Mbps tables or estimatedOutputFileLength


    // MARK: - Image pipeline

    // Prefer ImageIO thumbnail + JPEG destination
    //   maxEdge = imageMaxDimension
    //   quality = imageJPEGQuality (0…100 → 0…1)
    //   orientation via transform; GPS / bulky EXIF stripped
    // Fallback: UIImage → jpegData(compressionQuality:)
    // Skip GIF; skip if unlikely to shrink
    // Convert-cache key = content fingerprint + profile


    // MARK: - Video pipeline

    // Serial encode (process-wide queue) — one video at a time
    // MemoryGate: ~120 MB free in-app / ~80 MB in Share Extension
    //   bails early if free memory plateaus
    // Multi-video Manual may lower edgeCap (e.g. 640)
    // Keep original if output not smaller
    // Success → convert cache; after PUT → promote to download/


    // MARK: - Single vs multiple

    // Single:  encode (if needed) → one PUT → promote
    // Multiple:
    //   videos serial; photos on preparation queue (+ MemoryGate)
    //   upload max 2 concurrent PUTs (UploadGate)
    //   previews dropped on Send


    // MARK: - Automatic pick (per file)

    func pickAutomaticLevel(
        estimate: (Level) -> Int64,
        maxFileBytes: Int64,
        marginPercent: Double
    ) -> Level {
        let candidates: [Level] = [.low, .medium]

        for level in candidates {
            let est = estimate(level)
            // Accept if estimate × (1 + margin/100) < maxFileBytes
            if est * (100 + Int64(marginPercent)) / 100 < maxFileBytes {
                return level   // choose and stop
            }
            // else: try next candidate (do not assign High here)
        }

        return .high   // best effort — once, after both failed
    }

    // Bag limit = selection count (10), not total bytes


    // MARK: - Cache touchpoints

    // See Debug → Caching rules for download / upload / convert /
    // thumbs / SDImageCache + URLCache, caps, LRU.

    // Grep logs: MediaUploadTrace:
    // Timestamps UTC (…Z). Lines tagged [bBUILD].
    """#
}
