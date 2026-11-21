// SoundCue iOS entry point. Rust (eframe + winit) owns UIApplicationMain.
#import <AVFoundation/AVFoundation.h>

extern void soundcue_start(void);

int main(int argc, char *argv[]) {
    @autoreleasepool {
        AVAudioSession *s = [AVAudioSession sharedInstance];
        NSError *err = nil;
        // Playback + recording, mixes with nothing, plays with the silent switch on.
        [s setCategory:AVAudioSessionCategoryPlayAndRecord
                  mode:AVAudioSessionModeDefault
               options:AVAudioSessionCategoryOptionDefaultToSpeaker |
                       AVAudioSessionCategoryOptionAllowBluetoothA2DP |
                       AVAudioSessionCategoryOptionAllowAirPlay
                 error:&err];
        if (err) NSLog(@"SoundCue: audio session category error %@", err);
        [s setActive:YES error:&err];
        if (err) NSLog(@"SoundCue: audio session activate error %@", err);
        soundcue_start();
    }
    return 0;
}
