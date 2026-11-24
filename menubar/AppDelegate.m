#import "AppDelegate.h"
#import "MDController.h"
#import "MDWatchers.h"
#import "MDLoginItem.h"
#import "MDOverview.h"

@interface AppDelegate () <NSMenuDelegate>
@property (strong) NSStatusItem *statusItem;
@property (strong) MDController *controller;
@property (strong) MDWatchers *watchers;
@property (strong) MDOverview *overview;   // what overview-status last said; nil until the first answer
@property (assign) BOOL fetching;            // an overview-status is running
@property (assign) BOOL fetchAgain;          // something changed while it ran: ask once more after
@property (strong) NSDate *lastFull;         // when overview-status --full (the image check) last ran
@end

// How often to ask again: quickly while things are changing, rarely when steady (a change made
// outside our tools, such as Fusion's window, shows within that).
static const NSTimeInterval kFastSecs = 2, kSlowSecs = 30;

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)note {
  self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSSquareStatusItemLength];
  self.controller = [[MDController alloc] init];

  static NSString * const kSeeded = @"MDLoginItemSeeded";
  if (![[NSUserDefaults standardUserDefaults] boolForKey:kSeeded]) {
    [MDLoginItem setEnabled:YES];
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:kSeeded];
  }

  [self render];   // "Checking Docker…" until the first overview arrives
  __weak AppDelegate *weak = self;
  self.watchers = [[MDWatchers alloc] initWithOnChange:^{ [weak requestOverview]; }];
  [self.watchers start];
  [self requestOverview];
}

static BOOL isUp(NSString *s) {   // the VM is powered on, whatever Docker's readiness
  return [s isEqualToString:@"running"] || [s isEqualToString:@"finishing-setup"] ||
         [s isEqualToString:@"needs-attention"];
}
static BOOL isChanging(NSString *s) {
  return s == nil || [s isEqualToString:@"finishing-setup"] || [s isEqualToString:@"creating"] ||
         [s hasPrefix:@"working:"];
}

// Ask overview-status, one at a time: a nudge that arrives while one runs asks once more after it.
- (void)requestOverview {
  if (self.fetching) { self.fetchAgain = YES; return; }
  self.fetching = YES;
  BOOL full = !self.lastFull || -[self.lastFull timeIntervalSinceNow] >= kSlowSecs;
  [self.controller fetchOverviewFull:full completion:^(NSString *out) {
    MDOverview *o = [MDOverview overviewFromOutput:out previous:self.overview];
    if (o) { self.overview = o; if (full) self.lastFull = [NSDate date]; }
    // An answer that doesn't parse (an older or missing ctl) won't fix itself in 2 s: ask slowly.
    BOOL parseFailed = (o == nil);
    self.fetching = NO;
    [self render];
    if (self.fetchAgain) { self.fetchAgain = NO; [self requestOverview]; return; }
    [self.watchers scheduleNextIn:(!parseFailed && isChanging(self.overview.state) ? kFastSecs : kSlowSecs)];
  }];
}
- (void)menuWillOpen:(NSMenu *)menu { [self requestOverview]; }

- (BOOL)diskLow {
  return isUp(self.overview.state) && [self.overview.disk hasSuffix:@" low"];
}

- (void)render {
  NSString *state = self.overview.state;   // nil: no answer yet
  if ([state isEqualToString:@"no-fusion"]) [self maybePromptForFusion];
  NSImage *icon = [self iconForState:state];
  icon.template = YES;
  [self.statusItem setImage:icon];
  [self.statusItem setToolTip:[self humanState:state]];
  [self.watchers watchVmxPid:(isUp(state) ? self.overview.vmxPid : 0)];
  [self rebuildMenuForState:state];
}

