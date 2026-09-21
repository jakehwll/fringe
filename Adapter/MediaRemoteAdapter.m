// Loaded into /usr/bin/perl, not into Fringe.
//
// macOS gates MediaRemote's now-playing metadata: an ordinary third-party app
// gets nil back from MRMediaRemoteGetNowPlayingInfo no matter what is playing.
// The gate is on the calling *process*, and Perl is an Apple-signed system
// binary, so the same calls succeed from inside it.
//
// Perl's DynaLoader installs an exported symbol as an XSUB and calls it with
// (interpreter, cv). Neither is touched here — arguments arrive through the
// environment instead, which keeps this free of any Perl API.
//
// Results are written to stdout as one JSON object per line.

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdlib.h>
#include <unistd.h>

typedef void (*MRGetNowPlayingInfo)(dispatch_queue_t, void (^)(CFDictionaryRef));
typedef void (*MRGetIsPlaying)(dispatch_queue_t, void (^)(BOOL));
typedef void (*MRRegisterForNotifications)(dispatch_queue_t);
typedef Boolean (*MRSendCommand)(uint32_t, CFDictionaryRef);

/// Fingerprint of the artwork last sent. File scope rather than an
/// out-parameter: ARC treats `NSString **` as `__autoreleasing` and refuses
/// the address of a static.
static NSString *AdapterLastArtwork = nil;

static void *AdapterMediaRemote(void) {
    static void *handle;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        handle = dlopen(
            "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
            RTLD_LAZY
        );
    });
    return handle;
}

static void *AdapterSymbol(const char *name) {
    void *handle = AdapterMediaRemote();
    return handle ? dlsym(handle, name) : NULL;
}

static void AdapterEmit(NSDictionary *payload) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:payload options:0 error:NULL];
    if (!json) return;

    fwrite(json.bytes, 1, json.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

/// Artwork is ~100KB of base64. It is only worth sending when it actually
/// changes, so every payload carries a cheap fingerprint and the bytes ride
/// along only when that fingerprint moves.
static NSString *AdapterArtworkFingerprint(NSData *artwork) {
    if (!artwork.length) return nil;
    return [NSString stringWithFormat:@"%lu-%lu",
            (unsigned long)artwork.length,
            (unsigned long)artwork.hash];
}

static NSDictionary *AdapterSnapshot(NSDictionary *info, BOOL isPlaying) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];

    out[@"title"] = info[@"kMRMediaRemoteNowPlayingInfoTitle"] ?: @"";
    out[@"artist"] = info[@"kMRMediaRemoteNowPlayingInfoArtist"] ?: @"";
    out[@"album"] = info[@"kMRMediaRemoteNowPlayingInfoAlbum"] ?: @"";
    out[@"duration"] = info[@"kMRMediaRemoteNowPlayingInfoDuration"] ?: @0;
    out[@"elapsed"] = info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"] ?: @0;
    out[@"playbackRate"] = info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"] ?: @1;
    out[@"isPlaying"] = @(isPlaying);

    id timestamp = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
    if ([timestamp isKindOfClass:NSDate.class]) {
        out[@"timestamp"] = @([(NSDate *)timestamp timeIntervalSince1970]);
    }

    NSData *artwork = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
    NSString *fingerprint = AdapterArtworkFingerprint(artwork);
    if (fingerprint) {
        out[@"artworkID"] = fingerprint;
        if (![fingerprint isEqualToString:AdapterLastArtwork]) {
            out[@"artwork"] = [artwork base64EncodedStringWithOptions:0];
            AdapterLastArtwork = fingerprint;
        }
    } else {
        AdapterLastArtwork = nil;
    }

    return out;
}

static void AdapterFetch(void (^completion)(NSDictionary *)) {
    MRGetNowPlayingInfo getInfo =
        (MRGetNowPlayingInfo)AdapterSymbol("MRMediaRemoteGetNowPlayingInfo");
    MRGetIsPlaying getIsPlaying =
        (MRGetIsPlaying)AdapterSymbol("MRMediaRemoteGetNowPlayingApplicationIsPlaying");

    if (!getInfo || !getIsPlaying) {
        completion(nil);
        return;
    }

    getInfo(dispatch_get_main_queue(), ^(CFDictionaryRef raw) {
        NSDictionary *info = (__bridge NSDictionary *)raw;
        getIsPlaying(dispatch_get_main_queue(), ^(BOOL playing) {
            completion(info.count == 0 ? nil : AdapterSnapshot(info, playing));
        });
    });
}

#pragma mark - Entry points

/// Exits 0 only if metadata actually came back, which is what distinguishes a
/// working adapter from the entitlement gate returning empty results.
void adapter_test(void *interpreter, void *cv) {
    __block BOOL answered = NO;

    AdapterFetch(^(NSDictionary *snapshot) {
        answered = snapshot != nil;
        CFRunLoopStop(CFRunLoopGetMain());
    });

    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 3.0, false);
    exit(answered ? 0 : 1);
}

void adapter_get(void *interpreter, void *cv) {
    AdapterFetch(^(NSDictionary *snapshot) {
        AdapterEmit(snapshot ?: @{@"idle": @YES});
        CFRunLoopStop(CFRunLoopGetMain());
    });

    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 3.0, false);
    exit(0);
}

void adapter_stream(void *interpreter, void *cv) {
    MRRegisterForNotifications registerForNotifications =
        (MRRegisterForNotifications)AdapterSymbol("MRMediaRemoteRegisterForNowPlayingNotifications");
    if (registerForNotifications) {
        registerForNotifications(dispatch_get_main_queue());
    }

    void (^publish)(void) = ^{
        AdapterFetch(^(NSDictionary *snapshot) {
            AdapterEmit(snapshot ?: @{@"idle": @YES});
        });
    };

    NSArray<NSString *> *names = @[
        @"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
        @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
        @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
    ];
    for (NSString *name in names) {
        [NSNotificationCenter.defaultCenter addObserverForName:name
                                                        object:nil
                                                         queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(NSNotification *note) {
            publish();
        }];
    }

    // Occasional resync: elapsed time drifts, and a missed notification would
    // otherwise leave the panel stale indefinitely.
    [NSTimer scheduledTimerWithTimeInterval:5.0 repeats:YES block:^(NSTimer *timer) {
        publish();
    }];

    // Follow the app down. A killed parent reparents this process to launchd,
    // which is cheap to notice; the alternative is waiting for a write to the
    // closed stdout to raise SIGPIPE, which leaves an orphan alive in between
    // and not at all if the signal is ever handled.
    const pid_t parent = getppid();
    [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *timer) {
        if (getppid() != parent) exit(0);
    }];

    publish();
    CFRunLoopRun();
}

void adapter_send(void *interpreter, void *cv) {
    const char *raw = getenv("MEDIAREMOTEADAPTER_COMMAND");
    MRSendCommand send = (MRSendCommand)AdapterSymbol("MRMediaRemoteSendCommand");

    if (!raw || !send) exit(1);

    send((uint32_t)atoi(raw), NULL);
    // Give the command a moment to leave the process before exiting.
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.3, false);
    exit(0);
}
