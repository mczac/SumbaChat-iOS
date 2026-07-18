//
// SPDX-FileCopyrightText: 2026 Ivan Cursoroff and Peter Zakharov
// SPDX-License-Identifier: GPL-3.0-or-later
//

import UIKit

/// Debug reference: SumbaMedia + system caches, caps, and lifecycle.
final class MediaUploadCachePolicyViewController: UIViewController {

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
        title = NSLocalizedString("Caching rules", comment: "Debug screen explaining media / attachment caches")
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
        textView.attributedText = DebugAlgoCodeDocument.highlighted(
            Self.source,
            colors: colors,
            extraTypes: ["ShareItem", "AppGroup"]
        )
    }

    private static let source = #"""
    // CACHING ALGO
    // SumbaChat — readable summary of cache layout and eviction
    // Layout: App Group Library/Caches/SumbaMedia/

    enum Store {
        case download   // Full chat attachments (open / promote)
        case upload     // Send staging (original → outgoing)
        case convert    // Encoded reuse per account
        case thumbs     // Share-sheet image previews
        case system     // SDImageCache + URLCache (not SumbaMedia)
    }


    // MARK: - download/  (Chat cache / Cache limit)

    // Settings → Advanced → Caching → Chat cache
    // Cap = Cache limit (~3 GB default)
    // Purge when usage > 95% of limit → LRU until ≤ 80%
    // Sort key: contentAccessDate (fallback creationDate)
    // Never bump modificationDate on HIT
    //   (STALE still compares remote mtime + size)


    // MARK: - upload/  (Upload staging)

    // Soft cap 512 MB (not Cache limit)
    // Wiped after send, Cancel, next share, or Settings clear
    // .upload-session marker (45 min) blocks Settings/idle wipe
    // Touched on stage + every 10 min while sheet open
    // Cancel-during-upload delays wipe ~2.5s
    // Soft-cap cleanup: FIFO by creationDate


    // MARK: - convert/  (Convert cache)

    // Path: convert/{accountId}/ + v2 fingerprint + profile
    // Soft cap 512 MB; LRU on convert-HIT
    // File protection: completeUntilFirstUserAuthentication
    // Cleared from Caching → Convert (not Cache limit)


    // MARK: - thumbs/ + system

    // thumbs/  share previews; wiped with upload/
    // SDImageCache  avatars / server previews (~100 MB / ~4 weeks)
    // URLCache      HTTP bodies; cleared with System previews


    // MARK: - Settings map

    // Advanced → Caching
    //   Chat cache bar  = download/ vs Cache limit (inline MB)
    //   Other storage   = upload / convert / thumbs / previews
    //   Swipe row → clear; sizes whole KB/MB/GB


    // MARK: - Send one video (compress on)

    func sendCompressedVideo() {
        // 1. Original → upload/
        // 2. Prepare:
        //      convert miss → encode into upload/ + STORE convert/
        //      convert-HIT  → copy into upload/
        // 3. PUT from ShareItem.filePath (under upload/)
        // 4. PROPFIND OK → promote copy → download/
        // 5. Success → wipe upload/ + thumbs/; convert/ kept
    }


    // MARK: - Open attachment in chat

    func openAttachment() {
        // download-HIT   size + remote mtime match → open local
        //                bump contentAccessDate (LRU)
        // download-STALE mismatch → delete local, re-download
        // Bubble preview = server URL → SDImageCache (not thumbs/)
    }


    // MARK: - Extra rules

    // Scratch idle launch: skip while .upload-session fresh;
    //   else remove files older than 30 min
    // Cancel after PUT: PROPFIND / folder-retry / post
    //   re-check mediaFlowCancelled
    // Atomic writes: ImageIO + convert-STORE via temp sibling
    // Staging: no full-file map for videos or files > 48 MB
    // Staging names: lastPathComponent only; reject . / ..
    // Folder retry: PROPFIND exist → ready; 404 → create


    // MARK: - Logs

    // Grep: MediaUploadTrace:
    //   CACHE download-HIT|MISS|STALE|OK|FAIL
    //   CACHE convert-HIT|STORE
    //   CACHE promote / purge / scratch-clear
    // Timestamps UTC (…Z). Lines tagged [bBUILD].
    """#
}
