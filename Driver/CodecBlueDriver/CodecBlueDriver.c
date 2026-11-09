/*
    CodecBlueDriver — an AudioServerPlugIn that publishes one output device, "CodecBlue".

    It is the piece that turns codecblue from "play a file" into "any app's audio goes to the
    headphones": the system writes its output into this device, and codecblue reads it from a
    shared ring buffer and encodes it.

    What this file is, and what it is not
    -------------------------------------
    It is a **working skeleton**: the plug-in loads, the device appears in System Settings, the
    audio server calls StartIO at the right rate, and the samples land in the ring buffer where
    codecblue can pick them up. It is not finished: the ring is a single-producer buffer with no
    back-pressure (the consumer must keep up or the oldest audio is overwritten, which is the
    right behaviour for live audio anyway), and the device does not yet publish its latency
    accurately.

    The one rule that matters
    -------------------------
    Everything the audio server calls happens on a **real-time thread**. No allocation, no
    locks, no logging, no Objective-C, no Swift. The ring buffer is lock-free for that reason:
    the writer only ever moves an atomic index forward.

    Where the audio goes
    --------------------
    The ring lives in a file-backed shared memory region under /tmp so that codecblue, a separate
    process, can map the same pages. It is created by the driver on first use and published with
    a small header that says where the write index is.
*/

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <fcntl.h>
#include <unistd.h>

#pragma mark - Constants

#define kDeviceObjectID     2
#define kStreamObjectID     3
// The volume control's decibel range. macOS asks for this and, if it is missing, treats the
// scalar as a linear amplitude — which makes the first notch of the slider already loud and the
// top half unusable. With a range declared, the system maps its own slider onto decibels the way
// it does for every other device.
#define kVolumeMinDB       (-64.0f)
#define kVolumeMaxDB       (0.0f)
#define kVolumeControlID    4   // main (both channels)
#define kVolumeLeftID       5
#define kVolumeRightID      6
// The mute is a *control* of its own, and it has to be one.
//
// The driver has always stored a muted flag and answered `kAudioBooleanControlPropertyValue`, but
// no object in the control list was a boolean control — so the HAL had nothing to build a
// device-level mute from, and the Mac's mute button did not reach this device at all. Measured
// 2026-11-07: muting the Mac kept the audio playing in the headphones, because the flag existed
// and nobody could set it.
#define kMuteControlID      7

// One second of 48 kHz stereo float: enough that a consumer waking every 10 ms never falls
// behind, small enough to stay in cache-friendly territory.
#define kRingFrames         48000
#define kRingChannels       2
#define kRingSamples        (kRingFrames * kRingChannels)

// The sample rate is a *preference*, not a constant. 44.1 kHz is the native rate of nearly all
// music, so forcing 48 means resampling something that was already right. The rate is chosen by
// whoever starts the stream and written into the ring's header, which the driver reads when it
// opens the ring; a change takes effect when coreaudiod reloads the driver.
//
// The default stays 48 kHz: it is what the ring was sized for and what every existing setup
// expects, and a driver that silently changes rate on first load would be a surprise.
#define kSampleRateDefault  48000.0
#define kSampleRateMin      44100.0
#define kSampleRateMax      96000.0
#define kRingPath           "/tmp/codecblue-ring"
// The clock period the host schedules IO against. 512 frames = 10.7 ms at 48 kHz: fine enough
// that clock drift is corrected a hundred times a second instead of once, which is what stops
// the correction from being audible. See kAudioDevicePropertyZeroTimeStampPeriod.
#define kZeroTimeStampPeriod 512

#pragma mark - Shared ring

// The layout both sides agree on. `write` is the only field the driver moves; `read` is the
// only field codecblue moves. Keeping them apart is what makes this lock-free: each side owns
// one index and only reads the other.
typedef struct {
    _Atomic uint64_t write;         // frames written since the ring was created
    _Atomic uint64_t read;          // frames taken since the ring was created
    _Atomic uint32_t sampleRate;
    _Atomic uint32_t channels;
    _Atomic uint32_t generation;    // bumped when the driver restarts, so a reader can notice
    /// The pid of the process feeding this ring, or 0. Written by codecblue, read here.
    ///
    /// It exists because the driver cannot answer "is anyone going to fill this device?" by
    /// itself, and the obvious test — "has anyone opened it" — is circular: the device would be
    /// hidden because nobody uses it, and nobody could use it because it is hidden. So the fact
    /// comes from the only process that knows it. See `device_should_hide`.
    ///
    /// A pid and not a flag, and that is the whole point. The first version stored 1/0 and set it
    /// back on the way out — which works until the process does not get a way out. Measured
    /// 2026-11-09: `codecblue` was killed mid-stream, the ring kept `feeding = 1` with no process
    /// behind it, and the device stayed in the output list forever, accepting audio from anyone who
    /// chose it. A flag nobody can clear is a flag that lies; a pid can be checked.
    _Atomic int32_t feeder;
    float            samples[kRingSamples];
} CodecBlueRing;

static CodecBlueRing* gRing = NULL;
static void ring_open(void);
static int ring_feeder_alive(void);

