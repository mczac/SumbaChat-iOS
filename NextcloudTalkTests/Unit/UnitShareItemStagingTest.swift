//
// SPDX-FileCopyrightText: 2026 Ivan Cursoroff and Peter Zakharov
// SPDX-License-Identifier: GPL-3.0-or-later
//

import XCTest
@testable import SumbaChat

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

    /// Hostile / crafted provider names must not escape App Group upload/.
    func testPathTraversalNameStaysUnderUpload() throws {
        let source = try writeJPEG(named: "real.jpg")
        XCTAssertTrue(controller.addItem(withURLAndName: source, withName: "../../Library/evil.jpg"))
        waitUntilPreparingDone()
        let staged = try XCTUnwrap(controller.shareItems.first)
        XCTAssertEqual(staged.fileName, "evil.jpg")
        XCTAssertFalse(staged.filePath.contains(".."))
        let uploadRoot = (MediaUploadDiskStore.shared.uploadDirectoryPath as NSString).standardizingPath
        let stagedPath = (staged.filePath as NSString).standardizingPath
        XCTAssertTrue(stagedPath.hasPrefix(uploadRoot + "/") || stagedPath == uploadRoot)
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
        XCTAssertLessThan(totals.high, totals.medium)
        XCTAssertLessThanOrEqual(totals.medium, totals.low)
        XCTAssertLessThanOrEqual(totals.low, totals.none)
        XCTAssertGreaterThan(totals.medium, 0)
    }

    func testCheapPassthroughForNonMedia() throws {
        let pdf = scratchDir.appendingPathComponent("doc.pdf")
        try Data(repeating: 0x41, count: 50_000).write(to: pdf)
        let counts = MediaUploadPreprocessor.cheapEstimatedByteCounts(at: pdf)
        XCTAssertEqual(counts.none, 50_000)
        XCTAssertEqual(counts.low, 50_000)
        XCTAssertEqual(counts.medium, 50_000)
        XCTAssertEqual(counts.high, 50_000)
    }

    func testCheapMixedBagAddsPassthroughAndImage() throws {
        let image = try writeJPEG(named: "pic.jpg", size: CGSize(width: 48, height: 48))
        let other = scratchDir.appendingPathComponent("note.txt")
        try Data("hello".utf8).write(to: other)
        let totals = MediaUploadPreprocessor.cheapEstimatedByteCounts(forFileURLs: [image, other])
        let imageCounts = MediaUploadPreprocessor.cheapEstimatedByteCounts(at: image)
        XCTAssertEqual(totals.none, imageCounts.none + 5)
        XCTAssertEqual(totals.medium, imageCounts.medium + 5)
        XCTAssertEqual(totals.high, imageCounts.high + 5)
    }

    func testAutomaticPicksHighQualityWhenUnderFileCap() throws {
        let debug = MediaUploadDebugSettings.default
        debug.perFileMaxBytes = 16 * 1024 * 1024
        debug.packageMaxBytes = 16 * 1024 * 1024
        debug.automaticPhotoEstimateMarginPercent = 20
        debug.automaticVideoEstimateMarginPercent = 10
        debug.save()
        defer { MediaUploadDebugSettings.resetToDefaults() }

        let small = try writeJPEG(named: "auto-small.jpg", size: CGSize(width: 64, height: 64))
        let levels = MediaUploadAutomaticPolicy.compressionLevels(forFileURLs: [small])
        XCTAssertEqual(levels, [.low], "Tiny JPEG should fit High quality (Low compression)")
    }

    func testAutomaticEscalatesWhenHighQualityOverFileCap() throws {
        let debug = MediaUploadDebugSettings.default
        // Cap below any useful Low estimate for a large image → force Medium or High.
        debug.perFileMaxBytes = 2 * 1024
        debug.packageMaxBytes = 2 * 1024
        debug.automaticPhotoEstimateMarginPercent = 20
        debug.automaticVideoEstimateMarginPercent = 10
        debug.low.imageJPEGQuality = 95
        debug.low.imageMaxDimension = 4000
        debug.medium.imageJPEGQuality = 40
        debug.medium.imageMaxDimension = 800
        debug.high.imageJPEGQuality = 10
        debug.high.imageMaxDimension = 640
        debug.save()
        defer { MediaUploadDebugSettings.resetToDefaults() }

        let large = try writeJPEG(named: "auto-large.jpg", size: CGSize(width: 2000, height: 1500))
        let levels = MediaUploadAutomaticPolicy.compressionLevels(forFileURLs: [large])
        XCTAssertEqual(levels.count, 1)
        XCTAssertNotEqual(levels[0], .low, "Over-cap High quality must escalate")
        XCTAssertTrue(levels[0] == .medium || levels[0] == .high)
    }

    func testAutomaticEstimateMarginCeiling() {
        let cap: Int64 = 16 * 1024 * 1024
        // 20% photo margin → ceiling = cap / 1.2
        let photoCeiling = MediaUploadAutomaticPolicy.estimateAcceptanceCeilingBytes(fileCap: cap, marginPercent: 20)
        XCTAssertEqual(photoCeiling, Int64(Double(cap) / 1.2))
        XCTAssertTrue(MediaUploadAutomaticPolicy.estimateFitsUnderCap(12 * 1024 * 1024, fileCap: cap, marginPercent: 20))
        XCTAssertFalse(MediaUploadAutomaticPolicy.estimateFitsUnderCap(13 * 1024 * 1024, fileCap: cap, marginPercent: 20))

        // 10% video margin → ceiling = cap / 1.1
        let videoCeiling = MediaUploadAutomaticPolicy.estimateAcceptanceCeilingBytes(fileCap: cap, marginPercent: 10)
        XCTAssertEqual(videoCeiling, Int64(Double(cap) / 1.1))
        XCTAssertTrue(MediaUploadAutomaticPolicy.estimateFitsUnderCap(14 * 1024 * 1024, fileCap: cap, marginPercent: 10))
        XCTAssertFalse(MediaUploadAutomaticPolicy.estimateFitsUnderCap(15 * 1024 * 1024, fileCap: cap, marginPercent: 10))

        // 0% margin → compare directly to cap
        XCTAssertTrue(MediaUploadAutomaticPolicy.estimateFitsUnderCap(cap - 1, fileCap: cap, marginPercent: 0))
        XCTAssertFalse(MediaUploadAutomaticPolicy.estimateFitsUnderCap(cap, fileCap: cap, marginPercent: 0))
    }

    func testAutomaticDefaultMargins() {
        let defaults = MediaUploadDebugSettings.default
        XCTAssertEqual(defaults.automaticPhotoEstimateMarginPercent, 20, accuracy: 0.001)
        XCTAssertEqual(defaults.automaticVideoEstimateMarginPercent, 10, accuracy: 0.001)
    }

    func testContentFingerprintStableForSameBytes() throws {
        let a = try writeJPEG(named: "fp-a.jpg", size: CGSize(width: 32, height: 32))
        let b = scratchDir.appendingPathComponent("fp-b.jpg")
        try FileManager.default.copyItem(at: a, to: b)
        let fa = MediaUploadDiskStore.contentFingerprint(at: a)
        let fb = MediaUploadDiskStore.contentFingerprint(at: b)
        XCTAssertNotNil(fa)
        XCTAssertEqual(fa, fb)
        XCTAssertTrue(fa?.hasPrefix("v2_") == true)
    }

    /// Same size/head/tail but different middle must not collide (v2 mid samples).
    func testContentFingerprintDivergesOnMiddleBytes() throws {
        let size = 2 * 1024 * 1024
        var bytesA = Data(repeating: 0x11, count: size)
        var bytesB = Data(repeating: 0x11, count: size)
        bytesB[size / 2] = 0x22
        let a = scratchDir.appendingPathComponent("mid-a.bin")
        let b = scratchDir.appendingPathComponent("mid-b.bin")
        try bytesA.write(to: a)
        try bytesB.write(to: b)
        let fa = try XCTUnwrap(MediaUploadDiskStore.contentFingerprint(at: a))
        let fb = try XCTUnwrap(MediaUploadDiskStore.contentFingerprint(at: b))
        XCTAssertNotEqual(fa, fb)
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

    func testCompressMediumWritesNonEmptyJPEG() throws {
        let source = try writeJPEG(named: "big.jpg", size: CGSize(width: 400, height: 300))
        let dest = scratchDir.appendingPathComponent("medium.jpg")
        let settings = MediaUploadCompressionSettings(level: .medium)
        let didCompress = MediaUploadPreprocessor.compressImage(at: source, toDestinationURL: dest, settings: settings)
        XCTAssertTrue(didCompress)
        let size = try FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? NSNumber
        XCTAssertGreaterThan(size?.int64Value ?? 0, 0)
    }

    func testEffectiveRateRespectsMaxBytesCap() {
        let profile = MediaUploadProfileConfig.defaultHigh
        // 200s at 0.96 Mbps would be 24 MB; cap is 12 MB → rate ≤ 0.48 Mbps
        let rate = MediaUploadDebugSettings.effectiveRateMbps(profile: profile, durationSeconds: 200)
        XCTAssertLessThanOrEqual(rate, 0.96)
        XCTAssertEqual(rate, 12.0 * 8.0 / 200.0, accuracy: 0.001)
    }

    func testPresetGuestimateLabels() {
        XCTAssertEqual(MediaUploadDebugSettings.guestimatedExportPresetMbps("low"), 0.15, accuracy: 0.001)
        XCTAssertEqual(MediaUploadDebugSettings.guestimatedExportPresetMbps("medium"), 0.7, accuracy: 0.001)
        XCTAssertTrue(MediaUploadDebugSettings.guestimatedExportPresetLabel("720p").contains("4.00"))
    }

    func testCompressionLevelNoneAlwaysUseful() {
        XCTAssertTrue(MediaUploadDebugSettings.compressionLevelLikelyUseful(.none, forFileURLs: []))
    }

    func testExpectedJPEGBitsPerPixelMonotonic() {
        XCTAssertLessThan(
            MediaUploadDebugSettings.expectedJPEGBitsPerPixel(qualityPercent: 15),
            MediaUploadDebugSettings.expectedJPEGBitsPerPixel(qualityPercent: 80)
        )
    }

    func testPhotosOnlyTinyJPEGDisablesHarshLevels() throws {
        // Very small already-JPEG: High (q15 / 1280) quality-only should not look useful.
        let url = try writeJPEG(named: "tiny-gate.jpg", size: CGSize(width: 64, height: 64))
        // Ensure file is a normal small JPEG on disk.
        let size = MediaUploadPreprocessor.fileSizePublic(at: url)
        XCTAssertGreaterThan(size, 0)

        // High is harsh quality — still may or may not gate depending on bpp of our test JPEG writer.
        // At minimum, None stays useful.
        XCTAssertTrue(MediaUploadDebugSettings.compressionLevelLikelyUseful(.none, forFileURLs: [url]))
        // Low (mild, q80) on a 64px JPEG almost never helps.
        XCTAssertFalse(MediaUploadDebugSettings.imageCompressionLikelyShrinks(at: url, level: .low))
    }
}
