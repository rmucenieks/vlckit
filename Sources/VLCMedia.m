/*****************************************************************************
 * VLCMedia.m: VLCKit.framework VLCMedia implementation
 *****************************************************************************
 * Copyright (C) 2007 Pierre d'Herbemont
 * Copyright (C) 2013, 2017 Felix Paul Kühne
 * Copyright (C) 2007, 2013 VLC authors and VideoLAN
 * $Id$
 *
 * Authors: Pierre d'Herbemont <pdherbemont # videolan.org>
 *          Felix Paul Kühne <fkuehne # videolan.org>
 *          Soomin Lee <TheHungryBu # gmail.com>
 *
 * This program is free software; you can redistribute it and/or modify it
 * under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation; either version 2.1 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this program; if not, write to the Free Software Foundation,
 * Inc., 51 Franklin Street, Fifth Floor, Boston MA 02110-1301, USA.
 *****************************************************************************/

#import <VLCMedia.h>
#import <VLCMediaList.h>
#import <VLCLibrary.h>
#import <VLCLibVLCBridging.h>
#import <VLCTime.h>
#import <VLCMediaMetaData.h>
#import <vlc/libvlc.h>
#import <sys/sysctl.h> // for sysctlbyname

/* Notification Messages */
NSString *const VLCMediaMetaChanged              = @"VLCMediaMetaChanged";

/******************************************************************************
 * VLC callbacks for streaming.
 */
int open_cb(void *opaque, void **datap, uint64_t *sizep) {
    NSInputStream *stream = (__bridge NSInputStream *)(opaque);
    
    *datap = opaque;
    *sizep = UINT64_MAX;
    
    // Once a stream is closed, it cannot be reopened.
    if (stream && stream.streamStatus == NSStreamStatusNotOpen) {
        [stream open];
        return 0;
    } else {
        return stream.streamStatus == NSStreamStatusOpen ? 0 : -1;
    }
}

ssize_t read_cb(void *opaque, unsigned char *buf, size_t len) {
    NSInputStream *stream = (__bridge NSInputStream *)(opaque);
    if (!stream) {
        return -1;
    }
    
    return [stream read:buf maxLength:len];
}

int seek_cb(void *opaque, uint64_t offset) {
    NSInputStream *stream = (__bridge NSInputStream *)(opaque);
    if (!stream) {
        return -1;
    }
    
    /*
     By default, NSStream instances that are not file-based are non-seekable, one-way streams (although custom seekable subclasses are possible).
     Once the data has been provided or consumed, the data cannot be retrieved from the stream.
     
     However, you may want a peer subclass to NSInputStream whose instances are capable of seeking through a stream.
     */
    return [stream setProperty:@(offset) forKey:NSStreamFileCurrentOffsetKey] ? 0 : -1;
}

void close_cb(void *opaque) {
    NSInputStream *stream = (__bridge NSInputStream *)(opaque);
    if (stream && stream.streamStatus != NSStreamStatusClosed && stream.streamStatus != NSStreamStatusNotOpen) {
        [stream close];
    }
    return;
}

/******************************************************************************
 * VLCMedia ()
 */
@interface VLCMedia()
{
    void *                  p_md;                   ///< Internal media descriptor instance
    BOOL                    eventsAttached;         ///< YES when events are attached
    NSInputStream           *stream;                ///< Stream object if instance is initialized via NSInputStream to pass to callbacks
}

/* Make our properties internally readwrite */
@property (nonatomic, readwrite, strong, nullable) VLCMediaList * subitems;

- (void)parseIfNeeded;

/* Callback Methods */
- (void)parsedChanged;
- (void)metaChanged:(const libvlc_meta_t)metaType;
- (void)subItemAdded;

@end

/******************************************************************************
 * LibVLC Event Callback
 */
static void HandleMediaMetaChanged(const libvlc_event_t * event, void * self)
{
    @autoreleasepool {
        VLCMedia *media = (__bridge VLCMedia *)self;
        const libvlc_meta_t meta_type = event->u.media_meta_changed.meta_type;
        dispatch_async(dispatch_get_main_queue(), ^{
            [media metaChanged: meta_type];
        });
    }
}

