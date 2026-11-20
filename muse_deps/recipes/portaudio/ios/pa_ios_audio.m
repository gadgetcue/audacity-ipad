/*
 * PortAudio host API for iOS / iPadOS (RemoteIO audio unit).
 *
 * Exposes one full-duplex device ("iOS Audio") backed by AVAudioSession and the
 * RemoteIO audio unit. Registered as PaMacCore_Initialize so the stock
 * pa_unix_hostapis.c picks it up when PA_USE_COREAUDIO is defined.
 *
 * Callback streams only (Audacity uses callback streams).
 *
 * Copyright (c) 2026 Audacity iPad contributors. Licensed under the PortAudio
 * license (MIT-style), see LICENSE.txt of PortAudio.
 */

#import <AVFoundation/AVFoundation.h>
#include <AudioToolbox/AudioToolbox.h>
#include <mach/mach_time.h>
#include <string.h>

#include "portaudio.h"
#include "pa_util.h"
#include "pa_allocation.h"
#include "pa_hostapi.h"
#include "pa_stream.h"
#include "pa_cpuload.h"
#include "pa_process.h"
#include "pa_debugprint.h"

#define IOS_MAX_CHANNELS 2
#define IOS_OUTPUT_BUS 0
#define IOS_INPUT_BUS 1

typedef struct
{
    PaUtilHostApiRepresentation inheritedHostApiRep;
    PaUtilStreamInterface callbackStreamInterface;
    PaUtilAllocationGroup* allocations;
    PaDeviceInfo* devices;
    PaDeviceInfo** devicePtrs;
} PaIosHostApi;

typedef struct
{
    PaUtilStreamRepresentation streamRepresentation;
    PaUtilCpuLoadMeasurer cpuLoadMeasurer;
    PaUtilBufferProcessor bufferProcessor;

    AudioUnit unit;
    int inputChannels;
    int outputChannels;
    double sampleRate;

    float* inputBuffer;           /* interleaved float, maxFrames * inputChannels */
    UInt32 maxFrames;
    AudioBufferList inputList;

    volatile int isActive;
    volatile int isStopped;
    volatile int stopRequested;   /* paComplete/paAbort from callback */
    double startHostTime;
} PaIosStream;

/* ---------------------------------------------------------------- session */

static double IosSessionSampleRate(void)
{
    double sr = [AVAudioSession sharedInstance].sampleRate;
    return sr > 0 ? sr : 48000.0;
}

static int IosSessionInputChannels(void)
{
    AVAudioSession* s = [AVAudioSession sharedInstance];
    if (!s.isInputAvailable) {
        return 0;
    }
    NSInteger n = s.inputNumberOfChannels;
    if (n <= 0) {
        n = 1;
    }
    return (int)(n > IOS_MAX_CHANNELS ? IOS_MAX_CHANNELS : n);
}

static void IosConfigureSession(double preferredRate)
{
    AVAudioSession* s = [AVAudioSession sharedInstance];
    NSError* err = nil;
    [s setCategory:AVAudioSessionCategoryPlayAndRecord
              mode:AVAudioSessionModeDefault
           options:(AVAudioSessionCategoryOptionDefaultToSpeaker
                    | AVAudioSessionCategoryOptionAllowBluetoothA2DP
                    | AVAudioSessionCategoryOptionMixWithOthers)
             error:&err];
    if (preferredRate > 0) {
        [s setPreferredSampleRate:preferredRate error:&err];
    }
    [s setPreferredIOBufferDuration:0.005 error:&err];
    [s setActive:YES error:&err];
}

/* ------------------------------------------------------------- host api */

static void Terminate(struct PaUtilHostApiRepresentation* hostApi);
static PaError IsFormatSupported(struct PaUtilHostApiRepresentation* hostApi,
                                 const PaStreamParameters* inputParameters,
                                 const PaStreamParameters* outputParameters,
                                 double sampleRate);
static PaError OpenStream(struct PaUtilHostApiRepresentation* hostApi,
                          PaStream** s,
                          const PaStreamParameters* inputParameters,
                          const PaStreamParameters* outputParameters,
                          double sampleRate,
                          unsigned long framesPerBuffer,
                          PaStreamFlags streamFlags,
                          PaStreamCallback* streamCallback,
                          void* userData);
