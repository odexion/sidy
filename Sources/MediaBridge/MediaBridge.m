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

/// Prints the current track as one JSON object: title, artist, album, playing, bundle, app.
void mb_info(void *perl, void *cv) {
    void (*getInfo)(dispatch_queue_t, void (^)(NSDictionary *)) = remote("MRMediaRemoteGetNowPlayingInfo");
    void (*getPlaying)(dispatch_queue_t, void (^)(BOOL)) = remote("MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    void (*getClient)(dispatch_queue_t, void (^)(id)) = remote("MRMediaRemoteGetNowPlayingClient");
    NSString *(*bundleOf)(id) = remote("MRNowPlayingClientGetBundleIdentifier");
    NSString *(*parentOf)(id) = remote("MRNowPlayingClientGetParentAppBundleIdentifier");
    NSString *(*nameOf)(id) = remote("MRNowPlayingClientGetDisplayName");
    if (!getInfo) return;

    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    NSMutableDictionary *result = [NSMutableDictionary dictionary];

    await(^(dispatch_block_t done) {
        getInfo(queue, ^(NSDictionary *info) {
            result[@"title"] = info[@"kMRMediaRemoteNowPlayingInfoTitle"];
            result[@"artist"] = info[@"kMRMediaRemoteNowPlayingInfoArtist"];
            result[@"album"] = info[@"kMRMediaRemoteNowPlayingInfoAlbum"];
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

    NSData *json = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    fwrite(json.bytes, 1, json.length, stdout);
    fflush(stdout);
}

static void send(int command) {
    Boolean (*sendCommand)(int, NSDictionary *) = remote("MRMediaRemoteSendCommand");
    if (!sendCommand) return;
    sendCommand(command, nil);
    // The command is delivered asynchronously; give it a moment before perl exits.
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
}

void mb_toggle(void *perl, void *cv) { send(2); }
void mb_next(void *perl, void *cv) { send(4); }
void mb_previous(void *perl, void *cv) { send(5); }
