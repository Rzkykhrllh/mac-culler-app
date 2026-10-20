#if DEBUG
import AppKit
import AVFoundation
import CoreText
import CullerKit

/// DEBUG-only scripted tour for README screenshots and the demo video
/// (`-openFolder <copy of a shoot> -demo`). Marks and crops are written to the folder's XMP: run it on a copy.
/// Writes Documents/Demo/*.png and Documents/Demo/pickture-demo.mp4, then quits.
enum DebugDemo {
    static func run(_ s: FolderSession) async {
        while s.phase != .ready || s.indexing != nil { try? await Task.sleep(for: .milliseconds(100)) }
        guard let w = KeyboardController.shared.mainWindow else { return }
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Demo")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func log(_ m: String) { Log.session.info("DEMO \(m, privacy: .public)") }

        // The user's own settings are restored at the end.
        let saved = (size: s.settings.thumbnailSize, stacks: s.app.stackChoice, files: s.fileView, sidebar: s.app.sidebarVisibility, similarity: s.settings.similarityThreshold)
        func restore() {
            s.settings.thumbnailSize = saved.size
            s.app.setStackChoice(saved.stacks)
            s.setFileView(saved.files)
            s.app.sidebarVisibility = saved.sidebar
            s.app.setSimilarityThreshold(saved.similarity)
        }
        s.settings.thumbnailSize = 190
        s.app.sidebarVisibility = .detailOnly   // the sidebar lists the user's own folders
        s.showInfoPanel = false
        s.setFileView(.combined)
        s.app.setSimilarityThreshold(0.35)   // looser than the strict default, so the bursts of one scene stack
        s.app.setStackChoice(.similar)
        s.viewMode = .grid
        w.setContentSize(NSSize(width: 1440, height: 900))
        w.center()
        NSApp.activate(ignoringOtherApps: true)   // active window chrome in the shots
        w.makeKeyAndOrderFront(nil)
        for _ in 0..<60 where s.stackMembers.isEmpty { try? await Task.sleep(for: .milliseconds(500)) }   // similarity stacks
        for _ in 0..<120 where s.analysisProgress != nil { try? await Task.sleep(for: .milliseconds(500)) }   // focus check
        try? await Task.sleep(for: .seconds(3))   // thumbnails
        // Keep the real pointer from hovering a tile in the recording.
        if let screen = w.screen { CGWarpMouseCursorPosition(CGPoint(x: screen.frame.maxX - 2, y: 2)) }

        func windows() -> [(CGWindowID, CGRect)] { ([w] + (w.attachedSheet.map { [$0] } ?? [])).map { (CGWindowID($0.windowNumber), $0.frame) } }
        func snap(_ name: String) async {
            w.contentView?.layoutSubtreeIfNeeded(); w.contentView?.displayIfNeeded(); CATransaction.flush()
            try? await Task.sleep(for: .milliseconds(250))
            if let cg = DemoRecorder.capture(windows(), best: true) {
                try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name + ".png"))
            }
            log("snap \(name)")
        }
        let rec = DemoRecorder(url: dir.appendingPathComponent("pickture-demo.mp4"), size: CGSize(width: 1920, height: 1200))
        rec.windows = windows()
        rec.start()
        func say(_ caption: String?, _ seconds: Double = 0) async {
            rec.caption = caption
            if seconds > 0 { try? await Task.sleep(for: .seconds(seconds)) }
        }
        func wait(_ seconds: Double) async {
            rec.windows = windows()
            try? await Task.sleep(for: .seconds(seconds))
            rec.windows = windows()
        }

        // 1. The grid.
        await say("Open a shoot — RAW + JPEG shown as one photo", 2.5)
        await snap("01-grid")
        await say("← →  Move")
        for _ in 0..<3 { s.move(1); await wait(0.45) }
        await say("P  Pick")
        s.apply(.flag(.pick), advance: true); await wait(1.0)
        await say("X  Reject")
        s.apply(.flag(.reject), advance: true); await wait(1.0)
        await say("5  Five stars")
        s.apply(.rating(5), advance: false); await wait(0.9)
        await say("6  Red label")
        s.apply(.toggleLabel(.red), advance: true); await wait(1.0)
        await say("⇧P  Pick and move on")
        for _ in 0..<3 { s.apply(.flag(.pick), advance: true); await wait(0.55) }
        s.apply(.flag(.reject), advance: true); await wait(0.8)

        // 2. Stacks.
        log("stacks: \(s.stackMembers.count), collapsed entries: \(s.display.filter { if case .collapsedStack = $0.kind { return true } else { return false } }.count), stackBursts \(s.settings.stackBursts)")
        func total(_ e: DisplayEntry) -> Int { if case .collapsedStack(_, let t) = e.kind { return t } else { return 0 } }
        if let entry = s.display.filter({ total($0) >= 2 }).max(by: { total($0) < total($1) }) {
            s.select(entry.itemID)
            await say("Bursts and similar shots stack automatically", 1.6)
            await say("S  Expand the stack")
            s.toggleSelectedStacks(); await wait(1.8)
            await snap("02-stack")
            await say("B  Jump to the sharpest frame")
            s.goToSharpest(); await wait(1.6)

            // 3. Compare the stack.
            await say("C  Compare side by side")
            s.enterCompare(); await wait(2.6)
            await snap("03-compare")
            await say("→  Next candidate")
            s.stepActiveSlot(1); await wait(1.2)
            await say("P  Keep this one")
            s.apply(.flag(.pick)); await wait(1.2)
            s.viewMode = .grid; await wait(0.8)
            s.toggleSelectedStacks(); await wait(0.8)
        }

        // 4. Loupe, zoom, focus tools.
        await say("E  Loupe")
        s.viewMode = .loupe; await wait(2.2)
        await snap("04-loupe")
        await say("→  Next photo")
        s.move(1); await wait(1.4)
        s.move(1); await wait(1.4)
        await say("Z  100% zoom")
        s.viewports.toggleZoom(slot: 0); await wait(1.8)
        await say("F  Focus peaking")
        s.showPeaking = true; await wait(1.8)
        await snap("05-zoom-peaking")
        s.showPeaking = false
        await say("⌘0  Zoom to fit")
        s.viewports.fitAll(); await wait(1.2)

        // 5. Crop.
        await say("K  Crop and straighten")
        s.beginCrop(); await wait(1.4)
        if let item = s.currentItem {
            let size = ImageDecoder.orientedPixelSize(of: item.files.primary.url) ?? CGSize(width: 3, height: 2)
            await say("4:5 for a post")
            for step in 1...8 {
                let r = 1.5 - (1.5 - 0.8) * Double(step) / 8
                s.cropDraft = CropGeometry.largest(ratio: r, angle: 0, imageSize: size, aspect: step == 8 ? "4:5" : nil)
                await wait(0.08)
            }
            await wait(1.4)
            await snap("06-crop")
            await say("Saved to XMP — Lightroom shows the crop too", 0.6)
            s.commitCrop(); await wait(1.8)
        } else { s.cancelCrop() }

        // 6. Export.
        s.viewMode = .grid; await wait(1.0)
        await say("⇧⌘E  Export with a white border or a 4:5 canvas")
        s.exportTargets = s.selection.isEmpty ? [s.currentID].compactMap { $0 } : Array(s.selection)
        s.activeSheet = .export; await wait(2.8)
        await snap("07-export")
        s.activeSheet = nil; await wait(1.0)

        // 7. Filter the keepers.
        await say("Filter: picks only")
        s.showFilterBar = true
        s.filter.flags = [.pick]; await wait(2.4)
        await snap("08-filter-picks")
        s.filter = FilterState()
        s.showFilterBar = false; await wait(1.0)
        await say("Hand the keepers to Lightroom — ⌃⌘L", 2.4)
        await say(nil, 0.6)

        await rec.stop()
        restore()
        try? await Task.sleep(for: .milliseconds(300))
        log("done → \(dir.path)")
        exit(0)
    }
}

