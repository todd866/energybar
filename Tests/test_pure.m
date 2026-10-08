#import <Foundation/Foundation.h>
#import "pure.h"

static int gFails = 0;

static void expect(BOOL cond, NSString *msg) {
    if (!cond) {
        fprintf(stderr, "FAIL: %s\n", msg.UTF8String);
        gFails++;
    } else {
        printf("ok: %s\n", msg.UTF8String);
    }
}

static void expectEqual(NSString *got, NSString *want, NSString *msg) {
    if (![got isEqualToString:want]) {
        fprintf(stderr, "FAIL: %s — got '%s' want '%s'\n",
                msg.UTF8String, got.UTF8String, want.UTF8String);
        gFails++;
    } else {
        printf("ok: %s\n", msg.UTF8String);
    }
}

int main(int argc, const char *argv[]) {
    (void)argc; (void)argv;
    @autoreleasepool {
        expectEqual(EBFmtKW(4116), @"4.1", @"fmt 4116 W");
        expectEqual(EBFmtKW(500), @"0.5", @"fmt 500 W");
        expectEqual(EBGridSegment(-2600), @"↑2.6", @"export");
        expectEqual(EBGridSegment(6405), @"↓6.4", @"import");
        expectEqual(EBGridSegment(10), @"·0.0", @"near zero");

        expectEqual(EBChargerWord(@"AVAILABLE", @"NoVehicle", @"SolarControl", NO),
                    @"—", @"unplugged");
        expectEqual(EBChargerWord(@"CHARGING", @"Transfer", @"WaitingSolar", NO),
                    @"wait", @"waiting solar");
        expectEqual(EBChargerWord(@"CHARGING", @"Transfer", @"SolarControl", NO),
                    @"solar", @"solar control");
        expectEqual(EBChargerWord(@"CHARGING", @"Transfer", @"FullPower", YES),
                    @"charge", @"charge now");

        NSString *g = EBGlanceString(YES, 4030, YES, -907, YES,
                                     @"CHARGING", @"Transfer", @"SolarControl", NO);
        expectEqual(g, @"☀ 4.0  ↑0.9  🔌 solar", @"full glance");

        expect(EBComputeMatchState(YES, 80, YES, 2200, NO, NO, NO, 0) == EBMatchMatchingSolar,
               @"80 W import while charging is not grid charging");
        expect(EBComputeMatchState(YES, -400, YES, 2200, NO, NO, NO, 0) == EBMatchMatchingSolar,
               @"match matching");
        expect(EBComputeMatchState(YES, 800, YES, 7000, NO, NO, NO, 0) == EBMatchChargingFromGrid,
               @"match from grid");
        expect(EBComputeMatchState(YES, -600, YES, 0, NO, NO, NO, 0) == EBMatchSurplusUnused,
               @"match surplus unused");
        expect(EBComputeMatchState(YES, -600, YES, 0, YES, NO, NO, 0) == EBMatchIdle,
               @"match not ready");
        expect(EBComputeMatchState(YES, -600, YES, 0, NO, NO, YES, 95) == EBMatchIdle,
               @"match pack full");
        expect(EBComputeMatchState(YES, 200, YES, 0, NO, NO, NO, 0) == EBMatchIdle,
               @"match night import idle");
        expect(EBComputeMatchState(NO, 0, YES, 2200, NO, NO, NO, 0) == EBMatchUnknown,
               @"missing grid is unknown, not solar");
        expectEqual(EBMatchLabel(EBMatchMatchingSolar), @"Matching solar", @"match label");
        expectEqual(EBMatchLabel(EBMatchIdle), @"Idle", @"idle label");
        expect(EBBarStateForMatch(EBMatchSurplusUnused) == EBBarStateWarn, @"match warn");

        expect(gFails == 0, @"all assertions");
    }
    return gFails ? 1 : 0;
}
