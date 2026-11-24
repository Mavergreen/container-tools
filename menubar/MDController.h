#import <Foundation/Foundation.h>

// Bridges the app to the shell surface (docker-machine-ctl). Nothing here reads a file: the app
// asks overview-status and renders what it says.
// The path of a tool in this tree's bin/: beside the app (standalone archive), else the .pkg's install.
NSString *MDToolPath(NSString *name);

@interface MDController : NSObject

// Run a ctl verb asynchronously; `completion` is called on the main thread with the
// verb's stdout (trimmed) and exit code once it finishes.
- (void)runVerb:(NSString *)verb completion:(void (^)(NSString *out, int code))completion;
// The same, for a verb with arguments (e.g. @[@"autosize", @"on"]).
- (void)runArgs:(NSArray *)args completion:(void (^)(NSString *out, int code))completion;

// `docker-machine-ctl overview-status [--full]`, asynchronously; completion on the main thread with
// its stdout. Bounded by ctl to about 5 s.
- (void)fetchOverviewFull:(BOOL)full completion:(void (^)(NSString *output))completion;

@end