- (NSString *)humanState:(NSString *)s {
  // In-progress states read as verb phrases ("Stopping Docker…"), deliberately dropping the
  // "Docker: " status-label prefix the steady states use ("Docker: Stopped") — the action, not
  // the status, is what's current. Keep the two shapes distinct on purpose.
  if (s == nil) return @"Checking Docker…";
  if ([s hasPrefix:@"working:"]) {
    NSString *op = [s substringFromIndex:[@"working:" length]];
    if ([op isEqualToString:@"image-upgrade"]) return @"Updating VM image…";
    if ([op isEqualToString:@"start"])         return @"Starting Docker…";
    if ([op isEqualToString:@"stop"])          return @"Stopping Docker…";
    if ([op isEqualToString:@"restart"])       return @"Restarting Docker…";
    if ([op isEqualToString:@"free-space"])    return @"Freeing up space…";
    if ([op isEqualToString:@"auto-free"])     return @"Freeing up space…";
    if ([op isEqualToString:@"enlarge-disk"])  return @"Enlarging VM disk…";
    return @"Working…";
  }
  if ([s isEqualToString:@"running"])   return @"Docker: Running";
  if ([s isEqualToString:@"stopped"])   return @"Docker: Stopped";
  if ([s isEqualToString:@"finishing-setup"]) return @"Docker: Finishing setup…";
  if ([s isEqualToString:@"needs-attention"]) return @"Docker: Needs attention";
  if ([s isEqualToString:@"creating"])  return @"Docker: Starting…";
  if ([s isEqualToString:@"absent"])    return @"Docker: Not set up";
  if ([s isEqualToString:@"no-fusion"]) return @"VMware Fusion needed";
  if ([s isEqualToString:@"host-disk-full"])
    return self.overview.vmxPid > 0 ? @"Docker: Paused (Mac disk full)" : @"Docker: Stopped (Mac disk full)";
  return @"Docker: (error)";
}

- (void)rebuildMenuForState:(NSString *)state {
  // Into the same NSMenu, so a menu that is open while an overview arrives updates in place.
  NSMenu *m = self.statusItem.menu ?: [[NSMenu alloc] init];
  [m removeAllItems];
  m.delegate = self;

  NSMenuItem *header = [m addItemWithTitle:[self humanState:state] action:NULL keyEquivalent:@""];
  header.enabled = NO;
  if (isUp(state) || [state isEqualToString:@"stopped"]) {
    NSMenuItem *disk = [m addItemWithTitle:[self diskLineForState:(isUp(state) ? @"running" : state)] action:NULL keyEquivalent:@""];
    disk.enabled = NO;
    NSString *held = [self heldResizeLine];
    if (held) { NSMenuItem *h = [m addItemWithTitle:held action:NULL keyEquivalent:@""]; h.enabled = NO; }
  }
  [m addItem:[NSMenuItem separatorItem]];

  if ([state isEqualToString:@"no-fusion"]) {
    [m addItemWithTitle:@"Get VMware Fusion…" action:@selector(doGetFusion:) keyEquivalent:@""];
  } else if ([state isEqualToString:@"host-disk-full"] && self.overview.vmxPid > 0) {
    // VMware paused the VM and carries on by itself once there is room; nothing here would help.
    NSMenuItem *hint = [m addItemWithTitle:@"Free space on this Mac to resume" action:NULL keyEquivalent:@""];
    hint.enabled = NO;
  } else if ([state isEqualToString:@"host-disk-full"]) {
    // The VM is stopped: starting it was refused for want of room. Free some, then start it.
    NSMenuItem *hint = [m addItemWithTitle:@"Free space on this Mac, then start Docker" action:NULL keyEquivalent:@""];
    hint.enabled = NO;
    [m addItemWithTitle:@"Start Docker" action:@selector(doStart:) keyEquivalent:@""];
  } else if ([state isEqualToString:@"absent"] || [state isEqualToString:@"error"]) {
    [m addItemWithTitle:@"Set Up / Repair…" action:@selector(doSetup:) keyEquivalent:@""];
  } else if (state && ![state isEqualToString:@"creating"] && ![state hasPrefix:@"working"]) {
    if (isUp(state)) {
      if ([state isEqualToString:@"needs-attention"])
        [m addItemWithTitle:@"Repair Docker" action:@selector(doRepair:) keyEquivalent:@""];
      [m addItemWithTitle:@"Stop Docker" action:@selector(doStop:) keyEquivalent:@""];
      [m addItemWithTitle:@"Restart Docker" action:@selector(doRestart:) keyEquivalent:@""];
      [m addItemWithTitle:@"Free Up Space…" action:@selector(doFreeSpace:) keyEquivalent:@""];
      [m addItemWithTitle:@"Enlarge VM Disk…" action:@selector(doEnlargeDisk:) keyEquivalent:@""];
    } else {
      [m addItemWithTitle:@"Start Docker" action:@selector(doStart:) keyEquivalent:@""];
    }
    // Offer the roll onto the freshly-installed image when the VM is behind (images/containers/volumes
    // are preserved — they live on a separate disk). Drives docker-machine-ctl image-upgrade.
    if ([self.overview.image isEqualToString:@"stale"])
      [m addItemWithTitle:@"Update VM Image…" action:@selector(doImageUpgrade:) keyEquivalent:@""];
  }

  [m addItem:[NSMenuItem separatorItem]];
  [m addItemWithTitle:@"Show Log" action:@selector(showLog:) keyEquivalent:@""];
  [m addItemWithTitle:@"Show Diagnostics…" action:@selector(doDiagnostics:) keyEquivalent:@""];
  [m addItemWithTitle:@"Check for Updates…" action:@selector(checkForUpdates:) keyEquivalent:@""];

  [m addItem:[NSMenuItem separatorItem]];
  if (self.overview.autosize) {   // an older ctl says nothing about self-sizing: no item
    NSMenuItem *sz = [m addItemWithTitle:@"Size Automatically" action:@selector(toggleAutosize:) keyEquivalent:@""];
    sz.state = [self.overview.autosize isEqualToString:@"on"] ? NSOnState : NSOffState;
  }
  NSMenuItem *vmLogin = [m addItemWithTitle:@"Start Docker at Login"
                                     action:@selector(toggleVMLogin:) keyEquivalent:@""];
  vmLogin.state = [self.overview.login isEqualToString:@"on"] ? NSOnState : NSOffState;
  // No "Open at Login" toggle for the menu-bar app itself: it's redundant with the OS Login Items
  // pane (same LSSharedFileList the app self-seeds on first launch), and "Open" reads as nonsense
  // for a windowless status-bar app. Users manage the app's own login item in System Preferences.

  [m addItem:[NSMenuItem separatorItem]];
  [m addItemWithTitle:@"Quit Container Tools for Mavericks" action:@selector(terminate:) keyEquivalent:@""];

  for (NSMenuItem *it in m.itemArray) if (it.action && it.action != @selector(terminate:)) it.target = self;
  if (self.statusItem.menu != m) [self.statusItem setMenu:m];
}

