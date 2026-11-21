// Test host for GGGlass: does exactly what QuartzCore does (loads the system default.metallib, requests glass
// functions by name, builds a render pipeline with Apple's sdf_filter_vert_lpf vertex) and prints the function names received.
// Run with or without DYLD_INSERT_LIBRARIES=GGGlass.dylib; run-tests.sh compares the output.
// Build: clang -arch x86_64 -fobjc-arc -framework Foundation -framework Metal -o build/host host.m
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <mach-o/dyld.h>
#import <mach/mach.h>
#import <dlfcn.h>

static id<MTLRenderPipelineState> gLastPipeline;

static NSString *pipelineOKC(id<MTLDevice> dev, id<MTLLibrary> lib, id<MTLFunction> frag, NSString *vertName, MTLFunctionConstantValues *vcv) {
    // Functions with function constants (uber vertex fixed_vert_*) only build a pipeline once specialized.
    id<MTLFunction> vert = [lib newFunctionWithName:vertName constantValues:vcv error:nil];
    MTLVertexDescriptor *vd = [MTLVertexDescriptor vertexDescriptor];
    NSUInteger off = 0;
    for (MTLVertexAttribute *a in vert.vertexAttributes) {
        if (!a.active) continue;
        BOOL f4 = a.attributeType == MTLDataTypeFloat4;
        vd.attributes[a.attributeIndex].format = f4 ? MTLVertexFormatFloat4 : MTLVertexFormatFloat2;
        vd.attributes[a.attributeIndex].offset = off;
        vd.attributes[a.attributeIndex].bufferIndex = 30;
        off += f4 ? 16 : 8;
    }
    vd.layouts[30].stride = off ? off : 4;
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = vert; d.fragmentFunction = frag; d.vertexDescriptor = vd;
    d.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    NSError *e = nil;
    gLastPipeline = [dev newRenderPipelineStateWithDescriptor:d error:&e];
    return gLastPipeline ? @"ok" : [NSString stringWithFormat:@"fail(%@)", e.localizedDescription];
}

static NSString *pipelineOK(id<MTLDevice> dev, id<MTLLibrary> lib, id<MTLFunction> frag, NSString *vertName) {
    return pipelineOKC(dev, lib, frag, vertName, [MTLFunctionConstantValues new]);
}

/// Like QuartzCore: bind the pipeline, then bind uniforms at buffer index 1 (shared buffer, with offset). No drawing.
static void encodeUniforms(id<MTLDevice> dev, id<MTLRenderPipelineState> pso) {
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:4 height:4 mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget;
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = [dev newTextureWithDescriptor:td];
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    // 4 uniform sets (sdf variant: face_cm at byte 48 + 80): sets 1 and 2 share a face, differ at byte 0; set 3 has another face;
    // set 4 is like set 1 but its face differs in the lowest bit of one half (moving glass): treated as the same face.
    float u[4][68 + 4] = {{0}};
    u[0][4] = 1234.5f;   // offset 16 in the buffer = byte 0 of the uniforms
    u[1][4] = 99.0f;
    u[2][4] = 7.0f; u[2][4 + (48 + 80) / 4] = 0.5f;
    u[3][4] = 3.0f; ((uint16_t *)&u[3][4 + (48 + 80) / 4])[0] = 0x3800;          // half 0.5
    ((uint16_t *)&u[0][4 + (48 + 80) / 4])[0] = 0x3801;                           // half 0.5 + 1 ulp
    ((uint16_t *)&u[1][4 + (48 + 80) / 4])[0] = 0x3801;                           // set 2 shares set 1's face
    id<MTLBuffer> buf = [dev newBufferWithBytes:u length:sizeof u options:MTLResourceStorageModeShared];
    id<MTLCommandQueue> q = [dev newCommandQueue];
    id<MTLCommandBuffer> cb = [q commandBuffer];
    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
    [enc setRenderPipelineState:pso];
    // sdf_texture at slot 4 like QuartzCore's texture variant: 8x4 RGBA32Float, first texel (1.5, -2.25, 0.5, 1).
    MTLTextureDescriptor *sd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float width:8 height:4 mipmapped:NO];
    sd.storageMode = MTLStorageModeManaged;
    id<MTLTexture> sdf = [dev newTextureWithDescriptor:sd];
    float px[8 * 4 * 4] = {1.5f, -2.25f, 0.5f, 1.0f};
    [sdf replaceRegion:MTLRegionMake2D(0, 0, 8, 4) mipmapLevel:0 withBytes:px bytesPerRow:8 * 16];
    [enc setFragmentTexture:sdf atIndex:4];
    for (int i = 0; i < 4; i++) [enc setFragmentBuffer:buf offset:16 + i * sizeof u[0] atIndex:1];
    // HOST_DOCK=dark|light: add sdf-variant uniforms with a 26.6 Dock face (#10 dark: 0.075/0.9/1.06 black .1; #9 light:
    // 0.15/0.9/1.05 white .1) at byte 48 + 80, as QuartzCore binds when drawing the Dock.
    const char *dock = getenv("HOST_DOCK");
    if (dock) {
        BOOL dark = strcmp(dock, "dark") == 0;
        float B = dark ? 0.075f : 0.15f, Wt = 0.9f, S = dark ? 1.06f : 1.05f, a = 0.1f, f = dark ? 0 : 1, k = 1 - a;
        const float L[3] = {0.2126f, 0.7152f, 0.0722f};
        __fp16 du[160] = {0};
        for (int i = 0; i < 3; i++) {
            for (int j = 0; j < 3; j++) du[(48 + 80) / 2 + i * 4 + j] = (__fp16)((Wt - B - S) * L[j] * k + (i == j ? S * k : 0));
            du[(48 + 80) / 2 + i * 4 + 3] = (__fp16)(B * k + f * a);
        }
        [enc setFragmentBuffer:[dev newBufferWithBytes:du length:sizeof du options:MTLResourceStorageModeShared] offset:0 atIndex:1];
    }
    [enc endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    printf("encode=ok\n");
}

