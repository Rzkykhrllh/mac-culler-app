import AppKit
let names = ["style-1-dark", "style-2-light", "style-3-sunset", "style-4-flat", "style-5-polaroid", "style-6-line"]
let titles = ["1 · Dark glass", "2 · Light", "3 · Sunset", "4 · Flat", "5 · Polaroid", "6 · Line art"]
let cw = 380, W = 3 * cw + 80, H = 2 * 470 + 40
let img = NSImage(size: NSSize(width: W, height: H), flipped: false) { _ in
    NSColor(calibratedWhite: 0.93, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: W, height: H).fill()
    for (i, n) in names.enumerated() {
        let x = CGFloat(40 + (i % 3) * cw), y = CGFloat(H - 470 * (i / 3 + 1))
        let im = NSImage(contentsOfFile: n + ".png")!
        im.draw(in: NSRect(x: x + 20, y: y + 140, width: 300, height: 300))
        im.draw(in: NSRect(x: x + 130, y: y + 60, width: 64, height: 64))
        im.draw(in: NSRect(x: x + 214, y: y + 76, width: 32, height: 32))
        (titles[i] as NSString).draw(at: NSPoint(x: x + 24, y: y + 20), withAttributes: [.font: NSFont.systemFont(ofSize: 22, weight: .semibold), .foregroundColor: NSColor.black])
    }
    return true
}
try! NSBitmapImageRep(data: img.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "styles.png"))
