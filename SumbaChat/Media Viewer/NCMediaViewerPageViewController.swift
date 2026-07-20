//
// SPDX-FileCopyrightText: 2024 Nextcloud GmbH and Nextcloud contributors
// SPDX-FileCopyrightText: 2026 Peter Zakharov
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVKit
import AVFoundation
import Foundation
import UIKit
import SwiftyGif

@objc protocol NCMediaViewerPageViewControllerDelegate {
    @objc func mediaViewerPageZoomDidChange(_ controller: NCMediaViewerPageViewController, _ scale: Double)
    @objc func mediaViewerPageMediaDidLoad(_ controller: NCMediaViewerPageViewController)
}

@objcMembers class NCMediaViewerPageViewController: UIViewController, NCChatFileControllerDelegate, NCZoomableViewDelegate {

    public weak var delegate: NCMediaViewerPageViewControllerDelegate?

    public let message: NCChatMessage
    private let account: TalkAccount
    private let fileDownloader: NCChatFileController

    private lazy var zoomableView = {
        let zoomableView = NCZoomableView()
        zoomableView.translatesAutoresizingMaskIntoConstraints = false
        zoomableView.disablePanningOnInitialZoom = true
        zoomableView.delegate = self

        return zoomableView
    }()

    private lazy var imageView = {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFill
        imageView.isUserInteractionEnabled = true

        return imageView
    }()

    private lazy var errorView = {
        let errorView = UIView()
        errorView.translatesAutoresizingMaskIntoConstraints = false

        let iconConfiguration = UIImage.SymbolConfiguration(pointSize: 36)

        let errorImage = UIImageView()
        errorImage.image = UIImage(systemName: "photo")?.withConfiguration(iconConfiguration)
        errorImage.contentMode = .scaleAspectFit
        errorImage.translatesAutoresizingMaskIntoConstraints = false
        errorImage.tintColor = UIColor.white.withAlphaComponent(0.55)

        let errorText = UILabel()
        errorText.translatesAutoresizingMaskIntoConstraints = false
        errorText.text = NSLocalizedString("An error occurred downloading the picture", comment: "")
        errorText.numberOfLines = 0
        errorText.textAlignment = .center
        errorText.textColor = UIColor.white.withAlphaComponent(0.85)

        errorView.addSubview(errorImage)
        errorView.addSubview(errorText)

        NSLayoutConstraint.activate([
            errorImage.topAnchor.constraint(equalTo: errorView.topAnchor),
            errorImage.widthAnchor.constraint(equalToConstant: 150),
            errorImage.heightAnchor.constraint(greaterThanOrEqualToConstant: 0),
            errorImage.centerXAnchor.constraint(equalTo: errorView.centerXAnchor),
            errorText.topAnchor.constraint(equalTo: errorImage.bottomAnchor, constant: 10),
            errorText.bottomAnchor.constraint(equalTo: errorView.bottomAnchor),
            errorText.centerXAnchor.constraint(equalTo: errorView.centerXAnchor),
            errorText.leadingAnchor.constraint(equalTo: errorView.leadingAnchor, constant: 10),
            errorText.trailingAnchor.constraint(equalTo: errorView.trailingAnchor, constant: -10)
        ])

        return errorView
    }()

    public var currentImage: UIImage?
    public var currentVideoURL: URL?

    /// Used by the gallery host so chrome tap waits for zoom double-tap to fail.
    public var doubleTapGestureRecognizer: UITapGestureRecognizer? {
        zoomableView.doubleTapGestureRecoginzer
    }

    private var playerViewController: AVPlayerViewController?

    private lazy var activityIndicator: UIActivityIndicatorView = {
        let indicator = UIActivityIndicatorView(style: .large)
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.color = .white
        indicator.hidesWhenStopped = true
        return indicator
    }()

