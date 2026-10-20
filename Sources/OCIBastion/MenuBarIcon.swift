import AppKit

enum MenuBarIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let castle = NSBezierPath()
            castle.windingRule = .evenOdd

            // A simple castle silhouette remains legible at menu bar size.
            castle.move(to: NSPoint(x: 1.5, y: 1.5))
            castle.line(to: NSPoint(x: 1.5, y: 14.5))
            castle.line(to: NSPoint(x: 4.5, y: 14.5))
            castle.line(to: NSPoint(x: 4.5, y: 12))
            castle.line(to: NSPoint(x: 6, y: 12))
            castle.line(to: NSPoint(x: 6, y: 15.5))
            castle.line(to: NSPoint(x: 8, y: 15.5))
            castle.line(to: NSPoint(x: 8, y: 13))
            castle.line(to: NSPoint(x: 10, y: 13))
            castle.line(to: NSPoint(x: 10, y: 15.5))
            castle.line(to: NSPoint(x: 12, y: 15.5))
            castle.line(to: NSPoint(x: 12, y: 12))
            castle.line(to: NSPoint(x: 13.5, y: 12))
            castle.line(to: NSPoint(x: 13.5, y: 14.5))
            castle.line(to: NSPoint(x: 16.5, y: 14.5))
            castle.line(to: NSPoint(x: 16.5, y: 1.5))
            castle.close()

            // Cut an open arch through the base of the castle.
            castle.move(to: NSPoint(x: 6.3, y: -1))
            castle.line(to: NSPoint(x: 6.3, y: 6.5))
            castle.curve(to: NSPoint(x: 9, y: 9.5),
                         controlPoint1: NSPoint(x: 6.3, y: 8.2),
                         controlPoint2: NSPoint(x: 7.4, y: 9.5))
            castle.curve(to: NSPoint(x: 11.7, y: 6.5),
                         controlPoint1: NSPoint(x: 10.6, y: 9.5),
                         controlPoint2: NSPoint(x: 11.7, y: 8.2))
            castle.line(to: NSPoint(x: 11.7, y: -1))
            castle.close()

            NSColor.black.setFill()
            castle.fill()
            return true
        }
        image.isTemplate = true
        return image
    }()
}
