// Voice Memos waveform for the island (GGIsland in ControlCenter), the way macOS 27.3 feeds its Live Activity waveform
// (RE-27-BEHAVIOR s22.22). 27.3 VMAudioService creates an RCActivityWaveformProcessor for every new recorder
// (_prepareNewRecorderWithTitleBase:recordingID:error:, objc_opt_new 0x10005cc28); -[VMRecordingEngine inputNode:]'s tap
// then prepares it once and feeds it every buffer. 26.6 has the same tap and classes but never creates the processor (no
// caller of setActivityWaveformProcessor:), so the getter here creates it when the engine asks. Levels come from the
// app's own RCActivityWaveformDataProvider (amplitudeForSliceWithTimeRange:, normalised by the running average), one
// per 0.125 s slice, and go to ControlCenter as a Darwin notify state (VoiceMemosPack.h). A timer runs only while the
// processor receives audio.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>
#import "VoiceMemosPack.h"

BOOL ggSwizzle(Class c, SEL s, IMP imp, IMP *orig);
void ggLog(NSString *fmt, ...);

typedef struct { double start, end; } GGTimeRange;   // {?=dd}

static IMP oProcessor, oPrepare;
static __weak id gProc;          // processor of the recording in progress (owned by VMAudioRecorderImp)
static id gProvider;             // its data provider (holds the processor weakly)
static dispatch_source_t gTimer;
static int gToken = -1;
static long gLastSent = -1, gIdleTicks;
static double gLastEnd = -1;

static double dget(id o, const char *sel) { return ((double (*)(id, SEL))objc_msgSend)(o, sel_registerName(sel)); }

static void stopTimer(void) {
    if (gTimer) dispatch_source_cancel(gTimer);
    gTimer = nil;
}

static void tick(void) {
    id proc = gProc;
    if (!proc || !gProvider) { stopTimer(); return; }
    double end = dget(proc, "availableRangeEnd");
    if (end == gLastEnd) {   // no audio for 1 s: paused or stopped; the next prepare restarts the timer
        if (++gIdleTicks >= 8) stopTimer();
        return;
    }
    gIdleTicks = 0;
    gLastEnd = end;
    // Recording time of the newest sample: amplitudeForSlice maps t to t - punchInTime + recordingStartTime - 0.1 (27.3
    // constant 0x10027a4d0, 26.6 0x1001EA408), so invert that.
    double t = end - dget(proc, "recordingStartTime") + dget(proc, "punchInTime") + 0.1;
    long k = gg_vm_last_full_slice(t);
    if (k < 0 || k == gLastSent) return;
    SEL amp = sel_registerName("amplitudeForSliceWithTimeRange:fullTimeRangeSampled:");
    float levels[4];
    for (int i = 0; i < 4; i++) {
        long j = k - 3 + i;
        BOOL full = NO;
        GGTimeRange r = {j * GG_VM_SLICE_DURATION, (j + 1) * GG_VM_SLICE_DURATION};
        levels[i] = j < 0 ? 0 : (float)((double (*)(id, SEL, GGTimeRange, BOOL *))objc_msgSend)(gProvider, amp, r, &full);
    }
    notify_set_state(gToken, gg_vm_pack((uint32_t)k, levels));
    notify_post(GG_VM_NOTIFY);
    gLastSent = k;
}

static void startTimer(void) {
    if (gTimer) return;
    gIdleTicks = 0;
    gTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    uint64_t d = (uint64_t)(GG_VM_SLICE_DURATION * NSEC_PER_SEC);
    dispatch_source_set_timer(gTimer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)d), d, d / 10);
    dispatch_source_set_event_handler(gTimer, ^{ tick(); });
    dispatch_resume(gTimer);
}

/// -[VMAudioRecorderImp activityWaveformProcessor]: create the processor 27.3 would have created.
static id hProcessor(id self, SEL _cmd) {
    id p = ((id (*)(id, SEL))oProcessor)(self, _cmd);
    if (p) return p;
    Class pc = NSClassFromString(@"RCActivityWaveformProcessor"), dc = NSClassFromString(@"RCActivityWaveformDataProvider");
    if (!pc || !dc) return nil;
    p = [pc new];
    ((void (*)(id, SEL, id))objc_msgSend)(self, sel_registerName("setActivityWaveformProcessor:"), p);
    gProc = p;
    gProvider = ((id (*)(id, SEL, id))objc_msgSend)([dc alloc], sel_registerName("initWithWaveformProcessor:"), p);
    gLastSent = -1;
    gLastEnd = -1;
    return p;
}

/// -[RCActivityWaveformProcessor prepareToProcessWithFormat:audioTime:punchInTime:]: the tap starts feeding audio.
static void hPrepare(id self, SEL _cmd, id format, id time, double punchIn) {
    ((void (*)(id, SEL, id, id, double))oPrepare)(self, _cmd, format, time, punchIn);
    if (self != gProc) return;
    dispatch_async(dispatch_get_main_queue(), ^{ startTimer(); });
}

void gg_voicememos_install(void) {
    static BOOL done;
    if (done || ![[NSBundle mainBundle].bundleIdentifier isEqualToString:@"com.apple.VoiceMemos"]) return;
    done = YES;
    BOOL a = ggSwizzle(NSClassFromString(@"VMAudioRecorderImp"), sel_registerName("activityWaveformProcessor"), (IMP)hProcessor, &oProcessor);
    BOOL b = ggSwizzle(NSClassFromString(@"RCActivityWaveformProcessor"), sel_registerName("prepareToProcessWithFormat:audioTime:punchInTime:"),
                       (IMP)hPrepare, &oPrepare);
    uint32_t r = notify_register_check(GG_VM_NOTIFY, &gToken);
    ggLog(@"voice memos waveform: processor %d prepare %d notify %u", a, b, r);
}
