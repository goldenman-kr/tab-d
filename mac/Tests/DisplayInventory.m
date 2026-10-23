#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
int main(void) {
 @autoreleasepool {
  CGDirectDisplayID ids[16];uint32_t count=0;CGGetOnlineDisplayList(16,ids,&count);
  NSMutableArray *list=[NSMutableArray array];
  for(uint32_t i=0;i<count;i++) { CGDirectDisplayID d=ids[i];CGRect b=CGDisplayBounds(d);CGDisplayModeRef m=CGDisplayCopyDisplayMode(d);
   [list addObject:@{@"id":@(d),@"main":@(CGDisplayIsMain(d)),@"active":@(CGDisplayIsActive(d)),@"mirrorSet":@(CGDisplayIsInMirrorSet(d)),@"mirrors":@(CGDisplayMirrorsDisplay(d)),@"vendor":@(CGDisplayVendorNumber(d)),@"model":@(CGDisplayModelNumber(d)),@"bounds":@[@(b.origin.x),@(b.origin.y),@(b.size.width),@(b.size.height)],@"mode":m?@[@(CGDisplayModeGetWidth(m)),@(CGDisplayModeGetHeight(m)),@(CGDisplayModeGetPixelWidth(m)),@(CGDisplayModeGetPixelHeight(m))]:@[]}];
   if(m)CGDisplayModeRelease(m);
  }
  NSData *json=[NSJSONSerialization dataWithJSONObject:list options:NSJSONWritingPrettyPrinted error:nil];puts([[NSString alloc]initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
 }
}
