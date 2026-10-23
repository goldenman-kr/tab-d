#import <AppKit/AppKit.h>
#import "../Display/VirtualDisplayBridge.h"
#import <math.h>
#import <signal.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>

// This probe never selects a mode. Every observation is made by a newly
// launched process, independently of the creator's CoreGraphics mode cache.
static void pump(NSTimeInterval seconds) {
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
}
static void report(NSDictionary *value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:nil];
    puts([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String);
    fflush(stdout);
}
static NSDictionary *inventory(void) {
    uint32_t capacity = 0, count = 0;
    CGError code = CGGetOnlineDisplayList(0, NULL, &capacity);
    if (code != kCGErrorSuccess || capacity == 0 || capacity > 128) {
        return @{ @"error":@"cannot enumerate displays", @"code":@(code), @"count":@(capacity) };
    }
    CGDirectDisplayID *ids = calloc(capacity, sizeof(CGDirectDisplayID));
    if (!ids) return @{ @"error":@"cannot allocate display inventory" };
    code = CGGetOnlineDisplayList(capacity, ids, &count);
    if (code != kCGErrorSuccess) {
        free(ids);
        return @{ @"error":@"cannot read display inventory", @"code":@(code) };
    }
    NSMutableDictionary *displays = [NSMutableDictionary dictionary];
    for (uint32_t i = 0; i < count; i++) {
        CGDirectDisplayID ID = ids[i];
        CGRect bounds = CGDisplayBounds(ID);
        CGDisplayModeRef mode = CGDisplayCopyDisplayMode(ID);
        NSMutableDictionary *item = [@{
            @"displayID":@(ID), @"active":@(CGDisplayIsActive(ID)),
            @"builtIn":@(CGDisplayIsBuiltin(ID)), @"vendor":@(CGDisplayVendorNumber(ID)),
            @"model":@(CGDisplayModelNumber(ID)), @"mirrored":@(CGDisplayIsInMirrorSet(ID)),
            @"mirrorsDisplayID":@(CGDisplayMirrorsDisplay(ID)),
            @"bounds":@[@(bounds.origin.x), @(bounds.origin.y), @(bounds.size.width), @(bounds.size.height)],
            @"modeReadable":@(mode != NULL)
        } mutableCopy];
        if (mode) {
            [item addEntriesFromDictionary:@{
                @"logicalWidth":@(CGDisplayModeGetWidth(mode)), @"logicalHeight":@(CGDisplayModeGetHeight(mode)),
                @"pixelWidth":@(CGDisplayModeGetPixelWidth(mode)), @"pixelHeight":@(CGDisplayModeGetPixelHeight(mode)),
                @"refreshRate":@(CGDisplayModeGetRefreshRate(mode))
            }];
            CGDisplayModeRelease(mode);
        }
        displays[[NSString stringWithFormat:@"%u", ID]] = item;
    }
    free(ids);
    return @{ @"mainDisplayID":@(CGMainDisplayID()), @"displays":displays };
}
static NSDictionary *observe(NSURL *executable, NSTimeInterval timeout) {
    NSTask *task = [NSTask new];
    NSPipe *pipe = [NSPipe pipe];
    task.executableURL = executable;
    task.arguments = @[@"--observe"];
    task.standardOutput = pipe;
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        return @{ @"error":@"observer launch failed", @"detail":error.localizedDescription ?: @"unknown" };
    }
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + timeout;
    while (task.isRunning && NSProcessInfo.processInfo.systemUptime < deadline) pump(.01);
    if (task.isRunning) {
        kill(task.processIdentifier, SIGKILL);
        [task waitUntilExit];
        return @{ @"error":@"fresh observer timed out" };
    }
    [task waitUntilExit];
    NSData *bytes = [pipe.fileHandleForReading readDataToEndOfFile];
    NSDictionary *result = [NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil];
    if (task.terminationStatus != 0 || ![result isKindOfClass:NSDictionary.class]) {
        return @{ @"error":@"fresh observer failed", @"exitCode":@(task.terminationStatus) };
    }
    return result;
}
static NSString *baselineDifference(NSDictionary *baseline, NSDictionary *current) {
    if (current[@"error"]) return current[@"error"];
    if (![baseline[@"mainDisplayID"] isEqual:current[@"mainDisplayID"]]) return @"main display changed";
    NSDictionary *before = baseline[@"displays"], *after = current[@"displays"];
    for (NSString *key in before) {
        NSDictionary *original = before[key], *observed = after[key];
        if (!observed) return [@"baseline display disappeared: " stringByAppendingString:key];
        // Includes every pre-existing display, so physical displays and any
        // other pre-existing virtual display are protected equally.
        for (NSString *field in @[@"active", @"bounds", @"mirrored", @"mirrorsDisplayID", @"modeReadable",
                                  @"logicalWidth", @"logicalHeight", @"pixelWidth", @"pixelHeight"]) {
            if (![original[field] isEqual:observed[field]]) {
                return [NSString stringWithFormat:@"baseline display %@ changed %@", key, field];
            }
        }
    }
    return nil;
}
static NSString *connectedDifference(NSDictionary *baseline, NSDictionary *current,
                                     CGDirectDisplayID target, int width, int height) {
    NSString *difference = baselineDifference(baseline, current);
    if (difference) return difference;
    NSDictionary *before = baseline[@"displays"], *after = current[@"displays"];
    NSString *key = [NSString stringWithFormat:@"%u", target];
    if (before[key]) return @"created display reused an online baseline display ID";
    if (after.count != before.count + 1) return @"unexpected display count after creation";
    NSDictionary *display = after[key];
    if (!display || ![display[@"active"] boolValue]) return @"created display is not online and active";
    if ([display[@"mirrored"] boolValue] || [display[@"mirrorsDisplayID"] unsignedIntValue] != kCGNullDirectDisplay) {
        return @"created display is mirrored";
    }
    if (![display[@"modeReadable"] boolValue] || [display[@"pixelWidth"] intValue] != width ||
        [display[@"pixelHeight"] intValue] != height || [display[@"logicalWidth"] intValue] != width ||
        [display[@"logicalHeight"] intValue] != height) return @"actual display mode does not match requested non-HiDPI dimensions";
    if (fabs([display[@"refreshRate"] doubleValue] - 60.0) > .1) return @"actual mode is not 60 Hz";
    if ([current[@"mainDisplayID"] unsignedIntValue] == target) return @"created display became main";
    return nil;
}
static BOOL parseNumber(const char *argument, long minimum, long maximum, long *value) {
    char *end = NULL;
    long parsed = strtol(argument, &end, 10);
    if (!argument[0] || !end || *end || parsed < minimum || parsed > maximum) return NO;
    *value = parsed;
    return YES;
}
int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc == 2 && strcmp(argv[1], "--observe") == 0) {
            NSDictionary *snapshot = inventory();
            report(snapshot);
            return snapshot[@"error"] ? 4 : 0;
        }
        BOOL native = NO, explicitCycles = NO, hold = NO;
        long cycles = 3, holdSeconds = 1;
        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "--native") == 0) native = YES;
            else if (strcmp(argv[i], "--cycles") == 0 && i + 1 < argc && parseNumber(argv[i + 1], 1, 20, &cycles)) {
                explicitCycles = YES; i++;
            } else if (strcmp(argv[i], "--hold") == 0) {
                hold = YES; holdSeconds = 30;
                if (i + 1 < argc && argv[i + 1][0] != '-') {
                    if (!parseNumber(argv[++i], 1, 60, &holdSeconds)) {
                        report(@{ @"result":@"FAIL", @"reason":@"--hold requires 1–60 seconds" }); return 64;
                    }
                }
            } else {
                report(@{ @"result":@"FAIL", @"reason":@"usage: display-probe [--native] [--cycles 1..20] [--hold [1..60]]" }); return 64;
            }
        }
        if (hold && !explicitCycles) cycles = 1;
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        NSURL *executable = [[NSURL fileURLWithPath:NSProcessInfo.processInfo.arguments[0]] URLByStandardizingPath];
        int width = native ? 3504 : 1920, height = native ? 2190 : 1200;
        NSDictionary *baseline = observe(executable, 2);
        if (baseline[@"error"]) { report(@{ @"result":@"FAIL", @"stage":@"baseline", @"observation":baseline }); return 1; }
        for (NSDictionary *entry in [baseline[@"displays"] allValues]) {
            if (![entry[@"modeReadable"] boolValue]) {
                report(@{ @"result":@"FAIL", @"stage":@"baseline", @"reason":@"baseline mode is unreadable", @"observation":baseline }); return 1;
            }
        }
        report(@{ @"event":@"baseline", @"observation":baseline, @"cycles":@(cycles), @"native":@(native), @"hiDPI":@NO });
        for (long cycle = 1; cycle <= cycles; cycle++) {
            @autoreleasepool {
                TBDVirtualDisplay *display = [TBDVirtualDisplay new];
                NSError *error = nil;
                if (![display createWithPixelWidth:(unsigned int)width height:(unsigned int)height hiDPI:NO error:&error]) {
                    report(@{ @"result":@"FAIL", @"stage":@"create", @"cycle":@(cycle), @"error":error.localizedDescription ?: @"unknown" }); return 2;
                }
                CGDirectDisplayID target = display.displayID;
                pump(2);
                NSDictionary *created = observe(executable, 2);
                NSString *failure = connectedDifference(baseline, created, target, width, height);
                NSString *failureStage = @"created";
                NSDictionary *retained = @{};
                if (!failure) {
                    report(@{ @"event":@"created", @"cycle":@(cycle), @"displayID":@(target), @"observation":created });
                    pump(holdSeconds);
                    retained = observe(executable, 2);
                    failure = connectedDifference(baseline, retained, target, width, height);
                    if (!failure && display.displayID != target) failure = @"owner display ID changed during retention";
                    failureStage = @"retained";
                }
                // Clean up even after a failed mode/topology observation.
                [display remove];
                NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 5;
                NSDictionary *removed = @{};
                NSString *removalFailure = @"removal timed out";
                do {
                    NSTimeInterval remaining = deadline - NSProcessInfo.processInfo.systemUptime;
                    if (remaining <= 0) break;
                    removed = observe(executable, MIN(1.0, remaining));
                    removalFailure = baselineDifference(baseline, removed);
                    if (!removalFailure && ![[NSSet setWithArray:[removed[@"displays"] allKeys]] isEqualToSet:[NSSet setWithArray:[baseline[@"displays"] allKeys]]]) {
                        removalFailure = @"online display inventory has not returned to baseline";
                    }
                    if (!removalFailure) break;
                    pump(MIN(.1, MAX(0, deadline - NSProcessInfo.processInfo.systemUptime)));
                } while (NSProcessInfo.processInfo.systemUptime < deadline);
                if (failure || removalFailure) {
                    report(@{ @"result":@"FAIL", @"cycle":@(cycle), @"displayID":@(target),
                        @"stage":failure ? failureStage : @"removed", @"reason":failure ?: removalFailure,
                        @"createdObservation":created, @"retainedObservation":retained, @"removedObservation":removed,
                        @"removalError":removalFailure ?: @"" });
                    return 3;
                }
                report(@{ @"result":@"PASS", @"cycle":@(cycle), @"displayID":@(target),
                    @"pixelWidth":@(width), @"pixelHeight":@(height), @"hiDPI":@NO,
                    @"pauseOwnershipStable":@YES, @"baselineRestored":@YES,
                    @"retainedObservation":retained, @"removedObservation":removed });
            }
        }
        report(@{ @"result":@"PASS", @"cycles":@(cycles), @"removed":@YES,
            @"verification":@"fresh independent observers; no mode selection; baseline topology restored" });
    }
    return 0;
}