/// Records a set of the app's own windows into an H.264 file (no Screen Recording permission needed for own windows),
/// with a caption pill drawn at the bottom.
nonisolated final class DemoRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _caption: String?
    private var _windows: [(CGWindowID, CGRect)] = []
    var caption: String? { get { lock.withLock { _caption } } set { lock.withLock { _caption = newValue } } }
    var windows: [(CGWindowID, CGRect)] { get { lock.withLock { _windows } } set { lock.withLock { _windows = newValue } } }

    private let size: CGSize
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let queue = DispatchQueue(label: "demo.recorder")
    private var timer: DispatchSourceTimer?
    private var start0: CFAbsoluteTime = 0
    private var lastFrame: CGImage?

    init(url: URL, size: CGSize) {
        try? FileManager.default.removeItem(at: url)
        self.size = size
        writer = try! AVAssetWriter(outputURL: url, fileType: .mp4)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 10_000_000, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel],
        ])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        writer.add(input)
    }

    /// The first window, with the others (a sheet) composited at their place.
    static func capture(_ wins: [(CGWindowID, CGRect)], best: Bool) -> CGImage? {
        let opts: CGWindowImageOption = best ? [.boundsIgnoreFraming, .bestResolution] : [.boundsIgnoreFraming]
        guard let (mainID, mainFrame) = wins.first,
              let base = CGWindowListCreateImage(.null, .optionIncludingWindow, mainID, opts) else { return nil }
        guard wins.count > 1 else { return base }
        let k = CGFloat(base.width) / mainFrame.width
        guard let ctx = CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return base }
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
        for (id, f) in wins.dropFirst() {
            guard let img = CGWindowListCreateImage(.null, .optionIncludingWindow, id, opts) else { continue }
            // AppKit frames are bottom-left based, like the context.
            ctx.draw(img, in: CGRect(x: (f.minX - mainFrame.minX) * k, y: (f.minY - mainFrame.minY) * k,
                                     width: CGFloat(img.width) * k / (CGFloat(img.width) / f.width) , height: f.height * k))
        }
        return ctx.makeImage() ?? base
    }

    func start() {
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        start0 = CFAbsoluteTimeGetCurrent()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(1000 / 25))
        t.setEventHandler { [weak self] in self?.frame() }
        t.resume()
        timer = t
    }

    func stop() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async {
                self.timer?.cancel()
                self.input.markAsFinished()
                self.writer.finishWriting { c.resume() }
            }
        }
    }

    private func frame() {
        guard input.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { return }
        if let img = Self.capture(windows, best: true) { lastFrame = img }
        guard let img = lastFrame else { return }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        guard let pb else { return }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
        ctx.setFillColor(CGColor(gray: 0.08, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        // Fit the window (aspect kept) into the frame.
        let iw = CGFloat(img.width), ih = CGFloat(img.height)
        let scale = min(size.width / iw, size.height / ih)
        let r = CGRect(x: (size.width - iw * scale) / 2, y: (size.height - ih * scale) / 2, width: iw * scale, height: ih * scale)
        ctx.interpolationQuality = .high
        ctx.draw(img, in: r)
        if let text = caption { drawCaption(text, in: ctx) }
        let t = CMTime(seconds: CFAbsoluteTimeGetCurrent() - start0, preferredTimescale: 600)
        adaptor.append(pb, withPresentationTime: t)
    }

    private func drawCaption(_ text: String, in ctx: CGContext) {
        let font = CTFontCreateUIFontForLanguage(.system, 34, nil)!
        let attr = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
        ])
        let line = CTLineCreateWithAttributedString(attr)
        var asc: CGFloat = 0, desc: CGFloat = 0
        let w = CGFloat(CTLineGetTypographicBounds(line, &asc, &desc, nil))
        let pill = CGRect(x: (size.width - w) / 2 - 28, y: 56, width: w + 56, height: asc + desc + 26)
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.72))
        ctx.addPath(CGPath(roundedRect: pill, cornerWidth: pill.height / 2, cornerHeight: pill.height / 2, transform: nil))
        ctx.fillPath()
        ctx.textPosition = CGPoint(x: pill.minX + 28, y: pill.minY + 13 + desc)
        CTLineDraw(line, ctx)
    }
}
#endif
