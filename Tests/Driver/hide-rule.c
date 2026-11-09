// Tests the driver's hiding rule by compiling the driver's own source into a harness.
// The rule cannot be tested from Swift and cannot be tested live without sudo, so it is tested
// where it lives: one translation unit, the real function, no copy of the logic.
#include "../../Driver/CodecBlueDriver/CodecBlueDriver.c"
#include <assert.h>
#include <unistd.h>

int main(void) {
    int failures = 0;

    // No ring at all: nothing can feed the device, so it hides.
    gRing = NULL;
    gDriver.started = 0;
    if (device_should_hide() != 1) { printf("FAIL: no ring, nothing started -> should hide\n"); failures++; }

    // A ring nobody feeds: still hides.
    ring_open();
    if (gRing == NULL) { printf("FAIL: could not open the ring\n"); return 1; }
    atomic_store(&gRing->feeder, 0);
    if (device_should_hide() != 1) { printf("FAIL: ring not fed -> should hide\n"); failures++; }

    // A live process says it is feeding: visible.
    atomic_store(&gRing->feeder, (int32_t)getpid());
    if (device_should_hide() != 0) { printf("FAIL: ring fed by a live pid -> should be visible\n"); failures++; }

    // A pid with nothing behind it: hidden again, and the field is cleared.
    //
    // This is the case the first version got wrong. `feeding = 1` set by a process that was then
    // killed left the device in the output list forever, accepting audio from anyone who chose it.
    // A flag nobody can clear is a flag that lies; a pid can be checked.
    atomic_store(&gRing->feeder, 999999);
    if (device_should_hide() != 1) { printf("FAIL: dead feeder -> should hide\n"); failures++; }
    if (atomic_load(&gRing->feeder) != 0) { printf("FAIL: dead feeder was not cleared\n"); failures++; }

    // The host has it open: visible even with nobody feeding, because hiding a device underneath
    // an app that has it open turns silence into a stream of errors the app cannot explain.
    atomic_store(&gRing->feeder, 0);
    gDriver.started = 1;
    if (device_should_hide() != 0) { printf("FAIL: opened by the host -> must stay visible\n"); failures++; }

    // And back: the host closed it and nobody feeds it.
    gDriver.started = 0;
    if (device_should_hide() != 1) { printf("FAIL: closed and unfed -> should hide again\n"); failures++; }

    printf("%s\n", failures == 0 ? "driver hide rule: 7/7 ok" : "driver hide rule: FAILED");
    return failures == 0 ? 0 : 1;
}
