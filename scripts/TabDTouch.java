import android.view.InputDevice;
import android.view.InputEvent;
import android.view.MotionEvent;
import android.os.SystemClock;
import java.lang.reflect.Method;

/** Shell-only real multitouch injection fixture. Never shipped in Tab-D. */
public final class TabDTouch {
    private static Object manager;
    private static Method inject;
    private static long downTime;
    private static boolean active;
    private static float x, y;
    private static void event(int action, int count, float dx, float dy) throws Exception {
        MotionEvent.PointerProperties[] props = new MotionEvent.PointerProperties[count];
        MotionEvent.PointerCoords[] coords = new MotionEvent.PointerCoords[count];
        for (int i=0; i<count; i++) {
            props[i] = new MotionEvent.PointerProperties();
            props[i].id=i; props[i].toolType=MotionEvent.TOOL_TYPE_FINGER;
            coords[i] = new MotionEvent.PointerCoords();
            coords[i].x=x + (i==0 ? -70 : i==1 ? 70 : 180) + dx;
            coords[i].y=y+dy; coords[i].pressure=1; coords[i].size=1;
        }
        MotionEvent e = MotionEvent.obtain(downTime, SystemClock.uptimeMillis(), action, count,
                props, coords, 0, 0, 1, 1, 0, 0, InputDevice.SOURCE_TOUCHSCREEN, 0);
        try {
            if (!Boolean.TRUE.equals(inject.invoke(manager, e, 2))) throw new IllegalStateException("Input rejected");
            active=(action & MotionEvent.ACTION_MASK)!=MotionEvent.ACTION_UP && (action & MotionEvent.ACTION_MASK)!=MotionEvent.ACTION_CANCEL;
        } finally { e.recycle(); }
    }
    public static void main(String[] args) throws Exception {
        if(args.length!=6) throw new IllegalArgumentException("mode centerX centerY deltaX deltaY durationMs");
        String mode=args[0]; x=Float.parseFloat(args[1]); y=Float.parseFloat(args[2]);
        float dx=Float.parseFloat(args[3]), dy=Float.parseFloat(args[4]);
        int duration=Integer.parseInt(args[5]);
        if(duration<20 || duration>5000) throw new IllegalArgumentException("duration");
        Class<?> cls;
        try { cls=Class.forName("android.hardware.input.InputManagerGlobal"); }
        catch(ClassNotFoundException e) { cls=Class.forName("android.hardware.input.InputManager"); }
        manager=cls.getMethod("getInstance").invoke(null);
        inject=cls.getMethod("injectInputEvent",InputEvent.class,int.class);
        downTime=SystemClock.uptimeMillis();
        try {
            event(MotionEvent.ACTION_DOWN,1,0,0); SystemClock.sleep(30);
            if(mode.equals("drag")) { event(MotionEvent.ACTION_MOVE,1,0,100); y+=100; SystemClock.sleep(80); }
            event(MotionEvent.ACTION_POINTER_DOWN | (1<<MotionEvent.ACTION_POINTER_INDEX_SHIFT),2,0,0);
            if(mode.equals("third")) {
                SystemClock.sleep(20); event(MotionEvent.ACTION_POINTER_DOWN | (2<<MotionEvent.ACTION_POINTER_INDEX_SHIFT),3,0,0);
                SystemClock.sleep(20); event(MotionEvent.ACTION_MOVE,3,dx,dy);
                event(MotionEvent.ACTION_POINTER_UP | (2<<MotionEvent.ACTION_POINTER_INDEX_SHIFT),3,dx,dy);
            } else {
                int steps=Math.max(1,duration/16);
                for(int i=1;i<=steps;i++) {
                    SystemClock.sleep(duration/steps);
                    event(MotionEvent.ACTION_MOVE,2,dx*i/steps,dy*i/steps);
                }
            }
            if(mode.equals("cancel")) { event(MotionEvent.ACTION_CANCEL,2,dx,dy); }
            else {
                event(MotionEvent.ACTION_POINTER_UP | (1<<MotionEvent.ACTION_POINTER_INDEX_SHIFT),2,dx,dy);
                if(mode.equals("remaining")) { SystemClock.sleep(30); event(MotionEvent.ACTION_MOVE,1,dx,dy+150); }
                event(MotionEvent.ACTION_UP,1,dx,dy+(mode.equals("remaining")?150:0));
            }
            System.out.println("PASS OS multitouch injection " + mode);
        } finally {
            if(active) event(MotionEvent.ACTION_CANCEL,1,0,0);
        }
    }
}