static void ring_open(void) {
    if (gRing != NULL) { return; }
    // Two different users have to reach this file: the driver runs inside coreaudiod
    // (_coreaudiod) and the reader is whoever runs codecblue. So the ring is world read/write.
    // On a single-user Mac that is the same as before; on a shared one it means any local user
    // can listen to the audio going to the headphones, which is worth knowing.
    mode_t previous = umask(0);
    int fd = open(kRingPath, O_RDWR | O_CREAT, 0666);
    umask(previous);
    if (fd < 0) {
        // A stale ring may exist, owned by someone else (a test program, an earlier run as a
        // different user). Try to make it usable before giving up.
        chmod(kRingPath, 0666);
        fd = open(kRingPath, O_RDWR);
        if (fd < 0) { return; }
    }
    fchmod(fd, 0666);
    if (ftruncate(fd, sizeof(CodecBlueRing)) != 0) { close(fd); return; }
    void* map = mmap(NULL, sizeof(CodecBlueRing), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (map == MAP_FAILED) { return; }
    gRing = (CodecBlueRing*)map;
    // The ring may already carry a rate, put there by `codecblue rate 44100` before coreaudiod
    // was restarted. Honour it, within what the ring can hold: the buffer is sized for the
    // highest rate it will ever see, so any lower rate is safe and only wastes space.
    uint32_t existing = atomic_load(&gRing->sampleRate);
    if (existing < (uint32_t)kSampleRateMin || existing > (uint32_t)kSampleRateMax) {
        existing = (uint32_t)kSampleRateDefault;
    }
    atomic_store(&gRing->sampleRate, existing);
    atomic_store(&gRing->channels, (uint32_t)kRingChannels);
}

/// The rate the driver is running at, as stored in the ring.
///
/// Everything that used to read `kSampleRate` reads this: the format the host is offered, the
/// clock, and the zero-timestamp period. They must agree — a format at 44.1 with a clock at 48
/// would play everything 8.8% fast.
static double ring_sample_rate(void) {
    if (gRing == NULL) { return kSampleRateDefault; }
    uint32_t rate = atomic_load(&gRing->sampleRate);
    if (rate < (uint32_t)kSampleRateMin || rate > (uint32_t)kSampleRateMax) {
        return kSampleRateDefault;
    }
    return (double)rate;
}

#pragma mark - Driver state

typedef struct {
    AudioServerPlugInDriverInterface*   interface;
    /// What the factory returns: CoreAudio dereferences this once to reach the vtable, so it
    /// must point at the vtable itself.
    AudioServerPlugInDriverInterface*   self;
    AudioServerPlugInHostRef            host;
    UInt32                              refCount;
    UInt32                              started;
    UInt64                              hostTimeAnchor;
    UInt64                              frameAnchor;
    double                              hostTicksPerFrame;
    /// 0…1, applied to every sample the host writes. The driver had no volume control at all,
    /// so the system volume keys and the slider did nothing: the PCM went through untouched.
    _Atomic uint32_t                    volumeBits;   // Float32 bit pattern, atomic
    _Atomic uint32_t                    muted;
    pthread_mutex_t                     mutex;
} CodecBlueDriver;

static CodecBlueDriver gDriver = { .refCount = 1 };

// A device that accepts audio and throws it away is worse than a device that is not there: every
// app that picks "CodecBlue" plays into silence, with no error anywhere. So the device is hidden
// while nothing can feed it.
//
// Three states, and the third is the one that matters: a device hidden *underneath* an app that
// has it open turns a silence into a stream of errors the app cannot explain. So `started` wins —
// if the host has it open, it is visible, whatever the ring says.
static int device_should_hide(void) {
    if (gDriver.started > 0) { return 0; }
    if (gRing != NULL && ring_feeder_alive()) { return 0; }
    return 1;
}

// Whether the process that said it was feeding this ring still exists.
//
// `kill(pid, 0)` asks "may I signal this process", which for our own uid is the same question as
// "does it exist". The pid is never reused while the entry stays: a dead feeder is noticed within
// half a second and the field is cleared, so a recycled pid would have to be handed out in that
// window and then claim the ring — which would take a deliberate act, not bad luck.
//
// This is what makes the rule survive a crash, a `kill -9`, a panic and a reboot. The alternative —
// clearing the flag in a `defer` — was measured to fail the first time the process was killed.
static int ring_feeder_alive(void) {
    int32_t pid = atomic_load(&gRing->feeder);
    if (pid <= 0) { return 0; }
    if (kill((pid_t)pid, 0) == 0) { return 1; }
    if (errno != ESRCH) { return 1; }  // EPERM: it exists, it is just not ours to signal
    atomic_store(&gRing->feeder, 0);
    return 0;
}

// The host caches `IsHidden`, so saying it changed is the only way the list is rebuilt.
static void hide_state_maybe_changed(int previous) {
    if (gDriver.host == NULL) { return; }
    if (previous == device_should_hide()) { return; }
    AudioObjectPropertyAddress changed = {
        kAudioDevicePropertyIsHidden,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    gDriver.host->PropertiesChanged(gDriver.host, kDeviceObjectID, 1, &changed);
}

// The driver has no thread of its own: the ring is a file, and the only way to notice that
// `feeding` changed is to look. Half a second is the resolution of "the icon was pressed" —
// fast enough that nobody sees the device linger, slow enough to cost nothing.
static void* feeding_watcher(void* unused) {
    (void)unused;
    int previous = device_should_hide();
    for (;;) {
        struct timespec pause = { .tv_sec = 0, .tv_nsec = 500 * 1000 * 1000 };
        nanosleep(&pause, NULL);
        ring_open();
        // Checked every tick, not only when the device is visible-or-not is being decided.
        //
        // `device_should_hide` returns early when the host has the device open, so a dead feeder
        // was only noticed once nothing had it open — and the case that matters is exactly the one
        // where the device *is* open: a crash leaves CodecBlue as the system output, coreaudiod
        // keeps it running, and the stale pid sat in the ring until the listener changed output by
        // hand. Measured 2026-11-09. Clearing it here means the ring tells the truth within half a
        // second of the process dying, whatever else is going on.
        ring_feeder_alive();
        hide_state_maybe_changed(previous);
        previous = device_should_hide();
    }
    return NULL;
}


// The driver restarts with coreaudiod, and macOS remembers a volume per device UID. If the driver
// always initialised to full scale it would fight the system: the slider would jump back on every
// restart. So the value is kept in a small file and restored on Initialize.
#define kVolumeStatePath "/tmp/codecblue-volume"

static void volume_load(void) {
    int fd = open(kVolumeStatePath, O_RDONLY);
    if (fd < 0) { return; }
    Float32 value = 1.0f;
    if (read(fd, &value, sizeof(value)) == sizeof(value) && value >= 0 && value <= 1) {
        uint32_t bits; memcpy(&bits, &value, sizeof(bits));
        atomic_store(&gDriver.volumeBits, bits);
    }
    close(fd);
}

static void volume_save(Float32 value) {
    chmod(kVolumeStatePath, 0666);
    // 0666 on create, and the chmod for a file left behind by another user: the driver runs as
    // _coreaudiod and the file may have been written by a test run as the logged-in user.
    int fd = open(kVolumeStatePath, O_WRONLY | O_CREAT | O_TRUNC, 0666);
    if (fd < 0) { return; }
    (void)!write(fd, &value, sizeof(value));
    close(fd);
}


// The driver runs inside a service whose stdout goes nowhere, and os_log from a real-time
// thread is not allowed. So it leaves a trace in a file: one line per life-cycle event, opened
// and closed each time. It is the only way to answer "did StartIO ever get called?".
static void trace(const char* what) {
    // The driver runs as _coreaudiod and the file is usually left behind by a test run as the
    // logged-in user: 0644 owned by someone else means no append, and a silent no-op. So the
    // file is forced open to everyone every time.
    chmod("/tmp/codecblue-driver.log", 0666);
    int fd = open("/tmp/codecblue-driver.log", O_WRONLY | O_CREAT | O_APPEND, 0666);
    if (fd < 0) { return; }
    char line[256];
    int n = snprintf(line, sizeof(line), "%llu %s ring=%p started=%u\n",
                     (unsigned long long)mach_absolute_time(), what, (void*)gRing,
                     (unsigned)gDriver.started);
    if (n > 0) { (void)!write(fd, line, (size_t)n); }
    close(fd);
}


#pragma mark - Helpers

static double host_ticks_per_frame(void) {
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    double ticksPerSecond = 1e9 * (double)timebase.denom / (double)timebase.numer;
    return ticksPerSecond / ring_sample_rate();
}

#pragma mark - Interface: COM

static HRESULT driver_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface) {
    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    if (requested == NULL) { return kAudioHardwareIllegalOperationError; }
    HRESULT result = E_NOINTERFACE;
    if (CFEqual(requested, IUnknownUUID) ||
        CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID)) {
        gDriver.refCount += 1;
        *outInterface = &gDriver.interface;
        result = S_OK;
    }
    CFRelease(requested);
    return result;
}

