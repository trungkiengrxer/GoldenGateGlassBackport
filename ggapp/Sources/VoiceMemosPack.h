// Voice Memos waveform levels sent to GGIsland in ControlCenter as one Darwin notify state (64 bits), so no IPC buffer
// is needed: seq = index of the newest full slice (high 32 bits); the low 32 bits hold the four newest slice levels,
// newest in the lowest byte, each level (0...1, RCActivityWaveformDataProvider output) x 255 rounded.
// Unpacked by island/Sources/MediaStatus.swift voiceMemosLevels(state:lastSeq:levels:).
#import <math.h>
#import <stdint.h>

#define GG_VM_NOTIFY "com.goldengate.island.vmlevel"
/// RE 22.22: sliceDuration = timeWindow / slices = 2.0 / 16 on Mac (27.3 0x10005294c; 26.6 window 0x10000fe69).
#define GG_VM_SLICE_DURATION 0.125

/// levels: the four newest full slices, oldest first.
static inline uint64_t gg_vm_pack(uint32_t seq, const float levels[4]) {
    uint64_t s = (uint64_t)seq << 32;
    for (int i = 0; i < 4; i++) {
        float v = fminf(1, fmaxf(0, levels[i]));
        s |= (uint64_t)lroundf(v * 255) << (8 * (3 - i));
    }
    return s;
}

/// Index of the last slice that ends at or before recording time t (slice i = [0.125 i, 0.125 (i + 1)]), -1 if none.
static inline long gg_vm_last_full_slice(double t) {
    return (long)floor(t / GG_VM_SLICE_DURATION + 1e-9) - 1;
}
