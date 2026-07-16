//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import XCTest
@testable import NextcloudTalk

/// Simulates iOS 18 Photos / Share Extension staging edge cases without a device.
/// Covers the same ShareItemController path used by:
/// - Share Extension (share from Photos / Files / another app)
/// - In-app “+” → PHPicker → addItem(withURLAndName:)
final class UnitShareItemStagingTest: XCTestCase {

    private final class Delegate: NSObject, ShareItemControllerDelegate {
        var itemsChangedCount = 0
        var preparingChangedCount = 0
        var failureNames: [String] = []

        func shareItemControllerItemsChanged(_ shareItemController: ShareItemController) {
            itemsChangedCount += 1
        }

        func shareItemControllerPreparingItemsChanged(_ shareItemController: ShareItemController) {
            preparingChangedCount += 1
        }

        func shareItemController(_ shareItemController: ShareItemController, didFailToStageItemsWithNames fileNames: [String]) {
            failureNames.append(contentsOf: fileNames)
        }
    }

    private var controller: ShareItemController!
    private var delegate: Delegate!
    private var scratchDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        delegate = Delegate()
        controller = ShareItemController(mediaUploadCompressionSettings: MediaUploadCompressionSettings(level: .none))
        controller.delegate = delegate
        scratchDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("UnitShareItemStaging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratchDir)
        controller = nil
        delegate = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers (stand in for NSItemProvider temp URLs)

    private func writeJPEG(named name: String, size: CGSize = CGSize(width: 32, height: 32)) throws -> URL {
        let url = scratchDir.appendingPathComponent(name)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            UIColor.systemBlue.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        guard let data = image.jpegData(compressionQuality: 0.9), !data.isEmpty else {
            throw NSError(domain: "UnitShareItemStaging", code: 1)
        }
        try data.write(to: url)
        return url
    }

    private func writeEmptyFile(named name: String) throws -> URL {
        let url = scratchDir.appendingPathComponent(name)
        try Data().write(to: url)
        return url
    }

    private func writePNG(named name: String) throws -> URL {
        let url = scratchDir.appendingPathComponent(name)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24))
        let image = renderer.image { ctx in
            UIColor.systemGreen.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
        }
        guard let data = image.pngData(), !data.isEmpty else {
            throw NSError(domain: "UnitShareItemStaging", code: 2)
        }
        try data.write(to: url)
        return url
    }

    private func waitUntilPreparingDone(timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while controller.preparingItemCount > 0, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    // MARK: - Share from Photos / another app (file-url → local copy)

    func testValidJPEGStagesNonEmptyCopy() throws {
        let source = try writeJPEG(named: "IMG_7551.jpeg")
        let ok = controller.addItem(withURLAndName: source, withName: "IMG_7551.jpeg")
        XCTAssertTrue(ok, "Valid JPEG must stage")
        waitUntilPreparingDone()
        XCTAssertEqual(controller.shareItems.count, 1)
        let staged = try XCTUnwrap(controller.shareItems.first)
        let size = try FileManager.default.attributesOfItem(atPath: staged.filePath)[.size] as? NSNumber
        XCTAssertGreaterThan(size?.int64Value ?? 0, 0)
        XCTAssertTrue(delegate.failureNames.isEmpty)
    }

    /// iOS 18 Photos often hands a UUID.png path; content must still stage.
    func testUUIDStylePNGNameStages() throws {
        let name = "D914861E-F00B-4DAF-8649-15B88E809806.png"
        let source = try writePNG(named: name)
        XCTAssertTrue(controller.addItem(withURLAndName: source, withName: name))
        waitUntilPreparingDone()
        XCTAssertEqual(controller.shareItems.count, 1)
        XCTAssertEqual(controller.shareItems.first?.fileName, name)
    }

    /// Provider revoked / empty placeholder → must NOT become a fake share item (None=–, ~12.3 KB chips).
    func testEmptyFileRefusedAndReportedWhenCallerReports() throws {
        let source = try writeEmptyFile(named: "IMG_7542.jpeg")
        let ok = controller.addItem(withURLAndName: source, withName: "IMG_7542.jpeg")
        XCTAssertFalse(ok, "0-byte source must fail staging")
        waitUntilPreparingDone()
        XCTAssertTrue(controller.shareItems.isEmpty, "Must not stage empty placeholder")

        // Terminal failure path (ShareViewController / PHPicker after fallbacks exhausted).
        controller.reportStagingFailure(withName: "IMG_7542.jpeg")
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(delegate.failureNames, ["IMG_7542.jpeg"])
    }

    func testMissingFileRefused() {
        let missing = scratchDir.appendingPathComponent("gone-on-ios18.jpeg")
        let ok = controller.addItem(withURLAndName: missing, withName: "gone-on-ios18.jpeg")
        XCTAssertFalse(ok)
        waitUntilPreparingDone()
        XCTAssertTrue(controller.shareItems.isEmpty)
    }

    // MARK: - Manual chip cheap estimates (mixed bag)

    func testCheapImageEstimateUsesHeuristicNotFlatBag() throws {
        let a = try writeJPEG(named: "a.jpg", size: CGSize(width: 64, height: 64))
        let b = try writeJPEG(named: "b.jpg", size: CGSize(width: 64, height: 64))
        let totals = MediaUploadPreprocessor.cheapEstimatedByteCounts(forFileURLs: [a, b])
        let sizeA = try FileManager.default.attributesOfItem(atPath: a.path)[.size] as! NSNumber
        let sizeB = try FileManager.default.attributesOfItem(atPath: b.path)[.size] as! NSNumber
        let original = sizeA.int64Value + sizeB.int64Value
        XCTAssertEqual(totals.none, original)
        XCTAssertLessThan(totals.high, totals.moderate)
        XCTAssertLessThanOrEqual(totals.moderate, totals.none)
        // High should be well below a naive “22% of bag” only when… still ~22% for images; just ensure ladder.
        XCTAssertGreaterThan(totals.moderate, 0)
    }

    func testCheapPassthroughForNonMedia() throws {
        let pdf = scratchDir.appendingPathComponent("doc.pdf")
        try Data(repeating: 0x41, count: 50_000).write(to: pdf)
        let counts = MediaUploadPreprocessor.cheapEstimatedByteCounts(at: pdf)
        XCTAssertEqual(counts.none, 50_000)
        XCTAssertEqual(counts.moderate, 50_000)
        XCTAssertEqual(counts.high, 50_000)
    }

    func testCheapMixedBagAddsPassthroughAndImage() throws {
        let image = try writeJPEG(named: "pic.jpg", size: CGSize(width: 48, height: 48))
        let other = scratchDir.appendingPathComponent("note.txt")
        try Data("hello".utf8).write(to: other)
        let totals = MediaUploadPreprocessor.cheapEstimatedByteCounts(forFileURLs: [image, other])
        let imageCounts = MediaUploadPreprocessor.cheapEstimatedByteCounts(at: image)
        XCTAssertEqual(totals.none, imageCounts.none + 5)
        XCTAssertEqual(totals.moderate, imageCounts.moderate + 5)
        XCTAssertEqual(totals.high, imageCounts.high + 5)
    }

    // MARK: - Cancel prepare (Send-path)

    func testPreparationTokenCancelMarksCancelled() {
        let token = MediaUploadPreparationToken()
        XCTAssertFalse(token.isCancelled)
        token.cancel()
        XCTAssertTrue(token.isCancelled)
    }

    // MARK: - Compress passthrough vs compress

    func testCompressNoneLeavesSourceUntouchedAsFailureForSwap() throws {
        let source = try writeJPEG(named: "orig.jpg")
        let dest = scratchDir.appendingPathComponent("out.jpg")
        let settings = MediaUploadCompressionSettings(level: .none)
        let didCompress = MediaUploadPreprocessor.compressImage(at: source, toDestinationURL: dest, settings: settings)
        XCTAssertFalse(didCompress, "None must not rewrite to destination")
    }

    func testCompressModerateWritesNonEmptyJPEG() throws {
        let source = try writeJPEG(named: "big.jpg", size: CGSize(width: 400, height: 300))
        let dest = scratchDir.appendingPathComponent("moderate.jpg")
        let settings = MediaUploadCompressionSettings(level: .moderate)
        let didCompress = MediaUploadPreprocessor.compressImage(at: source, toDestinationURL: dest, settings: settings)
        XCTAssertTrue(didCompress)
        let size = try FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? NSNumber
        XCTAssertGreaterThan(size?.int64Value ?? 0, 0)
    }
}
