#import "MDOverview.h"

@interface MDOverview ()
@property (readwrite, copy) NSString *state, *disk, *login, *image, *autosize, *autosizePending;
@property (readwrite) pid_t vmxPid;
@end

@implementation MDOverview

+ (instancetype)overviewFromOutput:(NSString *)out previous:(MDOverview *)prev {
  NSArray *lines = [out componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
  if (lines.count == 0 || ![lines[0] isEqualToString:@"version 1"]) return nil;
  MDOverview *o = [[MDOverview alloc] init];
  o.state = prev.state; o.disk = prev.disk; o.login = prev.login; o.image = prev.image; o.vmxPid = prev.vmxPid;
  o.autosize = prev.autosize; o.autosizePending = prev.autosizePending;
  // autosize-pending comes only with an autosize line; without one, nothing is held.
  if ([lines containsObject:@"autosize on"] || [lines containsObject:@"autosize off"]) o.autosizePending = nil;
  for (NSString *line in lines) {
    NSRange sp = [line rangeOfString:@" "];
    if (sp.location == NSNotFound) continue;
    NSString *key = [line substringToIndex:sp.location];
    NSString *val = [line substringFromIndex:sp.location + 1];
    if ([key isEqualToString:@"state"])        o.state = val;
    else if ([key isEqualToString:@"disk"])    o.disk = val;
    else if ([key isEqualToString:@"login"])   o.login = val;
    else if ([key isEqualToString:@"image"])   o.image = val;
    else if ([key isEqualToString:@"vmx-pid"]) o.vmxPid = (pid_t)[val integerValue];
    else if ([key isEqualToString:@"autosize"]) o.autosize = val;
    else if ([key isEqualToString:@"autosize-pending"]) o.autosizePending = val;
  }
  return o.state.length ? o : nil;
}

@end
