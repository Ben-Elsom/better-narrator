// Touch Bar takeover test for Better Narrator.
//
// Checks whether a background app can put its own buttons on the Touch Bar
// while another app (e.g. Claude) is in front, even with the Touch Bar set to
// always show the full Control Strip. Uses the same unofficial calls as
// Pock/MTMR, looked up at runtime so a missing one is reported, not a crash.
//
// Build: see build.sh. Every button press is written to the log file.

#import <Cocoa/Cocoa.h>
#import <dlfcn.h>
#import <objc/message.h>

static NSString *const kBarID = @"app.betternarrator.test.bar";
static NSString *const kTrayID = @"app.betternarrator.test.tray";
static NSString *const kBack = @"app.betternarrator.test.back";
static NSString *const kPlay = @"app.betternarrator.test.play";
static NSString *const kFwd = @"app.betternarrator.test.fwd";
static NSString *const kStatus = @"app.betternarrator.test.status";
static NSString *const kDismiss = @"app.betternarrator.test.dismiss";

static NSString *gLogPath;

static void Log(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], msg];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:gLogPath];
    if (!fh) {
        [line writeToFile:gLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        return;
    }
    [fh seekToEndOfFile];
    [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
}

typedef void (*SetPresenceFn)(NSString *, BOOL);
typedef void (*ShowsCloseBoxFn)(BOOL);

@interface Controller : NSObject <NSApplicationDelegate, NSTouchBarDelegate>
@property (strong) NSTouchBar *bar;
@property (strong) NSCustomTouchBarItem *trayItem;
@property (strong) NSButton *playButton;
@property (strong) NSButton *dismissButton;
@property (strong) NSTextField *status;
@property BOOL playing;
@property double position;
@property BOOL dismissArmed;
@end

@implementation Controller

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    Class tb = [NSTouchBar class];
    SEL present3 = NSSelectorFromString(@"presentSystemModalTouchBar:placement:systemTrayItemIdentifier:");
    SEL present2 = NSSelectorFromString(@"presentSystemModalTouchBar:systemTrayItemIdentifier:");
    SEL dismiss = NSSelectorFromString(@"dismissSystemModalTouchBar:");
    SEL addTray = NSSelectorFromString(@"addSystemTrayItem:");
    Log(@"macOS %@", [[NSProcessInfo processInfo] operatingSystemVersionString]);
    Log(@"has presentSystemModalTouchBar:placement:systemTrayItemIdentifier: %d", [tb respondsToSelector:present3]);
    Log(@"has presentSystemModalTouchBar:systemTrayItemIdentifier: %d", [tb respondsToSelector:present2]);
    Log(@"has dismissSystemModalTouchBar: %d", [tb respondsToSelector:dismiss]);
    Log(@"has NSTouchBarItem addSystemTrayItem: %d", [[NSTouchBarItem class] respondsToSelector:addTray]);

    void *dfr = dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_LAZY);
    SetPresenceFn setPresence = dfr ? (SetPresenceFn)dlsym(dfr, "DFRElementSetControlStripPresenceForIdentifier") : NULL;
    ShowsCloseBoxFn showsClose = dfr ? (ShowsCloseBoxFn)dlsym(dfr, "DFRSystemModalShowsCloseBoxWhenFrontMost") : NULL;
    Log(@"DFRFoundation loaded %d, SetControlStripPresence %d, ShowsCloseBox %d", dfr != NULL, setPresence != NULL, showsClose != NULL);

    self.bar = [[NSTouchBar alloc] init];
    self.bar.delegate = self;
    self.bar.defaultItemIdentifiers = @[kBack, kPlay, kFwd, kStatus, NSTouchBarItemIdentifierFlexibleSpace, kDismiss];

    // A small button in the Control Strip that brings our controls back.
    self.trayItem = [[NSCustomTouchBarItem alloc] initWithIdentifier:kTrayID];
    self.trayItem.view = [NSButton buttonWithTitle:@"BN" target:self action:@selector(showBar)];
    if ([[NSTouchBarItem class] respondsToSelector:addTray]) {
        ((void (*)(id, SEL, id))objc_msgSend)([NSTouchBarItem class], addTray, self.trayItem);
    }
    if (setPresence) setPresence(kTrayID, YES);
    if (showsClose) showsClose(NO);

    [self showBar];
    [self updateStatus];
    // Safety net: quit on its own after 15 minutes.
    [NSTimer scheduledTimerWithTimeInterval:900 repeats:NO block:^(NSTimer *t) { [NSApp terminate:nil]; }];
    [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *t) {
        if (self.playing) { self.position += 1; [self updateStatus]; }
    }];
}