static PaError CloseStream(PaStream* stream);
static PaError StartStream(PaStream* stream);
static PaError StopStream(PaStream* stream);
static PaError AbortStream(PaStream* stream);
static PaError IsStreamStopped(PaStream* s);
static PaError IsStreamActive(PaStream* stream);
static PaTime GetStreamTime(PaStream* stream);
static double GetStreamCpuLoad(PaStream* stream);

PaError PaMacCore_Initialize(PaUtilHostApiRepresentation** hostApi, PaHostApiIndex hostApiIndex)
{
    (void)hostApiIndex;
    PaIosHostApi* api = (PaIosHostApi*)PaUtil_AllocateMemory(sizeof(PaIosHostApi));
    if (!api) {
        return paInsufficientMemory;
    }
    memset(api, 0, sizeof(*api));

    api->allocations = PaUtil_CreateAllocationGroup();
    if (!api->allocations) {
        PaUtil_FreeMemory(api);
        return paInsufficientMemory;
    }

    @autoreleasepool {
        IosConfigureSession(0);
    }

    *hostApi = &api->inheritedHostApiRep;
    (*hostApi)->info.structVersion = 1;
    (*hostApi)->info.type = paCoreAudio;
    (*hostApi)->info.name = "Core Audio";
    (*hostApi)->info.deviceCount = 1;
    (*hostApi)->info.defaultInputDevice = 0;
    (*hostApi)->info.defaultOutputDevice = 0;

    api->devices = (PaDeviceInfo*)PaUtil_GroupAllocateMemory(api->allocations, sizeof(PaDeviceInfo));
    api->devicePtrs = (PaDeviceInfo**)PaUtil_GroupAllocateMemory(api->allocations, sizeof(PaDeviceInfo*));
    if (!api->devices || !api->devicePtrs) {
        PaUtil_DestroyAllocationGroup(api->allocations);
        PaUtil_FreeMemory(api);
        return paInsufficientMemory;
    }

    PaDeviceInfo* d = &api->devices[0];
    memset(d, 0, sizeof(*d));
    d->structVersion = 2;
    d->hostApi = hostApiIndex;
    d->name = "iOS Audio";
    d->maxInputChannels = IOS_MAX_CHANNELS;
    d->maxOutputChannels = IOS_MAX_CHANNELS;
    d->defaultLowInputLatency = 0.005;
    d->defaultLowOutputLatency = 0.005;
    d->defaultHighInputLatency = 0.04;
    d->defaultHighOutputLatency = 0.04;
    d->defaultSampleRate = IosSessionSampleRate();
    api->devicePtrs[0] = d;

    (*hostApi)->deviceInfos = api->devicePtrs;
    (*hostApi)->Terminate = Terminate;
    (*hostApi)->OpenStream = OpenStream;
    (*hostApi)->IsFormatSupported = IsFormatSupported;

    PaUtil_InitializeStreamInterface(&api->callbackStreamInterface,
                                     CloseStream, StartStream, StopStream, AbortStream,
                                     IsStreamStopped, IsStreamActive,
                                     GetStreamTime, GetStreamCpuLoad,
                                     PaUtil_DummyRead, PaUtil_DummyWrite,
                                     PaUtil_DummyGetReadAvailable, PaUtil_DummyGetWriteAvailable);
    return paNoError;
}

static void Terminate(struct PaUtilHostApiRepresentation* hostApi)
{
    PaIosHostApi* api = (PaIosHostApi*)hostApi;
    if (api->allocations) {
        PaUtil_FreeAllAllocations(api->allocations);
        PaUtil_DestroyAllocationGroup(api->allocations);
    }
    PaUtil_FreeMemory(api);
}

static PaError CheckParams(const PaStreamParameters* p, int isInput)
{
    if (!p) {
        return paNoError;
    }
    if (p->device == paUseHostApiSpecificDeviceSpecification) {
        return paInvalidDevice;
    }
    if (p->device != 0) {
        return paInvalidDevice;
    }
    if (p->channelCount < 1 || p->channelCount > IOS_MAX_CHANNELS) {
        return paInvalidChannelCount;
    }
    if (p->hostApiSpecificStreamInfo) {
        return paIncompatibleHostApiSpecificStreamInfo;
    }
    (void)isInput;
    return paNoError;
}

