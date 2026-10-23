import AppKit
import Foundation

// Records only events delivered to this fixture's own virtual-display window.
private final class ClickWitnessWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class ClickWitnessView: NSView {
    var onMouseEvent: ((NSEvent, NSPoint, String) -> Void)?
    private var downCounts = [0, 0, 0, 0]
    private var upCounts = [0, 0, 0, 0]
    private var rightDownCounts = [0, 0, 0, 0]
    private var rightUpCounts = [0, 0, 0, 0]
    private var draggedCounts = [0, 0, 0, 0]
    private var lastPoint: NSPoint?
    private let names = ["TOP LEFT", "TOP RIGHT", "BOTTOM LEFT", "BOTTOM RIGHT"]

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) { record(event) }
    override func mouseUp(with event: NSEvent) { record(event) }
    override func rightMouseDown(with event: NSEvent) { record(event) }
    override func rightMouseUp(with event: NSEvent) { record(event) }
    override func mouseDragged(with event: NSEvent) { record(event) }
    override func rightMouseDragged(with event: NSEvent) { record(event) }

    private func record(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = (point.y >= bounds.midY ? 0 : 2) + (point.x >= bounds.midX ? 1 : 0)
        switch event.type {
        case .leftMouseDown: downCounts[index] += 1
        case .leftMouseUp: upCounts[index] += 1
        case .rightMouseDown: rightDownCounts[index] += 1
        case .rightMouseUp: rightUpCounts[index] += 1
        case .leftMouseDragged, .rightMouseDragged: draggedCounts[index] += 1
        default: return
        }
        lastPoint = point
        needsDisplay = true
        onMouseEvent?(event, point, names[index])
    }

    override func draw(_ dirtyRect: NSRect) {
        let colors: [NSColor] = [
            NSColor(calibratedRed: 0.12, green: 0.27, blue: 0.40, alpha: 1),
            NSColor(calibratedRed: 0.30, green: 0.19, blue: 0.39, alpha: 1),
            NSColor(calibratedRed: 0.14, green: 0.34, blue: 0.25, alpha: 1),
            NSColor(calibratedRed: 0.40, green: 0.27, blue: 0.12, alpha: 1)
        ]
        for index in 0..<4 {
            let rect = NSRect(x: index % 2 == 0 ? bounds.minX : bounds.midX,
                              y: index < 2 ? bounds.midY : bounds.minY,
                              width: bounds.width / 2, height: bounds.height / 2)
            let didReceiveInput = downCounts[index] + upCounts[index] + rightDownCounts[index] + rightUpCounts[index] + draggedCounts[index] > 0
            (didReceiveInput ? colors[index].blended(withFraction: 0.25, of: .white)! : colors[index]).setFill()
            rect.fill()
            let center = NSPoint(x: rect.midX, y: rect.midY)
            NSColor.white.withAlphaComponent(0.8).setStroke()
            let target = NSBezierPath(ovalIn: NSRect(x: center.x - 36, y: center.y - 36, width: 72, height: 72))
            target.lineWidth = 3
            target.stroke()
            drawCentered(names[index], at: NSPoint(x: center.x, y: center.y + 70), size: 30)
            drawCentered("DOWN \(downCounts[index])   UP \(upCounts[index])",
                         at: NSPoint(x: center.x, y: center.y - 90), size: 24)
            drawCentered("RIGHT \(rightDownCounts[index])/\(rightUpCounts[index])   DRAG \(draggedCounts[index])",
                         at: NSPoint(x: center.x, y: center.y - 130), size: 22)
        }
        if let point = lastPoint {
            NSColor.systemYellow.setFill()
            NSBezierPath(ovalIn: NSRect(x: point.x - 13, y: point.y - 13, width: 26, height: 26)).fill()
        }
        drawCentered("Tab-D · 실제 마우스 입력 검사", at: NSPoint(x: bounds.midX, y: bounds.maxY - 55), size: 26)
    }

    private func drawCentered(_ text: String, at point: NSPoint, size: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: size, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let string = text as NSString
        let dimensions = string.size(withAttributes: attributes)
        string.draw(at: NSPoint(x: point.x - dimensions.width / 2, y: point.y), withAttributes: attributes)
    }
}