- (void)notifyTitle:(NSString *)title text:(NSString *)text {
  NSUserNotification *n = [[NSUserNotification alloc] init];
  n.title = title;
  n.informativeText = text;
  [[NSUserNotificationCenter defaultUserNotificationCenter] deliverNotification:n];
}

- (void)runAndRefresh:(NSString *)verb {
  NSImage *icon = [self iconForState:@"working:"];
  icon.template = YES;
  [self.statusItem setImage:icon];
  [self.controller runVerb:verb completion:^(NSString *out, int code) {
    [self notifyForVerb:verb code:code out:out];
    // These change the disk: make the next overview a full one, so the badge follows at once.
    if ([verb isEqualToString:@"free-space"] || [verb isEqualToString:@"enlarge-disk"]) self.lastFull = nil;
    [self requestOverview];
  }];
}

// Terminal-outcome toasts. Only user-initiated menu actions reach here, so timer/login starts
// never toast. image-upgrade is the one long op that reports a meaningful exit code, so it is the
// only success toast; the quick verbs stay silent on success (the icon settles immediately) and
// only speak up on failure. setup is excluded entirely (its exec of bootstrap returns 0 at once).
- (void)notifyForVerb:(NSString *)verb code:(int)code out:(NSString *)out {
  // free-space and enlarge-disk print the new disk line last; the toast quotes it.
  NSString *newDisk = [[out componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]] lastObject];
  BOOL ok = (code == 0);
  if ([verb isEqualToString:@"image-upgrade"]) {
    if (ok) [self notifyTitle:@"Container Tools" text:@"VM image updated."];
    else    [self notifyTitle:@"Container Tools" text:@"VM image update failed — see Show Log."];
    return;
  }
  if ([verb isEqualToString:@"free-space"]) {
    if (ok) [self notifyTitle:@"Container Tools" text:[self diskLineFrom:newDisk]];
    else    [self notifyTitle:@"Container Tools" text:@"Freeing up space failed — see Show Log."];
    return;
  }
  if ([verb isEqualToString:@"repair"]) {
    if (ok) [self notifyTitle:@"Container Tools" text:@"Docker is ready."];
    else    [self notifyTitle:@"Container Tools" text:@"Docker still isn't ready — see Show Diagnostics."];
    return;
  }
  if ([verb isEqualToString:@"enlarge-disk"]) {
    if (ok) [self notifyTitle:@"Container Tools" text:[self diskLineFrom:newDisk]];
    else    [self notifyTitle:@"Container Tools" text:@"Enlarging the VM disk failed — see Show Log."];
    return;
  }
  if (ok) return;   // start/stop/restart: silent on success
  if ([verb isEqualToString:@"start"])   [self notifyTitle:@"Container Tools" text:@"Starting Docker failed — see Show Log."];
  if ([verb isEqualToString:@"stop"])    [self notifyTitle:@"Container Tools" text:@"Stopping Docker failed — see Show Log."];
  if ([verb isEqualToString:@"restart"]) [self notifyTitle:@"Container Tools" text:@"Restarting Docker failed — see Show Log."];
}
- (void)doStart:(id)s   { [self runAndRefresh:@"start"]; }
- (void)doStop:(id)s    { [self runAndRefresh:@"stop"]; }
- (void)doRestart:(id)s { [self runAndRefresh:@"restart"]; }
- (void)doSetup:(id)s   { [self runAndRefresh:@"setup"]; }
- (void)doImageUpgrade:(id)s { [self runAndRefresh:@"image-upgrade"]; }
- (void)doRepair:(id)s { [self runAndRefresh:@"repair"]; }