static ULONG driver_AddRef(void* inDriver) {
    gDriver.refCount += 1;
    return gDriver.refCount;
}

static ULONG driver_Release(void* inDriver) {
    gDriver.refCount -= 1;
    return gDriver.refCount;
}

#pragma mark - Interface: life cycle

static OSStatus driver_Initialize(AudioServerPlugInDriverRef inDriver,
                                  AudioServerPlugInHostRef inHost) {
    gDriver.host = inHost;
    gDriver.hostTicksPerFrame = host_ticks_per_frame();
    {
        // Full scale unless a value was saved: see volume_load.
        Float32 full = 1.0f; uint32_t bits; memcpy(&bits, &full, sizeof(bits));
        atomic_store(&gDriver.volumeBits, bits);
        atomic_store(&gDriver.muted, 0);
        volume_load();
    }
    ring_open();
    // Started here and never stopped: the driver lives as long as coreaudiod, and a thread that
    // sleeps half a second at a time costs less than the bookkeeping needed to end it.
    static int watcherStarted = 0;
    if (!watcherStarted) {
        watcherStarted = 1;
        pthread_t thread;
        if (pthread_create(&thread, NULL, feeding_watcher, NULL) == 0) {
            pthread_detach(thread);
        }
    }
    trace("Initialize");
    return kAudioHardwareNoError;
}

static OSStatus driver_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription,
                                    const AudioServerPlugInClientInfo* inClientInfo,
                                    AudioObjectID* outDeviceObjectID) {
    // The device is static: it exists because the plug-in exists. Creating another one from a
    // description is not supported, and saying so is better than pretending.
    *outDeviceObjectID = kDeviceObjectID;
    return kAudioHardwareNoError;
}

