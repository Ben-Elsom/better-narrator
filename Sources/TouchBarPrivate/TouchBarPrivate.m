#import "TouchBarPrivate.h"
#import <dlfcn.h>
#import <objc/message.h>

typedef void (*BNSetPresenceFn)(NSString *, BOOL);
typedef void (*BNShowsCloseBoxFn)(BOOL);

static void *BNDFRFoundation(void) {
    static void *handle;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        handle = dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_LAZY);
    });
    return handle;
}

BOOL BNPresentSystemModalTouchBar(NSTouchBar *bar, NSString *trayIdentifier) {
    void *dfr = BNDFRFoundation();
    if (dfr) {
        BNShowsCloseBoxFn showsClose = (BNShowsCloseBoxFn)dlsym(dfr, "DFRSystemModalShowsCloseBoxWhenFrontMost");
        if (showsClose) showsClose(NO);
    }
    Class tb = [NSTouchBar class];
    SEL withPlacement = NSSelectorFromString(@"presentSystemModalTouchBar:placement:systemTrayItemIdentifier:");
    SEL plain = NSSelectorFromString(@"presentSystemModalTouchBar:systemTrayItemIdentifier:");
    if ([tb respondsToSelector:withPlacement]) {
        ((void (*)(id, SEL, id, long long, id))objc_msgSend)(tb, withPlacement, bar, 1, trayIdentifier);
        return YES;
    }
    if ([tb respondsToSelector:plain]) {
        ((void (*)(id, SEL, id, id))objc_msgSend)(tb, plain, bar, trayIdentifier);
        return YES;
    }
    return NO;
}

void BNDismissSystemModalTouchBar(NSTouchBar *bar) {
    SEL dismiss = NSSelectorFromString(@"dismissSystemModalTouchBar:");
    if ([[NSTouchBar class] respondsToSelector:dismiss]) {
        ((void (*)(id, SEL, id))objc_msgSend)([NSTouchBar class], dismiss, bar);
    }
}

void BNSetControlStripItem(NSTouchBarItem *item, BOOL present) {
    Class cls = [NSTouchBarItem class];
    SEL sel = NSSelectorFromString(present ? @"addSystemTrayItem:" : @"removeSystemTrayItem:");
    if ([cls respondsToSelector:sel]) {
        ((void (*)(id, SEL, id))objc_msgSend)(cls, sel, item);
    }
    void *dfr = BNDFRFoundation();
    if (dfr) {
        BNSetPresenceFn setPresence = (BNSetPresenceFn)dlsym(dfr, "DFRElementSetControlStripPresenceForIdentifier");
        if (setPresence) setPresence(item.identifier, present);
    }
}