static void HandleMediaDurationChanged(const libvlc_event_t * event, void * self)
{
    @autoreleasepool {
        VLCMedia *media = (__bridge VLCMedia *)self;
        VLCTime *time = [VLCTime timeWithNumber: @(event->u.media_duration_changed.new_duration)];
        dispatch_async(dispatch_get_main_queue(), ^{
            [media setLength: time];
        });
    }
}

static void HandleMediaSubItemAdded(const libvlc_event_t * event, void * self)
{
    @autoreleasepool {
        VLCMedia *media = (__bridge VLCMedia *)self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [media subItemAdded];
        });
    }
}

static void HandleMediaParsedChanged(const libvlc_event_t * event, void * self)
{
    @autoreleasepool {
        VLCMedia *media = (__bridge VLCMedia *)self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [media parsedChanged];
        });
    }
}


/******************************************************************************
 * Implementation
 */
@implementation VLCMedia

+ (NSString *)codecNameForFourCC:(uint32_t)fourcc trackType:(VLCMediaTracksInformationType)trackType
{
    libvlc_track_type_t track_type = (libvlc_track_type_t)trackType;
    const char *ret = libvlc_media_get_codec_description(track_type, fourcc);
    return ret != NULL ? @(ret) : @"";
}

+ (instancetype)mediaWithURL:(NSURL *)anURL;
{
    return [[VLCMedia alloc] initWithURL:anURL];
}

+ (instancetype)mediaWithPath:(NSString *)aPath;
{
    return [[VLCMedia alloc] initWithPath:aPath];
}

+ (instancetype)mediaAsNodeWithName:(NSString *)aName;
{
    return [[VLCMedia alloc] initAsNodeWithName:aName];
}

- (instancetype)initWithPath:(NSString *)aPath
{
    return [self initWithURL:[NSURL fileURLWithPath:aPath isDirectory:NO]];
}

- (instancetype)initWithURL:(NSURL *)anURL
{
    if (self = [super init]) {
        const char *url;
        VLCLibrary *library = [VLCLibrary sharedLibrary];
        NSAssert(library.instance, @"no library instance when creating media");

        url = [[anURL absoluteString] UTF8String];

        p_md = libvlc_media_new_location(library.instance, url);

        [self initInternalMediaDescriptor];
    }
    return self;
}

- (instancetype)initWithStream:(NSInputStream *)stream
{
    if (self = [super init]) {
        VLCLibrary *library = [VLCLibrary sharedLibrary];
        NSAssert(library.instance, @"no library instance when creating media");
        NSAssert(stream.streamStatus != NSStreamStatusClosed, @"Passing closed stream to VLCMedia.init does not work");
        
        self->stream = stream;
        p_md = libvlc_media_new_callbacks(library.instance, open_cb, read_cb, seek_cb, close_cb, (__bridge void *)(stream));
        
        [self initInternalMediaDescriptor];
    }
    return self;
}

- (instancetype)initAsNodeWithName:(NSString *)aName
{
    if (self = [super init]) {
        p_md = libvlc_media_new_as_node([VLCLibrary sharedInstance], [aName UTF8String]);
        
        [self initInternalMediaDescriptor];
    }
    return self;
}

- (void)dealloc
{
    if (eventsAttached)
    {
        libvlc_event_manager_t * p_em = libvlc_media_event_manager(p_md);
        if (p_em) {
            libvlc_event_detach(p_em, libvlc_MediaMetaChanged,     HandleMediaMetaChanged,     (__bridge void *)(self));
            libvlc_event_detach(p_em, libvlc_MediaDurationChanged, HandleMediaDurationChanged, (__bridge void *)(self));
            libvlc_event_detach(p_em, libvlc_MediaSubItemAdded,    HandleMediaSubItemAdded,    (__bridge void *)(self));
            libvlc_event_detach(p_em, libvlc_MediaParsedChanged,    HandleMediaParsedChanged,   (__bridge void *)(self));
        }
    }

    if (p_md)
        libvlc_media_release(p_md);
}