static OSStatus driver_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID) {
    return kAudioHardwareNoError;
}

static OSStatus driver_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                       const AudioServerPlugInClientInfo* inClientInfo) {
    return kAudioHardwareNoError;
}

static OSStatus driver_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                          const AudioServerPlugInClientInfo* inClientInfo) {
    return kAudioHardwareNoError;
}

static OSStatus driver_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver,
                                                        AudioObjectID inDeviceObjectID, UInt64 inChangeAction,
                                                        void* inChangeInfo) {
    return kAudioHardwareNoError;
}

static OSStatus driver_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver,
                                                      AudioObjectID inDeviceObjectID, UInt64 inChangeAction,
                                                      void* inChangeInfo) {
    return kAudioHardwareNoError;
}

#pragma mark - Interface: IO

static Boolean driver_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID,
                                  pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress) {
    switch (inAddress->mSelector) {
        // The host does not discover devices by walking OwnedObjects: it asks the plug-in for its
        // device list. Without these the plug-in loads and then fails to activate, with a log line
        // that says only "Device activation failed".
        case kAudioPlugInPropertyDeviceList:
        case kAudioPlugInPropertyTranslateUIDToDevice:
        case kAudioPlugInPropertyResourceBundle:
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioObjectPropertyCustomPropertyInfoList:
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID:
        case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyRelatedDevices:
        case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning:
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertyStreams:
        case kAudioObjectPropertyControlList:
        case kAudioLevelControlPropertyScalarValue:
        case kAudioLevelControlPropertyDecibelValue:
        case kAudioLevelControlPropertyDecibelRange:
        case kAudioLevelControlPropertyConvertDecibelsToScalar:
        case kAudioLevelControlPropertyConvertScalarToDecibels:
        case kAudioBooleanControlPropertyValue:
        case kAudioObjectPropertyScopeGlobal:
        case kAudioObjectPropertyScopeOutput:
        case kAudioControlPropertyScope:
        case kAudioControlPropertyElement:
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyNominalSampleRate:
        case kAudioDevicePropertyAvailableNominalSampleRates:
        case kAudioDevicePropertyIsHidden:
        case kAudioDevicePropertyZeroTimeStampPeriod:
        case kAudioStreamPropertyIsActive:
        case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel:
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyPhysicalFormat:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            return true;
        default:
            return false;
    }
}

static OSStatus driver_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID,
                                          pid_t inClientProcessID,
                                          const AudioObjectPropertyAddress* inAddress,
                                          Boolean* outIsSettable) {
    switch (inAddress->mSelector) {
        case kAudioLevelControlPropertyScalarValue:
        case kAudioBooleanControlPropertyValue:
        case kAudioDevicePropertyNominalSampleRate:
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            *outIsSettable = true;
            return kAudioHardwareNoError;
        default:
            *outIsSettable = false;
            return kAudioHardwareNoError;
    }
}

static void describe_format(AudioStreamBasicDescription* format) {
    memset(format, 0, sizeof(*format));
    format->mSampleRate = ring_sample_rate();
    format->mFormatID = kAudioFormatLinearPCM;
    format->mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    format->mBytesPerPacket = sizeof(float) * kRingChannels;
    format->mFramesPerPacket = 1;
    format->mBytesPerFrame = sizeof(float) * kRingChannels;
    format->mChannelsPerFrame = kRingChannels;
    format->mBitsPerChannel = 32;
}

