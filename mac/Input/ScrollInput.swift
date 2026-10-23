import CoreGraphics
import CoreFoundation
import Foundation

struct ScrollRequest {
    let position: PointerClick
    let deltaY: Double
    init?(_ value: [String:Any]) {
        guard let position=PointerClick(value), position.button == .left, position.clickCount == 1,
              let number=value["deltaY"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue != 0,
              (-1...1).contains(number.doubleValue) else { return nil }
        self.position=position; self.deltaY=number.doubleValue
    }
}

// Each packet is an independent wheel delta, with no held buttons or inertia.
// Preserve subpixel movement until it becomes a whole Mac pixel.
final class ScrollInput {
    typealias Sink = (CGPoint, Int32) -> Bool
    private let sink: Sink
    private var epoch: UInt32?
    private var height: Double?
    private var remainder: Double = 0
    private(set) var lastPixels: Int32 = 0

    init(sink: Sink? = nil) {
        if let sink { self.sink=sink }
        else {
            let source=CGEventSource(stateID:.privateState)
            self.sink = { point, pixels in
                guard let source,
                      let move=CGEvent(mouseEventSource:source,mouseType:.mouseMoved,mouseCursorPosition:point,mouseButton:.left),
                      let scroll=CGEvent(scrollWheelEvent2Source:source,units:.pixel,wheelCount:1,wheel1:pixels,wheel2:0,wheel3:0) else { return false }
                move.flags=[]; scroll.flags=[]; scroll.location=point
                scroll.setIntegerValueField(.scrollWheelEventIsContinuous,value:1)
                // These are direct wheel deltas, not a synthesized momentum stream.
                scroll.setIntegerValueField(.scrollWheelEventScrollPhase,value:0)
                scroll.setIntegerValueField(.scrollWheelEventMomentumPhase,value:0)
                move.post(tap:.cghidEventTap); scroll.post(tap:.cghidEventTap)
                return true
            }
        }
    }
    func reset() { epoch=nil; height=nil; remainder=0; lastPixels=0 }

    func post(_ request: ScrollRequest, point: CGPoint, displayHeight: Double) -> Bool {
        guard point.x.isFinite, point.y.isFinite, displayHeight.isFinite, displayHeight >= 1 else { return false }
        if epoch != request.position.epoch || height != displayHeight {
            reset(); epoch=request.position.epoch; height=displayHeight
        }
        let total=request.deltaY * displayHeight + remainder
        guard total.isFinite, abs(total) <= Double(Int32.max) else { return false }
        let pixels=Int32(total.rounded(.towardZero))
        lastPixels=pixels
        if pixels != 0, !sink(point,pixels) { remainder=0; return false }
        remainder=total-Double(pixels)
        return true
    }
}
