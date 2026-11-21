#import "AtlasFiles.h"
#import "GCDWebServer.h"
#import "GCDWebServerDataResponse.h"
#import "GCDWebServerFileResponse.h"
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <WebKit/WebKit.h>

static const NSUInteger AtlasPort = 49173;
static NSString *const BaseURL = @"http://127.0.0.1:49173";
static NSString *const MemoryType = @"org.ieltsatlas.ipad.memory";
typedef void (^Reply)(id value, NSString *error);
typedef void (^Pick)(NSURL *url);
static void mainQueue(dispatch_block_t block) {
    dispatch_async(dispatch_get_main_queue(), block);
}
static BOOL localURL(NSURL *u) {
    return [u.scheme.lowercaseString isEqual:@"http"] && [u.host isEqual:@"127.0.0.1"] &&
           u.port.unsignedIntegerValue == AtlasPort;
}
static NSURL *pageURL(NSString *path) {
    return [NSURL URLWithString:[BaseURL stringByAppendingString:path]];
}
static BOOL allowedFrame(WKScriptMessage *m) {
    WKSecurityOrigin *o = m.frameInfo.securityOrigin;
    return m.frameInfo.isMainFrame && [o.protocol isEqual:@"http"] && [o.host isEqual:@"127.0.0.1"] &&
           o.port == AtlasPort;
}
static NSString *script(NSString *name) {
    return [NSString stringWithContentsOfURL:[NSBundle.mainBundle URLForResource:name
                                                                   withExtension:@"js"]
                                    encoding:NSUTF8StringEncoding
                                       error:NULL];
}
static NSString *errorText(NSError *e) {
    return e.userInfo[@"WKJavaScriptExceptionMessage"] ?: e.localizedDescription ?: @"操作未完成";
}

@interface AtlasController
    : UIViewController <WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandlerWithReply,
                        UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate,
                        WKDownloadDelegate>
@property(nonatomic, strong) GCDWebServer *server;
@property(atomic, copy) NSArray<NSURL *> *materialRoots;
@property(atomic, copy) NSDictionary<NSString *, NSURL *> *extensionFiles;
@property(nonatomic, copy) NSString *profileID, *cookieToken;
@property(nonatomic, strong) NSMutableArray<WKWebView *> *pages;
@property(nonatomic, strong) WKWebView *selected, *candidate;
@property(nonatomic, strong) UIView *host, *savingView, *notice;
@property(nonatomic, strong) UIStackView *windowBar;
@property(nonatomic, strong) UIButton *backButton, *windowsButton, *closeButton;
@property(nonatomic, copy) Pick pickerCallback;
@property(nonatomic, strong) UIDocumentPickerViewController *picker;
@property(nonatomic, strong) NSURL *pendingURL, *restoreState;
@property(nonatomic, copy) NSString *restoreID;
@property(nonatomic) BOOL busy, validating;
@property(nonatomic, strong) dispatch_queue_t io;
@property(nonatomic, strong) NSMutableDictionary<NSValue *, NSURL *> *downloads;
- (void)receiveURL:(NSURL *)url;
@end