- (VLCMediaType)mediaType
{
    libvlc_media_type_t libmediatype = libvlc_media_get_type(p_md);

    switch (libmediatype) {
        case libvlc_media_type_file:
            return VLCMediaTypeFile;
        case libvlc_media_type_directory:
            return VLCMediaTypeDirectory;
        case libvlc_media_type_disc:
            return VLCMediaTypeDisc;
        case libvlc_media_type_stream:
            return VLCMediaTypeStream;
        case libvlc_media_type_playlist:
            return VLCMediaTypePlaylist;

        default:
            return VLCMediaTypeUnknown;
    }
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@ %p>, md: %p, url: %@", [self class], self, p_md, [[_url absoluteString] stringByRemovingPercentEncoding]];
}

- (NSComparisonResult)compare:(nullable VLCMedia *)media
{
    if (self == media)
        return NSOrderedSame;
    if (!media)
        return NSOrderedDescending;
    return p_md == [media libVLCMediaDescriptor] ? NSOrderedSame : NSOrderedAscending;
}

- (BOOL)isEqual:(id)other
{
    return ([other isKindOfClass: [VLCMedia class]] &&
            [other libVLCMediaDescriptor] == p_md);
}

- (VLCTime *)length
{
    if (!_length) {
        // Try figuring out what the length is
        long long duration = libvlc_media_get_duration( p_md );
        if (duration < 0)
            return [VLCTime nullTime];
         _length = [VLCTime timeWithNumber:@(duration)];
    }
    return _length;
}

- (VLCTime *)lengthWaitUntilDate:(NSDate *)aDate
{
    static const long long thread_sleep = 10000;

    if (!_length) {
        // Force parsing of this item.
        [self parseIfNeeded];

        // wait until we are preparsed
       libvlc_media_parsed_status_t status = libvlc_media_get_parsed_status(p_md);
       while (!_length && !(status == VLCMediaParsedStatusFailed || status == VLCMediaParsedStatusDone) && [aDate timeIntervalSinceNow] > 0) {
          usleep( thread_sleep );
          status = libvlc_media_get_parsed_status(p_md);
       }

        // So we're done waiting, but sometimes we trap the fact that the parsing
        // was done before the length gets assigned, so lets go ahead and assign
        // it ourselves.
        if (!_length)
            return [self length];
    }

    return _length;
}

- (VLCMediaParsedStatus)parsedStatus
{
    if (!p_md)
        return VLCMediaParsedStatusFailed;
    libvlc_media_parsed_status_t status = libvlc_media_get_parsed_status(p_md);
    return (VLCMediaParsedStatus)status;
}

- (int)parseWithOptions:(VLCMediaParsingOptions)options timeout:(int)timeoutValue
{
    if (!p_md)
        return -1;

    // we are using the default time-out value
    return libvlc_media_parse_with_options(p_md,
                                           options,
                                           timeoutValue);
}

- (int)parseWithOptions:(VLCMediaParsingOptions)options
{
    if (!p_md)
        return -1;

    // we are using the default time-out value
    return libvlc_media_parse_with_options(p_md,
                                           options,
                                           -1);
}

- (void)parseStop
{
    if (p_md) {
        libvlc_media_parse_stop(p_md);
    }
}

- (void)addOption:(NSString *)option
{
    if (p_md) {
        libvlc_media_add_option(p_md, [option UTF8String]);
    }
}

- (void)addOptions:(NSDictionary*)options
{
    if (p_md) {
        [options enumerateKeysAndObjectsUsingBlock:^(NSString *key, id obj, BOOL *stop) {
            if (![obj isKindOfClass:[NSNull class]])
                libvlc_media_add_option(p_md, [[NSString stringWithFormat:@"%@=%@", key, obj] UTF8String]);
            else
                libvlc_media_add_option(p_md, [key UTF8String]);
        }];
    }
}

- (int)storeCookie:(NSString *)cookie
           forHost:(NSString *)host
              path:(NSString *)path
{
    if (!p_md || cookie == NULL || host == NULL || path == NULL) {
        return -1;
    }
#if TARGET_OS_IPHONE
    return libvlc_media_cookie_jar_store(p_md,
                                         [cookie UTF8String],
                                         [host UTF8String],
                                         [path UTF8String]);
#else
    return -1;
#endif
}

