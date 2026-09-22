#import "MDController.h"

static NSString * const kCtl = @"/usr/local/bin/docker-machine-ctl";

@implementation MDController

- (NSString *)stateFilePath {
  NSString *base = [NSHomeDirectory()
    stringByAppendingPathComponent:@"Library/Application Support/Mavergreen/container-tools"];
  return [base stringByAppendingPathComponent:@"state"];
}

- (NSString *)currentState {
  NSString *s = [NSString stringWithContentsOfFile:self.stateFilePath
                                          encoding:NSUTF8StringEncoding error:NULL];
  s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if (s.length) return s;
  // Seed synchronously the first time (no state file yet).
  return [self runVerbSync:@"status" out:NULL];
}

- (NSString *)runVerbSync:(NSString *)verb out:(int *)codeOut {
  NSTask *t = [[NSTask alloc] init];
  t.launchPath = kCtl;
  t.arguments = @[verb];
  NSPipe *pipe = [NSPipe pipe];
  t.standardOutput = pipe;
  t.standardError = [NSPipe pipe];
  NSString *out = @"";
  @try {
    [t launch];
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
    NSString *out = [self runVerbSync:verb out:&code];
    dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(out, code); });
  });
}

- (pid_t)vmxPid {
  NSString *s = [self runVerbSync:@"vmx-pid" out:NULL];
  return (pid_t)[s integerValue];   // 0 when empty
}

@end
