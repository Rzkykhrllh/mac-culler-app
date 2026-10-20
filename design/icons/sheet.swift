import AppKit
let names = ["1-contact-sheet", "2-fan", "3-picture-check", "4-p-frame"], titles = ["1 · Contact sheet", "2 · Fan of picks", "3 · Picture ✓", "4 · P-frame"]
let W = 4 * 420 + 40, H = 560
let img = NSImage(size: NSSize(width: W, height: H), flipped: false) { _ in
    NSColor(calibratedWhite: 0.93, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: W, height: H).fill()
    for (i, n) in names.enumerated() {
        let x = CGFloat(40 + i * 420)
        NSImage(contentsOfFile: n + ".png")!.draw(in: NSRect(x: x, y: 140, width: 380, height: 380))
        NSImage(contentsOfFile: n + ".png")!.draw(in: NSRect(x: x + 150, y: 60, width: 64, height: 64))   // Dock-ish size
        NSImage(contentsOfFile: n + ".png")!.draw(in: NSRect(x: x + 240, y: 76, width: 32, height: 32))
        (titles[i] as NSString).draw(at: NSPoint(x: x + 10, y: 20), withAttributes: [.font: NSFont.systemFont(ofSize: 22, weight: .semibold), .foregroundColor: NSColor.black])
    }
    return true
}
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "concepts.png"))