- (void)clearStoredCookies
{
    if (!p_md) {
        return;
    }

#if TARGET_OS_IPHONE
    libvlc_media_cookie_jar_clear(p_md);
#endif
}

- (VLCMediaFileStatReturnType)fileStatValueForType:(const VLCMediaFileStatType)type value:(uint64_t *)value
{
    if (!p_md || !value)
        return VLCMediaFileStatReturnTypeError;
    
    return libvlc_media_get_filestat(p_md, type, value);
}

- (nullable NSDictionary *)stats
{
    if (!p_md)
        return nil;

    libvlc_media_stats_t p_stats;
    libvlc_media_get_stats(p_md, &p_stats);

    return @{
        @"demuxBitrate" : @(p_stats.f_demux_bitrate),
        @"inputBitrate" : @(p_stats.f_input_bitrate),
        @"decodedAudio" : @(p_stats.i_decoded_audio),
        @"decodedVideo" : @(p_stats.i_decoded_video),
        @"demuxCorrupted" : @(p_stats.i_demux_corrupted),
        @"demuxDiscontinuity" : @(p_stats.i_demux_discontinuity),
        @"demuxReadBytes" : @(p_stats.i_demux_read_bytes),
        @"displayedPictures" : @(p_stats.i_displayed_pictures),
        @"lostAbuffers" : @(p_stats.i_lost_abuffers),
        @"lostPictures" : @(p_stats.i_lost_pictures),
        @"latePictures" : @(p_stats.i_late_pictures),
        @"playedAbuffers" : @(p_stats.i_played_abuffers),
        @"readBytes" : @(p_stats.i_read_bytes)
    };
}

- (NSInteger)numberOfReadBytesOnInput
{
    if (!p_md)
        return 0;

    libvlc_media_stats_t p_stats;
    libvlc_media_get_stats(p_md, &p_stats);

    return p_stats.i_read_bytes;
}

- (float)inputBitrate
{
    if (!p_md)
        return .0;

    libvlc_media_stats_t p_stats;
    libvlc_media_get_stats(p_md, &p_stats);

    return p_stats.f_input_bitrate;
}

- (NSInteger)numberOfReadBytesOnDemux
{
    if (!p_md)
        return 0;

    libvlc_media_stats_t p_stats;
    libvlc_media_get_stats(p_md, &p_stats);

    return p_stats.i_demux_read_bytes;
}

- (float)demuxBitrate
{
    if (!p_md)
        return .0;

    libvlc_media_stats_t p_stats;
    libvlc_media_get_stats(p_md, &p_stats);

    return p_stats.f_demux_bitrate;
}

- (NSInteger)numberOfDecodedVideoBlocks
{
    if (!p_md)
        return 0;

    libvlc_media_stats_t p_stats;
    libvlc_media_get_stats(p_md, &p_stats);

    return p_stats.i_decoded_video;
}

- (NSInteger)numberOfDecodedAudioBlocks
{
    if (!p_md)
        return 0;

    libvlc_media_stats_t p_stats;
    libvlc_media_get_stats(p_md, &p_stats);

    return p_stats.i_decoded_audio;
}

- (NSInteger)numberOfDisplayedPictures
{
    if (!p_md)
        return 0;

    libvlc_media_stats_t p_stats;
    libvlc_media_get_stats(p_md, &p_stats);

    return p_stats.i_displayed_pictures;
}

- (NSInteger)numberOfLostPictures
{
    if (!p_md)
        return 0;

    libvlc_media_stats_t p_stats;
    libvlc_media_get_stats(p_md, &p_stats);

    return p_stats.i_lost_pictures;
}

- (NSInteger)numberOfLatePictures
{
    if (!p_md)
        return 0;

    libvlc_media_stats_t p_stats;
    libvlc_media_get_stats(p_md, &p_stats);

    return p_stats.i_late_pictures;
}


- (NSInteger)numberOfPlayedAudioBuffers
{
    if (!p_md)
        return 0;

    libvlc_media_stats_t p_stats;
    libvlc_media_get_stats(p_md, &p_stats);

    return p_stats.i_played_abuffers;
}

