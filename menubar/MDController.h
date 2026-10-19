#import <Foundation/Foundation.h>

// Bridges the app to the Plan A shell surface (docker-machine-ctl) + the state file.
@interface MDController : NSObject

// The absolute path the state file lives at (also what MDWatchers watches).
@property (readonly) NSString *stateFilePath;

// Current status word, read from the state file (falls back to running `ctl status`
// if the file doesn't exist yet). One of: running/stopped/absent/creating/no-fusion/error.
- (NSString *)currentState;

// The VM's disk as the login agent's tick last cached it (`ctl disk-status`): "<total KB> <used KB>
// <avail KB> ok|low", or "unknown". A file read only, so it never waits on the VM.
- (NSString *)diskStatus;

// Run a ctl verb asynchronously; `completion` is called on the main thread with the
// verb's stdout (trimmed) and exit code once it finishes.
- (void)runVerb:(NSString *)verb completion:(void (^)(NSString *out, int code))completion;

// Convenience: the vmware-vmx pid (0 if none), via `ctl vmx-pid`. Synchronous, fast.
- (pid_t)vmxPid;

@end