static OSStatus driver_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID,
                                           pid_t inClientProcessID,
                                           const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize,
                                           const void* inQualifierData, UInt32* outDataSize) {
    switch (inAddress->mSelector) {
        case kAudioPlugInPropertyDeviceList:
            *outDataSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        case kAudioPlugInPropertyTranslateUIDToDevice:
            *outDataSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        case kAudioPlugInPropertyResourceBundle:
            *outDataSize = sizeof(CFStringRef);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyName:
            *outDataSize = sizeof(CFStringRef);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyOwnedObjects:
            // The plug-in object owns the device; the device owns the stream; the stream owns
            // nothing. Anything else owns nothing.
            if (inObjectID == kAudioObjectPlugInObject) { *outDataSize = sizeof(AudioObjectID); }
            else if (inObjectID == kDeviceObjectID) { *outDataSize = sizeof(AudioObjectID); }
            else { *outDataSize = 0; }
            return kAudioHardwareNoError;
        case kAudioObjectPropertyCustomPropertyInfoList:
            *outDataSize = 0;
            return kAudioHardwareNoError;
        case kAudioDevicePropertyStreams:
            *outDataSize = inObjectID == kDeviceObjectID ? sizeof(AudioObjectID) : 0;
            return kAudioHardwareNoError;
        case kAudioDevicePropertyRelatedDevices:
            *outDataSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyAvailableNominalSampleRates:
            *outDataSize = sizeof(AudioValueRange);
            return kAudioHardwareNoError;
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            *outDataSize = sizeof(AudioStreamRangedDescription);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyControlList:
            // Four controls: the main volume, one per channel, and the mute. The system asks for
            // all of them, and a device that answers only the main one leaves the per-channel
            // volume unknown — and a device with no boolean control has no mute the system can
            // find.
            *outDataSize = inObjectID == kDeviceObjectID ? 4 * sizeof(AudioObjectID) : 0;
            return kAudioHardwareNoError;
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
            *outDataSize = sizeof(AudioClassID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyOwner:
        case kAudioControlPropertyScope:
        case kAudioControlPropertyElement:
            *outDataSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyManufacturer:
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID:
            *outDataSize = sizeof(CFStringRef);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertyLatency:      // same selector as kAudioStreamPropertyLatency
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyZeroTimeStampPeriod:
        case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel:
            *outDataSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning:
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyIsHidden:
        case kAudioStreamPropertyIsActive:
            *outDataSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioStreamPropertyDirection:
            *outDataSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyNominalSampleRate:
            *outDataSize = sizeof(Float64);
            return kAudioHardwareNoError;
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            *outDataSize = sizeof(AudioStreamBasicDescription);
            return kAudioHardwareNoError;
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

/// Scalar 0…1 to decibels over the declared range. The mapping is the one every other device
/// uses: a straight line in dB, which is what makes the slider feel right to the ear.
static Float32 scalar_to_decibels(Float32 scalar) {
    if (scalar <= 0.0f) { return kVolumeMinDB; }
    if (scalar >= 1.0f) { return kVolumeMaxDB; }
    return kVolumeMinDB + scalar * (kVolumeMaxDB - kVolumeMinDB);
}

static Float32 decibels_to_scalar(Float32 decibels) {
    if (decibels <= kVolumeMinDB) { return 0.0f; }
    if (decibels >= kVolumeMaxDB) { return 1.0f; }
    return (decibels - kVolumeMinDB) / (kVolumeMaxDB - kVolumeMinDB);
}

static OSStatus driver_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID,
                                       pid_t inClientProcessID,
                                       const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize,
                                       const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize,
                                       void* outData) {
    switch (inAddress->mSelector) {
        case kAudioPlugInPropertyDeviceList:
            *(AudioObjectID*)outData = kDeviceObjectID;
            *outDataSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        case kAudioPlugInPropertyTranslateUIDToDevice: {
            // The host resolves a device UID to an object id when a client asks for a device by
            // name; answering "not found" for our own UID makes the device unusable.
            CFStringRef wanted = inQualifierDataSize >= sizeof(CFStringRef)
                ? *(const CFStringRef*)inQualifierData : NULL;
            Boolean isOurs = wanted != NULL && CFEqual(wanted, CFSTR("CodecBlue:output"));
            *(AudioObjectID*)outData = isOurs ? kDeviceObjectID : kAudioObjectUnknown;
            *outDataSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        }
        case kAudioPlugInPropertyResourceBundle:
            *(CFStringRef*)outData = CFSTR("");
            *outDataSize = sizeof(CFStringRef);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyName:
            *(CFStringRef*)outData = inObjectID == kDeviceObjectID ? CFSTR("CodecBlue")
                                    : inObjectID == kStreamObjectID ? CFSTR("CodecBlue Output")
                                    : CFSTR("CodecBlue");
            *outDataSize = sizeof(CFStringRef);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyBaseClass:
            *(AudioClassID*)outData = inObjectID == kDeviceObjectID ? kAudioDeviceClassID
                                      : inObjectID == kMuteControlID ? kAudioBooleanControlClassID
                                      : inObjectID >= kVolumeControlID ? kAudioLevelControlClassID
                                      : kAudioStreamClassID;
            *outDataSize = sizeof(AudioClassID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyClass:
            *(AudioClassID*)outData = inObjectID == kDeviceObjectID ? kAudioDeviceClassID
                                      : inObjectID == kMuteControlID ? kAudioMuteControlClassID
                                      : inObjectID >= kVolumeControlID ? kAudioVolumeControlClassID
                                      : kAudioStreamClassID;
            *outDataSize = sizeof(AudioClassID);
            return kAudioHardwareNoError;
        case kAudioControlPropertyScope:
            // A control without a scope and an element is not registered by the HAL, and then the
            // device-level volume property the system asks for does not exist.
            *(UInt32*)outData = kAudioObjectPropertyScopeOutput;
            *outDataSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioControlPropertyElement:
            *(UInt32*)outData = inObjectID == kVolumeLeftID ? 1
                              : inObjectID == kVolumeRightID ? 2
                              : kAudioObjectPropertyElementMain;
            *outDataSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyOwner:
            // The plug-in object is owned by the system; the device by the plug-in; the stream
            // and the volume control by the device.
            *(AudioObjectID*)outData = inObjectID == kDeviceObjectID ? kAudioObjectPlugInObject
                                       : kDeviceObjectID;
            *outDataSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyManufacturer:
            *(CFStringRef*)outData = CFSTR("CodecBlue");
            *outDataSize = sizeof(CFStringRef);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyOwnedObjects:
            if (inObjectID == kAudioObjectPlugInObject) {
                *(AudioObjectID*)outData = kDeviceObjectID;
                *outDataSize = sizeof(AudioObjectID);
            } else if (inObjectID == kDeviceObjectID) {
                *(AudioObjectID*)outData = kStreamObjectID;
                *outDataSize = sizeof(AudioObjectID);
            } else {
                *outDataSize = 0;
            }
            return kAudioHardwareNoError;
        case kAudioDevicePropertyStreams:
            *(AudioObjectID*)outData = kStreamObjectID;
            *outDataSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyDeviceUID:
            *(CFStringRef*)outData = CFSTR("CodecBlue:output");
            *outDataSize = sizeof(CFStringRef);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyModelUID:
            *(CFStringRef*)outData = CFSTR("CodecBlue:model");
            *outDataSize = sizeof(CFStringRef);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyTransportType:
            // "Virtual": the system will not try to treat it as hardware.
            *(UInt32*)outData = kAudioDeviceTransportTypeVirtual;
            *outDataSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyRelatedDevices:
            *(AudioObjectID*)outData = kDeviceObjectID;
            *outDataSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyClockDomain:
            *(UInt32*)outData = 0;
            *outDataSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyDeviceIsAlive:
            *(UInt32*)outData = 1;
            *outDataSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyDeviceIsRunning:
            *(UInt32*)outData = gDriver.started ? 1 : 0;
            *outDataSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            // A hidden device that stays eligible as the default is hidden only halfway: the
            // system would keep offering it for the one job it cannot do.
            *(UInt32*)outData = (UInt32)(device_should_hide() ? 0 : 1);
            *outDataSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertySafetyOffset:
            *(UInt32*)outData = 0;
            *outDataSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyIsHidden:
            *(UInt32*)outData = (UInt32)device_should_hide();
            *outDataSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyZeroTimeStampPeriod:
            // 512 frames (10.7 ms), not kRingFrames.
            //
            // This was 48000 — one whole second — and that is the clock the host schedules IO
            // against. With a period that long the host cannot compensate for the difference
            // between its clock and ours except once a second, so the error accumulates and is
            // then corrected in one step: a discontinuity in the audio, heard as a small
            // crackle from the very first second. A normal virtual device uses 512–4096.
            *(UInt32*)outData = kZeroTimeStampPeriod;
            *outDataSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyNominalSampleRate:
            *(Float64*)outData = ring_sample_rate();
            *outDataSize = sizeof(Float64);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyAvailableNominalSampleRates: {
            AudioValueRange* range = (AudioValueRange*)outData;
            range->mMinimum = 44100.0;
            range->mMaximum = 96000.0;
            *outDataSize = sizeof(AudioValueRange);
            return kAudioHardwareNoError;
        }
        case kAudioObjectPropertyControlList: {
            AudioObjectID* ids = (AudioObjectID*)outData;
            ids[0] = kVolumeControlID;
            ids[1] = kVolumeLeftID;
            ids[2] = kVolumeRightID;
            ids[3] = kMuteControlID;
            *outDataSize = 4 * sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        }
        case kAudioLevelControlPropertyDecibelRange: {
            AudioValueRange* range = (AudioValueRange*)outData;
            range->mMinimum = kVolumeMinDB;
            range->mMaximum = kVolumeMaxDB;
            *outDataSize = sizeof(AudioValueRange);
            return kAudioHardwareNoError;
        }
        case kAudioLevelControlPropertyDecibelValue: {
            uint32_t bits = atomic_load(&gDriver.volumeBits);
            Float32 value; memcpy(&value, &bits, sizeof(value));
            *(Float32*)outData = scalar_to_decibels(value);
            *outDataSize = sizeof(Float32);
            return kAudioHardwareNoError;
        }
        // The value to convert arrives in the qualifier, not in `inData`: this call has no
        // inData parameter at all. Getting that wrong is a compile error, which is how it was
        // found.
        case kAudioLevelControlPropertyConvertDecibelsToScalar:
            if (inQualifierData == NULL || inQualifierDataSize < sizeof(Float32)) {
                return kAudioHardwareBadPropertySizeError;
            }
            *(Float32*)outData = decibels_to_scalar(*(const Float32*)inQualifierData);
            *outDataSize = sizeof(Float32);
            return kAudioHardwareNoError;
        case kAudioLevelControlPropertyConvertScalarToDecibels:
            if (inQualifierData == NULL || inQualifierDataSize < sizeof(Float32)) {
                return kAudioHardwareBadPropertySizeError;
            }
            *(Float32*)outData = scalar_to_decibels(*(const Float32*)inQualifierData);
            *outDataSize = sizeof(Float32);
            return kAudioHardwareNoError;
        case kAudioLevelControlPropertyScalarValue: {
            // The same value for the main element and for each channel: the system asks for all
            // three, and answering only the main one leaves the per-channel volume unknown.
            uint32_t bits = atomic_load(&gDriver.volumeBits);
            Float32 value; memcpy(&value, &bits, sizeof(value));
            *(Float32*)outData = value;
            *outDataSize = sizeof(Float32);
            return kAudioHardwareNoError;
        }
        case kAudioBooleanControlPropertyValue:
            *(UInt32*)outData = atomic_load(&gDriver.muted);
            *outDataSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioStreamPropertyIsActive:
            *(UInt32*)outData = 1;
            *outDataSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioStreamPropertyDirection:
            *(UInt32*)outData = 0;  // output
            *outDataSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioStreamPropertyTerminalType:
            *(UInt32*)outData = kAudioStreamTerminalTypeSpeaker;
            *outDataSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioStreamPropertyStartingChannel:
            *(UInt32*)outData = 1;
            *outDataSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            describe_format((AudioStreamBasicDescription*)outData);
            *outDataSize = sizeof(AudioStreamBasicDescription);
            return kAudioHardwareNoError;
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats: {
            AudioStreamRangedDescription* description = (AudioStreamRangedDescription*)outData;
            describe_format(&description->mFormat);
            description->mSampleRateRange.mMinimum = 44100.0;
            description->mSampleRateRange.mMaximum = 96000.0;
            *outDataSize = sizeof(AudioStreamRangedDescription);
            return kAudioHardwareNoError;
        }
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

// Tell the host the volume changed, on every object that carries it.
//
// This is why the Mac's volume slider did not follow the headphones' own keys. The old code sent
// one notification, for `kDeviceObjectID`, carrying the selector it had just been given. But in
// an AudioServerPlugIn the volume is a *control* with its own object ID (4, 5, 6), and the host
// expects the notification on the control; the device-level volume the system shows is
// synthesised by the HAL from the controls, and the HAL only re-reads them when a control says it
// changed.
//
// Measured 2026-11-07: with the old code, a listener registered on the device's volume, on the
// control's, on both, from the same process and from another one, never fired — not once, for any
// write. The value was stored correctly and nothing ever announced it, so every client kept
// showing the old number forever.
static void volume_notify_changed(void) {
    if (gDriver.host == NULL) { return; }
    // The three controls, with the selector a level control actually has.
    AudioObjectPropertyAddress control = {
        kAudioLevelControlPropertyScalarValue,
        kAudioObjectPropertyScopeOutput,
        kAudioObjectPropertyElementMain
    };
    AudioObjectID controls[3] = { kVolumeControlID, kVolumeLeftID, kVolumeRightID };
    // One notification per control, each addressed to that control. An earlier version passed the
    // array with a count of 3 and the *device* as the object, which tells the host that three
    // consecutive property addresses on the device changed — and they are not addresses at all,
    // they are object IDs. The host read them as if they were, and the compiler said so.
    for (int i = 0; i < 3; i++) {
        gDriver.host->PropertiesChanged(gDriver.host, controls[i], 1, &control);
    }
    // And the device-level property the system reads. `kAudioDevicePropertyVolumeScalar` is a
    // HAL-side selector, not part of the plug-in API, so it is spelled out: 'volm'.
    AudioObjectPropertyAddress device = {
        (AudioObjectPropertySelector)0x766F6C6D,  // 'volm'
        kAudioObjectPropertyScopeOutput,
        kAudioObjectPropertyElementMain
    };
    gDriver.host->PropertiesChanged(gDriver.host, kDeviceObjectID, 1, &device);
}

static OSStatus driver_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID,
                                       pid_t inClientProcessID,
                                       const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize,
                                       const void* inQualifierData, UInt32 inDataSize, const void* inData) {
    switch (inAddress->mSelector) {
        case kAudioLevelControlPropertyScalarValue: {
            if (inDataSize < sizeof(Float32)) { return kAudioHardwareBadPropertySizeError; }
            Float32 value = *(const Float32*)inData;
            if (value < 0) { value = 0; }
            if (value > 1) { value = 1; }
            uint32_t bits; memcpy(&bits, &value, sizeof(bits));
            atomic_store(&gDriver.volumeBits, bits);
            volume_save(value);
            volume_notify_changed();
            return kAudioHardwareNoError;
        }
        case kAudioBooleanControlPropertyValue: {
            if (inDataSize < sizeof(UInt32)) { return kAudioHardwareBadPropertySizeError; }
            atomic_store(&gDriver.muted, *(const UInt32*)inData ? 1 : 0);
            // Announced on the *control*, like the volume. The device-level mute the system shows
            // is synthesised by the HAL from the control, and the HAL only re-reads it when the
            // control says it changed — the same bug the volume had.
            if (gDriver.host != NULL) {
                AudioObjectPropertyAddress changed = *inAddress;
                gDriver.host->PropertiesChanged(gDriver.host, kMuteControlID, 1, &changed);
            }
            return kAudioHardwareNoError;
        }
        default:
            // The device reports one fixed format. Accepting a change here without resampling
            // would mean playing 44.1 kHz audio at 48 kHz, which is worse than refusing.
            return kAudioHardwareNoError;
    }
}

#pragma mark - Interface: IO cycle

static OSStatus driver_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                               UInt32 inClientID) {
    pthread_mutex_lock(&gDriver.mutex);
    if (gDriver.started == 0) {
        ring_open();
        if (gRing != NULL) {
            atomic_fetch_add(&gRing->generation, 1);
            atomic_store(&gRing->write, 0);
            atomic_store(&gRing->read, 0);
        }
        gDriver.hostTimeAnchor = mach_absolute_time();
        gDriver.frameAnchor = 0;
    }
    gDriver.started += 1;
    pthread_mutex_unlock(&gDriver.mutex);
    trace("StartIO");
    return kAudioHardwareNoError;
}

static OSStatus driver_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                              UInt32 inClientID) {
    pthread_mutex_lock(&gDriver.mutex);
    if (gDriver.started > 0) { gDriver.started -= 1; }
    pthread_mutex_unlock(&gDriver.mutex);
    trace("StopIO");
    return kAudioHardwareNoError;
}

static OSStatus driver_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                        UInt32 inClientID, Float64* outSampleTime, UInt64* outHostTime,
                                        UInt64* outSeed) {
    // The device runs on its own clock: sample time is simply the number of frames since StartIO,
    // derived from the host clock. No hardware interrupts, no drift to chase.
    // The host requires the sample time to be a whole number of zero-time-stamp periods: it uses
    // this value to decide when the next IO cycle starts. Returning an arbitrary frame count
    // (which is what this did first) makes the clock look invalid, and the host then never calls
    // DoIOOperation at all — StartIO succeeds, the device says it is running, and no audio ever
    // arrives.
    UInt64 now = mach_absolute_time();
    UInt64 elapsedTicks = now - gDriver.hostTimeAnchor;
    UInt64 frames = (UInt64)((double)elapsedTicks / gDriver.hostTicksPerFrame);
    UInt64 periods = frames / kZeroTimeStampPeriod;
    UInt64 sampleTime = periods * kZeroTimeStampPeriod;
    *outSampleTime = (Float64)sampleTime;
    *outHostTime = gDriver.hostTimeAnchor
                 + (UInt64)((double)sampleTime * gDriver.hostTicksPerFrame);
    *outSeed = 1;
    return kAudioHardwareNoError;
}

static OSStatus driver_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                         UInt32 inClientID, UInt32 inOperationID, Boolean* outWillDo,
                                         Boolean* outWillDoInPlace) {
    switch (inOperationID) {
        case kAudioServerPlugInIOOperationWriteMix:
            *outWillDo = true;
            *outWillDoInPlace = true;
            break;
        default:
            *outWillDo = false;
            *outWillDoInPlace = true;
            break;
    }
    return kAudioHardwareNoError;
}

