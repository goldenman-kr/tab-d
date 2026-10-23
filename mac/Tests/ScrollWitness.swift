import AppKit
import Foundation

// This fixture observes only input delivered to its own virtual-display window.
private final class ScrollWitnessWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class ScrollWitnessDocument: NSView {
    var onMouseEvent: ((NSEvent) -> Void)?
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onMouseEvent?(event) }
    override func mouseUp(with event: NSEvent) { onMouseEvent?(event) }
    override func rightMouseDown(with event: NSEvent) { onMouseEvent?(event) }
    override func rightMouseUp(with event: NSEvent) { onMouseEvent?(event) }
    override func mouseDragged(with event: NSEvent) { onMouseEvent?(event) }
    override func rightMouseDragged(with event: NSEvent) { onMouseEvent?(event) }

    override func draw(_ dirtyRect: NSRect) {
        let rowHeight: CGFloat = 160
        let colors = [
            NSColor(calibratedRed: 0.11, green: 0.28, blue: 0.40, alpha: 1),
            NSColor(calibratedRed: 0.17, green: 0.35, blue: 0.27, alpha: 1),
            NSColor(calibratedRed: 0.34, green: 0.23, blue: 0.38, alpha: 1),
            NSColor(calibratedRed: 0.40, green: 0.28, blue: 0.14, alpha: 1)
        ]
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 34, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let firstRow = max(0, Int(floor(dirtyRect.minY / rowHeight)))
        let lastRow = max(firstRow, Int(ceil(min(bounds.maxY, dirtyRect.maxY) / rowHeight)))
        for row in firstRow...lastRow {
            let rect = NSRect(x: 0, y: CGFloat(row) * rowHeight, width: bounds.width, height: rowHeight)
            colors[row % colors.count].setFill()
            rect.fill()
            ("Tab-D SCROLL · ROW \(row + 1) · Y \(Int(rect.minY))" as NSString)
                .draw(at: NSPoint(x: 65, y: rect.minY + 62), withAttributes: attributes)
        }
    }
}

private final class ScrollWitnessScrollView: NSScrollView {
    var onScrollEvent: ((NSEvent) -> Void)?
    var onScrollApplied: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func scrollWheel(with event: NSEvent) {
        // Record arrival first, then let AppKit scroll the actual document.
        // The timer also observes any later animation or momentum changes.
        onScrollEvent?(event)
        super.scrollWheel(with: event)
        onScrollApplied?()
    }
}

