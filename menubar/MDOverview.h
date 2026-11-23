#import <Foundation/Foundation.h>

// What `docker-machine-ctl overview-status` said, parsed. The shell decides every field; the app
// only renders them. A line the overview left out keeps the previous overview's value.
@interface MDOverview : NSObject
@property (readonly, copy) NSString *state;   // running | finishing-setup | needs-attention | stopped | ...
@property (readonly, copy) NSString *disk;    // "<total KB> <used KB> <avail KB> ok|low" | "unknown" | nil
@property (readonly, copy) NSString *login;   // on | off
@property (readonly, copy) NSString *image;   // current | stale | absent | nil (not asked yet)
@property (readonly) pid_t vmxPid;            // 0 when none
// nil unless the first line is "version 1".
+ (instancetype)overviewFromOutput:(NSString *)out previous:(MDOverview *)prev;
@end
