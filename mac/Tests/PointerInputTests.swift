import CoreGraphics
import Foundation

@main struct PointerInputTests {
    static func main() {
        let id=UUID().uuidString.lowercased()
        func value(_ changes:[String:Any] = [:]) -> [String:Any] {
            ["epoch":1,"id":id,"x":0.25,"y":0.75].merging(changes) { _,new in new }
        }
        let click=PointerClick(value())!
        assert(click.point(in:CGRect(x:-1920,y:-1200,width:1920,height:1200)) == CGPoint(x:-1440.25,y:-300.75))
        assert(PointerClick(value(["x":0,"y":0]))!.point(in:CGRect(x:3840,y:0,width:3504,height:2190)) == CGPoint(x:3840,y:0))
        assert(PointerClick(value(["x":1,"y":1]))!.point(in:CGRect(x:3840,y:0,width:3504,height:2190)) == CGPoint(x:7343,y:2189))
        assert(click.point(in:.zero) == nil)
        assert(click.point(in:CGRect(x:0,y:0,width:Double.infinity,height:1200)) == nil)
        for bad:[String:Any] in [["epoch":-1],["epoch":4294967296.0],["epoch":1.5],["epoch":true],
            ["x":-0.001],["y":1.001],["x":Double.nan],["y":Double.infinity],["x":true],["x":"0.5"],
            ["id":"invalid"],["id":42]] { assert(PointerClick(value(bad)) == nil,"Accepted invalid click: \(bad)") }
        var session=SessionMachine(), gate=PointerClickGate()
        assert(!gate.accept(click,session:session,peerConnected:true))
        let epoch=session.begin(); assert(epoch == 1); assert(session.attach(17,epoch:epoch))
        assert(!gate.accept(click,session:session,peerConnected:true))
        assert(session.presented(epoch:epoch))
        assert(!gate.accept(click,session:session,peerConnected:false))
        assert(gate.accept(click,session:session,peerConnected:true))
        assert(!gate.accept(click,session:session,peerConnected:true))
        _=session.pause()
        assert(!gate.accept(click,session:session,peerConnected:true))
        let resumed=session.begin(); assert(session.presented(epoch:resumed))
        assert(!gate.accept(click,session:session,peerConnected:true))
        assert(gate.accept(PointerClick(value(["epoch":resumed]))!,session:session,peerConnected:true))
        _=session.losePeer()
        assert(!gate.accept(PointerClick(value(["epoch":session.epoch]))!,session:session,peerConnected:true))
        session.end()
        assert(!gate.accept(PointerClick(value(["epoch":session.epoch]))!,session:session,peerConnected:true))
        assert(PointerClick(value(["button":"right"]))!.button == .right)
        for button:Any in ["middle",true,42] { assert(PointerClick(value(["button":button])) == nil) }
        assert(PointerClick(value())!.clickCount == 1)
        assert(PointerClick(value(["clickCount":2]))!.clickCount == 2)
        for count:Any in [0,3,-1,1.5,true,"2",NSNull()] { assert(PointerClick(value(["clickCount":count])) == nil) }
        assert(PointerClick(value(["clickCount":2,"button":"right"])) == nil)
        func request(_ phase:String, _ sequence:Any, _ changes:[String:Any] = [:]) -> PointerRequest? {
            PointerRequest(value(["phase":phase,"sequence":sequence].merging(changes) { _,new in new }))
        }
        for sequence:Any in [-1,0.5,true,4294967296.0] { assert(request("move",sequence) == nil) }
        assert(request("begin",1) == nil && request("invalid",0) == nil)
        assert(request("begin",0,["button":"right"]) == nil)
        var posted:[(CGEventType,CGPoint,PointerButton)]=[]
        var failDrag=false
        let input=PointerInput { type, point, button, _ in
            if type == .leftMouseDragged && failDrag { return false }
            posted.append((type,point,button)); return true
        }
        let start=CGPoint(x:-1400,y:120), end=CGPoint(x:-900,y:650)
        assert(input.click(at:start,button:.right))
        assert(posted.map{$0.0} == [.mouseMoved,.rightMouseDown,.rightMouseUp])
        assert(posted.allSatisfy{$0.2 == .right}); posted=[]
        assert(input.handle(request("begin",0)!,point:start,now:0))
        assert(input.held && !input.click(at:end,button:.left))
        assert(!input.handle(request("begin",0)!,point:start,now:0.1))
        assert(!input.handle(request("move",0)!,point:end,now:0.2))
        assert(!input.handle(request("end",1,["id":UUID().uuidString])!,point:end,now:0.3))
        assert(!input.handle(request("end",1,["epoch":2])!,point:end,now:0.3))
        assert(input.held)
        assert(input.handle(request("move",2)!,point:end,now:0.5))
        assert(!input.handle(request("move",1)!,point:start,now:0.6))
        // Keepalive does not emit duplicate dragged events, but extends the lease.
        assert(input.handle(request("move",3)!,point:end,now:2))
        assert(!input.expire(now:3.9))
        assert(input.handle(request("end",4)!,point:end,now:4))
        assert(!input.held && posted.map{$0.0} == [.mouseMoved,.leftMouseDown,.leftMouseDragged,.leftMouseUp])
        assert(posted.first!.1 == start && posted.last!.1 == end)
        assert(!input.handle(request("begin",0)!,point:start,now:5)) // replay after terminal
        assert(!input.handle(request("end",5)!,point:end,now:5))
        posted=[]
        func next(_ phase:String,_ sequence:UInt32,_ epoch:UInt32) -> PointerRequest {
            request(phase,sequence,["epoch":epoch])!
        }
        assert(input.handle(next("begin",0,2),point:start,now:10))
        assert(input.expire(now:12)); assert(!input.held && input.lastReleaseReason == "idleTimeout")
        assert(!input.expire(now:13)); assert(posted.filter{$0.0 == .leftMouseUp}.count == 1)
        posted=[]
        assert(input.handle(next("begin",0,3),point:start,now:14))
        assert(input.handle(next("cancel",1,3),point:end,now:14.1))
        assert(!input.held && posted.last!.1 == start) // cancel releases at last delivered point
        posted=[]
        assert(input.handle(next("begin",0,4),point:start,now:15))
        failDrag=true
        assert(!input.handle(next("move",1,4),point:end,now:15.1))
        assert(!input.held && posted.last!.0 == .leftMouseUp && posted.last!.1 == start)
        failDrag=false; posted=[]
        assert(input.handle(next("begin",0,5),point:start,now:16))
        assert(input.release(reason:"pause")); assert(input.release(reason:"shutdown"))
        assert(posted.filter{$0.0 == .leftMouseUp}.count == 1)
        var upFailures=0
        let retry=PointerInput { type, _, _, _ in
            if type == .leftMouseUp || type == .rightMouseUp { upFailures += 1; return upFailures >= 3 }
            return true
        }
        assert(retry.handle(next("begin",0,6),point:start,now:17))
        assert(!retry.handle(next("cancel",1,6),point:end,now:17.1))
        assert(retry.held && !retry.click(at:end,button:.right))
        assert(retry.expire(now:17.2) && !retry.held && upFailures == 3)
        upFailures=0
        assert(!retry.click(at:start,button:.right) && retry.held)
        assert(retry.release(reason:"retry") && !retry.held)
        var clickEvents:[(CGEventType,Int)]=[]
        var remainingUpFailures=0
        let doubleInput=PointerInput { type, _, _, count in
            if type == .leftMouseUp && remainingUpFailures > 0 { remainingUpFailures -= 1; return false }
            clickEvents.append((type,count)); return true
        }
        assert(doubleInput.click(at:start,button:.left,clickCount:1))
        assert(doubleInput.click(at:start,button:.left,clickCount:2))
        assert(clickEvents.filter{$0.0 == .leftMouseDown}.map{$0.1} == [1,2])
        assert(clickEvents.filter{$0.0 == .leftMouseUp}.map{$0.1} == [1,2])
        assert(clickEvents.count == 6) // Second tap posts one pair, never an extra two-pair double click.
        assert(!doubleInput.click(at:start,button:.right,clickCount:2))
        assert(!doubleInput.click(at:start,button:.left,clickCount:3))
        remainingUpFailures=2
        assert(!doubleInput.click(at:start,button:.left,clickCount:2) && doubleInput.held)
        assert(doubleInput.expire(now:100) && !doubleInput.held)
        assert(clickEvents.last!.0 == .leftMouseUp && clickEvents.last!.1 == 2)
        assert(request("begin",0,["clickCount":2]) == nil)
        func scroll(_ changes:[String:Any] = [:]) -> ScrollRequest? {
            ScrollRequest(value(["deltaY":0.1].merging(changes) { _,new in new }))
        }
        for bad:Any in [0,1.01,-1.01,Double.nan,Double.infinity,true,"0.1",NSNull()] {
            assert(scroll(["deltaY":bad]) == nil)
        }
        assert(scroll(["button":"right"]) == nil && scroll(["clickCount":2]) == nil)
        assert(scroll(["epoch":true]) == nil && scroll(["x":1.1]) == nil)
        assert(scroll(["deltaY":-1]) != nil && scroll(["deltaY":1]) != nil)
        var wheel:[Int32]=[]
        var failWheel=false
        let scrolling=ScrollInput { _, pixels in
            if failWheel { return false }
            wheel.append(pixels); return true
        }
        let tiny=scroll(["deltaY":0.0004])!
        assert(scrolling.post(tiny,point:start,displayHeight:1200))
        assert(scrolling.post(tiny,point:start,displayHeight:1200))
        assert(wheel.isEmpty)
        assert(scrolling.post(tiny,point:start,displayHeight:1200) && wheel == [1])
        scrolling.reset(); wheel=[]
        assert(scrolling.post(scroll(["deltaY":-0.25])!,point:start,displayHeight:1200))
        assert(scrolling.post(scroll(["deltaY":0.25])!,point:start,displayHeight:2190))
        assert(wheel == [-300,547])
        wheel=[]
        assert(scrolling.post(scroll(["deltaY":0.0001,"epoch":2])!,point:start,displayHeight:2190))
        assert(wheel.isEmpty) // No residue from a previous epoch or mode.
        assert(!scrolling.post(tiny,point:start,displayHeight:Double.infinity))
        assert(!scrolling.post(tiny,point:CGPoint(x:Double.nan,y:0),displayHeight:1200))
        failWheel=true
        assert(!scrolling.post(scroll()!,point:start,displayHeight:1200))
        failWheel=false;wheel=[]
        assert(scrolling.post(tiny,point:start,displayHeight:1200) && wheel.isEmpty)
        var scrollReplay=PointerClickGate()
        var scrollSession=SessionMachine()
        let scrollEpoch=scrollSession.begin();assert(scrollSession.attach(18,epoch:scrollEpoch))
        assert(!scrollReplay.accept(scroll()!.position,session:scrollSession,peerConnected:true))
        assert(scrollSession.presented(epoch:scrollEpoch))
        assert(scrollReplay.accept(scroll()!.position,session:scrollSession,peerConnected:true))
        assert(!scrollReplay.accept(scroll()!.position,session:scrollSession,peerConnected:true))
        _=scrollSession.pause()
        assert(!scrollReplay.accept(scroll()!.position,session:scrollSession,peerConnected:true))
        print("PASS: pointer request validation, display coordinates, session/epoch and duplicate guards; pixel scroll validation/residue/replay, single/double/right click, ordered drag, cancel, failure and idle release")
    }
}