- (void)showBar {
    Class tb = [NSTouchBar class];
    SEL present3 = NSSelectorFromString(@"presentSystemModalTouchBar:placement:systemTrayItemIdentifier:");
    SEL present2 = NSSelectorFromString(@"presentSystemModalTouchBar:systemTrayItemIdentifier:");
    if ([tb respondsToSelector:present3]) {
        ((void (*)(id, SEL, id, long long, id))objc_msgSend)(tb, present3, self.bar, 1, kTrayID);
        Log(@"presented with placement");
    } else if ([tb respondsToSelector:present2]) {
        ((void (*)(id, SEL, id, id))objc_msgSend)(tb, present2, self.bar, kTrayID);
        Log(@"presented without placement");
    } else {
        Log(@"no way to present a system-wide Touch Bar");
    }
}

- (NSTouchBarItem *)touchBar:(NSTouchBar *)touchBar makeItemForIdentifier:(NSTouchBarItemIdentifier)ident {
    NSCustomTouchBarItem *item = [[NSCustomTouchBarItem alloc] initWithIdentifier:ident];
    if ([ident isEqual:kBack]) {
        item.view = [NSButton buttonWithTitle:@"−15s" target:self action:@selector(back)];
    } else if ([ident isEqual:kPlay]) {
        self.playButton = [NSButton buttonWithTitle:@"▶︎ Start" target:self action:@selector(togglePlay)];
        item.view = self.playButton;
    } else if ([ident isEqual:kFwd]) {
        item.view = [NSButton buttonWithTitle:@"+15s" target:self action:@selector(forward)];
    } else if ([ident isEqual:kStatus]) {
        self.status = [NSTextField labelWithString:@"0:00"];
        item.view = self.status;
    } else if ([ident isEqual:kDismiss]) {
        self.dismissButton = [NSButton buttonWithTitle:@"Dismiss" target:self action:@selector(dismissTapped)];
        item.view = self.dismissButton;
    } else {
        return nil;
    }
    return item;
}

- (void)updateStatus {
    int s = (int)self.position;
    self.status.stringValue = [NSString stringWithFormat:@"Test %d:%02d", s / 60, s % 60];
}

- (void)back { self.position = MAX(0, self.position - 15); Log(@"pressed −15s -> %.0f", self.position); [self updateStatus]; }
- (void)forward { self.position += 15; Log(@"pressed +15s -> %.0f", self.position); [self updateStatus]; }

- (void)togglePlay {
    self.playing = !self.playing;
    self.playButton.title = self.playing ? @"⏸ Pause" : @"▶︎ Play";
    Log(@"pressed play/pause -> %@", self.playing ? @"playing" : @"paused");
}

- (void)dismissTapped {
    if (!self.dismissArmed) {
        self.dismissArmed = YES;
        self.dismissButton.title = @"Tap again to close";
        self.dismissButton.bezelColor = [NSColor systemRedColor];
        Log(@"pressed dismiss once (armed)");
        [NSTimer scheduledTimerWithTimeInterval:3 repeats:NO block:^(NSTimer *t) {
            if (self.dismissArmed) {
                self.dismissArmed = NO;
                self.dismissButton.title = @"Dismiss";
                self.dismissButton.bezelColor = nil;
                Log(@"dismiss reset after 3s");
            }
        }];
        return;
    }
    Log(@"pressed dismiss twice -> closing");
    SEL dismiss = NSSelectorFromString(@"dismissSystemModalTouchBar:");
    if ([[NSTouchBar class] respondsToSelector:dismiss]) {
        ((void (*)(id, SEL, id))objc_msgSend)([NSTouchBar class], dismiss, self.bar);
    }
    SEL removeTray = NSSelectorFromString(@"removeSystemTrayItem:");
    if ([[NSTouchBarItem class] respondsToSelector:removeTray]) {
        ((void (*)(id, SEL, id))objc_msgSend)([NSTouchBarItem class], removeTray, self.trayItem);
    }
    [NSApp performSelector:@selector(terminate:) withObject:nil afterDelay:0.5];
}

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        gLogPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/BetterNarrator_TouchBarTest.log"];
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        Controller *c = [Controller new];
        app.delegate = c;
        [app run];
    }
    return 0;
}