int main(void) {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        NSURL *url = [NSURL fileURLWithPath:@"/System/Library/Frameworks/QuartzCore.framework/Versions/A/Resources/default.metallib"];
        NSError *e = nil;
        id<MTLLibrary> lib = [dev newLibraryWithURL:url error:&e];
        if (!lib) { printf("lib=fail\n"); return 1; }
        // GG_HOST_WARM: like right after WindowServer starts. The first request (glass_background_lph) starts loading the
        // library and the warm-up; wait for the log in GG_STATE to report "warm-up done" (up to 60 s), then time requests for
        // the 7 remaining glass functions as when opening the Dock/Control Center. Prints warm=<slowest ms> and the names received.
        if (getenv("GG_HOST_WARM")) {
            id<MTLFunction> first = [lib newFunctionWithName:@"glass_background_lph"];
            NSString *log = [@(getenv("GG_STATE") ?: "/tmp") stringByAppendingPathComponent:@"ggglass.log"];
            for (int i = 0; i < 600; i++) {
                if ([[NSString stringWithContentsOfFile:log encoding:NSUTF8StringEncoding error:nil] containsString:@"warm-up done"]) break;
                usleep(100000);
            }
            double worst = 0;
            NSMutableArray *names = [NSMutableArray arrayWithObject:first.name ?: @"nil"];
            for (NSString *n in @[@"glass_background_sdf_lpf", @"glass_background_sdf_no_bleed_lpf", @"glass_background_sdf_lph",
                                  @"glass_background_sdf_no_bleed_lph", @"glass_background_lpf", @"glass_background_no_bleed_lpf",
                                  @"glass_background_no_bleed_lph"]) {
                CFAbsoluteTime t = CFAbsoluteTimeGetCurrent();
                id<MTLFunction> f = [lib newFunctionWithName:n constantValues:[MTLFunctionConstantValues new] error:&e];
                worst = fmax(worst, (CFAbsoluteTimeGetCurrent() - t) * 1000);
                [names addObject:f.name ?: @"nil"];
            }
            printf("warm=%.0f names=%s\n", worst, [names componentsJoinedByString:@","].UTF8String);
            return 0;
        }
        // 1. newFunctionWithName:
        id<MTLFunction> f1 = [lib newFunctionWithName:@"glass_background_sdf_lpf"];
        printf("sdf=%s pipeline=%s\n", f1.name.UTF8String, pipelineOK(dev, lib, f1, @"sdf_filter_vert_lpf").UTF8String);
        // 2. newFunctionWithName:constantValues:error:
        id<MTLFunction> f2 = [lib newFunctionWithName:@"glass_background_sdf_no_bleed_lpf"
                                       constantValues:[MTLFunctionConstantValues new] error:&e];
        printf("nobleed=%s\n", f2.name.UTF8String);
        // 3. newFunctionWithDescriptor:error:
        MTLFunctionDescriptor *fd = [MTLFunctionDescriptor functionDescriptor];
        fd.name = @"glass_background_sdf_lpf";
        id<MTLFunction> f3 = [lib newFunctionWithDescriptor:fd error:&e];
        printf("desc=%s\n", f3.name.UTF8String);
        // 4. The _lph variant (chosen by QuartzCore on Intel GPUs): must be replaced and build a pipeline with the _lph vertex.
        id<MTLFunction> f4 = [lib newFunctionWithName:@"glass_background_sdf_lph"];
        printf("lph=%s pipeline=%s\n", f4.name.UTF8String, pipelineOK(dev, lib, f4, @"sdf_filter_vert_lph").UTF8String);
        if (gLastPipeline) encodeUniforms(dev, gLastPipeline);
        id<MTLRenderPipelineState> glassPSO = gLastPipeline;   // _lph glass pipeline (ours when the dylib is loaded)
        // 4b. The variant reading the SDF from a texture (QuartzCore uses it while the shape changes and for large glass): must be replaced.
        id<MTLFunction> f4b = [lib newFunctionWithName:@"glass_background_lph"];
        printf("texsdf=%s\n", f4b.name.UTF8String);
        id<MTLFunction> f4c = [lib newFunctionWithName:@"glass_background_no_bleed_lph" constantValues:[MTLFunctionConstantValues new] error:&e];
        printf("texnobleed=%s\n", f4c.name.UTF8String);
        // 4d. A name not in the replacement list: must keep the Apple function.
        id<MTLFunction> f4d = [lib newFunctionWithName:@"glass_foreground_sdf_lph"];
        printf("fg=%s\n", f4d.name.UTF8String);
        // 4e. The 26.6 highlight layer (CASDFKeyFillHighlightEffect, white alpha 1 when the window is key) is drawn by
        // QuartzCore's uber shader: fixed_frag_* with constant 28 (fc_texture_function) = 66 (sdf_key_fill_highlight). With
        // the dylib it must receive a function that draws nothing (the 27 highlight is drawn in the glass shader) and build a
        // pipeline with the real uber vertex; other values keep Apple. QuartzCore may set the constant by index or by name,
        // and call synchronously, asynchronously or via a descriptor.
        uint8_t kfFn = 66, otherFn = 64;
        MTLFunctionConstantValues *kcv = [MTLFunctionConstantValues new];
        [kcv setConstantValue:&kfFn type:MTLDataTypeUChar atIndex:28];
        id<MTLFunction> kf = [lib newFunctionWithName:@"fixed_frag_lph_cph" constantValues:kcv error:&e];
        printf("kf=%s pipeline=%s\n", kf.name.UTF8String, pipelineOK(dev, lib, kf, @"fixed_vert_lph_spc").UTF8String);
        MTLFunctionConstantValues *ncv = [MTLFunctionConstantValues new];
        [ncv setConstantValue:&kfFn type:MTLDataTypeUChar withName:@"fc_texture_function"];
        printf("kfname=%s\n", [lib newFunctionWithName:@"fixed_frag_lph_cph" constantValues:ncv error:&e].name.UTF8String);
        MTLFunctionDescriptor *kd = [MTLFunctionDescriptor functionDescriptor];
        kd.name = @"fixed_frag_lpf_cpf"; kd.constantValues = kcv;
        printf("kfdesc=%s\n", [lib newFunctionWithDescriptor:kd error:&e].name.UTF8String);
        dispatch_semaphore_t kfDone = dispatch_semaphore_create(0);
        __block NSString *asyncName = nil;
        [lib newFunctionWithName:@"fixed_frag_lph_cph" constantValues:kcv completionHandler:^(id<MTLFunction> f, NSError *err) {
            asyncName = f.name; dispatch_semaphore_signal(kfDone); }];
        dispatch_semaphore_wait(kfDone, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC));
        printf("kfasync=%s\n", asyncName.UTF8String);
        MTLFunctionConstantValues *ocv = [MTLFunctionConstantValues new];
        [ocv setConstantValue:&otherFn type:MTLDataTypeUChar atIndex:28];
        printf("kfother=%s\n", [lib newFunctionWithName:@"fixed_frag_lph_cph" constantValues:ocv error:&e].name.UTF8String);
        // 4e'. The 26.6 SDF rim (UberShader::sdf_rim, constant 28 = 13/14/77): a 1 px white stroke outside toolbar button
        // edges. Must keep Apple (it also draws sidebar content, Dock menus, Spotlight icons).
        uint8_t rimFn = 14;
        MTLFunctionConstantValues *rcv = [MTLFunctionConstantValues new];
        [rcv setConstantValue:&rimFn type:MTLDataTypeUChar atIndex:28];
        printf("rim=%s\n", [lib newFunctionWithName:@"fixed_frag_lph_cph" constantValues:rcv error:&e].name.UTF8String);
        // 4f. Generic uber (constant 0 fc_generic = true): FragmentShaderConfig (52 bytes) at fragment buffer 0, texture
        // function at byte 33. QuartzCore may draw the 26.6 highlight with this variant. Bind config 66 (highlight) via
        // setFragmentBytes and then via setFragmentBuffer, plus config 7, each with a 0-vertex draw (no GPU work).
        // With the dylib the log must record exactly 2 skipped highlight draws; the function is still Apple's.
        {
            BOOL generic = YES;
            MTLFunctionConstantValues *gcv = [MTLFunctionConstantValues new];
            [gcv setConstantValue:&generic type:MTLDataTypeBool atIndex:0];
            id<MTLFunction> gfn = [lib newFunctionWithName:@"fixed_frag_lph_cph" constantValues:gcv error:&e];
            printf("uber=%s pipeline=%s\n", gfn.name.UTF8String, pipelineOKC(dev, lib, gfn, @"fixed_vert_lph_gen", gcv).UTF8String);
            id<MTLRenderPipelineState> gpso = gLastPipeline;
            MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:4 height:4 mipmapped:NO];
            td.usage = MTLTextureUsageRenderTarget;
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture = [dev newTextureWithDescriptor:td];
            rp.colorAttachments[0].loadAction = MTLLoadActionClear;
            id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer];
            id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
            uint8_t cfg[52] = {0};
            // A glass draw first (traceDraws logs the draw sequence right after our glass).
            if (glassPSO) { [enc setRenderPipelineState:glassPSO]; [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:0]; }
            if (gpso) {
                [enc setRenderPipelineState:gpso];
                cfg[33] = 66; [enc setFragmentBytes:cfg length:sizeof cfg atIndex:0];
                [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:0];
                id<MTLBuffer> cb66 = [dev newBufferWithBytes:cfg length:sizeof cfg options:MTLResourceStorageModeShared];
                cfg[33] = 7; [enc setFragmentBytes:cfg length:sizeof cfg atIndex:0];
                [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:0];
                [enc setFragmentBuffer:cb66 offset:0 atIndex:0];
                [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:0 instanceCount:1];
            }
            [enc endEncoding]; [cb commit]; [cb waitUntilCompleted];
            printf("uberdraw=ok\n");
        }
        // 5. A non-glass function.
        id<MTLFunction> f5 = [lib newFunctionWithName:@"sdf_filter_vert_lpf"];
        printf("vert=%s\n", f5.name.UTF8String);
        // 6. GG_HOST_DUMP_MIG: where the stub_routine cell of msgh_id 30591 (PostCoordinatedDistributedNotificationFenced) in
        // __CGXCGXServices_subsystem (static 0x7ff840ae72b8 on 25G72) points, then call it like WindowServer with fake
        // messages (type 3, type 12, type 12 with a wrong size). Outside WindowServer there is no connection, so Apple returns 1003.
        // SkyLight's slide comes from an exported symbol (the executable may live inside SkyLight.framework like WindowServer).
        Dl_info sky = {0};
        if (getenv("GG_HOST_DUMP_MIG") && dladdr(dlsym(RTLD_DEFAULT, "SLSMainConnectionID"), &sky) && sky.dli_fbase) {
            {
                void (**cell)(mach_msg_header_t *, mach_msg_header_t *) =
                    (void *)(0x7ff840ae72b8ULL + ((intptr_t)sky.dli_fbase - (intptr_t)0x7ff8091fd000));
                Dl_info di = {0};
                dladdr((const void *)*cell, &di);
                printf("migcell=%s\n", di.dli_fname && strstr(di.dli_fname, "GGGlass") ? "GGGlass" : "SkyLight");
                int rc[3];
                for (int k = 0; k < 3; k++) {
                    uint8_t in[0x3c] = {0}, out[0x40] = {0};
                    mach_msg_header_t *h = (mach_msg_header_t *)in;
                    h->msgh_bits = MACH_MSGH_BITS_COMPLEX; h->msgh_size = k == 2 ? 0x38 : 0x3c; h->msgh_id = 30591;
                    *(uint32_t *)(in + 0x18) = 1; *(uint16_t *)(in + 0x26) = 0x11;
                    *(uint32_t *)(in + 0x30) = k == 0 ? 3 : 12; *(double *)(in + 0x34) = 0.5;
                    (*cell)(h, (mach_msg_header_t *)out);
                    rc[k] = *(int32_t *)(out + 0x20);
                }
                int *calls = dlsym(RTLD_DEFAULT, "gg_mig_type12_calls");
                printf("mig3=%d mig12=%d migbad=%d mig12calls=%d\n", rc[0], rc[1], rc[2], calls ? *calls : -1);
            }
        }
        // Keep the process alive (like a long-running WindowServer) to test the dylib's appearance tracking.
        if (getenv("HOST_WAIT")) sleep((unsigned)atoi(getenv("HOST_WAIT")));
    }
    return 0;
}