- (NSInteger)numberOfLostAudioBuffers
{
    if (!p_md)
        return 0;

    libvlc_media_stats_t p_stats;
    libvlc_media_get_stats(p_md, &p_stats);

    return p_stats.i_lost_abuffers;
}

- (NSInteger)numberOfCorruptedDataPackets
{
    if (!p_md)
        return 0;

    libvlc_media_stats_t p_stats;
    libvlc_media_get_stats(p_md, &p_stats);

    return p_stats.i_demux_corrupted;
}

- (NSInteger)numberOfDiscontinuties
{
    if (!p_md)
        return 0;

    libvlc_media_stats_t p_stats;
    libvlc_media_get_stats(p_md, &p_stats);

    return p_stats.i_demux_discontinuity;
}

- (NSArray<VLCMediaTracksInformation *> *)tracksInformation
{
    NSMutableArray<VLCMediaTracksInformation *> *array = @[].mutableCopy;
    
    // 3 = (libvlc_track_audio = 0 | libvlc_track_video = 1 | libvlc_track_text = 2)
    for (int i = 0; i < 3; i++) {
        libvlc_track_type_t type = (libvlc_track_type_t)i;
        libvlc_media_tracklist_t *tracklist = libvlc_media_get_tracklist(p_md, type);
        
        size_t tracklistCount = libvlc_media_tracklist_count(tracklist);
        for (size_t j = 0; j < tracklistCount; j++) {
            libvlc_media_track_t *track = libvlc_media_tracklist_at(tracklist, j);
            VLCMediaTracksInformation *info = [[VLCMediaTracksInformation alloc] initWithMediaTrack: track];
            [array addObject: info];
        }
        
        libvlc_media_tracklist_delete(tracklist);
    }
    
    return array;
}

- (BOOL)isMediaSizeSuitableForDevice
{
#if TARGET_OS_IPHONE
    // Trigger parsing if needed
    VLCMediaParsedStatus parsedStatus = [self parsedStatus];
    if (parsedStatus == VLCMediaParsedStatusSkipped || parsedStatus == VLCMediaParsedStatusInit) {
        [self parseWithOptions:VLCMediaParseLocal|VLCMediaParseNetwork];
        sleep(2);
    }

    NSUInteger biggestWidth = 0;
    NSUInteger biggestHeight = 0;
    libvlc_media_track_t **tracksInfo;
    unsigned int count = libvlc_media_tracks_get(p_md, &tracksInfo);
    for (NSUInteger i = 0; i < count; i++) {
        switch (tracksInfo[i]->i_type) {
            case libvlc_track_video:
                if (tracksInfo[i]->video->i_width > biggestWidth)
                    biggestWidth = tracksInfo[i]->video->i_width;
                if (tracksInfo[i]->video->i_height > biggestHeight)
                    biggestHeight = tracksInfo[i]->video->i_height;
                break;
            default:
                break;
        }
    }

    if (biggestHeight > 0 && biggestWidth > 0) {
        size_t size;
        sysctlbyname("hw.machine", NULL, &size, NULL, 0);

        char *answer = malloc(size);
        sysctlbyname("hw.machine", answer, &size, NULL, 0);

        NSString *currentMachine = @(answer);
        free(answer);

        NSUInteger totalNumberOfPixels = biggestWidth * biggestHeight;

        if ([currentMachine hasPrefix:@"iPhone2"] || [currentMachine hasPrefix:@"iPhone3"] || [currentMachine hasPrefix:@"iPad1"] || [currentMachine hasPrefix:@"iPod3"] || [currentMachine hasPrefix:@"iPod4"]) {
            // iPhone 3GS, iPhone 4, first gen. iPad, 3rd and 4th generation iPod touch
            return (totalNumberOfPixels < 600000); // between 480p and 720p
        } else if ([currentMachine hasPrefix:@"iPhone4"] || [currentMachine hasPrefix:@"iPad3,1"] || [currentMachine hasPrefix:@"iPad3,2"] || [currentMachine hasPrefix:@"iPad3,3"] || [currentMachine hasPrefix:@"iPod4"] || [currentMachine hasPrefix:@"iPad2"] || [currentMachine hasPrefix:@"iPod5"]) {
            // iPhone 4S, iPad 2 and 3, iPod 4 and 5
            return (totalNumberOfPixels < 922000); // 720p
        } else {
            // iPhone 5, iPad 4
            return (totalNumberOfPixels < 2074000); // 1080p
        }
    }
#endif

    return YES;
}