@main private enum ScrollWitness {
    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count == 3, let displayID = UInt32(arguments[1]), displayID != 0 else { exit(64) }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }) else { exit(1) }
        let window = ScrollWitnessWindow(contentRect: screen.frame, styleMask: .borderless,
                                         backing: .buffered, defer: false, screen: screen)
        window.isOpaque = true
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        root.autoresizingMask = [.width, .height]
        let scroll = ScrollWitnessScrollView(frame: root.bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = false
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .black
        let document = ScrollWitnessDocument(frame: .zero)
        scroll.documentView = document
        root.addSubview(scroll)
        let status = NSTextField(labelWithString: "Tab-D · 스크롤 입력 검사")
        status.font = .monospacedSystemFont(ofSize: 22, weight: .medium)
        status.textColor = .white
        status.backgroundColor = NSColor.black.withAlphaComponent(0.85)
        status.drawsBackground = true
        status.alignment = .center
        status.frame = NSRect(x: 20, y: root.bounds.height - 60, width: root.bounds.width - 40, height: 42)
        status.autoresizingMask = [.width, .minYMargin]
        root.addSubview(status)
        window.contentView = root
        window.setFrame(screen.frame, display: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        window.makeFirstResponder(document)

        var scrollCount = 0
        var scrollDeltaYTotal: CGFloat = 0
        var lastScroll: [String: Any] = [:]
        var recentScrollEvents: [[String: Any]] = []
        var lastMouseEvent: [String: Any] = [:]
        var recentMouseEvents: [[String: Any]] = []
        var leftDownCount = 0
        var leftUpCount = 0
        var rightDownCount = 0
        var rightUpCount = 0
        var draggedCount = 0
        var leftButtonHeld = false
        var rightButtonHeld = false
        let output = URL(fileURLWithPath: arguments[2])
        func rectArray(_ rect: CGRect) -> [CGFloat] { [rect.origin.x, rect.origin.y, rect.width, rect.height] }
        func layoutDocument(initial: Bool) {
            scroll.tile()
            let viewport = scroll.contentView.bounds.size
            document.setFrameSize(NSSize(width: viewport.width, height: viewport.height * 4))
            let offset = initial ? viewport.height : min(scroll.contentView.bounds.minY, max(0, document.frame.height - viewport.height))
            scroll.contentView.scroll(to: NSPoint(x: 0, y: offset))
            scroll.reflectScrolledClipView(scroll.contentView)
            document.needsDisplay = true
        }
        func writeState() {
            let visible = scroll.documentVisibleRect
            status.stringValue = "SCROLL \(scrollCount) · OFFSET \(Int(visible.minY)) · LEFT \(leftDownCount)/\(leftUpCount) · RIGHT \(rightDownCount)/\(rightUpCount) · DRAG \(draggedCount)"
            let state: [String: Any] = [
                "ready": true, "displayID": displayID,
                "windowBounds": rectArray(window.frame), "windowFrameCoordinateSystem": "AppKit bottom-left",
                "currentCGDisplayBounds": rectArray(CGDisplayBounds(displayID)),
                "scrollCount": scrollCount, "scrollDeltaYTotal": scrollDeltaYTotal,
                "lastScroll": lastScroll, "recentScrollEvents": recentScrollEvents,
                "lastMouseEvent": lastMouseEvent, "recentMouseEvents": recentMouseEvents,
                "documentVisibleRect": rectArray(visible), "contentOffsetY": visible.minY,
                "documentHeight": document.frame.height, "viewportHeight": scroll.contentView.bounds.height,
                "leftDownCount": leftDownCount, "leftUpCount": leftUpCount,
                "rightDownCount": rightDownCount, "rightUpCount": rightUpCount,
                "draggedCount": draggedCount, "leftButtonHeld": leftButtonHeld, "rightButtonHeld": rightButtonHeld,
                "localNormalizedCoordinateSystem": "window top-left (x right, y down)",
                "updatedAt": ISO8601DateFormatter().string(from: Date())
            ]
            do {
                let data = try JSONSerialization.data(withJSONObject: state, options: .sortedKeys)
                try data.write(to: output, options: .atomic)
            } catch {
                fputs("ScrollWitness: cannot write its own diagnostics JSON\n", stderr)
                app.terminate(nil)
            }
        }
        document.onMouseEvent = { event in
            switch event.type {
            case .leftMouseDown: leftDownCount += 1; leftButtonHeld = true
            case .leftMouseUp: leftUpCount += 1; leftButtonHeld = false
            case .rightMouseDown: rightDownCount += 1; rightButtonHeld = true
            case .rightMouseUp: rightUpCount += 1; rightButtonHeld = false
            case .leftMouseDragged, .rightMouseDragged: draggedCount += 1
            default: return
            }
            let point = root.convert(event.locationInWindow, from: nil)
            var value: [String: Any] = [
                "type": String(describing: event.type), "timestamp": event.timestamp,
                "clickCount": event.clickCount,
                "localNormalized": [(point.x - root.bounds.minX) / max(1, root.bounds.width),
                                    1 - (point.y - root.bounds.minY) / max(1, root.bounds.height)]
            ]
            if let cgEvent = event.cgEvent {
                value["globalCGLocation"] = [cgEvent.location.x, cgEvent.location.y]
                value["sourcePID"] = cgEvent.getIntegerValueField(.eventSourceUnixProcessID)
            }
            lastMouseEvent = value
            recentMouseEvents.append(value)
            if recentMouseEvents.count > 64 { recentMouseEvents.removeFirst(recentMouseEvents.count - 64) }
            writeState()
        }
        scroll.onScrollEvent = { event in
            scrollCount += 1
            scrollDeltaYTotal += event.scrollingDeltaY
            let point = root.convert(event.locationInWindow, from: nil)
            var value: [String: Any] = [
                "sequence": scrollCount, "timestamp": event.timestamp,
                "scrollingDeltaY": event.scrollingDeltaY,
                "hasPreciseScrollingDeltas": event.hasPreciseScrollingDeltas,
                "phase": event.phase.rawValue, "momentumPhase": event.momentumPhase.rawValue,
                "localNormalized": [(point.x - root.bounds.minX) / max(1, root.bounds.width),
                                    1 - (point.y - root.bounds.minY) / max(1, root.bounds.height)],
                "flags": event.modifierFlags.rawValue,
                "leftButtonHeldAtScroll": leftButtonHeld, "rightButtonHeldAtScroll": rightButtonHeld
            ]
            if let cgEvent = event.cgEvent {
                value["globalCGLocation"] = [cgEvent.location.x, cgEvent.location.y]
                value["sourcePID"] = cgEvent.getIntegerValueField(.eventSourceUnixProcessID)
            }
            lastScroll = value
            recentScrollEvents.append(value)
            if recentScrollEvents.count > 128 { recentScrollEvents.removeFirst(recentScrollEvents.count - 128) }
            writeState()
        }
        scroll.onScrollApplied = { writeState() }
        layoutDocument(initial: true)
        writeState()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard CGDisplayIsActive(displayID) != 0,
                      let currentScreen = NSScreen.screens.first(where: {
                          ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
                      }) else { app.terminate(nil); return }
                if currentScreen.frame != window.frame {
                    window.setFrame(currentScreen.frame, display: true)
                    layoutDocument(initial: false)
                }
                writeState()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        withExtendedLifetime((window, root, scroll, document, status, timer)) { app.run() }
    }
}
