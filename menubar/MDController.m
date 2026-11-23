#import "MDController.h"

static NSString * const kCtl = @"/usr/local/mavergreen/container-tools/bin/docker-machine-ctl";

@implementation MDController

- (NSString *)runArgsSync:(NSArray *)args out:(int *)codeOut {
  NSTask *t = [[NSTask alloc] init];
  t.launchPath = kCtl;
  t.arguments = args;
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
    NSString *out = [self runArgsSync:@[verb] out:&code];
    dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(out, code); });
  });
}

- (void)fetchOverviewFull:(BOOL)full completion:(void (^)(NSString *))completion {
  NSArray *args = full ? @[@"overview-status", @"--full"] : @[@"overview-status"];
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    NSString *out = [self runArgsSync:args out:NULL];
    dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(out); });
  });
}

@end