// What docker-machine-ctl diagnostics says (no key material), in an alert the user can copy from.
- (void)doDiagnostics:(id)s {
  [self.controller runVerb:@"diagnostics" completion:^(NSString *out, int code) {
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = @"Container Tools diagnostics";
    a.informativeText = out.length ? out : @"(No diagnostics; see Show Log.)";
    [a addButtonWithTitle:@"Copy"];
    [a addButtonWithTitle:@"Close"];
    [NSApp activateIgnoringOtherApps:YES];
    if ([a runModal] == NSAlertFirstButtonReturn) {
      [[NSPasteboard generalPasteboard] clearContents];
      [[NSPasteboard generalPasteboard] setString:a.informativeText forType:NSPasteboardTypeString];
    }
  }];
}

// "Disk: 5.2 GB free of 19.1 GB", from the latest overview.
- (NSString *)diskLineForState:(NSString *)state {
  if (![state isEqualToString:@"running"]) return @"Disk: unknown (Docker stopped)";
  return [self diskLineFrom:self.overview.disk];
}
- (NSString *)diskLineFrom:(NSString *)disk {   // "<total KB> <used KB> <avail KB> ok|low"
  NSArray *f = [(disk ?: @"unknown") componentsSeparatedByString:@" "];
  if (f.count != 4) return @"Disk: unknown";
  NSString *free = [NSByteCountFormatter stringFromByteCount:[f[2] longLongValue] * 1024
                                                  countStyle:NSByteCountFormatterCountStyleFile];
  NSString *total = [NSByteCountFormatter stringFromByteCount:[f[0] longLongValue] * 1024
                                                   countStyle:NSByteCountFormatterCountStyleFile];
  if ([f[3] isEqualToString:@"low"]) return [NSString stringWithFormat:@"Disk almost full: %@ free", free];
  return [NSString stringWithFormat:@"Disk: %@ free of %@", free, total];
}

// Like Docker Desktop's "Clean up": confirm with what docker says can be freed, then remove unused
// images and build cache only. Containers and volumes can hold the user's data, so never those.
- (void)doFreeSpace:(id)s {
  [self.controller runVerb:@"reclaimable" completion:^(NSString *out, int code) {
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = @"Free up space on the Docker VM?";
    NSString *what = (code == 0 && out.length) ? out : @"(Docker could not say how much.)";
    a.informativeText = [NSString stringWithFormat:
      @"This removes unused images and build cache:\n\n%@\n\nImages download again when something "
       "next needs them. Containers and volumes are not touched.", what];
    [a addButtonWithTitle:@"Free Up Space"];   // first = default
    [a addButtonWithTitle:@"Cancel"];
    [NSApp activateIgnoringOtherApps:YES];      // a menu-bar extra's alert must come to the front
    if ([a runModal] == NSAlertFirstButtonReturn) [self runAndRefresh:@"free-space"];
  }];
}