static PaError IsFormatSupported(struct PaUtilHostApiRepresentation* hostApi,
                                 const PaStreamParameters* inputParameters,
                                 const PaStreamParameters* outputParameters,
                                 double sampleRate)
{
    (void)hostApi;
    PaError err;
    if ((err = CheckParams(inputParameters, 1)) != paNoError) {
        return err;
    }
    if ((err = CheckParams(outputParameters, 0)) != paNoError) {
        return err;
    }
    if (sampleRate < 8000.0 || sampleRate > 192000.0) {
        return paInvalidSampleRate;
    }
    return paFormatIsSupported;
}

/* --------------------------------------------------------------- render */

static PaTime HostTimeToSeconds(UInt64 hostTime)
{
    static mach_timebase_info_data_t tb;
    if (tb.denom == 0) {
        mach_timebase_info(&tb);
    }
    return (PaTime)hostTime * tb.numer / tb.denom / 1e9;
}

static OSStatus RenderCallback(void* inRefCon,
                               AudioUnitRenderActionFlags* ioActionFlags,
                               const AudioTimeStamp* inTimeStamp,
                               UInt32 inBusNumber,
                               UInt32 inNumberFrames,
                               AudioBufferList* ioData)
{
    (void)inBusNumber;
    PaIosStream* st = (PaIosStream*)inRefCon;

    if (st->stopRequested || !st->isActive) {
        if (ioData) {
            for (UInt32 i = 0; i < ioData->mNumberBuffers; ++i) {
                memset(ioData->mBuffers[i].mData, 0, ioData->mBuffers[i].mDataByteSize);
            }
            *ioActionFlags |= kAudioUnitRenderAction_OutputIsSilence;
        }
        return noErr;
    }

    PaUtil_BeginCpuLoadMeasurement(&st->cpuLoadMeasurer);

    PaStreamCallbackFlags statusFlags = 0;
    const float* input = NULL;
    if (st->inputChannels > 0) {
        UInt32 frames = inNumberFrames > st->maxFrames ? st->maxFrames : inNumberFrames;
        st->inputList.mNumberBuffers = 1;
        st->inputList.mBuffers[0].mNumberChannels = (UInt32)st->inputChannels;
        st->inputList.mBuffers[0].mDataByteSize = frames * sizeof(float) * (UInt32)st->inputChannels;
        st->inputList.mBuffers[0].mData = st->inputBuffer;
        AudioUnitRenderActionFlags f = 0;
        OSStatus r = AudioUnitRender(st->unit, &f, inTimeStamp, IOS_INPUT_BUS, frames, &st->inputList);
        if (r == noErr) {
            input = st->inputBuffer;
        } else {
            memset(st->inputBuffer, 0, frames * sizeof(float) * (UInt32)st->inputChannels);
            input = st->inputBuffer;
            statusFlags |= paInputUnderflow;
        }
    }

    PaStreamCallbackTimeInfo timeInfo;
    PaTime now = HostTimeToSeconds(inTimeStamp->mHostTime);
    timeInfo.currentTime = now;
    timeInfo.inputBufferAdcTime = now - [AVAudioSession sharedInstance].inputLatency;
    timeInfo.outputBufferDacTime = now + [AVAudioSession sharedInstance].outputLatency;

    PaUtil_BeginBufferProcessing(&st->bufferProcessor, &timeInfo, statusFlags);

    if (st->inputChannels > 0) {
        PaUtil_SetInputFrameCount(&st->bufferProcessor, inNumberFrames);
        PaUtil_SetInterleavedInputChannels(&st->bufferProcessor, 0, (void*)input, st->inputChannels);
    }
    if (st->outputChannels > 0 && ioData) {
        PaUtil_SetOutputFrameCount(&st->bufferProcessor, inNumberFrames);
        PaUtil_SetInterleavedOutputChannels(&st->bufferProcessor, 0, ioData->mBuffers[0].mData, st->outputChannels);
    }

    int callbackResult = paContinue;
    unsigned long framesProcessed = PaUtil_EndBufferProcessing(&st->bufferProcessor, &callbackResult);

    PaUtil_EndCpuLoadMeasurement(&st->cpuLoadMeasurer, framesProcessed);

    if (callbackResult != paContinue) {
        st->stopRequested = 1;
        PaIosStream* captured = st;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (captured->isActive) {
                AudioOutputUnitStop(captured->unit);
                captured->isActive = 0;
                captured->isStopped = 1;
                if (captured->streamRepresentation.streamFinishedCallback) {
                    captured->streamRepresentation.streamFinishedCallback(captured->streamRepresentation.userData);
                }
            }
        });
    }
    return noErr;
}

