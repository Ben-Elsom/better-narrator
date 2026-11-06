#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// Shows `bar` on the Touch Bar even when another app is in front.
/// Returns NO if this macOS doesn't offer the unofficial call.
BOOL BNPresentSystemModalTouchBar(NSTouchBar *bar, NSString *trayIdentifier);

/// Removes a bar shown with BNPresentSystemModalTouchBar.
void BNDismissSystemModalTouchBar(NSTouchBar *bar);

/// Adds or removes a small button in the Control Strip.
void BNSetControlStripItem(NSTouchBarItem *item, BOOL present);

NS_ASSUME_NONNULL_END