// Grow the VM's disk in place by ctl's default step (enlarge_disk in docker-machine-common.sh).
// enlarge-disk-plan says what would happen, or why it can't; a refusal is shown, not run.
- (void)doEnlargeDisk:(id)s {
  [self.controller runVerb:@"enlarge-disk-plan" completion:^(NSString *out, int code) {
    NSString *plan = [out stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSArray *f = [plan componentsSeparatedByString:@" "];
    NSAlert *a = [[NSAlert alloc] init];
    [NSApp activateIgnoringOtherApps:YES];      // a menu-bar extra's alert must come to the front
    if (code != 0 || f.count != 4) {
      a.messageText = @"The Docker VM's disk can't be enlarged right now.";
      a.informativeText = plan.length ? plan : @"(No reason given; see Show Log.)";
      [a addButtonWithTitle:@"OK"];
      [a runModal];
      return;
    }
    a.messageText = [NSString stringWithFormat:@"Enlarge the Docker VM's disk from %@ GB to %@ GB?", f[0], f[1]];
    a.informativeText = [NSString stringWithFormat:
      @"Docker stops for a few minutes while the disk grows. Images, volumes and containers are kept; "
       "containers set to restart come back by themselves.\n\nThis needs about %@ GB free on this Mac "
       "(%@ GB free now). The disk file grows only as Docker uses it.", f[2], f[3]];
    [a addButtonWithTitle:@"Enlarge"];   // first = default
    [a addButtonWithTitle:@"Cancel"];
    if ([a runModal] == NSAlertFirstButtonReturn) [self runAndRefresh:@"enlarge-disk"];
  }];
}

- (void)doGetFusion:(id)s {
  [self notifyTitle:@"Container Tools" text:@"Opening the VMware Fusion download (467 MB) in your browser…"];
  NSTask *t = [[NSTask alloc] init];
  t.launchPath = MDToolPath(@"container-tools-get-fusion");
  @try { [t launch]; }
  @catch (NSException *e) { NSLog(@"Container Tools: could not run get-fusion: %@", e); }
}

- (void)maybePromptForFusion {
  static NSString * const kSeeded = @"MDFusionPromptSeeded";
  NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
  if ([d boolForKey:kSeeded]) return;
  // Seed before showing so the alert can never appear twice (fires at most once, ever).
  [d setBool:YES forKey:kSeeded];
  NSAlert *a = [[NSAlert alloc] init];
  a.messageText = @"VMware Fusion is required";
  a.informativeText = @"Container Tools needs VMware Fusion to run the Docker VM.";
  [a addButtonWithTitle:@"Get VMware Fusion"];   // first = default
  [a addButtonWithTitle:@"Later"];
  if ([a runModal] == NSAlertFirstButtonReturn) [self doGetFusion:nil];
}

- (void)showLog:(id)s {
  NSString *log = [NSHomeDirectory() stringByAppendingPathComponent:
    @"Library/Logs/Mavergreen/container-tools/bootstrap.log"];
  [[NSWorkspace sharedWorkspace] openFile:log withApplication:@"Console"];
}

- (void)checkForUpdates:(id)s {
  // Hand off to the bundled Sparkle updater's interactive check (shows the update dialog, or an
  // "up to date" alert). Launch it via LaunchServices (`open`), NOT a direct fork+exec of the
  // executable: Sparkle's package install needs a LaunchServices-launched host — a fork+exec child
  // has no LaunchServices session, so AuthorizationExecuteWithPrivileges can't run its privileged
  // helper and the install fails with -60008 (see the updater's Info.plist note in shipyard).
  // `open` returns as soon as it hands off, so there's nothing to reap.
  NSTask *t = [[NSTask alloc] init];
  t.launchPath = @"/usr/bin/open";
  t.arguments = @[@"/Library/Application Support/Mavergreen/container-tools-updater.app",
                  @"--args", @"--user"];
  @try {
    [t launch];
  } @catch (NSException *e) {
    NSLog(@"Container Tools: could not launch updater: %@", e);
  }
}

// Self-sizing (2026-11-24): the VM grows and shrinks by itself; off pins its size.
- (void)toggleAutosize:(id)s {
  BOOL on = [self.overview.autosize isEqualToString:@"on"];
  [self.controller runArgs:@[@"autosize", (on ? @"off" : @"on")] completion:^(NSString *o, int c) { [self requestOverview]; }];
}
// "Resizes to 6 GB, 1 CPU when idle" for a resize self-sizing holds for a restart; nil when none.
- (NSString *)heldResizeLine {
  NSArray *p = [self.overview.autosizePending componentsSeparatedByString:@" "];
  if (p.count != 2) return nil;
  double gb = [p[0] doubleValue] / 1024.0;
  NSInteger cpus = [p[1] integerValue];
  NSString *g = (gb == floor(gb)) ? [NSString stringWithFormat:@"%.0f", gb] : [NSString stringWithFormat:@"%.1f", gb];
  return [NSString stringWithFormat:@"Resizes to %@ GB, %ld CPU%@ when idle", g, (long)cpus, cpus == 1 ? @"" : @"s"];
}

- (void)toggleVMLogin:(id)s {
  BOOL on = [self.overview.login isEqualToString:@"on"];
  [self.controller runVerb:(on ? @"login-off" : @"login-on") completion:^(NSString *o, int c) { [self requestOverview]; }];
}

- (NSImage *)iconForState:(NSString *)state {
  BOOL running   = isUp(state);
  BOOL working   = isChanging(state);
  BOOL attention = [state isEqualToString:@"no-fusion"] ||
                   [state isEqualToString:@"absent"]    ||
                   [state isEqualToString:@"error"]     ||
                   [state isEqualToString:@"host-disk-full"] ||
                   [state isEqualToString:@"needs-attention"] ||
                   (running && self.diskLow);

  NSImage *img = [NSImage imageWithSize:NSMakeSize(18, 18) flipped:NO
      drawingHandler:^BOOL(NSRect r) {
    [[NSColor blackColor] set];   // template image; the system re-tints it for the menu bar

    // A single intermodal container, side-on: rounded body + top/bottom rails + corrugation
    // ribs. Derived from the product's container art (updater/container-tools-updater.svg),
    // reduced to a monochrome silhouette that survives 16px (see updater/ICON-CREDIT.txt).
    NSRect body = NSMakeRect(2.0, 4.5, 14.0, 9.0);
    NSBezierPath *container = [NSBezierPath bezierPathWithRect:body];   // sharp corners read as a box

    // Rails (two horizontals) + corrugation (three verticals): stroked as detail when the
    // container is an outline, or punched back out of the body when it is a solid silhouette.
    NSBezierPath *detail = [NSBezierPath bezierPath];
    for (int i = 1; i <= 3; i++) {
      CGFloat x = NSMinX(body) + i * (NSWidth(body) / 4.0);
      [detail moveToPoint:NSMakePoint(x, NSMinY(body) + 2.0)];
      [detail lineToPoint:NSMakePoint(x, NSMaxY(body) - 2.0)];
    }
    for (int k = 0; k < 2; k++) {
      CGFloat y = (k == 0) ? NSMinY(body) + 1.8 : NSMaxY(body) - 1.8;
      [detail moveToPoint:NSMakePoint(NSMinX(body) + 1.0, y)];
      [detail lineToPoint:NSMakePoint(NSMaxX(body) - 1.0, y)];
    }

    if (running) {
      [container fill];                                  // solid body = up
      NSGraphicsContext *gc = [NSGraphicsContext currentContext];
      [gc setCompositingOperation:NSCompositeClear];     // punch rails/ribs back to transparent
      detail.lineWidth = 1.0; [detail stroke];
      [gc setCompositingOperation:NSCompositeSourceOver];
    } else {
      container.lineWidth = 1.4; [container stroke];     // outline = down / needs setup
      detail.lineWidth = 0.9;   [detail stroke];
    }

    if (working) {
      // Rising dots above the container = starting / creating.
      for (int i = 0; i < 3; i++)
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(5.0 + i * 3.0, 14.6, 1.6, 1.6)] fill];
    } else if (attention) {
      // Filled badge, lower-right = needs attention (no Fusion / absent / error / disk almost full).
      [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(12.6, 1.8, 4.2, 4.2)] fill];
    }
    return YES;
  }];
  return img;
}

@end
