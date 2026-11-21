// 27 style SwiftUI sidebar icons: makes the Solarium closure of SwiftUI.SidebarRow_Mac 26.6 (25G72, 0x7ff916c77480 unslid,
// returns Color.primary into the result slot at %rax) jump to gg_sidebar_icon_thunk, which calls gg_sidebar_icon_color()
// (SidebarIcon.swift, color per 27 SidebarRow_Mac.calistogaIconStyle). Patches only when the first 28 bytes match 25G72.
// The machine runs with amfi_get_out_of_my_way, so shared cache code pages are writable via VM_PROT_COPY (a private
// copy for the process).
#import <Foundation/Foundation.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <mach-o/dyld.h>
#include <string.h>
#include <dlfcn.h>
#include <libkern/OSCacheControl.h>

void ggLog(NSString *fmt, ...);

// %rax: result slot (Color, 8 bytes), %rsi: SidebarRow_Mac (unused). The returned Color is already +1 like Color.primary.getter.
__asm__(
    ".text\n"
    ".globl _gg_sidebar_icon_thunk\n"
    "_gg_sidebar_icon_thunk:\n"
    "    pushq %rbp\n"
    "    movq %rsp, %rbp\n"
    "    pushq %rbx\n"
    "    pushq %r12\n"
    "    movq %rax, %rbx\n"
    "    callq _gg_sidebar_icon_color\n"
    "    movq %rax, (%rbx)\n"
    "    popq %r12\n"
    "    popq %rbx\n"
    "    popq %rbp\n"
    "    retq\n");
void gg_sidebar_icon_thunk(void);

static const uint64_t kClosure = 0x7ff916c77480;   // SwiftUI 25G72, unslid
static const uint8_t kExpect[28] = {0x55, 0x48, 0x89, 0xe5, 0x53, 0x48, 0x83, 0xec, 0x18, 0x48, 0x89, 0xc3, 0x48, 0x8b,
                                    0x7e, 0x40, 0x8b, 0x76, 0x48, 0x48, 0x8d, 0x45, 0xe8, 0xe8, 0xa4, 0x6c, 0x06, 0x00};

/// Writes `patch` over the code at p (private copy page). Returns 1 when written correctly.
static int writeCode(uint8_t *p, const uint8_t *patch, size_t n) {
    mach_vm_address_t page = (mach_vm_address_t)p & ~(mach_vm_address_t)(vm_page_size - 1);
    mach_vm_size_t len = ((mach_vm_address_t)p + n > page + vm_page_size) ? 2 * vm_page_size : vm_page_size;
    kern_return_t kr = mach_vm_protect(mach_task_self(), page, len, FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS) { ggLog(@"code patch: mach_vm_protect error %d", kr); return 0; }
    memcpy(p, patch, n);
    mach_vm_protect(mach_task_self(), page, len, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
    sys_icache_invalidate(p, n);
    return memcmp(p, patch, n) == 0;
}

/// Patches the closure in the SwiftUI image (slide). Returns 1 when patched, 0 on mismatch or error (SwiftUI left untouched).
static int patchSwiftUI(intptr_t slide) {
    uint8_t *p = (uint8_t *)(kClosure + slide);
    if (memcmp(p, kExpect, sizeof kExpect) != 0) { ggLog(@"sidebar SwiftUI: icon closure does not match 25G72, not patching"); return 0; }
    uint8_t patch[13] = {0x49, 0xbb, 0, 0, 0, 0, 0, 0, 0, 0, 0x41, 0xff, 0xe3};   // movabsq $thunk, %r11; jmpq *%r11
    uint64_t t = (uint64_t)&gg_sidebar_icon_thunk;
    memcpy(patch + 2, &t, 8);
    int ok = writeCode(p, patch, sizeof patch);
    ggLog(@"sidebar SwiftUI: 27 style icons %d", ok);
    return ok;
}

// Glass search field without a pocket, like 27. The background closure of
// DesignLibrary.MacEngineeringSearchField 26.6 (0x7ffc0a5cc250, 25G72 unslid) picks glass when environment flag bit 1
// (0x7ffc0a5ca4c0) AND a pocketContainer (0x7ffc0a5ca5c0) are present. 27 (0x195e48648) picks glass when bit 1 OR pocket, when
// AppKit explicitly sets the glass-disallowed value = false. Patch: replace the je after the pocket check (0x7ffc0a5cc678,
// 6 bytes) with a 6 byte NOP. The glass branch does not read the pocket again. Checks 19 bytes from 0x7ffc0a5cc66b
// (mov; mov; call 0x...ca5c0; test $1, %al; je).
static const uint64_t kPocketJe = 0x7ffc0a5cc678;
static const uint8_t kPocketExpect[19] = {0x48, 0x89, 0xdf, 0x4d, 0x89, 0xfd, 0xe8, 0x4a, 0xdf, 0xff, 0xff, 0xa8, 0x01,
                                          0x0f, 0x84, 0x82, 0x00, 0x00, 0x00};

static void onDesignLibrary(const struct mach_header *mh, intptr_t slide) {
    static int done;
    Dl_info di;
    if (done || !dladdr(mh, &di) || !di.dli_fname || !strstr(di.dli_fname, "/DesignLibrary.framework/Versions/A/DesignLibrary")) return;
    done = 1;
    uint8_t *p = (uint8_t *)(kPocketJe + slide);
    if (memcmp(p - 13, kPocketExpect, sizeof kPocketExpect) != 0) { ggLog(@"search field: background closure does not match 25G72, not patching"); return; }
    static const uint8_t nop6[6] = {0x66, 0x0f, 0x1f, 0x44, 0x00, 0x00};
    ggLog(@"search field: glass without pocket like 27 %d", writeCode(p, nop6, sizeof nop6));
}

/// Patches DesignLibrary if already loaded, or when it loads later.
void gg_search_glass_install(void) {
    static int registered;
    if (!registered) { registered = 1; _dyld_register_func_for_add_image(onDesignLibrary); }
}

static void onImage(const struct mach_header *mh, intptr_t slide) {
    static int done;
    Dl_info di;
    if (done || !dladdr(mh, &di) || !di.dli_fname || !strstr(di.dli_fname, "/SwiftUI.framework/Versions/A/SwiftUI")) return;
    done = 1;
    patchSwiftUI(slide);
}

/// Patches when SwiftUI is already loaded, or as soon as it loads later (AppKit apps that load SwiftUI late).
void gg_sidebar_swiftui_install(void) {
    static int registered;
    if (!registered) { registered = 1; _dyld_register_func_for_add_image(onImage); }
}
