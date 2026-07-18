//
// SPDX-FileCopyrightText: 2026 Ivan Cursorov and Peter Zakharov
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
        view.backgroundColor = .systemBackground
        view.textContainerInset = UIEdgeInsets(top: 16, left: 14, bottom: 24, right: 14)
        view.font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view.textColor = .label
        view.adjustsFontForContentSizeCategory = false
        return view
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = NSLocalizedString("Cache Policy", comment: "Debug screen explaining media / attachment caches")
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
    CACHE POLICY
    ============

    Layout (App Group Library/Caches/SumbaMedia/)
    ---------------------------------------------
    download/   Full chat attachments (open / promote).
                Settings: Cached Images / Videos / Documents
                + Cache limit. Cap = Settings value (~3 GB
                default). Purge at 95% → 80% by LRU access.
    upload/     Send staging (original then outgoing file).
                Soft cap 512 MB. Wiped after send, Cancel,
                next share session, or Settings clear.
                Cross-process: .upload-session marker (45 min)
                blocks Settings/idle wipe while share is open.
                Touched on stage + every 10 min while sheet open.
                Cancel-during-upload delays wipe ~2.5s.
    convert/    Encoded reuse per account
                (convert/{accountId}/ + v2 fingerprint + profile).
                Soft cap 512 MB. LRU on convert-HIT. Cleared
                from Settings Convert cache row (not Cache limit).
                Files use completeUntilFirstUserAuthentication.
    thumbs/     Share-sheet image previews only. Session wipe
                with upload/. Own Settings size row.


    System (not under SumbaMedia/)
    ------------------------------
    SDImageCache   Avatars, server file previews, link thumbs.
                   ~100 MB / ~4 weeks (NCAPIController).
    URLCache       HTTP bodies under SDWebImage / URLSession.
                   Cleared with System previews row.


    Settings → Advanced map
    -----------------------
    Cached Images/Videos/Documents
      = download/ only, by type. Sum = usage vs Cache limit.
    Cache limit
      = max bytes for download/ only.
    Upload staging / Convert cache / Share thumbs /
    System previews
      = everything else (sizes + clear). Not in Cache limit.


    Send one video (compress on)
    ----------------------------
    1. Original → upload/
    2. Prepare: convert miss → encode into upload/
       + STORE copy in convert/
       (or convert-HIT → copy into upload/)
    3. PUT from upload/ path (ShareItem.filePath)
    4. PROPFIND OK → promote copy → download/
    5. Success → wipe upload/ + thumbs/; convert/ kept


    Open attachment in chat
    -----------------------
    download-HIT   size + remote mtime match → open local;
                   bump contentAccessDate (LRU).
    download-STALE mismatch → delete local, re-download.
    Bubble preview = server preview URL → SDImageCache
                   (not thumbs/).


    Purge rules
    -----------
    download/ + convert/  LRU by contentAccessDate
                          (fallback creationDate).
                          Never bump modificationDate on HIT
                          (STALE key = remote mtime + size).
    upload/               Soft cap FIFO by creation; session
                          wipe is the main cleanup.
    Scratch idle launch   skipped while .upload-session is
                          fresh; else files older than 30 min.
    Cancel after PUT      verify / folder-retry / post callbacks
                          re-check mediaFlowCancelled.
    Atomic writes         ImageIO + convert-STORE via temp sibling
                          then move (no corrupt HIT on crash).
    Staging fallback      No mapped full-file read for videos or
                          files > 48 MB (jetsam).
    Staging names         lastPathComponent only; reject . / ..
                          (no App Group path traversal).
    Folder retry          PROPFIND exist → ready; 404 → create.


    Grep device logs:  MediaUploadTrace:
    CACHE download-HIT|MISS|STALE|OK|FAIL
    CACHE convert-HIT|STORE
    CACHE promote / purge / scratch-clear
    Timestamps UTC (…Z). Lines tagged [bBUILD].
    """
}