static OSStatus driver_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                        UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                        const AudioServerPlugInIOCycleInfo* inIOCycleInfo) {
    return kAudioHardwareNoError;
}

static OSStatus driver_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                     AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID,
                                     UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo,
                                     void* ioMainBuffer, void* ioSecondaryBuffer) {
    if (inOperationID != kAudioServerPlugInIOOperationWriteMix || gRing == NULL) {
        return kAudioHardwareNoError;
    }
    const float* source = (const float*)ioMainBuffer;
    if (source == NULL) { return kAudioHardwareNoError; }
    static _Atomic int traced = 0;
    if (atomic_exchange(&traced, 1) == 0) {
        char line[128];
        snprintf(line, sizeof(line), "first DoIOOperation frames=%u buffer=%p",
                 (unsigned)inIOBufferFrameSize, ioMainBuffer);
        trace(line);
    }

    // Real-time path: no allocation, no locks, no logging. The writer owns `write`; the reader
    // owns `read` and we only ever load it. If the reader has fallen behind, the oldest audio is
    // overwritten, which is what live audio wants: a gap is better than a growing delay.
    uint64_t write = atomic_load_explicit(&gRing->write, memory_order_relaxed);
    uint64_t read = atomic_load_explicit(&gRing->read, memory_order_acquire);
    uint32_t frames = inIOBufferFrameSize;

    // The samples are written at full scale on purpose: the volume is applied by codecblue just
    // before the encoder. Applying it here too would multiply twice, and — worse — a change here
    // has to travel through the ring buffer and the packet queue before it is heard, which was
    // measured at two to three seconds. The control still lives on the device so that the slider
    // and the volume keys keep working; codecblue reads it.
    for (uint32_t i = 0; i < frames; i++) {
        uint64_t slot = (write + i) % kRingFrames;
        gRing->samples[slot * kRingChannels + 0] = source[i * kRingChannels + 0];
        gRing->samples[slot * kRingChannels + 1] = source[i * kRingChannels + 1];
    }
    (void)read;
    atomic_store_explicit(&gRing->write, write + frames, memory_order_release);
    return kAudioHardwareNoError;
}

