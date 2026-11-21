// UIKit helpers called from Rust (see ios/rust/src/lib.rs).
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

extern void sc_ios_on_opened(const char *const *paths, int n);

static UIViewController *SCTopController(void) {
    UIWindow *win = nil;
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
        if (![sc isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)sc).windows) { if (w.isKeyWindow) { win = w; break; } }
        if (!win) win = ((UIWindowScene *)sc).windows.firstObject;
        if (win) break;
    }
    if (!win) win = UIApplication.sharedApplication.windows.firstObject;
    UIViewController *vc = win.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

static void SCAnchorPopover(UIViewController *picker, UIViewController *host) {
    // iPad presents pickers as popovers; anchor them to the top centre of the window.
    UIPopoverPresentationController *pop = picker.popoverPresentationController;
    if (pop) {
        pop.sourceView = host.view;
        CGRect b = host.view.bounds;
        pop.sourceRect = CGRectMake(CGRectGetMidX(b), 60, 1, 1);
        pop.permittedArrowDirections = 0;
    }
}

@interface SCPickerDelegate : NSObject <UIDocumentPickerDelegate>
@property (nonatomic) BOOL importing;
@end

@implementation SCPickerDelegate
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (!self.importing) return;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *docs = [fm URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *dir = [docs URLByAppendingPathComponent:@"Imported" isDirectory:YES];
    [fm createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (NSURL *u in urls) {
        BOOL scoped = [u startAccessingSecurityScopedResource];
        NSString *name = u.lastPathComponent;
        NSURL *dst = [dir URLByAppendingPathComponent:name];
        NSString *stem = name.stringByDeletingPathExtension, *ext = name.pathExtension;
        for (int i = 2; [fm fileExistsAtPath:dst.path]; i++) {
            NSString *n = ext.length ? [NSString stringWithFormat:@"%@ %d.%@", stem, i, ext] : [NSString stringWithFormat:@"%@ %d", stem, i];
            dst = [dir URLByAppendingPathComponent:n];
        }
        NSError *err = nil;
        if ([fm copyItemAtURL:u toURL:dst error:&err]) [out addObject:dst.path];
        else NSLog(@"SoundCue: import copy failed %@", err);
        if (scoped) [u stopAccessingSecurityScopedResource];
    }
    const char **c = calloc(out.count ? out.count : 1, sizeof(char *));
    for (NSUInteger i = 0; i < out.count; i++) c[i] = out[i].fileSystemRepresentation;
    sc_ios_on_opened(c, (int)out.count);
    free(c);
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    if (self.importing) sc_ios_on_opened(NULL, 0);
}
@end

static SCPickerDelegate *gDelegate;

void sc_ios_request_open(int multi) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSArray<UTType *> *types = @[UTTypeAudio, UTTypeData];
        UIDocumentPickerViewController *p = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:YES];
        p.allowsMultipleSelection = multi != 0;
        gDelegate = [SCPickerDelegate new];
        gDelegate.importing = YES;
        p.delegate = gDelegate;
        UIViewController *host = SCTopController();
        SCAnchorPopover(p, host);
        [host presentViewController:p animated:YES completion:nil];
    });
}

void sc_ios_request_export(const char *path) {
    NSString *s = [NSString stringWithUTF8String:path];
    dispatch_async(dispatch_get_main_queue(), ^{
        NSURL *u = [NSURL fileURLWithPath:s];
        UIDocumentPickerViewController *p = [[UIDocumentPickerViewController alloc] initForExportingURLs:@[u] asCopy:YES];
        gDelegate = [SCPickerDelegate new];
        gDelegate.importing = NO;
        p.delegate = gDelegate;
        UIViewController *host = SCTopController();
        SCAnchorPopover(p, host);
        [host presentViewController:p animated:YES completion:nil];
    });
}

void sc_ios_open_url(const char *url) {
    NSString *s = [NSString stringWithUTF8String:url];
    dispatch_async(dispatch_get_main_queue(), ^{
        NSURL *u = [NSURL URLWithString:s];
        if (u) [UIApplication.sharedApplication openURL:u options:@{} completionHandler:nil];
    });
}
