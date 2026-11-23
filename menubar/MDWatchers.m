#import "MDWatchers.h"
#import <AppKit/AppKit.h>
#import <notify.h>

@interface MDWatchers () {
  void (^_onChange)(void);
  dispatch_source_t _procSrc;   // vmx NOTE_EXIT
  dispatch_source_t _timerSrc;  // next scheduled check
  id _wakeObserver;             // NSWorkspace wake token
  int _notifyToken;
  BOOL _notifyRegistered;
}
@end

static const char kChanged[] = "dev.mavergreen.container-tools.changed";

@implementation MDWatchers

- (instancetype)initWithOnChange:(void (^)(void))onChange {
  if ((self = [super init])) { _onChange = [onChange copy]; }
  return self;
}

- (void)fire { if (_onChange) _onChange(); }

- (void)start {
  __weak MDWatchers *weak = self;
  // The shell's announce (notifyutil -p) after every change it makes.
  if (notify_register_dispatch(kChanged, &_notifyToken, dispatch_get_main_queue(), ^(int t) {
        [weak fire];
      }) == NOTIFY_STATUS_OK)
    _notifyRegistered = YES;
  _timerSrc = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
  dispatch_source_set_timer(_timerSrc, DISPATCH_TIME_FOREVER, DISPATCH_TIME_FOREVER, 0);
  dispatch_source_set_event_handler(_timerSrc, ^{ [weak fire]; });
  dispatch_resume(_timerSrc);
  _wakeObserver = [[[NSWorkspace sharedWorkspace] notificationCenter]
      addObserverForName:NSWorkspaceDidWakeNotification
      object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) { [weak fire]; }];
}

- (void)scheduleNextIn:(NSTimeInterval)secs {
  if (!_timerSrc) return;
  dispatch_source_set_timer(_timerSrc, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(secs * NSEC_PER_SEC)),
                            DISPATCH_TIME_FOREVER, (uint64_t)(0.1 * secs * NSEC_PER_SEC));
}

- (void)dealloc {
  if (_notifyRegistered) notify_cancel(_notifyToken);
  if (_procSrc) dispatch_source_cancel(_procSrc);
  if (_timerSrc) dispatch_source_cancel(_timerSrc);
  if (_wakeObserver) [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:_wakeObserver];
}

- (void)watchVmxPid:(pid_t)pid {
  if (_procSrc) { dispatch_source_cancel(_procSrc); _procSrc = nil; }
  if (pid <= 0) return;
  _procSrc = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, (uintptr_t)pid,
      DISPATCH_PROC_EXIT, dispatch_get_main_queue());
  __weak MDWatchers *weak = self;
  dispatch_source_set_event_handler(_procSrc, ^{
    MDWatchers *me = weak; if (!me) return;
    // Stop watching this pid BEFORE notifying. _onChange leads to applyOverview: -> watchVmxPid:, which
    // cancels+nils _procSrc; doing that first and then touching me->_procSrc here would call
    // dispatch_source_cancel(NULL) -> crash. Snapshot the source, clear the ivar, cancel the
    // snapshot, then notify (the re-entrant watchVmxPid: now sees a nil _procSrc and no-ops).
    dispatch_source_t src = me->_procSrc;
    me->_procSrc = nil;
    if (src) dispatch_source_cancel(src);
    if (me->_onChange) me->_onChange();
  });
  dispatch_resume(_procSrc);
}

@end
