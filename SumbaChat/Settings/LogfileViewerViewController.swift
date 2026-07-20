//
// SPDX-FileCopyrightText: 2026 Ivan Cursoroff and Peter Zakharov
// SPDX-License-Identifier: GPL-3.0-or-later
//

import UIKit

/// Pretty log viewer for NCLog daily files (`timestamp [bN] (queue): message`).
final class LogfileViewerViewController: UIViewController {

    private let fileURL: URL

    private let textView: UITextView = {
        let view = UITextView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isEditable = false
        view.isSelectable = true
        view.alwaysBounceVertical = true
        view.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 24, right: 12)
        view.adjustsFontForContentSizeCategory = false
        return view
    }()

    private lazy var shareButton = UIBarButtonItem(
        barButtonSystemItem: .action,
        target: self,
        action: #selector(shareTapped)
    )

    init(fileURL: URL) {
        self.fileURL = fileURL
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // Prefer a short date title over `debug-yyyy-mm-dd.log`.
        let name = fileURL.deletingPathExtension().lastPathComponent
        title = name.hasPrefix("debug-") ? String(name.dropFirst("debug-".count)) : name

        NCAppBranding.styleViewController(self)
        navigationItem.rightBarButtonItem = shareButton

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
        textView.textColor = colors.plain
        textView.text = NSLocalizedString("Loading…", comment: "")

        let url = fileURL
        let traits = traitCollection
        DispatchQueue.global(qos: .userInitiated).async {
            let source = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let attributed = Self.highlightedLog(source, colors: DebugAlgoCodeDocument.colors(for: traits))
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.textView.attributedText = attributed
                self.textView.layoutIfNeeded()
                // Jump near the end — newest lines are usually what you want.
                let overflow = self.textView.contentSize.height - self.textView.bounds.height
                if overflow > 0 {
                    self.textView.setContentOffset(CGPoint(x: 0, y: overflow), animated: false)
                }
            }
        }
    }

    @objc private func shareTapped() {
        let activity = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
        activity.popoverPresentationController?.barButtonItem = shareButton
        present(activity, animated: true)
    }

    // MARK: - Highlighting

    /// Format: `2026-07-20 11:31:35.210Z [b36] (com.apple.main-thread): message`
    static func highlightedLog(_ source: String, colors: DebugAlgoCodeDocument.Colors) -> NSAttributedString {
        let font = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let result = NSMutableAttributedString(
            string: source,
            attributes: [
                .font: font,
                .foregroundColor: colors.plain
            ]
        )

        let ns = source as NSString
        let full = NSRange(location: 0, length: ns.length)
        let linePattern = #"(?m)^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}Z) (\[b[^\]]+\]) (\([^)]+\)): (.*)$"#

        guard let regex = try? NSRegularExpression(pattern: linePattern) else {
            return result
        }

        regex.enumerateMatches(in: source, options: [], range: full) { match, _, _ in
            guard let match, match.numberOfRanges >= 5 else { return }
            result.addAttribute(.foregroundColor, value: colors.comment, range: match.range(at: 1))   // timestamp
            result.addAttribute(.foregroundColor, value: colors.number, range: match.range(at: 2))    // [b36]
            result.addAttribute(.foregroundColor, value: colors.typeName, range: match.range(at: 3))  // (queue)
            result.addAttribute(.foregroundColor, value: colors.plain, range: match.range(at: 4))     // message
        }

        // Soft emphasis for common status words in the message body.
        let emphasis = [
            (#"(?i)\b(error|failed|fail|exception)\b"#, colors.keyword),
            (#"(?i)\b(connected|success|ok)\b"#, colors.comment),
            (#"(?i)\b(warning|warn)\b"#, colors.attribute)
        ]
        for (pattern, color) in emphasis {
            guard let wordRegex = try? NSRegularExpression(pattern: pattern) else { continue }
            wordRegex.enumerateMatches(in: source, options: [], range: full) { match, _, _ in
                guard let match else { return }
                result.addAttribute(.foregroundColor, value: color, range: match.range)
            }
        }

        return result
    }
}
