// This file exists purely because xcode doesn't like header only targets, SPM is fine with them
#import "private.h"
#import <Carbon/Carbon.h> // GetProcessForPID, ProcessSerialNumber
#import <dlfcn.h>         // dlopen, dlsym
#import <dispatch/dispatch.h>
#import <string.h>        // memcpy, memset

// Private SkyLight (WindowServer) symbols. Same key-window sequence used by yabai and Amethyst.
// https://github.com/Hammerspoon/hammerspoon/issues/370#issuecomment-545545468
typedef CGError (*SLPSSetFrontProcessWithOptionsFn)(ProcessSerialNumber *psn, uint32_t wid, uint32_t mode);
typedef CGError (*SLPSPostEventRecordToFn)(ProcessSerialNumber *psn, uint8_t *bytes);

static SLPSSetFrontProcessWithOptionsFn setFrontProcessWithOptions;
static SLPSPostEventRecordToFn postEventRecordTo;
static dispatch_once_t loadSkyLightOnce;

static void aeroLoadPrivateFocusSymbols(void) {
    dispatch_once(&loadSkyLightOnce, ^{
        void *handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL);
        if (handle == NULL) { return; }
        setFrontProcessWithOptions = (SLPSSetFrontProcessWithOptionsFn)dlsym(handle, "_SLPSSetFrontProcessWithOptions");
        postEventRecordTo = (SLPSPostEventRecordToFn)dlsym(handle, "SLPSPostEventRecordTo");
    });
}

bool aeroPrivateFocusAvailable(void) {
    aeroLoadPrivateFocusSymbols();
    return setFrontProcessWithOptions != NULL && postEventRecordTo != NULL;
}

bool aeroMakeKeyWindow(pid_t pid, uint32_t wid) {
    if (!aeroPrivateFocusAvailable()) { return false; }

    ProcessSerialNumber psn;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations" // GetProcessForPID is the documented way to obtain a PSN
    if (GetProcessForPID(pid, &psn) != noErr) { return false; }
#pragma clang diagnostic pop

    // 0x200 == kCPSUserGenerated: mark the activation as user-initiated.
    if (setFrontProcessWithOptions(&psn, wid, 0x200) != kCGErrorSuccess) { return false; }

    // Two synthesized WindowServer key-window events; they differ only in byte 0x08 (0x01 then 0x02).
    uint8_t bytes[0xf8] = {0};
    bytes[0x04] = 0xf8;
    bytes[0x3a] = 0x10;
    memcpy(bytes + 0x3c, &wid, sizeof(uint32_t));
    memset(bytes + 0x20, 0xff, 0x10);
    bytes[0x08] = 0x01;
    if (postEventRecordTo(&psn, bytes) != kCGErrorSuccess) { return false; }
    bytes[0x08] = 0x02;
    if (postEventRecordTo(&psn, bytes) != kCGErrorSuccess) { return false; }
    return true;
}
