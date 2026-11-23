#import <Foundation/Foundation.h>

// Pushes "something changed, ask again" to its handler: the shell's change notification
// (dev.mavergreen.container-tools.changed, posted by notifyutil), the vmware-vmx process exiting
// (kqueue NOTE_EXIT), system wake, and a one-shot timer the app re-arms after each overview.
// All callbacks fire on the main thread.
@interface MDWatchers : NSObject
- (instancetype)initWithOnChange:(void (^)(void))onChange;
- (void)start;
// Call when the VM is up to (re)arm the exit watch on `pid`; pass 0 to disarm.
- (void)watchVmxPid:(pid_t)pid;
// Fire the handler once, secs from now (replacing any earlier schedule).
- (void)scheduleNextIn:(NSTimeInterval)secs;
@end