/******************************************************************************
 * Implementation VLCMedia ()
 */
- (void)initInternalMediaDescriptor
{
    _metaData = [[VLCMediaMetaData alloc] initWithMedia: self];
    
    char * p_url = libvlc_media_get_mrl( p_md );
    if (!p_url)
        return;

    NSString *urlString = [NSString stringWithUTF8String:p_url];
    if (!urlString) {
        free(p_url);
        return;
    }

    _url = [NSURL URLWithString:urlString];
    if (!_url) /* Attempt to interpret as a file path then */ {
         _url = [NSURL fileURLWithPath:urlString];
         if(!_url) {
             free(p_url);
             return;
         }
    }
    free(p_url);

    libvlc_media_set_user_data(p_md, (__bridge void*)self);

    libvlc_event_manager_t * p_em = libvlc_media_event_manager( p_md );
    if (p_em) {
        libvlc_event_attach(p_em, libvlc_MediaMetaChanged,     HandleMediaMetaChanged,     (__bridge void *)(self));
        libvlc_event_attach(p_em, libvlc_MediaDurationChanged, HandleMediaDurationChanged, (__bridge void *)(self));
        libvlc_event_attach(p_em, libvlc_MediaSubItemAdded,    HandleMediaSubItemAdded,    (__bridge void *)(self));
        libvlc_event_attach(p_em, libvlc_MediaParsedChanged,    HandleMediaParsedChanged,   (__bridge void *)(self));
        eventsAttached = YES;
    }

    libvlc_media_list_t * p_mlist = libvlc_media_subitems( p_md );

    if (p_mlist) {
        self.subitems = [VLCMediaList mediaListWithLibVLCMediaList:p_mlist];
        libvlc_media_list_release( p_mlist );
    }
}

- (void)parseIfNeeded
{
    VLCMediaParsedStatus parsedStatus = [self parsedStatus];
    if (parsedStatus == VLCMediaParsedStatusSkipped || parsedStatus == VLCMediaParsedStatusInit)
        [self parseWithOptions:VLCMediaParseLocal | VLCMediaFetchLocal];
}

- (void)metaChanged:(const libvlc_meta_t)metaType
{
    [self.metaData handleMediaMetaChanged: metaType];

    if ([_delegate respondsToSelector:@selector(mediaMetaDataDidChange:)])
        [_delegate mediaMetaDataDidChange:self];
}

- (void)subItemAdded
{
    if (_subitems)
        return; /* Nothing to do */

    libvlc_media_list_t * p_mlist = libvlc_media_subitems( p_md );

    NSAssert( p_mlist, @"The mlist shouldn't be nil, we are receiving a subItemAdded");

    self.subitems = [VLCMediaList mediaListWithLibVLCMediaList:p_mlist];

    libvlc_media_list_release( p_mlist );
}

- (void)parsedChanged
{
    [self willChangeValueForKey:@"parsedStatus"];
    [self parsedStatus];
    [self didChangeValueForKey:@"parsedStatus"];
    
    if ([_delegate respondsToSelector:@selector(mediaDidFinishParsing:)])
        [_delegate mediaDidFinishParsing:self];
}

@end

/******************************************************************************
 * Implementation VLCMedia (LibVLCBridging)
 */
@implementation VLCMedia (LibVLCBridging)

+ (id)mediaWithLibVLCMediaDescriptor:(void *)md
{
    return [[VLCMedia alloc] initWithLibVLCMediaDescriptor:md];
}

+ (id)mediaWithMedia:(VLCMedia *)media andLibVLCOptions:(NSDictionary *)options
{
    libvlc_media_t * p_md;
    p_md = libvlc_media_duplicate([media libVLCMediaDescriptor]);

    for (NSString * key in [options allKeys]) {
        if (options[key] != [NSNull null])
            libvlc_media_add_option(p_md, [[NSString stringWithFormat:@"%@=%@", key, options[key]] UTF8String]);
        else
            libvlc_media_add_option(p_md, [[NSString stringWithFormat:@"%@", key] UTF8String]);
    }
    return [VLCMedia mediaWithLibVLCMediaDescriptor:p_md];
}