@main private enum ClickWitness {
    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count == 3, let displayID = UInt32(arguments[1]), displayID != 0 else { exit(64) }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }) else { exit(1) }
        let expectedBounds = CGDisplayBounds(displayID)
        let window = ClickWitnessWindow(contentRect: screen.frame, styleMask: .borderless,
                                        backing: .buffered, defer: false, screen: screen)
        window.isOpaque = true
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        let view = ClickWitnessView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.autoresizingMask = [.width, .height]
        window.contentView = view
        window.setFrame(screen.frame, display: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        window.makeFirstResponder(view)

        let output = URL(fileURLWithPath: arguments[2])
        var downCount = 0
        var upCount = 0
        var rightDownCount = 0
        var rightUpCount = 0
        var draggedCount = 0
        var leftButtonHeld = false
        var rightButtonHeld = false
        var lastEventType = "none"
        var lastDown: [String: Any] = [:]
        var lastUp: [String: Any] = [:]
        var lastRightDown: [String: Any] = [:]
        var lastRightUp: [String: Any] = [:]
        var lastDragged: [String: Any] = [:]
        var recentEvents: [[String: Any]] = []
        func rectArray(_ rect: CGRect) -> [CGFloat] { [rect.origin.x, rect.origin.y, rect.width, rect.height] }
        func writeState() {
            let state: [String: Any] = [
                "ready": true, "displayID": displayID,
                "expectedCGDisplayBounds": rectArray(expectedBounds),
                "currentCGDisplayBounds": rectArray(CGDisplayBounds(displayID)),
                "viewFrame": rectArray(view.frame), "viewBounds": rectArray(view.bounds),
                "windowFrame": rectArray(window.frame), "windowFrameCoordinateSystem": "AppKit bottom-left",
                "localNormalizedCoordinateSystem": "top-left (x right, y down)",
                "downCount": downCount, "upCount": upCount,
                "rightDownCount": rightDownCount, "rightUpCount": rightUpCount, "draggedCount": draggedCount,
                "leftButtonHeld": leftButtonHeld, "rightButtonHeld": rightButtonHeld,
                "lastEventType": lastEventType, "lastDown": lastDown, "lastUp": lastUp,
                "lastRightDown": lastRightDown, "lastRightUp": lastRightUp, "lastDragged": lastDragged,
                "recentEvents": recentEvents,
                "updatedAt": ISO8601DateFormatter().string(from: Date())
            ]
            do {
                let bytes = try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
                try bytes.write(to: output, options: .atomic)
            } catch {
                fputs("ClickWitness: cannot write its own diagnostics JSON\n", stderr)
                app.terminate(nil)
            }
        }
        view.onMouseEvent = { event, point, quadrant in
            let x = (point.x - view.bounds.minX) / max(1, view.bounds.width)
            let bottomY = (point.y - view.bounds.minY) / max(1, view.bounds.height)
            switch event.type {
            case .leftMouseDown: lastEventType = "leftMouseDown"
            case .leftMouseUp: lastEventType = "leftMouseUp"
            case .rightMouseDown: lastEventType = "rightMouseDown"
            case .rightMouseUp: lastEventType = "rightMouseUp"
            case .leftMouseDragged: lastEventType = "leftMouseDragged"
            case .rightMouseDragged: lastEventType = "rightMouseDragged"
            default: return
            }
            var record: [String: Any] = [
                "type": lastEventType, "timestamp": event.timestamp, "quadrant": quadrant,
                "localPointBottomLeft": [point.x, point.y],
                "localNormalized": [x, 1 - bottomY], "localNormalizedBottomLeft": [x, bottomY],
                "buttonNumber": event.buttonNumber, "clickCount": event.clickCount
            ]
            if let cgPoint = event.cgEvent?.location {
                record["globalCGLocation"] = [cgPoint.x, cgPoint.y]
            }
            switch event.type {
            case .leftMouseDown: downCount += 1; leftButtonHeld = true; lastDown = record
            case .leftMouseUp: upCount += 1; leftButtonHeld = false; lastUp = record
            case .rightMouseDown: rightDownCount += 1; rightButtonHeld = true; lastRightDown = record
            case .rightMouseUp: rightUpCount += 1; rightButtonHeld = false; lastRightUp = record
            case .leftMouseDragged, .rightMouseDragged: draggedCount += 1; lastDragged = record
            default: return
            }
            recentEvents.append(record)
            if recentEvents.count > 64 { recentEvents.removeFirst(recentEvents.count - 64) }
            writeState()
        }
        writeState()
        let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard CGDisplayIsActive(displayID) != 0 else { app.terminate(nil); return }
                guard let currentScreen = NSScreen.screens.first(where: {
                    ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
                }) else { app.terminate(nil); return }
                if currentScreen.frame != window.frame {
                    window.setFrame(currentScreen.frame, display: true)
                }
                writeState()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        withExtendedLifetime((window, view, timer)) { app.run() }
    }
}