    private lazy var downloadProgressLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = UIColor.white.withAlphaComponent(0.85)
        label.textAlignment = .center
        label.numberOfLines = 2
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.75
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        label.text = NSLocalizedString("Loading…", comment: "File download in progress")
        return label
    }()

    private lazy var downloadProgressView: UIProgressView = {
        let progress = UIProgressView(progressViewStyle: .bar)
        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.progressTintColor = .white
        progress.trackTintColor = UIColor.white.withAlphaComponent(0.25)
        progress.layer.cornerRadius = 2
        progress.clipsToBounds = true
        progress.progress = 0
        progress.setContentHuggingPriority(.required, for: .vertical)
        return progress
    }()

    private lazy var downloadStatusContainer: UIStackView = {
        let stack = UIStackView(arrangedSubviews: [activityIndicator, downloadProgressLabel, downloadProgressView])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        // Center keeps the spinner intrinsic; label/bar are pinned to stack width below.
        stack.alignment = .center
        stack.spacing = 12
        return stack
    }()

    init(message: NCChatMessage, account: TalkAccount) {
        self.message = message
        self.account = account

        self.fileDownloader = NCChatFileController(account: account)

        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        self.view.backgroundColor = .black
        self.view.addSubview(self.zoomableView)
        self.view.addSubview(self.downloadStatusContainer)

        // Progress cluster: fills available width up to 280pt so SE / landscape / iPad all stay readable.
        let fillWidth = downloadStatusContainer.widthAnchor.constraint(
            equalTo: view.safeAreaLayoutGuide.widthAnchor,
            constant: -64
        )
        fillWidth.priority = .defaultHigh

        // Full-bleed media for immersive gallery browsing.
        NSLayoutConstraint.activate([
            self.zoomableView.leftAnchor.constraint(equalTo: self.view.leftAnchor),
            self.zoomableView.rightAnchor.constraint(equalTo: self.view.rightAnchor),
            self.zoomableView.topAnchor.constraint(equalTo: self.view.topAnchor),
            self.zoomableView.bottomAnchor.constraint(equalTo: self.view.bottomAnchor),

            self.downloadStatusContainer.centerXAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.centerXAnchor),
            self.downloadStatusContainer.centerYAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.centerYAnchor),
            self.downloadStatusContainer.leadingAnchor.constraint(greaterThanOrEqualTo: self.view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            self.downloadStatusContainer.trailingAnchor.constraint(lessThanOrEqualTo: self.view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            self.downloadStatusContainer.widthAnchor.constraint(lessThanOrEqualToConstant: 280),
            fillWidth,

            self.downloadProgressLabel.widthAnchor.constraint(equalTo: self.downloadStatusContainer.widthAnchor),
            self.downloadProgressView.widthAnchor.constraint(equalTo: self.downloadStatusContainer.widthAnchor),
            self.downloadProgressView.heightAnchor.constraint(equalToConstant: 4)
        ])

        self.zoomableView.replaceContentView(self.imageView)
        showDownloadProgressUI(progress: 0, completedBytes: 0, totalBytes: Int64(message.file()?.size ?? 0), canReportProgress: false)

        fileDownloader.delegate = self
        fileDownloader.downloadFile(withFileId: self.message.file().parameterId)

        self.navigationItem.title = self.message.file().name

        NotificationCenter.default.addObserver(self, selector: #selector(didChangeDownloadProgress(notification:)), name: NSNotification.Name.NCChatFileControllerDidChangeDownloadProgress, object: nil)

        AllocationTracker.shared.addAllocation("NCMediaViewerPageViewController")
    }

    deinit {
        self.removePlayerViewControllerIfNeeded()
        AllocationTracker.shared.removeAllocation("NCMediaViewerPageViewController")
    }

    override func viewWillDisappear(_ animated: Bool) {
        self.playerViewController?.player?.pause()
    }

    override func viewDidLayoutSubviews() {
        // Make sure we have the correct bounds and center the view correctly
        self.zoomableView.resizeContentView()
    }

    func showErrorView() {
        self.imageView.image = nil
        self.removePlayerViewControllerIfNeeded()
        self.view.addSubview(self.errorView)

        NSLayoutConstraint.activate([
            self.errorView.leadingAnchor.constraint(greaterThanOrEqualTo: self.view.safeAreaLayoutGuide.leadingAnchor, constant: 10),
            self.errorView.trailingAnchor.constraint(greaterThanOrEqualTo: self.view.safeAreaLayoutGuide.trailingAnchor, constant: -10),
            self.errorView.centerXAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.centerXAnchor),
            self.errorView.centerYAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.centerYAnchor)
        ])
    }

    private func showDownloadProgressUI(progress: Float, completedBytes: Int64, totalBytes: Int64, canReportProgress: Bool) {
        downloadStatusContainer.isHidden = false

        let knownTotal = totalBytes > 0 ? totalBytes : Int64(message.file()?.size ?? 0)
        let indeterminate = !canReportProgress || knownTotal <= 0 || progress <= 0

        if indeterminate {
            activityIndicator.startAnimating()
            downloadProgressView.setProgress(0, animated: false)
            downloadProgressLabel.text = NSLocalizedString("Loading…", comment: "File download in progress")
        } else {
            activityIndicator.stopAnimating()
            downloadProgressView.setProgress(min(max(progress, 0), 1), animated: true)
            let loaded = NCUtils.readableFileSize(completedBytes)
            let total = NCUtils.readableFileSize(knownTotal)
            if loaded.isEmpty || total.isEmpty {
                downloadProgressLabel.text = NSLocalizedString("Loading…", comment: "File download in progress")
            } else {
                downloadProgressLabel.text = String(
                    format: NSLocalizedString("Loading %@ of %@", comment: "File download progress, e.g. Loading 12 MB of 40 MB"),
                    loaded,
                    total
                )
            }
        }
    }

    private func hideDownloadProgressUI() {
        activityIndicator.stopAnimating()
        downloadStatusContainer.isHidden = true
        downloadProgressView.setProgress(0, animated: false)
    }

    // MARK: - NCChatFileController delegate
    func fileControllerDidLoadFile(_ fileController: NCChatFileController, with fileStatus: NCChatFileStatus) {
        hideDownloadProgressUI()

        guard let localPath = fileStatus.fileLocalPath, let mimetype = message.file()?.mimetype else {
            self.showErrorView()
            return
        }

        if NCUtils.isImage(fileType: mimetype) {
            displayImage(from: localPath)
        } else if NCUtils.isVideo(fileType: mimetype) {
            playVideo(from: localPath)
        } else {
            self.showErrorView()
        }
    }

    func fileControllerDidFailLoadingFile(_ fileController: NCChatFileController, withFileId fileId: String, withErrorDescription errorDescription: String) {
        hideDownloadProgressUI()

        self.showErrorView()

        print("Error downloading picture: " + errorDescription)
    }

    func didChangeDownloadProgress(notification: Notification) {
        DispatchQueue.main.async {
            guard let fileParameter = self.message.file(),
                  let receivedStatus = NCChatFileStatus.getStatus(from: notification, for: fileParameter)
            else { return }

            self.showDownloadProgressUI(progress: receivedStatus.downloadProgress,
                                        completedBytes: receivedStatus.completedBytes,
                                        totalBytes: receivedStatus.totalBytes,
                                        canReportProgress: receivedStatus.canReportProgress)
        }
    }

    // MARK: - NCZoomableView delegate

    func contentViewZoomDidChange(_ view: NCZoomableView, _ scale: Double) {
        self.delegate?.mediaViewerPageZoomDidChange(self, scale)
    }

    private func displayImage(from localPath: String) {
        guard var image = UIImage(contentsOfFile: localPath) else {
            self.showErrorView()
            return
        }

        // Set original image as current image
        self.currentImage = image

        // Downscale images that are too large and require too much memory
        if image.size.width > 2048 ||  image.size.height > 2048 {
            let newSize = AVMakeRect(aspectRatio: image.size, insideRect: .init(x: 0, y: 0, width: 2048, height: 2048)).size
            guard let scaledImage = NCUtils.renderAspectImage(image: image, ofSize: newSize, scale: image.scale, centerImage: false)
            else {
                self.showErrorView()
                return
            }

            image = scaledImage
        }

        if message.file() != nil, message.isAnimatableGif,
           let data = try? Data(contentsOf: URL(fileURLWithPath: localPath)),
           let gifImage = try? UIImage(gifData: data) {

            self.imageView.setGifImage(gifImage)
            self.currentImage = gifImage
        } else {
            self.imageView.image = image
        }

        // Adjust the view to the new image (use the non-gif version here for correct dimensions)
        self.zoomableView.contentViewSize = image.size
        self.zoomableView.resizeContentView()

        self.zoomableView.isHidden = false
        self.imageView.isHidden = false

        removePlayerViewControllerIfNeeded()
        self.delegate?.mediaViewerPageMediaDidLoad(self)
    }

    private func playVideo(from localPath: String) {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Failed to set audio session category: \(error)")
        }

        let videoURL = URL(fileURLWithPath: localPath)
        self.currentVideoURL = videoURL
        let player = AVPlayer(url: videoURL)
        let playerViewController = AVPlayerViewController()
        playerViewController.player = player
        playerViewController.showsPlaybackControls = true
        self.playerViewController = playerViewController

        self.addChild(playerViewController)
        self.view.addSubview(playerViewController.view)
        playerViewController.view.frame = self.view.bounds
        playerViewController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        playerViewController.didMove(toParent: self)

        // Start with sound; mute via gallery footer (Sumba). AVKit's top-right speaker is display-only.
        player.isMuted = false
        player.play()

        self.zoomableView.contentViewSize = playerViewController.view.bounds.size
        self.zoomableView.resizeContentView()
        self.zoomableView.isHidden = false
        self.imageView.isHidden = true

        self.delegate?.mediaViewerPageMediaDidLoad(self)
    }

    @discardableResult
    public func toggleVideoMute() -> Bool {
        guard let player = playerViewController?.player else { return false }
        player.isMuted.toggle()
        return player.isMuted
    }

    public var isVideoMuted: Bool {
        playerViewController?.player?.isMuted ?? false
    }

    private func removePlayerViewControllerIfNeeded() {
        if let playerVC = self.playerViewController {
            playerVC.player?.replaceCurrentItem(with: nil)
            playerVC.willMove(toParent: nil)
            playerVC.view.removeFromSuperview()
            playerVC.removeFromParent()
            self.playerViewController = nil
            self.currentVideoURL = nil
        }
    }
}
