//
// SPDX-FileCopyrightText: 2026 Ivan Cursorov and Peter Zakharov
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
        view.backgroundColor = .systemBackground
        view.textContainerInset = UIEdgeInsets(top: 16, left: 14, bottom: 24, right: 14)
        view.font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view.textColor = .label
        view.adjustsFontForContentSizeCategory = false
        return view
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = NSLocalizedString("Compression Algo", comment: "Debug screen explaining media compression")
        NCAppBranding.styleViewController(self)
        view.backgroundColor = .systemBackground
        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        textView.text = Self.document
    }

    private static let document = """
    MEDIA COMPRESSION ALGO
    ======================

    Modes (Settings → Compression)
    ------------------------------
    None        Upload originals (no re-encode).
    Automatic   Per file: pick Mildest level whose estimate
                × (1 + margin) stays under the max file size.
                Photo margin default 20%, video 10% (Debug).
    Manual      User picks None / Low / Medium / High chips
                on the send sheet (estimates shown).

    Levels are aggressiveness, not Apple preset names:
      Low    = milder shrink, better quality
      Medium = balanced default
      High   = stronger shrink, smaller files


    VIDEO ENGINES
    -------------
    Debug → Media Compression Settings → Video engine

    1) Bitrate  (AVAssetWriter)     [default]
       • Target TOTAL rate in Mbps (video+audio budget).
       • Writer derives video bitrate ≈ rateMbps×1e6 − 128 kbps audio.
       • Scales to profile videoMaxEdge (and batch edge cap).
       • Uses profile videoFPS.
       • Estimate ≈ rateMbps × duration (bits → bytes).
       • On Writer failure → falls back to ExportSession once.

    2) Presets  (AVAssetExportSession)
       • Apple preset per level (e.g. 720p / 540p / LowQuality).
       • Apple chooses bitrate; we only pick the preset.
       • Estimate from calibrated Mbps tables + duration
         (or Apple estimatedOutputFileLength when available).


    IMAGE PIPELINE
    --------------
    • Prefer ImageIO thumbnail + JPEG destination
        - max edge = profile imageMaxDimension
        - quality   = profile imageJPEGQuality (0–100 → 0–1)
        - orientation baked via transform
        - GPS / bulky EXIF stripped (no property copy)
    • Fallback: UIImage decode → jpegData(compressionQuality:)
    • Skip GIF; skip if “unlikely to shrink”.
    • Convert-cache key: content fingerprint + profile
      (reuse same encode on re-send with same settings).


    VIDEO PIPELINE
    --------------
    • Serial encode (process-wide queue) — one video at a time
      (Share Extension jetsam mitigation).
    • MemoryGate waits for ~100–120 MB free between encodes.
    • Multi-video Manual batches may lower edgeCap (e.g. 640)
      so peak memory stays safer; logged as edgeCap=.
    • Output must be smaller than source or we keep original.
    • Success → store in convert cache; after upload PROPFIND
      → promote into download cache for reopen.


    SINGLE vs MULTIPLE
    ------------------
    Single file
      Encode (if needed) → one PUT → promote.

    Multiple files
      • Videos: always serial encode (never parallel Writer).
      • Photos: compress on the preparation queue (still
        gated by MemoryGate after each image).
      • Upload: max 2 concurrent PUTs (UploadGate).
      • Previews dropped on Send (progress alert) to free RAM.


    AUTOMATIC PICK (per file)
    -------------------------
      for level in [Low, Medium, High]:
        if estimate(level) × (1 + margin/100) < maxFileBytes:
          choose level; stop
      else
        still use High (best effort)

    Bag limit is selection count (10), not total bytes.


    CACHE TOUCHPOINTS
    -----------------
    See Debug → Cache Policy for the full map (download /
    upload / convert / thumbs / SD + URLCache, caps, LRU).

    Grep device logs:  MediaUploadTrace:
    Timestamps are UTC (…Z). Lines tagged [bBUILD].
    """
}
