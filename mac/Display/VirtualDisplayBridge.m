#import "VirtualDisplayBridge.h"

// Private selectors verified against the upstream Chromium virtual display test
// implementation. Keep declarations here; never expose them to app/session code.
@interface CGVirtualDisplayDescriptor : NSObject
@property unsigned int vendorID, productID, serialNum, serialNumber;
@property(strong) NSString *name;
@property CGSize sizeInMillimeters;
@property unsigned int maxPixelsWide, maxPixelsHigh;
@property CGPoint redPrimary, greenPrimary, bluePrimary, whitePoint;
@property(strong) id queue;
@end
@interface CGVirtualDisplaySettings : NSObject
@property(strong) NSArray *modes;
@property unsigned int hiDPI;
@end
@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)rate;
@end
@interface CGVirtualDisplay : NSObject
@property(readonly) unsigned int displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

@implementation TBDVirtualDisplay {
    CGVirtualDisplay *_display;
}
- (CGDirectDisplayID)displayID { return _display ? _display.displayID : 0; }
- (BOOL)createWithPixelWidth:(unsigned int)width height:(unsigned int)height
                     hiDPI:(BOOL)hiDPI error:(NSError **)error {
    NSAssert([NSThread isMainThread], @"Display ownership must remain on the main thread");
    if (_display) return YES;
    NSString *failure = nil;
    if (!width || !height || (hiDPI && ((width % 2) || (height % 2)))) {
        failure = @"Invalid virtual display dimensions";
    } else if (!NSClassFromString(@"CGVirtualDisplay") ||
               !NSClassFromString(@"CGVirtualDisplayDescriptor") ||
               !NSClassFromString(@"CGVirtualDisplaySettings") ||
               !NSClassFromString(@"CGVirtualDisplayMode")) {
        failure = @"This macOS version does not expose the virtual display API";
    } else {
        @try {
            CGVirtualDisplayDescriptor *d = [NSClassFromString(@"CGVirtualDisplayDescriptor") new];
            d.name = @"Tab-D";
            // macOS remembers modes by display identity. Never reuse an identity for
            // a different resolution, and never mutate its active CG display mode.
            d.vendorID = 0x5444; d.productID = 3;
            d.serialNum = 0x10000000U ^ (width << 12) ^ height ^ (hiDPI ? 0x08000000U : 0);
            d.serialNumber = d.serialNum;
            d.maxPixelsWide = width; d.maxPixelsHigh = height;
            d.sizeInMillimeters = CGSizeMake(25.4 * width / 96.0, 25.4 * height / 96.0); // Advertise 96 dpi for an unscaled desktop.
            d.redPrimary = CGPointMake(.64, .33);
            d.greenPrimary = CGPointMake(.30, .60);
            d.bluePrimary = CGPointMake(.15, .06);
            d.whitePoint = CGPointMake(.3127, .3290);
            d.queue = dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0);
            CGVirtualDisplay *candidate = [(CGVirtualDisplay *)[NSClassFromString(@"CGVirtualDisplay") alloc] initWithDescriptor:d];
            CGVirtualDisplaySettings *s = [NSClassFromString(@"CGVirtualDisplaySettings") new];
            s.hiDPI = hiDPI ? 1 : 0;
            CGVirtualDisplayMode *mode = [(CGVirtualDisplayMode *)[NSClassFromString(@"CGVirtualDisplayMode") alloc]
                initWithWidth:hiDPI ? width / 2 : width height:hiDPI ? height / 2 : height refreshRate:60];
            s.modes = @[mode];
            if (candidate && [candidate applySettings:s] && candidate.displayID) {
                _display = candidate;
                return YES;
            }
            failure = @"macOS refused the virtual display or its mode";
        } @catch (NSException *exception) {
            failure = [@"Virtual display API exception: " stringByAppendingString:exception.name];
        }
    }
    if (error) *error = [NSError errorWithDomain:@"xyz.kryp.app.tabd.display" code:1
        userInfo:@{NSLocalizedDescriptionKey:failure ?: @"Virtual display creation failed"}];
    return NO;
}
- (void)remove {
    NSAssert([NSThread isMainThread], @"Display ownership must remain on the main thread");
    _display = nil;
}
@end