/* ---------------------------------------------------------------- open */

static PaError OpenStream(struct PaUtilHostApiRepresentation* hostApi,
                          PaStream** s,
                          const PaStreamParameters* inputParameters,
                          const PaStreamParameters* outputParameters,
                          double sampleRate,
                          unsigned long framesPerBuffer,
                          PaStreamFlags streamFlags,
                          PaStreamCallback* streamCallback,
                          void* userData)
{
    PaIosHostApi* api = (PaIosHostApi*)hostApi;
    PaError err;

    if (!streamCallback) {
        return paCanNotReadFromAnOutputOnlyStream; /* blocking i/o not supported */
    }
    if ((err = CheckParams(inputParameters, 1)) != paNoError) {
        return err;
    }
    if ((err = CheckParams(outputParameters, 0)) != paNoError) {
        return err;
    }
    if ((streamFlags & paPlatformSpecificFlags) != 0) {
        return paInvalidFlag;
    }

    int inCh = inputParameters ? inputParameters->channelCount : 0;
    int outCh = outputParameters ? outputParameters->channelCount : 0;

    @autoreleasepool {
        IosConfigureSession(sampleRate);
        if (inCh > 0) {
            int avail = IosSessionInputChannels();
            if (avail == 0) {
                return paDeviceUnavailable;
            }
        }
    }

    PaIosStream* st = (PaIosStream*)PaUtil_AllocateMemory(sizeof(PaIosStream));
    if (!st) {
        return paInsufficientMemory;
    }
    memset(st, 0, sizeof(*st));
    st->inputChannels = inCh;
    st->outputChannels = outCh;
    st->sampleRate = sampleRate;
    st->isStopped = 1;
    st->maxFrames = 4096;

    if (inCh > 0) {
        st->inputBuffer = (float*)PaUtil_AllocateMemory(st->maxFrames * sizeof(float) * (size_t)inCh);
        if (!st->inputBuffer) {
            PaUtil_FreeMemory(st);
            return paInsufficientMemory;
        }
    }

    PaUtil_InitializeStreamRepresentation(&st->streamRepresentation,
                                          &api->callbackStreamInterface, streamCallback, userData);
    PaUtil_InitializeCpuLoadMeasurer(&st->cpuLoadMeasurer, sampleRate);

    PaSampleFormat userIn = inputParameters ? inputParameters->sampleFormat : paFloat32;
    PaSampleFormat userOut = outputParameters ? outputParameters->sampleFormat : paFloat32;

    err = PaUtil_InitializeBufferProcessor(&st->bufferProcessor,
                                           inCh, userIn, paFloat32,
                                           outCh, userOut, paFloat32,
                                           sampleRate, streamFlags, framesPerBuffer,
                                           0, paUtilUnknownHostBufferSize,
                                           streamCallback, userData);
    if (err != paNoError) {
        PaUtil_FreeMemory(st->inputBuffer);
        PaUtil_FreeMemory(st);
        return err;
    }

    /* RemoteIO unit */
    AudioComponentDescription desc = { 0 };
    desc.componentType = kAudioUnitType_Output;
    desc.componentSubType = kAudioUnitSubType_RemoteIO;
    desc.componentManufacturer = kAudioUnitManufacturer_Apple;
    AudioComponent comp = AudioComponentFindNext(NULL, &desc);
    OSStatus r = comp ? AudioComponentInstanceNew(comp, &st->unit) : -1;
    if (r != noErr) {
        PaUtil_TerminateBufferProcessor(&st->bufferProcessor);
        PaUtil_FreeMemory(st->inputBuffer);
        PaUtil_FreeMemory(st);
        return paUnanticipatedHostError;
    }

    UInt32 one = 1, zero = 0;
    AudioUnitSetProperty(st->unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output,
                         IOS_OUTPUT_BUS, outCh > 0 ? &one : &zero, sizeof(UInt32));
    AudioUnitSetProperty(st->unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input,
                         IOS_INPUT_BUS, inCh > 0 ? &one : &zero, sizeof(UInt32));

    AudioStreamBasicDescription fmt = { 0 };
    fmt.mSampleRate = sampleRate;
    fmt.mFormatID = kAudioFormatLinearPCM;
    fmt.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    fmt.mFramesPerPacket = 1;
    fmt.mBitsPerChannel = 32;

    if (outCh > 0) {
        fmt.mChannelsPerFrame = (UInt32)outCh;
        fmt.mBytesPerFrame = fmt.mBytesPerPacket = 4 * (UInt32)outCh;
        AudioUnitSetProperty(st->unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input,
                             IOS_OUTPUT_BUS, &fmt, sizeof(fmt));
    }
    if (inCh > 0) {
        fmt.mChannelsPerFrame = (UInt32)inCh;
        fmt.mBytesPerFrame = fmt.mBytesPerPacket = 4 * (UInt32)inCh;
        AudioUnitSetProperty(st->unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output,
                             IOS_INPUT_BUS, &fmt, sizeof(fmt));
    }

    UInt32 maxFrames = st->maxFrames;
    AudioUnitSetProperty(st->unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global,
                         0, &maxFrames, sizeof(maxFrames));

    AURenderCallbackStruct cb = { RenderCallback, st };
    if (outCh > 0) {
        r = AudioUnitSetProperty(st->unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input,
                                 IOS_OUTPUT_BUS, &cb, sizeof(cb));
    } else {
        /* input only: get notified when input is available */
        r = AudioUnitSetProperty(st->unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global,
                                 IOS_INPUT_BUS, &cb, sizeof(cb));
    }
    if (r == noErr) {
        r = AudioUnitInitialize(st->unit);
    }
    if (r != noErr) {
        AudioComponentInstanceDispose(st->unit);
        PaUtil_TerminateBufferProcessor(&st->bufferProcessor);
        PaUtil_FreeMemory(st->inputBuffer);
        PaUtil_FreeMemory(st);
        return paUnanticipatedHostError;
    }

    double ioLatency = [AVAudioSession sharedInstance].IOBufferDuration;
    st->streamRepresentation.streamInfo.inputLatency = inCh > 0
        ? [AVAudioSession sharedInstance].inputLatency + ioLatency : 0;
    st->streamRepresentation.streamInfo.outputLatency = outCh > 0
        ? [AVAudioSession sharedInstance].outputLatency + ioLatency : 0;
    st->streamRepresentation.streamInfo.sampleRate = sampleRate;

    *s = (PaStream*)st;
    return paNoError;
}