@implementation AtlasController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.io = dispatch_queue_create("org.ieltsatlas.files", DISPATCH_QUEUE_SERIAL);
    self.pages = [NSMutableArray array];
    self.downloads = [NSMutableDictionary dictionary];
    self.cookieToken = NSUUID.UUID.UUIDString;
    self.windowBar = [UIStackView new];
    self.windowBar.axis = UILayoutConstraintAxisHorizontal;
    self.windowBar.alignment = UIStackViewAlignmentCenter;
    self.windowBar.spacing = 8;
    self.backButton = [self button:@"主窗口" action:@selector(goBack:)];
    self.windowsButton = [self button:@"切换窗口" action:nil];
    self.windowsButton.showsMenuAsPrimaryAction = YES;
    self.closeButton = [self button:@"关闭窗口" action:@selector(closeTab:)];
    for (UIView *v in @[ self.backButton, [UIView new], self.windowsButton, self.closeButton ])
        [self.windowBar addArrangedSubview:v];
    self.windowBar.hidden = YES;
    self.host = [UIView new];
    UIStackView *layout = [[UIStackView alloc] initWithArrangedSubviews:@[ self.windowBar, self.host ]];
    layout.axis = UILayoutConstraintAxisVertical;
    layout.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:layout];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [layout.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [layout.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
        [layout.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [layout.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor]
    ]];
    [self boot];
}
- (UIButton *)button:(NSString *)text action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration *c = UIButtonConfiguration.plainButtonConfiguration;
    c.title = text;
    c.buttonSize = UIButtonConfigurationSizeSmall;
    b.configuration = c;
    if (action)
        [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (self.pendingURL && self.pages.count && !self.busy) {
        NSURL *u = self.pendingURL;
        self.pendingURL = nil;
        [self receiveURL:u];
    }
}
- (void)tell:(NSString *)title message:(NSString *)s {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title
                                                               message:s
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    UIViewController *p = self;
    while (p.presentedViewController && !p.presentedViewController.isBeingDismissed)
        p = p.presentedViewController;
    [p presentViewController:a animated:YES completion:nil];
}
- (void)bootFailure:(NSError *)e {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"暂时无法打开 IELTS Atlas"
                                                               message:errorText(e)
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"重试"
                                          style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *action) {
                                            [self boot];
                                        }]];
    mainQueue(^{
        [self presentViewController:a animated:YES completion:nil];
    });
}
- (BOOL)persistProfile:(NSString *)identifier error:(NSError **)e {
    return [identifier writeToURL:AFChild(AFBase(), @"current")
                       atomically:YES
                         encoding:NSUTF8StringEncoding
                            error:e];
}
- (void)boot {
    NSError *e = nil;
    NSURL *marker = AFChild(AFBase(), @"current");
    BOOL exists = [NSFileManager.defaultManager fileExistsAtPath:marker.path];
    NSString *uid = exists ? [NSString stringWithContentsOfURL:marker
                                                      encoding:NSUTF8StringEncoding
                                                         error:&e]
                           : NSUUID.UUID.UUIDString;
    if (![[NSUUID alloc] initWithUUIDString:uid ?: @""]) {
        [self bootFailure:e ?: AFError(@"无法读取数据空间标识")];
        return;
    }
    NSURL *m = AFChild(AFProfile(uid), @"materials");
    if (!AFMake(m, &e) || (!exists && ![self persistProfile:uid error:&e])) {
        [self bootFailure:e];
        return;
    }
    self.profileID = uid;
    self.materialRoots = @[ m ];
    self.extensionFiles = AFExtensionFiles(m);
    if (![self startServer:&e]) {
        [self bootFailure:e];
        return;
    }
    WKWebView *home = [self newView:[self config:uid]];
    [self.pages addObject:home];
    [self show:home];
    [self loadPath:@"/index.html" in:home];
    NSArray *profiles = [NSFileManager.defaultManager
          contentsOfDirectoryAtURL:AFProfile(uid).URLByDeletingLastPathComponent
        includingPropertiesForKeys:nil
                           options:0
                             error:NULL];
    for (NSURL *p in profiles) {
        if (![p.lastPathComponent isEqual:uid] &&
            [[NSUUID alloc] initWithUUIDString:p.lastPathComponent])
            [self discard:p.lastPathComponent];
    }
}
- (BOOL)startServer:(NSError **)err {
    if (self.server.isRunning)
        return YES;
    self.server = [GCDWebServer new];
    __weak AtlasController *weak = self;
    NSURL *web = [NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:@"Web" isDirectory:YES];
    [self.server
        addHandlerForMethod:@"GET"
                  pathRegex:@"^/.*$"
               requestClass:GCDWebServerRequest.class
               processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
                   AtlasController *s = weak;
                   NSString *host = request.headers[@"Host"] ?: request.headers[@"host"];
                   if (![host isEqualToString:@"127.0.0.1:49173"])
                       return [GCDWebServerResponse responseWithStatusCode:403];
                   NSString *path = request.path;
                   if ([path isEqual:@"/_atlas/restore.html"])
                       return [GCDWebServerDataResponse
                           responseWithHTML:
                               @"<!doctype html><html><head><meta charset=utf-8><title>IELTS "
                               @"Atlas</title></head><body></body></html>"];
                   if ([path isEqual:@"/"])
                       path = @"/index.html";
                   BOOL material = [path hasPrefix:@"/_atlas/material/"];
                   NSString *relative =
                       [path substringFromIndex:material ? [@"/_atlas/material/" length] : 1];
                   for (NSString *part in [relative componentsSeparatedByString:@"/"]) {
                       if (!AFSafePart(part))
                           return [GCDWebServerResponse responseWithStatusCode:404];
                   }
                   NSURL *extra = s.extensionFiles[relative];
                   if (material || extra) {
                       NSString *cookie = request.headers[@"Cookie"] ?: request.headers[@"cookie"];
                       NSString *expected = [@"atlasLocal=" stringByAppendingString:s.cookieToken];
                       if (![[cookie componentsSeparatedByString:@"; "] containsObject:expected])
                           return [GCDWebServerResponse responseWithStatusCode:403];
                   }
                   NSMutableArray<NSURL *> *candidates = [NSMutableArray array];
                   if (material) {
                       for (NSURL *root in s.materialRoots)
                           [candidates addObject:AFChild(root, relative)];
                   } else {
                       [candidates addObject:AFChild(web, relative)];
                       if (extra)
                           [candidates addObject:extra];
                   }
                   for (NSURL *file in candidates) {
                       BOOL dir = NO;
                       if ([NSFileManager.defaultManager fileExistsAtPath:file.path isDirectory:&dir] &&
                           !dir) {
                           GCDWebServerFileResponse *r =
                               [GCDWebServerFileResponse responseWithFile:file.path
                                                                byteRange:request.byteRange];
                           if (r) {
                               [r setValue:@"bytes" forAdditionalHeader:@"Accept-Ranges"];
                               r.cacheControlMaxAge = 0;
                               return r;
                           }
                       }
                   }
                   return [GCDWebServerResponse responseWithStatusCode:404];
               }];
    return [self.server startWithOptions:@{
        GCDWebServerOption_Port : @(AtlasPort),
        GCDWebServerOption_BindToLocalhost : @YES,
        GCDWebServerOption_AutomaticallySuspendInBackground : @NO,
        GCDWebServerOption_AutomaticallyMapHEADToGET : @YES
    }
                                   error:err];
}
- (WKWebViewConfiguration *)config:(NSString *)uuid {
    WKWebViewConfiguration *c = [WKWebViewConfiguration new];
    c.websiteDataStore =
        [WKWebsiteDataStore dataStoreForIdentifier:[[NSUUID alloc] initWithUUIDString:uuid]];
    c.preferences.javaScriptCanOpenWindowsAutomatically = YES;
    c.preferences.elementFullscreenEnabled = YES;
    c.allowsInlineMediaPlayback = YES;
    c.mediaTypesRequiringUserActionForPlayback = WKAudiovisualMediaTypeNone;
    c.defaultWebpagePreferences.preferredContentMode = WKContentModeRecommended;
    for (NSString *name in @[ @"memory", @"ipad" ]) {
        WKUserScript *js = [[WKUserScript alloc] initWithSource:script(name)
                                                  injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                               forMainFrameOnly:YES];
        [c.userContentController addUserScript:js];
    }
    [c.userContentController addScriptMessageHandlerWithReply:self
                                                 contentWorld:WKContentWorld.pageWorld
                                                         name:@"atlasPort"];
    return c;
}
- (WKWebView *)newView:(WKWebViewConfiguration *)c {
    WKWebView *v = [[WKWebView alloc] initWithFrame:self.host.bounds configuration:c];
    v.UIDelegate = self;
    v.navigationDelegate = self;
    v.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    v.allowsBackForwardNavigationGestures = YES;
    v.scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    [self.host addSubview:v];
    return v;
}
- (void)loadPath:(NSString *)path in:(WKWebView *)v {
    NSHTTPCookie *cookie = [NSHTTPCookie cookieWithProperties:@{
        NSHTTPCookieName : @"atlasLocal",
        NSHTTPCookieValue : self.cookieToken,
        NSHTTPCookieDomain : @"127.0.0.1",
        NSHTTPCookiePath : @"/",
        NSHTTPCookieOriginURL : pageURL(@"/"),
        @"HttpOnly" : @"TRUE",
        @"SameSite" : @"Strict"
    }];
    [v.configuration.websiteDataStore.httpCookieStore
                setCookie:cookie
        completionHandler:^{
            [v loadRequest:[NSURLRequest requestWithURL:pageURL(path)]];
        }];
}
- (void)show:(WKWebView *)v {
    self.selected = v;
    for (WKWebView *p in self.pages)
        p.hidden = p != v;
    v.hidden = NO;
    [self.host bringSubviewToFront:v];
    if (self.candidate && self.candidate != v)
        [self.host sendSubviewToBack:self.candidate];
    [self updateBar];
}
- (void)updateBar {
    self.windowBar.hidden = self.pages.count < 2;
    self.closeButton.hidden = self.selected == self.pages.firstObject;
    self.backButton.hidden = self.selected == self.pages.firstObject;
    [self.backButton setTitle:self.selected.canGoBack ? @"返回" : @"主窗口"
                     forState:UIControlStateNormal];
    NSMutableArray *actions = [NSMutableArray array];
    for (WKWebView *p in self.pages) {
        NSString *title = p == self.pages.firstObject ? @"主窗口"
                          : p.title.length            ? p.title
                                                      : @"练习窗口";
        UIAction *a = [UIAction actionWithTitle:title
                                          image:nil
                                     identifier:nil
                                        handler:^(UIAction *action) {
                                            [self show:p];
                                        }];
        a.state = p == self.selected ? UIMenuElementStateOn : UIMenuElementStateOff;
        [actions addObject:a];
    }
    self.windowsButton.menu = [UIMenu menuWithTitle:@"" children:actions];
}
- (void)goBack:(id)sender {
    if (self.selected.canGoBack)
        [self.selected goBack];
    else
        [self show:self.pages.firstObject];
}
- (void)closeTab:(id)sender {
    [self webViewDidClose:self.selected];
}
- (WKWebView *)webView:(WKWebView *)webView
    createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration
               forNavigationAction:(WKNavigationAction *)action
                    windowFeatures:(WKWindowFeatures *)features {
    if (self.candidate == webView)
        return nil;
    NSURL *u = action.request.URL;
    if (action.navigationType == WKNavigationTypeLinkActivated &&
        ([u.scheme isEqual:@"https"] || [u.scheme isEqual:@"http"]) && !localURL(u)) {
        [UIApplication.sharedApplication openURL:u options:@{} completionHandler:nil];
        return nil;
    }
    WKWebView *v = [self newView:configuration];
    [self.pages addObject:v];
    [self show:v];
    return v;
}
- (void)webViewDidClose:(WKWebView *)v {
    if (v == self.pages.firstObject || ![self.pages containsObject:v])
        return;
    NSUInteger i = [self.pages indexOfObject:v];
    BOOL active = v == self.selected;
    [self.pages removeObject:v];
    v.navigationDelegate = nil;
    v.UIDelegate = nil;
    [v removeFromSuperview];
    if (active)
        [self show:self.pages[i ? i - 1 : 0]];
    else
        [self updateBar];
}
- (void)webView:(WKWebView *)w
    decidePolicyForNavigationAction:(WKNavigationAction *)a
                    decisionHandler:(void (^)(WKNavigationActionPolicy))decide {
    NSURL *u = a.request.URL;
    NSString *scheme = u.scheme.lowercaseString;
    if (a.shouldPerformDownload) {
        decide(WKNavigationActionPolicyDownload);
        return;
    }
    if ((!a.targetFrame || a.targetFrame.isMainFrame) && u && !localURL(u) &&
        ((a.navigationType == WKNavigationTypeLinkActivated &&
          ([scheme isEqual:@"http"] || [scheme isEqual:@"https"])) ||
         [scheme isEqual:@"mailto"])) {
        [UIApplication.sharedApplication openURL:u options:@{} completionHandler:nil];
        decide(WKNavigationActionPolicyCancel);
        return;
    }
    decide(WKNavigationActionPolicyAllow);
}
- (void)webView:(WKWebView *)w
    decidePolicyForNavigationResponse:(WKNavigationResponse *)r
                      decisionHandler:(void (^)(WKNavigationResponsePolicy))decide {
    decide(r.canShowMIMEType ? WKNavigationResponsePolicyAllow : WKNavigationResponsePolicyDownload);
}
- (void)webView:(WKWebView *)w
     navigationAction:(WKNavigationAction *)a
    didBecomeDownload:(WKDownload *)d {
    d.delegate = self;
}
- (void)webView:(WKWebView *)w
    navigationResponse:(WKNavigationResponse *)r
     didBecomeDownload:(WKDownload *)d {
    d.delegate = self;
}
- (void)download:(WKDownload *)d
    decideDestinationUsingResponse:(NSURLResponse *)response
                 suggestedFilename:(NSString *)name
                 completionHandler:(void (^)(NSURL *))handler {
    NSError *e = nil;
    NSURL *dir = AFTemp(&e);
    NSURL *out = dir ? AFChild(dir, AFSafePart(name) ? name : @"IELTS-Atlas") : nil;
    if (out)
        self.downloads[[NSValue valueWithNonretainedObject:d]] = out;
    handler(out);
}
- (void)downloadDidFinish:(WKDownload *)d {
    NSValue *key = [NSValue valueWithNonretainedObject:d];
    NSURL *f = self.downloads[key];
    [self.downloads removeObjectForKey:key];
    if (f)
        [self exportFile:f reply:nil];
}
- (void)download:(WKDownload *)d didFailWithError:(NSError *)e resumeData:(NSData *)data {
    NSValue *k = [NSValue valueWithNonretainedObject:d];
    NSURL *f = self.downloads[k];
    if (f)
        [NSFileManager.defaultManager removeItemAtURL:f.URLByDeletingLastPathComponent error:NULL];
    [self.downloads removeObjectForKey:k];
    [self tell:@"下载失败" message:errorText(e)];
}
- (void)dialog:(NSString *)msg
          kind:(NSInteger)kind
       initial:(NSString *)initial
         reply:(void (^)(id))done {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"IELTS Atlas"
                                                               message:msg
                                                        preferredStyle:UIAlertControllerStyleAlert];
    if (kind == 2)
        [a addTextFieldWithConfigurationHandler:^(UITextField *field) {
            field.text = initial;
        }];
    if (kind)
        [a addAction:[UIAlertAction actionWithTitle:@"取消"
                                              style:UIAlertActionStyleCancel
                                            handler:^(UIAlertAction *x) {
                                                done(nil);
                                            }]];
    [a addAction:[UIAlertAction actionWithTitle:@"确定"
                                          style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *x) {
                                            done(kind == 2 ? a.textFields.firstObject.text : @YES);
                                        }]];
    UIViewController *p = self;
    while (p.presentedViewController && !p.presentedViewController.isBeingDismissed)
        p = p.presentedViewController;
    [p presentViewController:a animated:YES completion:nil];
}
- (void)webView:(WKWebView *)w
    runJavaScriptAlertPanelWithMessage:(NSString *)s
                      initiatedByFrame:(WKFrameInfo *)frame
                     completionHandler:(void (^)(void))h {
    [self dialog:s
            kind:0
         initial:nil
           reply:^(id r) {
               h();
           }];
}
- (void)webView:(WKWebView *)w
    runJavaScriptConfirmPanelWithMessage:(NSString *)s
                        initiatedByFrame:(WKFrameInfo *)frame
                       completionHandler:(void (^)(BOOL))h {
    [self dialog:s
            kind:1
         initial:nil
           reply:^(id r) {
               h([r boolValue]);
           }];
}
- (void)webView:(WKWebView *)w
    runJavaScriptTextInputPanelWithPrompt:(NSString *)s
                              defaultText:(NSString *)t
                         initiatedByFrame:(WKFrameInfo *)f
                        completionHandler:(void (^)(NSString *))h {
    [self dialog:s
            kind:2
         initial:t
           reply:^(id r) {
               h(r);
           }];
}
- (void)offerBackup {
    if (self.notice || self.busy)
        return;
    UIButton *save = [self button:@"练习已保存 · 导出记忆文件" action:@selector(exportTapped:)];
    UIButton *hide = [self button:@"✕" action:@selector(hideNotice)];
    hide.accessibilityLabel = @"关闭备份提示";
    UIStackView *box = [[UIStackView alloc] initWithArrangedSubviews:@[ save, hide ]];
    box.axis = UILayoutConstraintAxisHorizontal;
    box.alignment = UIStackViewAlignmentCenter;
    box.backgroundColor = UIColor.secondarySystemBackgroundColor;
    box.layer.cornerRadius = 12;
    box.layer.shadowOpacity = .16;
    box.layer.shadowRadius = 5;
    box.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:box];
    self.notice = box;
    [NSLayoutConstraint activateConstraints:@[
        [box.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor
                                           constant:-12],
        [box.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor
                                         constant:-10]
    ]];
}
- (void)hideNotice {
    [self.notice removeFromSuperview];
    self.notice = nil;
}
- (void)exportTapped:(id)sender {
    [self exportMemory:nil];
}
- (void)progress:(NSString *)message {
    [self.savingView removeFromSuperview];
    self.savingView = nil;
    if (!message)
        return;
    UIView *cover = [UIView new];
    cover.backgroundColor = [UIColor.systemBackgroundColor colorWithAlphaComponent:.88];
    cover.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:cover];
    self.savingView = cover;
    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    [spinner startAnimating];
    UILabel *label = [UILabel new];
    label.text = message;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[ spinner, label ]];
    row.spacing = 12;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [cover addSubview:row];
    [NSLayoutConstraint activateConstraints:@[
        [cover.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [cover.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [cover.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [cover.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [row.centerXAnchor constraintEqualToAnchor:cover.centerXAnchor],
        [row.centerYAnchor constraintEqualToAnchor:cover.centerYAnchor]
    ]];
}
- (void)pick:(UIDocumentPickerViewController *)p then:(Pick)block {
    if (self.picker || self.presentedViewController) {
        block(nil);
        return;
    }
    self.picker = p;
    self.pickerCallback = block;
    p.delegate = self;
    p.modalPresentationStyle = UIModalPresentationFormSheet;
    p.presentationController.delegate = self;
    [self presentViewController:p animated:YES completion:nil];
}
- (void)finishPick:(UIDocumentPickerViewController *)p url:(NSURL *)url {
    if (self.picker != p)
        return;
    Pick callback = self.pickerCallback;
    self.picker = nil;
    self.pickerCallback = nil;
    void (^finish)(void) = ^{
        if (callback)
            callback(url);
    };
    if (p.isBeingDismissed) {
        id<UIViewControllerTransitionCoordinator> tc = p.transitionCoordinator;
        if (tc &&
            [tc animateAlongsideTransition:nil
                                completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
                                    finish();
                                }])
            return;
        mainQueue(finish);
        return;
    }
    if (p.presentingViewController)
        [p dismissViewControllerAnimated:YES completion:finish];
    else
        mainQueue(finish);
}
- (void)documentPicker:(UIDocumentPickerViewController *)controller
    didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    [self finishPick:controller url:urls.firstObject];
}
- (void)presentationControllerDidDismiss:(UIPresentationController *)presentation {
    if (presentation.presentedViewController == self.picker)
        [self finishPick:self.picker url:nil];
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    [self finishPick:controller url:nil];
}
- (void)exportFile:(NSURL *)url reply:(Reply)reply {
    UIDocumentPickerViewController *p =
        [[UIDocumentPickerViewController alloc] initForExportingURLs:@[ url ] asCopy:YES];
    [self pick:p
          then:^(NSURL *dest) {
              [NSFileManager.defaultManager removeItemAtURL:url.URLByDeletingLastPathComponent
                                                      error:NULL];
              if (reply)
                  reply(dest ? @YES : nil, dest ? nil : @"ATLAS_CANCEL");
          }];
}
- (void)exportMemory:(Reply)reply {
    if (self.busy || !self.pages.firstObject) {
        if (reply)
            reply(nil, @"请等待当前操作结束");
        return;
    }
    self.busy = YES;
    [self progress:@"正在生成记忆文件…"];
    NSURL *profile = AFProfile(self.profileID);
    [self.pages.firstObject callAsyncJavaScript:@"return await window.AtlasMemory.capture()"
                                      arguments:@{}
                                        inFrame:nil
                                 inContentWorld:WKContentWorld.pageWorld
                              completionHandler:^(id value, NSError *e) {
                                  if (e || ![value isKindOfClass:NSString.class]) {
                                      self.busy = NO;
                                      [self progress:nil];
                                      NSString *s = errorText(e);
                                      if (reply)
                                          reply(nil, s);
                                      else
                                          [self tell:@"备份失败" message:s];
                                      return;
                                  }
                                  dispatch_async(self.io, ^{
                                      NSError *err = nil;
                                      NSURL *file = AFPack(value, profile, &err);
                                      mainQueue(^{
                                          [self progress:nil];
                                          if (!file) {
                                              self.busy = NO;
                                              NSString *s = errorText(err);
                                              if (reply)
                                                  reply(nil, s);
                                              else
                                                  [self tell:@"备份失败" message:s];
                                              return;
                                          }
                                          [self exportFile:file
                                                     reply:^(id result, NSString *issue) {
                                                         self.busy = NO;
                                                         if (result)
                                                             [self hideNotice];
                                                         if (reply)
                                                             reply(result, issue);
                                                         [self processPending];
                                                     }];
                                      });
                                  });
                              }];
}
- (void)importPicker:(Reply)reply {
    if (self.busy) {
        reply(nil, @"请等待当前操作结束");
        return;
    }
    UTType *memory = [UTType typeWithIdentifier:MemoryType];
    UIDocumentPickerViewController *p = [[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:@[ memory ?: UTTypeData, UTTypeJSON ]
                            asCopy:YES];
    [self pick:p
          then:^(NSURL *url) {
              reply(url ? @YES : nil, url ? nil : @"ATLAS_CANCEL");
              if (url)
                  [self receiveURL:url];
          }];
}
- (void)processPending {
    if (self.pendingURL && !self.busy && self.view.window && !self.presentedViewController) {
        NSURL *url = self.pendingURL;
        self.pendingURL = nil;
        [self receiveURL:url];
    }
}
- (void)receiveURL:(NSURL *)url {
    if (!url.isFileURL)
        return;
    if (self.busy || !self.isViewLoaded || !self.view.window || !self.pages.count ||
        self.presentedViewController) {
        self.pendingURL = url;
        return;
    }
    if (![@[ @"atlasbackup", @"json" ] containsObject:url.pathExtension.lowercaseString]) {
        [self tell:@"无法识别文件" message:@"请选择 .atlasbackup 记忆文件或原版 v2 备份 JSON。"];
        return;
    }
    NSString *s = [NSString
        stringWithFormat:@"从“%@”恢复后，将切换到备份中的学习记录和设置。", url.lastPathComponent];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"恢复学习数据？"
                                                               message:s
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"恢复"
                                          style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *action) {
                                            [self beginRestore:url];
                                        }]];
    [self presentViewController:a animated:YES completion:nil];
}
- (void)beginRestore:(NSURL *)url {
    if (self.busy)
        return;
    self.busy = YES;
    [self progress:@"正在检查记忆文件…"];
    self.restoreID = NSUUID.UUID.UUIDString;
    NSURL *dest = AFProfile(self.restoreID);
    dispatch_async(self.io, ^{
        NSError *e = nil;
        NSURL *state = AFPrepareRestore(url, dest, &e);
        mainQueue(^{
            if (!state) {
                [self restoreFailed:e];
                return;
            }
            self.restoreState = state;
            self.materialRoots =
                @[ AFChild(AFProfile(self.profileID), @"materials"), AFChild(dest, @"materials") ];
            self.extensionFiles = AFExtensionFiles(AFChild(dest, @"materials"));
            self.candidate = [self newView:[self config:self.restoreID]];
            self.candidate.alpha = .01;
            self.candidate.userInteractionEnabled = NO;
            [self.host sendSubviewToBack:self.candidate];
            [self loadPath:@"/_atlas/restore.html" in:self.candidate];
        });
    });
}
- (void)runRestore:(WKWebView *)v {
    NSURL *file = self.restoreState;
    self.restoreState = nil;
    [self progress:@"正在恢复并核对学习数据…"];
    dispatch_async(self.io, ^{
        NSError *e = nil;
        NSString *state = [NSString stringWithContentsOfURL:file encoding:NSUTF8StringEncoding error:&e];
        mainQueue(^{
            if (self.candidate != v)
                return;
            if (!state) {
                [self restoreFailed:e];
                return;
            }
            [v callAsyncJavaScript:@"return await window.AtlasMemory.restore(payload)"
                         arguments:@{@"payload" : state}
                           inFrame:nil
                    inContentWorld:WKContentWorld.pageWorld
                 completionHandler:^(id value, NSError *err) {
                     if (self.candidate != v)
                         return;
                     if (err || ![value isEqual:@YES]) {
                         [self restoreFailed:err ?: AFError(@"恢复校验失败")];
                         return;
                     }
                     [NSFileManager.defaultManager removeItemAtURL:file error:NULL];
                     self.validating = YES;
                     [self loadPath:@"/index.html" in:v];
                 }];
        });
    });
}
- (void)validateHome:(WKWebView *)v {
    self.validating = NO;
    NSString *verify =
        @"const end=Date.now()+30000;while(!window.AppData?.backups){if(Date.now()>end)throw "
        @"Error('学习模块没有启动');await new Promise(r=>setTimeout(r,100));}await "
        @"window.AppData.ready;await window.AppData.practice.list();return true;";
    [v callAsyncJavaScript:verify
                 arguments:@{}
                   inFrame:nil
            inContentWorld:WKContentWorld.pageWorld
         completionHandler:^(id result, NSError *e) {
             if (self.candidate != v)
                 return;
             if (e || ![result isEqual:@YES]) {
                 [self restoreFailed:e ?: AFError(@"恢复后首页校验失败")];
                 return;
             }
             NSError *io = nil;
             if (![self persistProfile:self.restoreID error:&io]) {
                 [self restoreFailed:io];
                 return;
             }
             NSString *old = self.profileID;
             self.profileID = self.restoreID;
             self.restoreID = nil;
             self.materialRoots = @[ AFChild(AFProfile(self.profileID), @"materials") ];
             self.extensionFiles = AFExtensionFiles(self.materialRoots.firstObject);
             NSArray *oldPages = self.pages.copy;
             [self.pages removeAllObjects];
             for (WKWebView *p in oldPages) {
                 p.navigationDelegate = nil;
                 p.UIDelegate = nil;
                 [p.configuration.userContentController
                     removeScriptMessageHandlerForName:@"atlasPort"
                                          contentWorld:WKContentWorld.pageWorld];
                 [p stopLoading];
                 [p removeFromSuperview];
             }
             self.candidate = nil;
             v.alpha = 1;
             v.userInteractionEnabled = YES;
             [self.pages addObject:v];
             [self show:v];
             [self progress:nil];
             [self hideNotice];
             self.busy = NO;
             [self tell:@"恢复完成" message:@"已打开备份中的学习记录。"];
             mainQueue(^{
                 [self discard:old];
             });
         }];
}
- (void)discard:(NSString *)uuid {
    if (!uuid.length || [uuid isEqual:self.profileID])
        return;
    NSUUID *identifier = [[NSUUID alloc] initWithUUIDString:uuid];
    if (!identifier)
        return;
    [WKWebsiteDataStore
        removeDataStoreForIdentifier:identifier
                   completionHandler:^(NSError *error) {
                       if (!error)
                           dispatch_async(self.io, ^{
                               [NSFileManager.defaultManager removeItemAtURL:AFProfile(uuid) error:NULL];
                           });
                   }];
}
- (void)restoreFailed:(NSError *)err {
    NSString *bad = self.restoreID;
    WKWebView *v = self.candidate;
    v.navigationDelegate = nil;
    v.UIDelegate = nil;
    [v.configuration.userContentController removeScriptMessageHandlerForName:@"atlasPort"
                                                                contentWorld:WKContentWorld.pageWorld];
    [v stopLoading];
    [v removeFromSuperview];
    self.candidate = nil;
    self.restoreState = nil;
    self.restoreID = nil;
    self.validating = NO;
    self.materialRoots = @[ AFChild(AFProfile(self.profileID), @"materials") ];
    self.extensionFiles = AFExtensionFiles(self.materialRoots.firstObject);
    [self progress:nil];
    self.busy = NO;
    [self tell:@"未能恢复" message:errorText(err)];
    mainQueue(^{
        [self discard:bad];
    });
}
- (void)webView:(WKWebView *)w didFinishNavigation:(WKNavigation *)nav {
    if (w == self.candidate) {
        if (self.restoreState && [w.URL.path isEqual:@"/_atlas/restore.html"])
            [self runRestore:w];
        else if (self.validating && [w.URL.path isEqual:@"/index.html"])
            [self validateHome:w];
        return;
    }
    [self updateBar];
    [self processPending];
}
- (void)webView:(WKWebView *)v didFailProvisionalNavigation:(WKNavigation *)n withError:(NSError *)e {
    if (e.code == NSURLErrorCancelled)
        return;
    if (v == self.candidate) {
        [self restoreFailed:e];
        return;
    }
    if (v == self.pages.firstObject)
        [self tell:@"页面未能打开" message:errorText(e)];
}
- (void)webView:(WKWebView *)v didFailNavigation:(WKNavigation *)n withError:(NSError *)e {
    [self webView:v didFailProvisionalNavigation:n withError:e];
}
- (void)webViewWebContentProcessDidTerminate:(WKWebView *)v {
    if (v == self.candidate)
        [self restoreFailed:AFError(@"恢复进程已中断，请重新打开记忆文件")];
    else
        [v reload];
}
- (void)chooseFolder:(NSString *)op reply:(Reply)reply {
    BOOL extension = [op isEqual:@"chooseExtensions"],
         library = extension || [op isEqual:@"chooseLibrary"];
    UIDocumentPickerViewController *p =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[ UTTypeFolder ] asCopy:NO];
    [self pick:p
          then:^(NSURL *url) {
              if (!url) {
                  reply(nil, @"ATLAS_CANCEL");
                  return;
              }
              self.busy = YES;
              [self progress:library ? @"正在复制题库文件…" : @"正在连接备份文件夹…"];
              NSURL *m = AFChild(AFProfile(self.profileID), @"materials");
              dispatch_async(self.io, ^{
                  NSError *e = nil;
                  id result = library ? AFImportFolder(url, m, extension, &e) : AFBindFolder(url, &e);
                  mainQueue(^{
                      self.busy = NO;
                      if (result && library)
                          self.extensionFiles = AFExtensionFiles(m);
                      [self progress:nil];
                      reply(result, result ? nil : errorText(e));
                      [self processPending];
                  });
              });
          }];
}
- (void)userContentController:(WKUserContentController *)c
      didReceiveScriptMessage:(WKScriptMessage *)message
                 replyHandler:(void (^)(id, NSString *))reply {
    NSDictionary *r = [message.body isKindOfClass:NSDictionary.class] ? message.body : nil;
    NSString *op = r[@"op"];
    WKWebView *v = message.webView;
    if (!allowedFrame(message) || ![op isKindOfClass:NSString.class] || ![self.pages containsObject:v]) {
        reply(nil, @"此页面不能访问 iPad 文件");
        return;
    }
    if ([op isEqual:@"focus"]) {
        if (!self.busy)
            [self show:v];
        reply(@YES, nil);
        return;
    }
    if ([op isEqual:@"completed"]) {
        [self offerBackup];
        reply(@YES, nil);
        return;
    }
    if ([op isEqual:@"download"]) {
        NSString *name = r[@"name"], *data = r[@"data"];
        if (![data isKindOfClass:NSString.class] || ![name isKindOfClass:NSString.class]) {
            reply(nil, @"下载文件无效");
            return;
        }
        dispatch_async(self.io, ^{
            NSError *e = nil;
            NSURL *dir = AFTemp(&e);
            NSURL *out =
                dir ? AFChild(dir, AFSafePart(name) ? name.lastPathComponent : @"IELTS-Atlas") : nil;
            NSData *bytes = [[NSData alloc] initWithBase64EncodedString:data options:0];
            BOOL ok = out && bytes && [bytes writeToURL:out options:NSDataWritingAtomic error:&e];
            mainQueue(^{
                if (ok)
                    [self exportFile:out reply:reply];
                else
                    reply(nil, errorText(e));
            });
        });
        return;
    }
    BOOL home = v == self.pages.firstObject && localURL(v.URL) &&
                ([v.URL.path isEqual:@"/index.html"] || [v.URL.path isEqual:@"/"]);
    if (!home) {
        reply(nil, @"请从主窗口打开文件");
        return;
    }
    if ([op isEqual:@"disk"]) {
        dispatch_async(self.io, ^{
            NSError *e = nil;
            id result = AFDisk(r, &e);
            mainQueue(^{
                reply(result, result ? nil : errorText(e));
            });
        });
        return;
    }
    if (self.busy || self.picker) {
        reply(nil, @"请等待当前文件操作结束");
        return;
    }
    if ([op isEqual:@"exportMemory"])
        [self exportMemory:reply];
    else if ([op isEqual:@"importMemory"])
        [self importPicker:reply];
    else if ([op isEqual:@"chooseLibrary"] || [op isEqual:@"chooseBackupDirectory"] ||
             [op isEqual:@"chooseExtensions"])
        [self chooseFolder:op reply:reply];
    else
        reply(nil, @"未知的文件操作");
}
@end
@interface AtlasScene : UIResponder <UIWindowSceneDelegate>
@property(nonatomic, strong) UIWindow *window;
@end
@implementation AtlasScene
- (void)scene:(UIScene *)scene
    willConnectToSession:(UISceneSession *)session
                 options:(UISceneConnectionOptions *)options {
    AtlasController *root = [AtlasController new];
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = root;
    [self.window makeKeyAndVisible];
    NSURL *url = options.URLContexts.anyObject.URL;
    if (url)
        mainQueue(^{
            [root receiveURL:url];
        });
}
- (void)scene:(UIScene *)scene openURLContexts:(NSSet<UIOpenURLContext *> *)contexts {
    NSURL *url = contexts.anyObject.URL;
    if (url)
        [(AtlasController *)self.window.rootViewController receiveURL:url];
}
@end
@interface AtlasApp : UIResponder <UIApplicationDelegate>
@end
@implementation AtlasApp
- (UISceneConfiguration *)application:(UIApplication *)application
    configurationForConnectingSceneSession:(UISceneSession *)session
                                   options:(UISceneConnectionOptions *)options {
    UISceneConfiguration *config = [[UISceneConfiguration alloc] initWithName:@"Atlas"
                                                                  sessionRole:session.role];
    config.delegateClass = AtlasScene.class;
    return config;
}
@end
int main(int argc, char **argv) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(AtlasApp.class));
    }
}
