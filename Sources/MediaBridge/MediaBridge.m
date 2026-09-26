#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include "MediaBridge.h"

static void *remote(const char *symbol) {
    static void *handle;
    if (!handle) handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
    return handle ? dlsym(handle, symbol) : NULL;
}

static void await(void (^body)(dispatch_block_t done)) {
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    body(^{ dispatch_semaphore_signal(semaphore); });
    dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
}

/// The current track: title, artist, album, duration, elapsed, timestamp, playing, bundle, app,
/// plus the artwork (base64) unless `have` already names this track ("title\x1Fartist").
static NSDictionary *snapshot(NSString *have) {
    void (*getInfo)(dispatch_queue_t, void (^)(NSDictionary *)) = remote("MRMediaRemoteGetNowPlayingInfo");
    void (*getPlaying)(dispatch_queue_t, void (^)(BOOL)) = remote("MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    void (*getClient)(dispatch_queue_t, void (^)(id)) = remote("MRMediaRemoteGetNowPlayingClient");
    NSString *(*bundleOf)(id) = remote("MRNowPlayingClientGetBundleIdentifier");
    NSString *(*parentOf)(id) = remote("MRNowPlayingClientGetParentAppBundleIdentifier");
    NSString *(*nameOf)(id) = remote("MRNowPlayingClientGetDisplayName");
    if (!getInfo) return nil;

    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    NSMutableDictionary *result = [NSMutableDictionary dictionary];

    await(^(dispatch_block_t done) {
        getInfo(queue, ^(NSDictionary *info) {
            result[@"title"] = info[@"kMRMediaRemoteNowPlayingInfoTitle"];
            result[@"artist"] = info[@"kMRMediaRemoteNowPlayingInfoArtist"];
            result[@"album"] = info[@"kMRMediaRemoteNowPlayingInfoAlbum"];
            result[@"duration"] = info[@"kMRMediaRemoteNowPlayingInfoDuration"];
            result[@"elapsed"] = info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"];
            NSDate *timestamp = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
            if (timestamp) result[@"timestamp"] = @(timestamp.timeIntervalSince1970);
            NSString *title = info[@"kMRMediaRemoteNowPlayingInfoTitle"];
            NSData *artwork = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
            NSString *key = [NSString stringWithFormat:@"%@\x1F%@", title ?: @"", info[@"kMRMediaRemoteNowPlayingInfoArtist"] ?: @""];
            if (title.length && artwork.length && ![key isEqualToString:have ?: @""])
                result[@"artwork"] = [artwork base64EncodedStringWithOptions:0];
            done();
        });
    });
    if (getPlaying) await(^(dispatch_block_t done) {
        getPlaying(queue, ^(BOOL playing) { result[@"playing"] = @(playing); done(); });
    });
    if (getClient) await(^(dispatch_block_t done) {
        getClient(queue, ^(id client) {
            if (client) {
                NSString *parent = parentOf ? parentOf(client) : nil;
                result[@"bundle"] = parent ?: (bundleOf ? bundleOf(client) : nil);
                result[@"app"] = nameOf ? nameOf(client) : nil;
            }
            done();
        });
    });
    return result;
}

static void print(NSDictionary *object) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:object ?: @{} options:0 error:nil];
    fwrite(json.bytes, 1, json.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

void mb_info(void *perl, void *cv) {
    const char *have = getenv("MB_ARTWORK_HAVE");
    print(snapshot(have ? @(have) : nil));
}

/// Prints a snapshot line whenever the track, player or playback state changes, and every ten seconds
/// to keep the position in step. Runs until the app's end of stdin closes, so it never outlives Sidy.
void mb_stream(void *perl, void *cv) {
    void (*registerFor)(dispatch_queue_t) = remote("MRMediaRemoteRegisterForNowPlayingNotifications");
    if (!registerFor) return;
    registerFor(dispatch_get_main_queue());

    __block NSString *sent = nil;   // the track whose artwork was last printed
    __block BOOL pending = NO;
    // Changes arrive in bursts; one snapshot a moment later covers them all.
    dispatch_block_t schedule = ^{
        if (pending) return;
        pending = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            pending = NO;
            NSDictionary *state = snapshot(sent);
            if (state[@"artwork"]) sent = [NSString stringWithFormat:@"%@\x1F%@", state[@"title"] ?: @"", state[@"artist"] ?: @""];
            print(state);
        });
    };

    for (NSString *name in @[@"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                             @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                             @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification"]) {
        [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *note) { schedule(); }];
    }

    dispatch_source_t input = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, STDIN_FILENO, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(input, ^{
        char buffer[64];
        if (read(STDIN_FILENO, buffer, sizeof buffer) <= 0) exit(0);
    });
    dispatch_resume(input);

    // The timer also keeps the run loop alive.
    [NSTimer scheduledTimerWithTimeInterval:10 repeats:YES block:^(NSTimer *timer) { schedule(); }];
    schedule();
    CFRunLoopRun();
}

// Commands are delivered asynchronously; give them a moment before perl exits.
static void settle(void) {
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
}

static void send(int command) {
    Boolean (*sendCommand)(int, NSDictionary *) = remote("MRMediaRemoteSendCommand");
    if (!sendCommand) return;
    sendCommand(command, nil);
    settle();
}

void mb_toggle(void *perl, void *cv) { send(2); }
void mb_next(void *perl, void *cv) { send(4); }
void mb_previous(void *perl, void *cv) { send(5); }

void mb_seek(void *perl, void *cv) {
    void (*setElapsed)(double) = remote("MRMediaRemoteSetElapsedTime");
    const char *value = getenv("MB_SEEK");
    if (!setElapsed || !value) return;
    setElapsed(atof(value));
    settle();
}
