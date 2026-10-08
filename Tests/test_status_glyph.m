#import <Foundation/Foundation.h>
#import "pure.h"

#define expect(cond, msg) do { \
    if (!(cond)) { fprintf(stderr, "FAIL: %s\n", [(msg) UTF8String]); exit(1); } \
} while (0)

int main(void) {
    @autoreleasepool {
        expect([EBBarGlyphNameForState(EBBarStateError, YES,
                                       YES, 3000, YES, -800, YES, 0, 12)
                isEqualToString:@"exclamationmark.triangle.fill"],
               @"error has distinct glyph");
        expect([EBBarGlyphNameForState(EBBarStateWarn, NO,
                                       YES, 3000, YES, -800, YES, 0, 12)
                isEqualToString:@"questionmark.circle.fill"],
               @"unknown has distinct glyph");
        expect([EBBarGlyphNameForState(EBBarStateWarn, YES,
                                       YES, 3000, YES, -800, NO, 0, 12)
                isEqualToString:@"questionmark.circle.fill"],
               @"unavailable charger has distinct glyph");
        expect(EBComputeChargerState(nil, @"NoVehicle", @"", NO, NO)
               == EBChargerStateUnplugged, @"live NoVehicle works without detail");
        expect(EBComputeChargerState(nil, @"Transfer", @"SolarControl", NO, NO)
               == EBChargerStateSolar, @"live solar control works without detail");
        expect(EBComputeChargerState(nil, @"Transfer", @"FullPower", NO, NO)
               == EBChargerStateCharging, @"live full-power control works without detail");
        expect(EBComputeChargerState(nil, @"Transfer", @"WaitingSolar", NO, NO)
               == EBChargerStateWaiting, @"live waiting control works without detail");
        expect(EBComputeChargerState(@"FINISHING", @"Transfer", @"", NO, YES)
               == EBChargerStateWaiting, @"finishing remains plugged");
        puts("ok: status glyph and charger state");
    }
    return 0;
}
