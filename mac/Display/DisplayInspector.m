#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

// Read-only, short-lived observer. The creator's CG mode/topology cache can be
// stale forever; each observation must come from a newly launched process.
int main(int argc, const char **argv) {
    @autoreleasepool {
        CGDirectDisplayID ids[32]; uint32_t count = 0;
        if (CGGetOnlineDisplayList(32, ids, &count) != kCGErrorSuccess) return 1;
        CGDirectDisplayID target = argc > 1 ? (CGDirectDisplayID)strtoul(argv[1], NULL, 10) : 0;
        NSMutableArray *displays = [NSMutableArray array];
        NSMutableDictionary *result = [NSMutableDictionary dictionary];
        for (uint32_t i = 0; i < count; i++) {
            CGDirectDisplayID display = ids[i];
            CGRect bounds = CGDisplayBounds(display);
            CGDisplayModeRef mode = CGDisplayCopyDisplayMode(display);
            NSMutableDictionary *item = [@{
                @"displayID":@(display), @"main":@(CGDisplayIsMain(display)),
                @"active":@(CGDisplayIsActive(display)), @"mirrored":@(CGDisplayIsInMirrorSet(display)),
                @"vendor":@(CGDisplayVendorNumber(display)), @"product":@(CGDisplayModelNumber(display)),
                @"bounds":@[@(bounds.origin.x), @(bounds.origin.y), @(bounds.size.width), @(bounds.size.height)]
            } mutableCopy];
            if (mode) {
                [item addEntriesFromDictionary:@{
                    @"logicalWidth":@(CGDisplayModeGetWidth(mode)), @"logicalHeight":@(CGDisplayModeGetHeight(mode)),
                    @"pixelWidth":@(CGDisplayModeGetPixelWidth(mode)), @"pixelHeight":@(CGDisplayModeGetPixelHeight(mode)),
                    @"refreshRate":@(CGDisplayModeGetRefreshRate(mode))}];
                CGDisplayModeRelease(mode);
            }
            [displays addObject:item];
            if (display == target) [result addEntriesFromDictionary:item];
        }
        result[@"displays"] = displays;
        NSData *json = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingSortedKeys error:nil];
        puts([[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
        return 0;
    }
}