- (id)initWithLibVLCMediaDescriptor:(void *)md
{
    if (self = [super init]) {
        libvlc_media_retain(md);
        p_md = md;
        
        [self initInternalMediaDescriptor];
    }
    return self;
}

- (void *)libVLCMediaDescriptor
{
    return p_md;
}


@end


/******************************************************************************
 * Implementation VLCMediaTracksInformation
 */
@implementation VLCMediaTracksInformation

- (instancetype)initWithMediaTrack:(libvlc_media_track_t *)track
{
    if (self = [super init]) {
        _type = (VLCMediaTracksInformationType)track->i_type;
        _codec = track->i_codec;
        _fourcc = track->i_original_fourcc;
        _identifier = track->i_id;
        _profile = track->i_profile;
        _level = track->i_level;
        _bitrate = track->i_bitrate;
        
        if (track->psz_language)
            _language = @(track->psz_language);
        
        if (track->psz_description)
            _trackDescription = @(track->psz_description);
        
        if (track->i_type == libvlc_track_audio && track->audio)
            _audio = [[VLCMediaTracksInformationAudio alloc] initWithAudioTrack: track->audio];
        else if (track->i_type == libvlc_track_video && track->video)
            _video = [[VLCMediaTracksInformationVideo alloc] initWithVideoTrack: track->video];
        else if (track->i_type == libvlc_track_text && track->subtitle)
            _text = [[VLCMediaTracksInformationText alloc] initWithSubtitleTrack: track->subtitle];
    }
    return self;
}

- (NSString *)codecName
{
    return [VLCMedia codecNameForFourCC: _fourcc trackType: _type];
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@ %p>, codec: %d, fourcc: %d, codecName: %@, identifier: %d, profile: %d, level: %d, bitrate: %d, language: %@, trackDescription: %@, audio: %@, video: %@, text: %@", [self class], self, _codec, _fourcc, [self codecName], _identifier, _profile, _level, _bitrate, _language, _trackDescription, [_audio description], [_video description], [_text description]];
}

@end


/******************************************************************************
 * Implementation VLCMediaTracksInformationAudio
 */
@implementation VLCMediaTracksInformationAudio

- (instancetype)initWithAudioTrack:(libvlc_audio_track_t *)audio
{
    if (self = [super init]) {
        _channelsNumber = audio->i_channels;
        _rate = audio->i_rate;
    }
    return self;
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@ %p>, channelsNumber: %d, rate: %d", [self class], self, _channelsNumber, _rate];
}

@end


/******************************************************************************
 * Implementation VLCMediaTracksInformationVideo
 */
@implementation VLCMediaTracksInformationVideo

- (instancetype)initWithVideoTrack:(libvlc_video_track_t *)video
{
    if (self = [super init]) {
        _width = video->i_width;
        _height = video->i_height;
        _orientation = (VLCMediaOrientation)video->i_orientation;
        _projection = (VLCMediaProjection)video->i_projection;
        _sourceAspectRatio = video->i_sar_num;
        _sourceAspectRatioDenominator = video->i_sar_den;
        _frameRate = video->i_frame_rate_num;
        _frameRateDenominator = video->i_frame_rate_den;
    }
    return self;
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@ %p>, width: %d, height: %d, orientation: %lu, projection: %lu, sourceAspectRatio: %d, sourceAspectRatioDenominator: %d, frameRate: %d, frameRateDenominator: %d", [self class], self, _width, _height, _orientation, _projection, _sourceAspectRatio, _sourceAspectRatioDenominator, _frameRate, _frameRateDenominator];
}

@end


/******************************************************************************
 * Implementation VLCMediaTracksInformationText
 */
@implementation VLCMediaTracksInformationText

- (instancetype)initWithSubtitleTrack:(libvlc_subtitle_track_t *)subtitle
{
    if (self = [super init]) {
        if (subtitle->psz_encoding)
            _encoding = @(subtitle->psz_encoding);
    }
    return self;
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@ %p>, encoding: %@", [self class], self, _encoding];
}

@end
