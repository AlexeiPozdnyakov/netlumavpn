#include <TargetConditionals.h>

#if TARGET_OS_SIMULATOR
// The vendored wireguard-apple Makefile (tag 1.0.16-27) only maps GOOS for `iphoneos` and `macosx`,
// not `iphonesimulator`, so the simulator slice of libwg-go.a is built with GOOS=darwin. Go's cgo
// references `darwin_arm_init_mach_exception_handler` / `darwin_arm_init_thread_exception_port`
// (gcc_darwin_arm64.c, under TARGET_OS_IPHONE — true on the simulator) but only *defines* them when
// GOOS=ios (gcc_signal_ios_nolldb.c, build tag `ios && arm64`). On a device build GOOS=ios, so the
// device libwg-go.a defines them itself (as no-ops) and this file compiles to nothing.
//
// WireGuard cannot actually run on the simulator (Network Extension limitation), so providing no-op
// stubs here just lets the simulator build/link (and the test suite, which runs on the simulator).
// These match Go's own production no-op definitions in gcc_signal_ios_nolldb.c.
void darwin_arm_init_mach_exception_handler(void) {}
void darwin_arm_init_thread_exception_port(void) {}
#endif
