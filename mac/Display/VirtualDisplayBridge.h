#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// The only owner of the private CoreGraphics API. Use on the main thread.
@interface TBDVirtualDisplay : NSObject
@property(nonatomic, readonly) CGDirectDisplayID displayID;
- (BOOL)createWithPixelWidth:(unsigned int)width
                    height:(unsigned int)height
                     hiDPI:(BOOL)hiDPI
                     error:(NSError * _Nullable * _Nullable)error;
- (void)remove;
@end

NS_ASSUME_NONNULL_END