/* -------------------------------------------------------------- control */

static PaError CloseStream(PaStream* s)
{
    PaIosStream* st = (PaIosStream*)s;
    if (st->unit) {
        AudioOutputUnitStop(st->unit);
        AudioUnitUninitialize(st->unit);
        AudioComponentInstanceDispose(st->unit);
    }
    PaUtil_TerminateBufferProcessor(&st->bufferProcessor);
    PaUtil_TerminateStreamRepresentation(&st->streamRepresentation);
    PaUtil_FreeMemory(st->inputBuffer);
    PaUtil_FreeMemory(st);
    return paNoError;
}

static PaError StartStream(PaStream* s)
{
    PaIosStream* st = (PaIosStream*)s;
    PaUtil_ResetBufferProcessor(&st->bufferProcessor);
    st->stopRequested = 0;
    st->isStopped = 0;
    st->isActive = 1;
    st->startHostTime = HostTimeToSeconds(mach_absolute_time());
    if (AudioOutputUnitStart(st->unit) != noErr) {
        st->isActive = 0;
        st->isStopped = 1;
        return paUnanticipatedHostError;
    }
    return paNoError;
}

static PaError StopStream(PaStream* s)
{
    PaIosStream* st = (PaIosStream*)s;
    AudioOutputUnitStop(st->unit);
    int wasActive = st->isActive;
    st->isActive = 0;
    st->isStopped = 1;
    if (wasActive && st->streamRepresentation.streamFinishedCallback) {
        st->streamRepresentation.streamFinishedCallback(st->streamRepresentation.userData);
    }
    return paNoError;
}

static PaError AbortStream(PaStream* s)
{
    return StopStream(s);
}

static PaError IsStreamStopped(PaStream* s)
{
    return ((PaIosStream*)s)->isStopped;
}

static PaError IsStreamActive(PaStream* s)
{
    PaIosStream* st = (PaIosStream*)s;
    return st->isActive && !st->stopRequested;
}

static PaTime GetStreamTime(PaStream* s)
{
    (void)s;
    return HostTimeToSeconds(mach_absolute_time());
}

static double GetStreamCpuLoad(PaStream* s)
{
    return PaUtil_GetCpuLoad(&((PaIosStream*)s)->cpuLoadMeasurer);
}
