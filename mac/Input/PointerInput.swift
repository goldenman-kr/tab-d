import CoreGraphics
import CoreFoundation
import Foundation

private func inputNumber(_ value: Any?) -> Double? {
    guard let number=value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
          number.doubleValue.isFinite else { return nil }
    return number.doubleValue
}
private func inputUInt(_ value: Any?) -> UInt32? {
    guard let number=inputNumber(value), number >= 0, number <= Double(UInt32.max),
          number.rounded(.towardZero) == number else { return nil }
    return UInt32(number)
}

enum PointerButton: String { case left, right }
struct PointerClick {
    let epoch: UInt32
    let id: String
    let x: Double
    let y: Double
    let button: PointerButton
    let clickCount: Int

    init?(_ value: [String:Any]) {
        guard let epoch=inputUInt(value["epoch"]),
              let id=value["id"] as? String, id.count == 36, UUID(uuidString:id) != nil,
              let x=inputNumber(value["x"]), let y=inputNumber(value["y"]),
              (0...1).contains(x), (0...1).contains(y),
              let button=PointerButton(rawValue:(value["button"] as? String) ?? "left"),
              value["button"] == nil || value["button"] is String,
              let count=inputUInt(value["clickCount"] ?? 1), (1...2).contains(count),
              button == .left || count == 1 else { return nil }
        self.epoch=epoch; self.id=id.lowercased(); self.x=x; self.y=y; self.button=button; self.clickCount=Int(count)
    }

    func point(in bounds: CGRect) -> CGPoint? {
        guard bounds.origin.x.isFinite, bounds.origin.y.isFinite,
              bounds.width.isFinite, bounds.height.isFinite, bounds.width >= 1, bounds.height >= 1 else { return nil }
        return CGPoint(x:bounds.minX + x * (bounds.width-1), y:bounds.minY + y * (bounds.height-1))
    }
}

enum PointerPhase: String { case begin, move, end, cancel }
struct PointerRequest {
    let position: PointerClick
    let phase: PointerPhase
    let sequence: UInt32
    var id: String { position.id }
    var epoch: UInt32 { position.epoch }
    init?(_ value: [String:Any]) {
        guard let position=PointerClick(value), position.button == .left, position.clickCount == 1,
              let phaseText=value["phase"] as? String, let phase=PointerPhase(rawValue:phaseText),
              let sequence=inputUInt(value["sequence"]), phase != .begin || sequence == 0 else { return nil }
        self.position=position; self.phase=phase; self.sequence=sequence
    }
}

struct PointerClickGate {
    private var epoch: UInt32?
    private var recent: [String] = []
    private var recentIDs: Set<String> = []

    mutating func accept(_ click: PointerClick, session: SessionMachine, peerConnected: Bool) -> Bool {
        guard peerConnected, session.phase == .streaming, session.displayID != nil,
              click.epoch == session.epoch else { return false }
        if epoch != session.epoch {
            epoch=session.epoch; recent.removeAll(keepingCapacity:true); recentIDs.removeAll(keepingCapacity:true)
        }
        guard recentIDs.insert(click.id).inserted else { return false }
        recent.append(click.id)
        if recent.count > 128 { recentIDs.remove(recent.removeFirst()) }
        return true
    }
}

// Stateful even across callbacks: every successful down has one matching up.
// The injected sink lets tests exercise failure and interruption without OS input.
final class PointerInput {
    typealias Sink = (CGEventType, CGPoint, PointerButton, Int) -> Bool
    private let sink: Sink
    private struct Drag {
        let epoch: UInt32
        let id: String
        var sequence: UInt32
        var point: CGPoint
        var lastActivity: TimeInterval
    }
    private var drag: Drag?
    private var pendingRelease: (point: CGPoint, button: PointerButton, clickCount: Int)?
    private var replayEpoch: UInt32?
    private var recent: [String] = []
    private var recentIDs: Set<String> = []
    private(set) var lastReleaseReason = ""
    var held: Bool { drag != nil || pendingRelease != nil }
    var diagnostics: [String:Any] {
        ["held":held,"id":drag?.id ?? "","epoch":drag?.epoch ?? 0,
         "sequence":drag?.sequence ?? 0,"lastReleaseReason":lastReleaseReason]
    }

    init(sink: Sink? = nil) {
        if let sink { self.sink=sink }
        else {
            let source=CGEventSource(stateID:.privateState)
            self.sink = { type, point, button, clickCount in
                guard let source, let event=CGEvent(mouseEventSource:source,mouseType:type,
                    mouseCursorPosition:point,mouseButton:button == .left ? .left : .right) else { return false }
                event.flags=[]
                event.setIntegerValueField(.mouseEventClickState,value:Int64(clickCount))
                event.post(tap:.cghidEventTap)
                return true
            }
        }
    }

    func click(at point: CGPoint, button: PointerButton, clickCount: Int = 1) -> Bool {
        guard (1...2).contains(clickCount), button == .left || clickCount == 1, !held else { return false }
        guard sink(.mouseMoved,point,button,clickCount) else { return false }
        let down: CGEventType = button == .left ? .leftMouseDown : .rightMouseDown
        let up: CGEventType = button == .left ? .leftMouseUp : .rightMouseUp
        guard sink(down,point,button,clickCount) else { return false }
        // Retry a failed up once; never leave a successful down unpaired silently.
        pendingRelease=(point,button,clickCount)
        let released=sink(up,point,button,clickCount) || sink(up,point,button,clickCount)
        if released { pendingRelease=nil }
        return released
    }

    func handle(_ request: PointerRequest, point: CGPoint, now: TimeInterval) -> Bool {
        switch request.phase {
        case .begin:
            guard !held else { return false }
            if replayEpoch != request.epoch {
                replayEpoch=request.epoch; recent=[]; recentIDs=[]
            }
            guard !recentIDs.contains(request.id) else { return false }
            // Remember even a failed begin, so a replay cannot produce another down.
            recentIDs.insert(request.id); recent.append(request.id)
            if recent.count > 128 { recentIDs.remove(recent.removeFirst()) }
            guard sink(.mouseMoved,point,.left,1), sink(.leftMouseDown,point,.left,1) else { return false }
            drag=Drag(epoch:request.epoch,id:request.id,sequence:0,point:point,lastActivity:now)
            return true
        case .move, .end, .cancel:
            guard var current=drag, current.epoch == request.epoch, current.id == request.id,
                  request.sequence > current.sequence else { return false }
            current.sequence=request.sequence; current.lastActivity=now
            if request.phase == .cancel {
                return release(reason:"cancel")
            }
            if point != current.point {
                guard sink(.leftMouseDragged,point,.left,1) else { release(reason:"postFailed"); return false }
                current.point=point
            }
            drag=current
            if request.phase == .end { return release(reason:"end") }
            return true
        }
    }

    @discardableResult func release(reason: String) -> Bool {
        if let current=drag { pendingRelease=(current.point,.left,1); drag=nil }
        guard let pending=pendingRelease else { return true }
        lastReleaseReason=reason
        let up: CGEventType = pending.button == .left ? .leftMouseUp : .rightMouseUp
        let released=sink(up,pending.point,pending.button,pending.clickCount) || sink(up,pending.point,pending.button,pending.clickCount)
        if released { pendingRelease=nil }
        return released
    }
    @discardableResult func expire(now: TimeInterval) -> Bool {
        if pendingRelease != nil { return release(reason:lastReleaseReason) }
        guard let current=drag, now-current.lastActivity >= 2 else { return false }
        release(reason:"idleTimeout"); return true
    }
}
