// Headless test of the Voice Memos waveform packing (Sources/VoiceMemosPack.h): the format GGIsland unpacks in
// ControlCenter (island/Sources/MediaStatus.swift voiceMemosLevels). Prints "OK  ..." / "FAIL ..." and exits 1 on failure.
// Build: clang -arch x86_64 -fobjc-arc -framework Foundation -I ggapp/Sources vmwave.m
#import <Foundation/Foundation.h>
#import "VoiceMemosPack.h"

static int gFail;
static void expect(BOOL ok, const char *name, unsigned long long got) {
    printf("%s %s", ok ? "OK " : "FAIL", name);
    if (!ok) { printf(" (got: 0x%016llx)", got); gFail = 1; }
    printf("\n");
}

int main(void) {
    // seq in the high 32 bits, newest level in the lowest byte, then the three before it; level x 255 rounded, clamped.
    float l[4] = {1.0f, 0.5f, 0.0f, 0.2f};   // oldest .. newest
    uint64_t s = gg_vm_pack(7, l);
    expect(s == 0x00000007FF800033ULL, "vmPackLayout", s);
    float c[4] = {-1.0f, 2.0f, 0.0f, 0.0f};
    s = gg_vm_pack(1, c);
    expect(s == 0x0000000100FF0000ULL, "vmPackClamps", s);
    // Slice i covers [0.125 i, 0.125 (i + 1)] of recording time (RE 22.22); the last full slice at t ends <= t.
    expect(gg_vm_last_full_slice(0.10) == -1, "vmNoFullSliceYet", (unsigned long long)gg_vm_last_full_slice(0.10));
    expect(gg_vm_last_full_slice(0.125) == 0, "vmFirstSliceAtBoundary", (unsigned long long)gg_vm_last_full_slice(0.125));
    expect(gg_vm_last_full_slice(1.30) == 9, "vmSliceTenAt1_3", (unsigned long long)gg_vm_last_full_slice(1.30));
    return gFail;
}
