// Brings the 27 style Liquid Glass slider into the Appearance pane of System Settings 26.6.
// 27 changes exactly one place: Appearance.GlassStyleRow.body returns GlassStylePicker(.settings). We patch the same place
// in the pane process (Appearance.appex, ggapp loaded via AppexEnv.m): take the instantiated View witness table of
// GlassStyleRow (swift_getWitnessTable) and change three slots: associated type Body -> AnyView, Body: View -> AnyView: View,
// body -> gg_settings_body_thunk (returns AnyView(GGGlassStylePicker27)). Done at load, before SwiftUI builds the pane.
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <mach-o/getsect.h>
#include <mach-o/dyld.h>
#include <string.h>

void ggLog(NSString *fmt, ...);
extern const void *swift_getWitnessTable(const void *conformance, const void *type, const void *const *instantiationArgs);

// View.body witness: %rax result slot (Body = AnyView, 8 bytes), %r13 self (ignored). The returned AnyView is already +1.
__asm__(
    ".text\n"
    ".globl _gg_settings_body_thunk\n"
    "_gg_settings_body_thunk:\n"
    "    pushq %rbp\n"
    "    movq %rsp, %rbp\n"
    "    pushq %rbx\n"
    "    pushq %r12\n"
    "    movq %rax, %rbx\n"
    "    callq _gg_settings_glass_row\n"
    "    movq %rax, (%rbx)\n"
    "    popq %r12\n"
    "    popq %rbx\n"
    "    popq %rbp\n"
    "    retq\n");
void gg_settings_body_thunk(void);

static const uint8_t *relp(const void *field) {
    return (const uint8_t *)field + *(const int32_t *)field;
}

/// "Indirectable" relative pointer: bit 0 = points at a slot holding the real pointer.
static const void *relIndirect(const void *field) {
    int32_t v = *(const int32_t *)field;
    const uint8_t *p = (const uint8_t *)field + (v & ~1);
    return (v & 1) ? *(const void *const *)p : p;
}

typedef struct { const void *metadata; long state; } MetaResp;

/// Finds the <type>: SwiftUI.View conformance in image mh and returns the instantiated witness table (NULL if not found).
static void **viewWitnessTable(const struct mach_header_64 *mh, const char *typeName, const char *moduleName) {
    unsigned long size = 0;
    const uint8_t *sec = getsectiondata(mh, "__TEXT", "__swift5_proto", &size);
    const void *viewProto = dlsym(RTLD_DEFAULT, "$s7SwiftUI4ViewMp");
    if (!sec || !viewProto) return NULL;
    for (unsigned long i = 0; i + 4 <= size; i += 4) {
        const uint8_t *cd = relp(sec + i);
        uint32_t flags = *(const uint32_t *)(cd + 12);
        if (((flags >> 3) & 7) != 0) continue;                          // direct type descriptors only
        const uint8_t *desc = relp(cd + 4);
        if (strcmp((const char *)relp(desc + 8), typeName) != 0) continue;
        if (relIndirect(cd) != viewProto) continue;
        const uint8_t *parent = (const uint8_t *)relIndirect(desc + 4);
        if (!parent || strcmp((const char *)relp(parent + 8), moduleName) != 0) continue;
        MetaResp (*accessor)(long) = (MetaResp (*)(long))relp(desc + 12);
        const void *meta = accessor(0).metadata;
        return meta ? (void **)swift_getWitnessTable(cd, meta, NULL) : NULL;
    }
    return NULL;
}

/// Patches the View witness table of <module>.<type> in the main image so body returns AnyView(27 view). Returns 1 when patched.
/// Exported so tests/app.swift (settings mode) can try it on a type of the test app itself.
int gg_settings_patch_row(const char *type, const char *module) {
    const struct mach_header_64 *exe = NULL;   // image 0 may be an inserted library (DYLD_INSERT_LIBRARIES): look for MH_EXECUTE
    for (uint32_t i = 0; i < _dyld_image_count() && !exe; i++) {
        const struct mach_header_64 *h = (const struct mach_header_64 *)_dyld_get_image_header(i);
        if (h && h->filetype == MH_EXECUTE) exe = h;
    }
    void **t = exe ? viewWitnessTable(exe, type, module) : NULL;
    void *anyView = dlsym(RTLD_DEFAULT, "$s7SwiftUI7AnyViewVN"), *anyViewIsView = dlsym(RTLD_DEFAULT, "$s7SwiftUI7AnyViewVAA0D0AAWP");
    if (!t || !anyView || !anyViewIsView) { ggLog(@"Settings slider: %s.%s: View not found (table %p)", module, type, t); return 0; }
    // Table slots follow the order of View's requirement descriptors (8 bytes each, slot 0 is the conformance descriptor).
    // 26.6: Body: View (Tn), Body (Tl), _makeView, _makeViewList, _viewListCount, body.
    const uint8_t *conf = dlsym(RTLD_DEFAULT, "$s7SwiftUI4ViewP4BodyAC_AaBTn"), *assoc = dlsym(RTLD_DEFAULT, "$s4Body7SwiftUI4ViewPTl"),
                  *body = dlsym(RTLD_DEFAULT, "$s7SwiftUI4ViewP4body4BodyQzvgTq");
    if (!conf || !assoc || !body) return 0;
    const uint8_t *first = conf < assoc ? conf : assoc;
    long iConf = (conf - first) / 8 + 1, iAssoc = (assoc - first) / 8 + 1, iBody = (body - first) / 8 + 1;
    if (iBody > 8 || iConf > 8 || iAssoc > 8) { ggLog(@"Settings slider: unexpected View requirement order (%ld %ld %ld)", iConf, iAssoc, iBody); return 0; }
    t[iConf] = anyViewIsView;
    t[iAssoc] = anyView;                 // ...VN is the metadata pointer (address point)
    t[iBody] = (void *)gg_settings_body_thunk;
    return 1;
}

void gg_settings_slider_install(void) {
    if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.Appearance-Settings.extension"]) return;
    ggLog(@"Settings slider: GlassStyleRow -> slider 27 %d", gg_settings_patch_row("GlassStyleRow", "Appearance"));
}