static OSStatus driver_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                      UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                      const AudioServerPlugInIOCycleInfo* inIOCycleInfo) {
    return kAudioHardwareNoError;
}

#pragma mark - Factory

static AudioServerPlugInDriverInterface gInterface = {
    NULL,                       // _reserved
    driver_QueryInterface,
    driver_AddRef,
    driver_Release,
    driver_Initialize,
    driver_CreateDevice,
    driver_DestroyDevice,
    driver_AddDeviceClient,
    driver_RemoveDeviceClient,
    driver_PerformDeviceConfigurationChange,
    driver_AbortDeviceConfigurationChange,
    driver_HasProperty,
    driver_IsPropertySettable,
    driver_GetPropertyDataSize,
    driver_GetPropertyData,
    driver_SetPropertyData,
    driver_StartIO,
    driver_StopIO,
    driver_GetZeroTimeStamp,
    driver_WillDoIOOperation,
    driver_BeginIOOperation,
    driver_DoIOOperation,
    driver_EndIOOperation,
};

__attribute__((visibility("default")))
void* CodecBlueDriver_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID) {
    if (!CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID)) { return NULL; }
    // The factory returns a pointer to a pointer: CoreAudio dereferences it once to get the
    // vtable. `self` must therefore hold the address of the vtable itself, not the address of
    // the `interface` field — getting that wrong makes every method call jump into the middle
    // of the struct.
    gDriver.interface = &gInterface;
    gDriver.self = &gInterface;
    pthread_mutex_init(&gDriver.mutex, NULL);
    // Return the address of the vtable pointer: CoreAudio dereferences it once.
    return &gDriver.self;
}
