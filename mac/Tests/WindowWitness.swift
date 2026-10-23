import AppKit
import Foundation

// An owned test window records its own frame; it never inspects other app windows.
final class PatternView: NSView {
    var tick = 0
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedRed:0.08,green:0.15,blue:0.19,alpha:1).setFill(); bounds.fill()
        let attributes:[NSAttributedString.Key:Any] = [.font:NSFont.systemFont(ofSize:48,weight:.medium),.foregroundColor:NSColor.white]
        ("Tab-D · 실제 기기 영상 검사" as NSString).draw(at:NSPoint(x:80,y:bounds.height-140),withAttributes:attributes)
        ("프레임 \(tick)" as NSString).draw(at:NSPoint(x:80,y:90),withAttributes:attributes)
        let x=CGFloat(tick % 480) / 480 * max(1,bounds.width-160)
        NSColor(calibratedRed:0.68,green:0.81,blue:0.68,alpha:1).setFill()
        NSBezierPath(roundedRect:NSRect(x:x,y:bounds.height/2,width:160,height:160),xRadius:24,yRadius:24).fill()
    }
}
@main enum Witness {
    static func main() {
        let arguments=CommandLine.arguments
        guard arguments.count == 3, let displayID=UInt32(arguments[1]) else { exit(64) }
        let app=NSApplication.shared; app.setActivationPolicy(.accessory)
        guard let screen=NSScreen.screens.first(where:{ ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID }) else { exit(1) }
        let window=NSWindow(contentRect:screen.frame,styleMask:.borderless,backing:.buffered,defer:false,screen:screen)
        let view=PatternView(frame:NSRect(origin:.zero,size:screen.frame.size))
        window.contentView=view; window.setFrame(screen.frame,display:true); window.orderFrontRegardless()
        var initial=window.frame
        let path=URL(fileURLWithPath:arguments[2])
        let timer=Timer.scheduledTimer(withTimeInterval:1.0/60,repeats:true) { _ in
            guard CGDisplayIsActive(displayID) != 0 else { app.terminate(nil); return }
            view.tick += 1; view.needsDisplay=true
            if view.tick == 120 { initial=window.frame }
            if view.tick % 30 == 0 {
                let frame=window.frame
                let data:[String:Any]=["displayID":displayID,"tick":view.tick,
                    "frame":[frame.origin.x,frame.origin.y,frame.width,frame.height],
                    "unchanged":frame == initial]
                if let json=try? JSONSerialization.data(withJSONObject:data,options:.sortedKeys) { try? json.write(to:path,options:.atomic) }
            }
        }
        RunLoop.main.add(timer,forMode:.common)
        app.run()
    }
}
