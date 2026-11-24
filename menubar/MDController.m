#import "MDController.h"

// A tool of this tree's bin/. In the standalone archive the app sits beside bin/ (<tree>/<Name>.app),
// so look there first; the .pkg installs the app in /Applications and the tree at its install location.
NSString *MDToolPath(NSString *name) {
  NSString *tree = [[[NSBundle mainBundle] bundlePath] stringByDeletingLastPathComponent];
  NSString *beside = [[tree stringByAppendingPathComponent:@"bin"] stringByAppendingPathComponent:name];
  if ([[NSFileManager defaultManager] isExecutableFileAtPath:beside]) return beside;
  return [@"/usr/local/mavergreen/container-tools/bin" stringByAppendingPathComponent:name];
}
// overview-status bounds itself to a few seconds; this is the backstop if it ever hangs (a
// docker-machine stuck in the kernel), so one stuck fetch can't freeze the menu for good.
static const int64_t kFetchTimeout = 30;   // a full overview on a loaded 10.9 box measured 8-10 s

@implementation MDController

- (NSString *)runArgsSync:(NSArray *)args out:(int *)codeOut {
  return [self runArgsSync:args out:codeOut timeout:0];
}
- (NSString *)runArgsSync:(NSArray *)args out:(int *)codeOut timeout:(int64_t)secs {
  NSTask *t = [[NSTask alloc] init];
  t.launchPath = MDToolPath(@"docker-machine-ctl");
  t.arguments = args;
  NSPipe *pipe = [NSPipe pipe];
  t.standardOutput = pipe;
  t.standardError = [NSPipe pipe];
  NSString *out = @"";
  @try {
    [t launch];
    if (secs > 0)
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, secs * NSEC_PER_SEC),
                     dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        if (t.isRunning) [t terminate];
      });
    NSData *d = [[pipe fileHandleForReading] readDataToEndOfFile];
    [t waitUntilExit];
    if (codeOut) *codeOut = t.terminationStatus;
    out = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
  } @catch (NSException *e) {
    if (codeOut) *codeOut = 127;   // ctl missing / not runnable
  }
  return [out stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

- (void)runVerb:(NSString *)verb completion:(void (^)(NSString *, int))completion {
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    int code = 0;
    NSString *out = [self runArgsSync:@[verb] out:&code];
    dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(out, code); });
  });
}

- (void)fetchOverviewFull:(BOOL)full completion:(void (^)(NSString *))completion {
  NSArray *args = full ? @[@"overview-status", @"--full"] : @[@"overview-status"];
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    NSString *out = [self runArgsSync:args out:NULL timeout:kFetchTimeout];
    dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(out); });
  });
}

@end
