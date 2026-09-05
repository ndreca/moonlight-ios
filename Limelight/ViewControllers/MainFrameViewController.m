//  MainFrameViewController.m
//  Moonlight
//
//  Created by Diego Waxemberg on 1/17/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

@import ImageIO;
@import GameController;

#import "MainFrameViewController.h"
#import "AppDelegate.h"
#import "CryptoManager.h"
#import "HttpManager.h"
#import "Connection.h"
#import "StreamManager.h"
#import "Utils.h"
#import "UIComputerView.h"
#import "UIAppView.h"
#import "DataManager.h"
#import "TemporarySettings.h"
#import "WakeOnLanManager.h"
#import "AppListResponse.h"
#import "ServerInfoResponse.h"
#import "StreamFrameViewController.h"
#import "LoadingFrameViewController.h"
#import "ComputerScrollView.h"
#import "TemporaryApp.h"
#import "IdManager.h"
#import "ConnectionHelper.h"

#if !TARGET_OS_TV
#import "SettingsViewController.h"

@interface MoonlightBrowserControllerState : NSObject
@property(nonatomic) int lastButtonFlags;
@property(nonatomic) NSInteger horizontalStickLatch;
@property(nonatomic) NSInteger verticalStickLatch;
@property(nonatomic) BOOL menuPressed;
@property(nonatomic) int rawButtonFlags;
@property(nonatomic) BOOL rawMenuPressed;
@property(nonatomic) NSInteger rawHorizontalStickDirection;
@property(nonatomic) NSInteger rawVerticalStickDirection;
@property(nonatomic) BOOL awaitingNeutral;
@end

@implementation MoonlightBrowserControllerState
@end
#else
#import <sys/utsname.h>
#endif

#import <VideoToolbox/VideoToolbox.h>

#include <Limelight.h>
#include <math.h>

@interface MainFrameViewController ()

- (void)configureBrowsingControllerCallbacks;
- (void)clearBrowsingControllerCallbacks;
- (BOOL)beginStreamLaunch;

#if !TARGET_OS_TV
- (BOOL)browserControllerInputAvailable;
- (void)handleBrowserControllerSnapshotForController:(GCController *)controller
                                     buttonFlags:(int)buttonFlags
                                           menu:(BOOL)menuPressed
                                          stickX:(float)stickX
                                          stickY:(float)stickY;
- (void)resetBrowserControllerSelection;
- (void)updateBrowserControllerSelectionAtIndexPath:(NSIndexPath *)indexPath animated:(BOOL)animated;
- (void)moveBrowserControllerSelectionHorizontal:(NSInteger)horizontal vertical:(NSInteger)vertical;
- (void)activateBrowserControllerSelection;
- (void)toggleSettingsFromController;
- (void)openSettingsOverlay;
- (void)dismissSettingsOverlay;
- (UIView *)navigationGlassControlWithImageName:(NSString *)imageName
                                         action:(SEL)action
                             accessibilityLabel:(NSString *)accessibilityLabel
                        accessibilityIdentifier:(NSString *)accessibilityIdentifier;
#endif

@end

@implementation MainFrameViewController {
    NSOperationQueue* _opQueue;
    TemporaryHost* _selectedHost;
    BOOL _showHiddenApps;
    NSString* _uniqueId;
    NSData* _clientCert;
    DiscoveryManager* _discMan;
    AppAssetManager* _appManager;
    StreamConfiguration* _streamConfig;
    UIAlertController* _pairAlert;
    LoadingFrameViewController* _loadingFrame;
    UIScrollView* hostScrollView;
    FrontViewPosition currentPosition;
    NSArray* _sortedAppList;
    NSArray* _sortedHostList;
    NSCache* _boxArtCache;
    bool _background;
    BOOL _showingHosts;
    BOOL _streamLaunchInProgress;
    CGSize _lastCollectionBoundsSize;
#if !TARGET_OS_TV
    id _browserControllerConnectObserver;
    id _browserControllerDisconnectObserver;
    dispatch_queue_t _browserControllerQueue;
    uint64_t _browserControllerGeneration;
    BOOL _browserControllerOwnershipActive;
    NSMutableDictionary<NSValue *, MoonlightBrowserControllerState *> *_browserControllerStates;
    NSIndexPath *_browserControllerIndexPath;
    CFTimeInterval _lastBrowserControllerActivationTime;
    UINavigationController *_settingsOverlayController;
    UIBarButtonItem *_backButtonItem;
#endif
#if TARGET_OS_TV
    UITapGestureRecognizer* _menuRecognizer;
#endif
}
static NSMutableSet* hostList;

#if !TARGET_OS_TV
enum {
    BrowserButtonA     = 1 << 0,
    BrowserButtonB     = 1 << 1,
    BrowserButtonUp    = 1 << 2,
    BrowserButtonDown  = 1 << 3,
    BrowserButtonLeft  = 1 << 4,
    BrowserButtonRight = 1 << 5,
};
#endif

- (void)startPairing:(NSString *)PIN {
    // Needs to be synchronous to ensure the alert is shown before any potential
    // failure callback could be invoked.
    dispatch_sync(dispatch_get_main_queue(), ^{
        self->_pairAlert = [UIAlertController alertControllerWithTitle:@"Pairing"
                                                               message:[NSString stringWithFormat:@"Enter the following PIN on the host machine: %@\n\nIf your host PC is running Sunshine, navigate to the Sunshine web UI to enter the PIN.", PIN]
                                                        preferredStyle:UIAlertControllerStyleAlert];
        [self->_pairAlert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleDestructive handler:^(UIAlertAction* action) {
            self->_pairAlert = nil;
            [self->_discMan startDiscovery];
            [self hideLoadingFrame: ^{
                [self showHostSelectionView];
            }];
        }]];
        [[self activeViewController] presentViewController:self->_pairAlert animated:YES completion:nil];
    });
}

- (void)displayPairingFailureDialog:(NSString *)message {
    UIAlertController* failedDialog = [UIAlertController alertControllerWithTitle:@"Pairing Failed"
                                                                          message:message
                                                                   preferredStyle:UIAlertControllerStyleAlert];
    [Utils addHelpOptionToDialog:failedDialog];
    [failedDialog addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    
    [_discMan startDiscovery];
    
    [self hideLoadingFrame: ^{
        [self showHostSelectionView];
        [[self activeViewController] presentViewController:failedDialog animated:YES completion:nil];
    }];
}

- (void)pairFailed:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_pairAlert != nil) {
            [self->_pairAlert dismissViewControllerAnimated:YES completion:^{
                [self displayPairingFailureDialog:message];
            }];
            self->_pairAlert = nil;
        }
    });
}

- (void)pairSuccessful:(NSData*)serverCert {
    dispatch_async(dispatch_get_main_queue(), ^{
        // Store the cert from pairing with the host
        self->_selectedHost.serverCert = serverCert;
        
        [self->_pairAlert dismissViewControllerAnimated:YES completion:nil];
        self->_pairAlert = nil;
        
        [self->_discMan startDiscovery];
        [self alreadyPaired];
    });
}

- (void)disableUpButton {
#if !TARGET_OS_TV
    self.navigationItem.rightBarButtonItem = nil;
    self.navigationItem.rightBarButtonItems = @[];
#endif
}

- (void)enableUpButton {
#if !TARGET_OS_TV
    self.navigationItem.rightBarButtonItem = _backButtonItem;
#endif
}

- (void)updateTitle {
    if (_selectedHost != nil) {
        self.title = _selectedHost.name;
    }
    else if ([hostList count] == 0) {
        self.title = @"Looking for computers…";
    }
    else {
        self.title = @"Computers";
    }
}

- (void)alreadyPaired {
    BOOL usingCachedAppList = false;
    
    // Capture the host here because it can change once we
    // leave the main thread
    TemporaryHost* host = _selectedHost;
    if (host == nil) {
        [self hideLoadingFrame: nil];
        return;
    }
    
    if ([host.appList count] > 0) {
        usingCachedAppList = true;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (host != self->_selectedHost) {
                [self hideLoadingFrame: nil];
                return;
            }
            
            [self updateAppsForHost:host];
            [self hideLoadingFrame: nil];
        });
    }
    Log(LOG_I, @"Using cached app list: %d", usingCachedAppList);
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // Exempt this host from discovery while handling the applist query
        [self->_discMan pauseDiscoveryForHost:host];
        
        AppListResponse* appListResp = [ConnectionHelper getAppListForHost:host];
        
        [self->_discMan resumeDiscoveryForHost:host];

        if (![appListResp isStatusOk] || [appListResp getAppList] == nil) {
            Log(LOG_W, @"Failed to get applist: %@", appListResp.statusMessage);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (host != self->_selectedHost) {
                    [self hideLoadingFrame: nil];
                    return;
                }
                
                UIAlertController* applistAlert = [UIAlertController alertControllerWithTitle:@"Connection Interrupted"
                                                                                      message:appListResp.statusMessage
                                                                               preferredStyle:UIAlertControllerStyleAlert];
                [Utils addHelpOptionToDialog:applistAlert];
                [applistAlert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                [self hideLoadingFrame: ^{
                    [self showHostSelectionView];
                    [[self activeViewController] presentViewController:applistAlert animated:YES completion:nil];
                }];
                host.state = StateOffline;
            });
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self updateApplist:[appListResp getAppList] forHost:host];

                if (host != self->_selectedHost) {
                    [self hideLoadingFrame: nil];
                    return;
                }
                
                [self updateAppsForHost:host];
                [self->_appManager stopRetrieving];
                [self->_appManager retrieveAssetsFromHost:host];
                [self hideLoadingFrame: nil];
            });
        }
    });
}

- (void) updateAppEntry:(TemporaryApp*)app forHost:(TemporaryHost*)host {
    DataManager* database = [[DataManager alloc] init];
    NSMutableSet* newHostAppList = [NSMutableSet setWithSet:host.appList];

    for (TemporaryApp* savedApp in newHostAppList) {
        if ([app.id isEqualToString:savedApp.id]) {
            savedApp.name = app.name;
            savedApp.hdrSupported = app.hdrSupported;
            savedApp.hidden = app.hidden;
            
            host.appList = newHostAppList;

            [database updateAppsForExistingHost:host];
            return;
        }
    }
}
    
- (void) updateApplist:(NSSet*) newList forHost:(TemporaryHost*)host {
    DataManager* database = [[DataManager alloc] init];
    NSMutableSet* newHostAppList = [NSMutableSet setWithSet:host.appList];
    
    for (TemporaryApp* app in newList) {
        BOOL appAlreadyInList = NO;
        for (TemporaryApp* savedApp in newHostAppList) {
            if ([app.id isEqualToString:savedApp.id]) {
                savedApp.name = app.name;
                savedApp.hdrSupported = app.hdrSupported;
                // Don't propagate hidden, because we want the local data to prevail
                appAlreadyInList = YES;
                break;
            }
        }
        if (!appAlreadyInList) {
            app.host = host;
            [newHostAppList addObject:app];
        }
    }
    
    BOOL appWasRemoved;
    do {
        appWasRemoved = NO;
        
        for (TemporaryApp* app in newHostAppList) {
            appWasRemoved = YES;
            for (TemporaryApp* mergedApp in newList) {
                if ([mergedApp.id isEqualToString:app.id]) {
                    appWasRemoved = NO;
                    break;
                }
            }
            if (appWasRemoved) {
                // Removing the app mutates the list we're iterating (which isn't legal).
                // We need to jump out of this loop and restart enumeration.
                
                [newHostAppList removeObject:app];
                
                // It's important to remove the app record from the database
                // since we'll have a constraint violation now that appList
                // doesn't have this app in it.
                [database removeApp:app];
                
                break;
            }
        }
        
        // Keep looping until the list is no longer being mutated
    } while (appWasRemoved);
    
    host.appList = newHostAppList;

    [database updateAppsForExistingHost:host];
    
    // This host may be eligible for a shortcut now that the app list
    // has been populated
    [self updateHostShortcuts];
}

- (void)showHostSelectionView {
#if TARGET_OS_TV
    // Remove the menu button intercept to allow the app to exit
    // when at the host selection view.
    [self.navigationController.view removeGestureRecognizer:_menuRecognizer];
#endif
    
    [_appManager stopRetrieving];
    _showHiddenApps = NO;
    _selectedHost = nil;
    _sortedAppList = nil;
    _showingHosts = YES;
#if !TARGET_OS_TV
    [self resetBrowserControllerSelection];
#endif
    
    [self updateTitle];
    [self disableUpButton];
    
    [self.collectionView reloadData];
#if !TARGET_OS_TV
    if (_browserControllerStates.count > 0 &&
        [self collectionView:self.collectionView numberOfItemsInSection:0] > 0) {
        [self updateBrowserControllerSelectionAtIndexPath:[NSIndexPath indexPathForItem:0 inSection:0]
                                                 animated:NO];
    }
#endif
#if TARGET_OS_TV
    [self.view addSubview:hostScrollView];
#endif
}

- (void) receivedAssetForApp:(TemporaryApp*)app {
    // Update the box art cache now so we don't have to do it
    // on the main thread
    [self updateBoxArtCacheForApp:app];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.collectionView reloadData];
    });
}

- (void)displayDnsFailedDialog {
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Network Error"
                                                                   message:@"Failed to resolve host."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [Utils addHelpOptionToDialog:alert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [[self activeViewController] presentViewController:alert animated:YES completion:nil];
}

- (void) hostClicked:(TemporaryHost *)host view:(UIView *)view {
    // Treat clicks on offline hosts to be long clicks
    // This shows the context menu with wake, delete, etc. rather
    // than just hanging for a while and failing as we would in this
    // code path.
    if (host.state != StateOnline && view != nil) {
        [self hostLongClicked:host view:view];
        return;
    }
    
    Log(LOG_D, @"Clicked host: %@", host.name);
    _selectedHost = host;
    [self updateTitle];
    [self enableUpButton];
    [self disableNavigation];
    
#if TARGET_OS_TV
    // Intercept the menu key to go back to the host page
    [self.navigationController.view addGestureRecognizer:_menuRecognizer];
#endif
    
    // If we are online, paired, and have a cached app list, skip straight
    // to the app grid without a loading frame. This is the fast path that users
    // should hit most. Check for a valid view because we don't want to hit the fast
    // path after coming back from streaming, since we need to fetch serverinfo too
    // so that our active game data is correct.
    if (host.state == StateOnline && host.pairState == PairStatePaired && host.appList.count > 0 && view != nil) {
        [self alreadyPaired];
        return;
    }
    
    [self showLoadingFrame: ^{
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            // Wait for the PC's status to be known
            while (host.state == StateUnknown) {
                sleep(1);
            }
            
            // Don't bother polling if the server is already offline
            if (host.state == StateOffline) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self hideLoadingFrame:^{
                        [self showHostSelectionView];
                    }];
                });
                return;
            }
            
            HttpManager* hMan = [[HttpManager alloc] initWithHost:host];
            ServerInfoResponse* serverInfoResp = [[ServerInfoResponse alloc] init];
            
            // Exempt this host from discovery while handling the serverinfo request
            [self->_discMan pauseDiscoveryForHost:host];
            [hMan executeRequestSynchronously:[HttpRequest requestForResponse:serverInfoResp withUrlRequest:[hMan newServerInfoRequest:false]
                                                                fallbackError:401 fallbackRequest:[hMan newHttpServerInfoRequest]]];
            [self->_discMan resumeDiscoveryForHost:host];
            
            if (![serverInfoResp isStatusOk]) {
                Log(LOG_W, @"Failed to get server info: %@", serverInfoResp.statusMessage);
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (host != self->_selectedHost) {
                        [self hideLoadingFrame:nil];
                        return;
                    }
                    
                    UIAlertController* applistAlert = [UIAlertController alertControllerWithTitle:@"Connection Failed"
                                                                            message:serverInfoResp.statusMessage
                                                                                   preferredStyle:UIAlertControllerStyleAlert];
                    [Utils addHelpOptionToDialog:applistAlert];
                    [applistAlert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                    
                    // Only display an alert if this was the result of a real
                    // user action, not just passively entering the foreground again
                    [self hideLoadingFrame: ^{
                        [self showHostSelectionView];
                        if (view != nil) {
                            [[self activeViewController] presentViewController:applistAlert animated:YES completion:nil];
                        }
                    }];
                    
                    host.state = StateOffline;
                });
            } else {
                // Update the host object with this data
                [serverInfoResp populateHost:host];
                if (host.pairState == PairStatePaired) {
                    Log(LOG_I, @"Already Paired");
                    [self alreadyPaired];
                }
                // Only pair when this was the result of explicit user action
                else if (view != nil) {
                    Log(LOG_I, @"Trying to pair");
                    // Polling the server while pairing causes the server to screw up
                    [self->_discMan stopDiscoveryBlocking];
                    PairManager* pMan = [[PairManager alloc] initWithManager:hMan clientCert:self->_clientCert callback:self];
                    [self->_opQueue addOperation:pMan];
                }
                else {
                    // Not user action, so just return to host screen
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self hideLoadingFrame:^{
                            [self showHostSelectionView];
                        }];
                    });
                }
            }
        });
    }];
}

- (UIViewController*) activeViewController {
    UIWindow *window = self.view.window;
    if (window == nil) {
        AppDelegate *appDelegate = (AppDelegate *)UIApplication.sharedApplication.delegate;
        window = appDelegate.activeWindow;
    }
    UIViewController *topController = window.rootViewController;

    while (topController.presentedViewController) {
        topController = topController.presentedViewController;
    }

    return topController;
}

- (void)hostLongClicked:(TemporaryHost *)host view:(UIView *)view {
    Log(LOG_D, @"Long clicked host: %@", host.name);
    NSString* message;
    
    switch (host.state) {
        case StateOffline:
            message = @"Offline";
            break;
            
        case StateOnline:
            if (host.pairState == PairStatePaired) {
                message = @"Online - Paired";
            }
            else {
                message = @"Online - Not Paired";
            }
            break;
        
        case StateUnknown:
            message = @"Connecting";
            break;
            
        default:
            break;
    }
    
    UIAlertController* longClickAlert = [UIAlertController alertControllerWithTitle:host.name message:message preferredStyle:UIAlertControllerStyleActionSheet];
    if (host.state != StateOnline) {
        [longClickAlert addAction:[UIAlertAction actionWithTitle:@"Wake PC" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action){
            UIAlertController* wolAlert = [UIAlertController alertControllerWithTitle:@"Wake-On-LAN" message:@"" preferredStyle:UIAlertControllerStyleAlert];
            [wolAlert addAction:[UIAlertAction actionWithTitle:@"OK"
                                                         style:UIAlertActionStyleDefault
                                                       handler:^(UIAlertAction *okAction) {
                [self configureBrowsingControllerCallbacks];
            }]];
            if (host.mac == nil || [host.mac isEqualToString:@"00:00:00:00:00:00"]) {
                wolAlert.message = @"Host MAC unknown, unable to send WOL Packet";
            } else {
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    [WakeOnLanManager wakeHost:host];
                });
                wolAlert.message = @"Successfully sent wake-up request. It may take a few moments for the PC to wake. If it never wakes up, ensure it's properly configured for Wake-on-LAN.";
            }
            [[self activeViewController] presentViewController:wolAlert animated:YES completion:nil];
        }]];
    }
    else if (host.pairState == PairStatePaired) {
        [longClickAlert addAction:[UIAlertAction actionWithTitle:@"View All Apps" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action){
            [self configureBrowsingControllerCallbacks];
            self->_showHiddenApps = YES;
            [self hostClicked:host view:view];
        }]];
        
#if !TARGET_OS_TV
        if (host.isNvidiaServerSoftware) {
            [longClickAlert addAction:[UIAlertAction actionWithTitle:@"NVIDIA GameStream End-of-Service" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action){
                [self configureBrowsingControllerCallbacks];
                [Utils launchUrl:@"https://github.com/moonlight-stream/moonlight-docs/wiki/NVIDIA-GameStream-End-Of-Service-Announcement-FAQ"];
            }]];
        }
#endif
    }
    [longClickAlert addAction:[UIAlertAction actionWithTitle:@"Test Network" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
        [self showLoadingFrame:^{
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                // Perform the network test on a GCD worker thread. It may take a while.
                unsigned int portTestResult = LiTestClientConnectivity(CONN_TEST_SERVER, 443, ML_PORT_FLAG_ALL);
                dispatch_sync(dispatch_get_main_queue(), ^{
                    [self hideLoadingFrame:^{
                        NSString* message;
                        
                        if (portTestResult == 0) {
                            message = @"This network does not appear to be blocking Moonlight. If you still have trouble connecting, check your PC's firewall settings.\n\nVisit the Moonlight Setup Guide on GitHub for additional setup help and troubleshooting steps.";
                        }
                        else if (portTestResult == ML_TEST_RESULT_INCONCLUSIVE) {
                            message = @"The network test could not be performed because none of Moonlight's connection testing servers were reachable. Check your Internet connection or try again later.";
                        }
                        else {
                            char blockedPorts[512];
                            LiStringifyPortFlags(portTestResult, "\n", blockedPorts, sizeof(blockedPorts));
                            message = [NSString stringWithFormat:@"Your current network connection seems to be blocking Moonlight. Streaming may not work while connected to this network.\n\nThe following network ports were blocked:\n%s", blockedPorts];
                        }
                        
                        UIAlertController* netTestAlert = [UIAlertController alertControllerWithTitle:@"Network Test Complete" message:message preferredStyle:UIAlertControllerStyleAlert];
                        [netTestAlert addAction:[UIAlertAction actionWithTitle:@"OK"
                                                                        style:UIAlertActionStyleDefault
                                                                      handler:^(UIAlertAction *okAction) {
                            [self configureBrowsingControllerCallbacks];
                        }]];
                        [[self activeViewController] presentViewController:netTestAlert animated:YES completion:nil];
                    }];
                });
            });
        }];
    }]];
#if !TARGET_OS_TV
    if (host.state != StateOnline) {
        [longClickAlert addAction:[UIAlertAction actionWithTitle:@"NVIDIA GameStream End-of-Service" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action){
            [self configureBrowsingControllerCallbacks];
            [Utils launchUrl:@"https://github.com/moonlight-stream/moonlight-docs/wiki/NVIDIA-GameStream-End-Of-Service-Announcement-FAQ"];
        }]];
        [longClickAlert addAction:[UIAlertAction actionWithTitle:@"Connection Help" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action){
            [self configureBrowsingControllerCallbacks];
            [Utils launchUrl:@"https://github.com/moonlight-stream/moonlight-docs/wiki/Troubleshooting"];
        }]];
    }
#endif
    [longClickAlert addAction:[UIAlertAction actionWithTitle:@"Remove Host" style:UIAlertActionStyleDestructive handler:^(UIAlertAction* action) {
        [self configureBrowsingControllerCallbacks];
        [self->_discMan removeHostFromDiscovery:host];
        DataManager* dataMan = [[DataManager alloc] init];
        [dataMan removeHost:host];
        @synchronized(hostList) {
            [hostList removeObject:host];
            [self updateAllHosts:[hostList allObjects]];
        }
        
    }]];
    [longClickAlert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                                       style:UIAlertActionStyleCancel
                                                     handler:^(UIAlertAction *action) {
        [self configureBrowsingControllerCallbacks];
    }]];
    
    // these two lines are required for iPad support of UIAlertSheet
    longClickAlert.popoverPresentationController.sourceView = view;
    
    longClickAlert.popoverPresentationController.sourceRect = CGRectMake(view.bounds.size.width / 2.0, view.bounds.size.height / 2.0, 1.0, 1.0); // center of the view
    [self clearBrowsingControllerCallbacks];
    [[self activeViewController] presentViewController:longClickAlert animated:YES completion:nil];
    longClickAlert.presentationController.delegate = self;
}

- (void) addHostClicked {
    Log(LOG_D, @"Clicked add host");
    UIAlertController* alertController = [UIAlertController alertControllerWithTitle:@"Add Host Manually" message:@"If Moonlight doesn't find your local gaming PC automatically,\nenter the IP address of your PC" preferredStyle:UIAlertControllerStyleAlert];
    [alertController addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                                        style:UIAlertActionStyleCancel
                                                      handler:^(UIAlertAction *action) {
        [self configureBrowsingControllerCallbacks];
    }]];
    [alertController addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action){
        [self configureBrowsingControllerCallbacks];
        NSString* hostAddress = [((UITextField*)[[alertController textFields] objectAtIndex:0]).text trim];
        [self showLoadingFrame:^{
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
                [self->_discMan discoverHost:hostAddress withCallback:^(TemporaryHost* host, NSString* error){
                    if (host != nil) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [self hideLoadingFrame:^{
                                @synchronized(hostList) {
                                    [hostList addObject:host];
                                }
                                [self updateHosts];
                            }];
                        });
                    } else {
                        unsigned int portTestResults = LiTestClientConnectivity(CONN_TEST_SERVER, 443,
                                                                                ML_PORT_FLAG_TCP_47984 | ML_PORT_FLAG_TCP_47989);
                        if (portTestResults != ML_TEST_RESULT_INCONCLUSIVE && portTestResults != 0) {
                            error = [error stringByAppendingString:@"\n\nYour device's network connection is blocking Moonlight. Streaming may not work while connected to this network."];
                        }
                        
                        UIAlertController* hostNotFoundAlert = [UIAlertController alertControllerWithTitle:@"Add Host Manually" message:error preferredStyle:UIAlertControllerStyleAlert];
                        [Utils addHelpOptionToDialog:hostNotFoundAlert];
                        [hostNotFoundAlert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [self hideLoadingFrame:^{
                                [[self activeViewController] presentViewController:hostNotFoundAlert animated:YES completion:nil];
                            }];
                        });
                    }
                }];
            });
        }];
    }]];
    [alertController addTextFieldWithConfigurationHandler:nil];
    [self clearBrowsingControllerCallbacks];
    [[self activeViewController] presentViewController:alertController animated:YES completion:nil];
}

- (void) prepareToStreamApp:(TemporaryApp *)app {
    _streamConfig = [[StreamConfiguration alloc] init];
    _streamConfig.host = app.host.activeAddress;
    _streamConfig.httpsPort = app.host.httpsPort;
    _streamConfig.appID = app.id;
    _streamConfig.appName = app.name;
    _streamConfig.serverCert = app.host.serverCert;
    
    DataManager* dataMan = [[DataManager alloc] init];
    TemporarySettings* streamSettings = [dataMan getSettings];
    
    _streamConfig.frameRate = [streamSettings.framerate intValue];
    if (@available(iOS 10.3, *)) {
        // Don't stream more FPS than the display can show
        if (_streamConfig.frameRate > [UIScreen mainScreen].maximumFramesPerSecond) {
            _streamConfig.frameRate = (int)[UIScreen mainScreen].maximumFramesPerSecond;
            Log(LOG_W, @"Clamping FPS to maximum refresh rate: %d", _streamConfig.frameRate);
        }
    }
    
    _streamConfig.height = [streamSettings.height intValue];
    _streamConfig.width = [streamSettings.width intValue];
#if TARGET_OS_TV
    // Don't allow streaming 4K on the Apple TV HD
    struct utsname systemInfo;
    uname(&systemInfo);
    if (strcmp(systemInfo.machine, "AppleTV5,3") == 0 && _streamConfig.height >= 2160) {
        Log(LOG_W, @"4K streaming not supported on Apple TV HD");
        _streamConfig.width = 1920;
        _streamConfig.height = 1080;
    }
#endif
    
    _streamConfig.bitRate = [streamSettings.bitrate intValue];
    _streamConfig.optimizeGameSettings = streamSettings.optimizeGames;
    _streamConfig.playAudioOnPC = streamSettings.playAudioOnPC;
    _streamConfig.useFramePacing = streamSettings.useFramePacing;
    _streamConfig.swapABXYButtons = streamSettings.swapABXYButtons;
    
    // multiController must be set before calling getConnectedGamepadMask
    _streamConfig.multiController = streamSettings.multiController;
    _streamConfig.gamepadMask = [ControllerSupport getConnectedGamepadMask:_streamConfig];
    
    // Probe for supported channel configurations
    int physicalOutputChannels = (int)[AVAudioSession sharedInstance].maximumOutputNumberOfChannels;
    Log(LOG_I, @"Audio device supports %d channels", physicalOutputChannels);
    
    int numberOfChannels = MIN([streamSettings.audioConfig intValue], physicalOutputChannels);
    Log(LOG_I, @"Selected number of audio channels %d", numberOfChannels);
    if (numberOfChannels >= 8) {
        _streamConfig.audioConfiguration = AUDIO_CONFIGURATION_71_SURROUND;
    }
    else if (numberOfChannels >= 6) {
        _streamConfig.audioConfiguration = AUDIO_CONFIGURATION_51_SURROUND;
    }
    else {
        _streamConfig.audioConfiguration = AUDIO_CONFIGURATION_STEREO;
    }
    
    _streamConfig.serverCodecModeSupport = app.host.serverCodecModeSupport;
    
    switch (streamSettings.preferredCodec) {
        case CODEC_PREF_AV1:
#if defined(__IPHONE_16_0) || defined(__TVOS_16_0)
            if (VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)) {
                _streamConfig.supportedVideoFormats |= VIDEO_FORMAT_AV1_MAIN8;
            }
#endif
            // Fall-through
            
        case CODEC_PREF_AUTO:
        case CODEC_PREF_HEVC:
            if (VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)) {
                _streamConfig.supportedVideoFormats |= VIDEO_FORMAT_H265;
            }
            // Fall-through
            
        case CODEC_PREF_H264:
            _streamConfig.supportedVideoFormats |= VIDEO_FORMAT_H264;
            break;
    }
    
    // HEVC is supported if the user wants it (or it's required by the chosen resolution) and the SoC supports it
    if ((_streamConfig.width > 4096 || _streamConfig.height > 4096 || streamSettings.enableHdr) && VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)) {
        _streamConfig.supportedVideoFormats |= VIDEO_FORMAT_H265;
        
        // HEVC Main10 is supported if the user wants it and the display supports it
        if (streamSettings.enableHdr && (AVPlayer.availableHDRModes & AVPlayerHDRModeHDR10) != 0) {
            _streamConfig.supportedVideoFormats |= VIDEO_FORMAT_H265_MAIN10;
        }
    }
    
#if defined(__IPHONE_16_0) || defined(__TVOS_16_0)
    // Add the AV1 Main10 format if AV1 and HDR are both enabled and supported
    if ((_streamConfig.supportedVideoFormats & VIDEO_FORMAT_MASK_AV1) && streamSettings.enableHdr &&
        VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1) && (AVPlayer.availableHDRModes & AVPlayerHDRModeHDR10) != 0) {
        _streamConfig.supportedVideoFormats |= VIDEO_FORMAT_AV1_MAIN10;
    }
#endif
}

- (BOOL)beginStreamLaunch {
    if (_streamLaunchInProgress) {
        Log(LOG_W, @"Ignoring duplicate stream launch activation");
        return NO;
    }

    _streamLaunchInProgress = YES;
    self.collectionView.userInteractionEnabled = NO;
#if !TARGET_OS_TV
    [self clearBrowsingControllerCallbacks];
#endif
    return YES;
}

- (void)appLongClicked:(TemporaryApp *)app view:(UIView *)view {
    Log(LOG_D, @"Long clicked app: %@", app.name);
    
    [_appManager stopRetrieving];
    
#if !TARGET_OS_TV
    if (currentPosition != FrontViewPositionLeft) {
        // This must not be animated because we need the position
        // to change (and notify our callback to save settings data)
        // before we call prepareToStreamApp.
        [[self revealViewController] revealToggleAnimated:NO];
    }
#endif

    TemporaryApp* currentApp = [self findRunningApp:app.host];
    
    NSString* message;
    
    if (currentApp == nil || [app.id isEqualToString:currentApp.id]) {
        if (app.hidden) {
            message = @"Hidden";
        }
        else {
            message = @"";
        }
    }
    else {
        message = [NSString stringWithFormat:@"%@ is currently running", currentApp.name];
    }
    
    UIAlertControllerStyle alertStyle = UIAlertControllerStyleActionSheet;
#if !TARGET_OS_TV
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPhone &&
        self.traitCollection.verticalSizeClass == UIUserInterfaceSizeClassCompact) {
        // iOS 27's glass action-sheet host exceeds the compact landscape
        // height by two points and emits broken-constraint diagnostics.
        alertStyle = UIAlertControllerStyleAlert;
    }
#endif

    UIAlertController* alertController = [UIAlertController
                                          alertControllerWithTitle: app.name
                                          message:message
                                          preferredStyle:alertStyle];
    
    [alertController addAction:[UIAlertAction
                                actionWithTitle:currentApp == nil ? @"Launch App" : ([app.id isEqualToString:currentApp.id] ? @"Resume App" : @"Resume Running App") style:UIAlertActionStyleDefault handler:^(UIAlertAction* action){
        if (![self beginStreamLaunch]) {
            return;
        }
        [self configureBrowsingControllerCallbacks];
        if (currentApp != nil) {
            Log(LOG_I, @"Resuming application: %@", currentApp.name);
            [self prepareToStreamApp:currentApp];
        }
        else {
            Log(LOG_I, @"Launching application: %@", app.name);
            [self prepareToStreamApp:app];
        }

        [self performSegueWithIdentifier:@"createStreamFrame" sender:nil];
    }]];
    
    if (currentApp != nil) {
        [alertController addAction:[UIAlertAction actionWithTitle:
                                    [app.id isEqualToString:currentApp.id] ? @"Quit App" : @"Quit Running App and Start" style:UIAlertActionStyleDestructive handler:^(UIAlertAction* action){
                                        [self configureBrowsingControllerCallbacks];
                                        Log(LOG_I, @"Quitting application: %@", currentApp.name);
                                        [self showLoadingFrame: ^{
                                            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                                                HttpManager* hMan = [[HttpManager alloc] initWithHost:app.host];
                                                HttpResponse* quitResponse = [[HttpResponse alloc] init];
                                                HttpRequest* quitRequest = [HttpRequest requestForResponse: quitResponse withUrlRequest:[hMan newQuitAppRequest]];
                                                
                                                // Exempt this host from discovery while handling the quit operation
                                                [self->_discMan pauseDiscoveryForHost:app.host];
                                                [hMan executeRequestSynchronously:quitRequest];
                                                if (quitResponse.statusCode == 200) {
                                                    ServerInfoResponse* serverInfoResp = [[ServerInfoResponse alloc] init];
                                                    [hMan executeRequestSynchronously:[HttpRequest requestForResponse:serverInfoResp withUrlRequest:[hMan newServerInfoRequest:false]
                                                                                                        fallbackError:401 fallbackRequest:[hMan newHttpServerInfoRequest]]];
                                                    if (![serverInfoResp isStatusOk] || [[serverInfoResp getStringTag:@"state"] hasSuffix:@"_SERVER_BUSY"]) {
                                                        // On newer GFE versions, the quit request succeeds even though the app doesn't
                                                        // really quit if another client tries to kill your app. We'll patch the response
                                                        // to look like the old error in that case, so the UI behaves.
                                                        quitResponse.statusCode = 599;
                                                    }
                                                    else if ([serverInfoResp isStatusOk]) {
                                                        // Update the host object with this info
                                                        [serverInfoResp populateHost:app.host];
                                                    }
                                                }
                                                [self->_discMan resumeDiscoveryForHost:app.host];

                                                // If it fails, display an error and stop the current operation
                                                if (quitResponse.statusCode != 200) {
                                                    UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Quitting App Failed"
                                                                                                message:@"Failed to quit app. If this app was started by "
                                                             "another device, you'll need to quit from that device."
                                                                                         preferredStyle:UIAlertControllerStyleAlert];
                                                    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                                                    dispatch_async(dispatch_get_main_queue(), ^{
                                                        [self updateAppsForHost:app.host];
                                                        [self hideLoadingFrame: ^{
                                                            [[self activeViewController] presentViewController:alert animated:YES completion:nil];
                                                        }];
                                                    });
                                                }
                                                else {
                                                    app.host.currentGame = @"0";
                                                    dispatch_async(dispatch_get_main_queue(), ^{
                                                        // If it succeeds and we're to start streaming, segue to the stream
                                                        if (![app.id isEqualToString:currentApp.id]) {
                                                            if (![self beginStreamLaunch]) {
                                                                [self hideLoadingFrame:nil];
                                                                return;
                                                            }
                                                            [self prepareToStreamApp:app];
                                                            [self hideLoadingFrame: ^{
                                                                [self performSegueWithIdentifier:@"createStreamFrame" sender:nil];
                                                            }];
                                                        }
                                                        else {
                                                            // Otherwise, just hide the loading icon
                                                            [self hideLoadingFrame:nil];
                                                        }
                                                    });
                                                }
                                            });
                                        }];
                                        
                                    }]];
    }

    if (currentApp == nil || ![app.id isEqualToString:currentApp.id] || app.hidden) {
        [alertController addAction:[UIAlertAction actionWithTitle:app.hidden ? @"Show App" : @"Hide App"
                                                            style:app.hidden ? UIAlertActionStyleDefault : UIAlertActionStyleDestructive
                                                          handler:^(UIAlertAction* action) {
            [self configureBrowsingControllerCallbacks];
            app.hidden = !app.hidden;
            [self updateAppEntry:app forHost:app.host];
            
            // Don't call updateAppsForHost because that will nuke this
            // app immediately if we're not showing hidden apps.
        }]];
    }
    
    [alertController addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                                        style:UIAlertActionStyleCancel
                                                      handler:^(UIAlertAction *action) {
        [self configureBrowsingControllerCallbacks];
    }]];

    if (alertController.popoverPresentationController != nil) {
        UIView *sourceView = view ?: self.collectionView;
        alertController.popoverPresentationController.sourceView = sourceView;
        alertController.popoverPresentationController.sourceRect =
            CGRectMake(CGRectGetMidX(sourceView.bounds), CGRectGetMidY(sourceView.bounds), 1.0, 1.0);
    }
    [self clearBrowsingControllerCallbacks];
    [[self activeViewController] presentViewController:alertController animated:YES completion:nil];
    if (alertStyle == UIAlertControllerStyleActionSheet) {
        // iOS 27 forbids changing the presentation-controller delegate of an
        // alert-style UIAlertController. Action sheets still need dismissal
        // callbacks for iPad popover/tap-outside dismissal.
        alertController.presentationController.delegate = self;
    }
}

- (void) appClicked:(TemporaryApp *)app view:(UIView *)view {
    Log(LOG_D, @"Clicked app: %@", app.name);
    
    [_appManager stopRetrieving];
    
#if !TARGET_OS_TV
    if (currentPosition != FrontViewPositionLeft) {
        // This must not be animated because we need the position
        // to change (and notify our callback to save settings data)
        // before we call prepareToStreamApp.
        [[self revealViewController] revealToggleAnimated:NO];
    }
#endif
    
    if ([self findRunningApp:app.host]) {
        // If there's a running app, display a menu
        [self appLongClicked:app view:view];
    } else {
        if (![self beginStreamLaunch]) {
            return;
        }
        [self prepareToStreamApp:app];
        [self performSegueWithIdentifier:@"createStreamFrame" sender:nil];
    }
}

- (TemporaryApp*) findRunningApp:(TemporaryHost*)host {
    for (TemporaryApp* app in host.appList) {
        if ([app.id isEqualToString:host.currentGame]) {
            return app;
        }
    }
    return nil;
}

#if !TARGET_OS_TV
- (void)revealController:(SWRevealViewController *)revealController didMoveToPosition:(FrontViewPosition)position {
    // If we moved back to the center position, we should save the settings
    if (position == FrontViewPositionLeft) {
        [(SettingsViewController*)[revealController rearViewController] saveSettings];
    }

    BOOL settingsVisible = position != FrontViewPositionLeft;
    revealController.frontViewController.view.accessibilityElementsHidden = settingsVisible;
    revealController.rearViewController.view.accessibilityViewIsModal = settingsVisible;
    if (settingsVisible) {
        UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification,
                                        revealController.rearViewController.view);
    }
    [revealController setNeedsFocusUpdate];
    
    currentPosition = position;
}
#endif

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
#if TARGET_OS_TV
    [self appClicked:_sortedAppList[indexPath.row] view:nil];
#else
    UIView *sourceView = [collectionView cellForItemAtIndexPath:indexPath].contentView.subviews.firstObject;
    if (_showingHosts) {
        if (indexPath.item < _sortedHostList.count) {
            [self hostClicked:_sortedHostList[indexPath.item] view:sourceView];
        }
        else {
            [self addHostClicked];
        }
    }
    else if (indexPath.item < _sortedAppList.count) {
        [self appClicked:_sortedAppList[indexPath.item] view:sourceView];
    }
#endif
}

- (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender {
    if ([segue.destinationViewController isKindOfClass:[StreamFrameViewController class]]) {
#if !TARGET_OS_TV
        // Release browser-level Menu/B ownership before the stream installs its
        // controller handlers. Doing this here avoids racing StreamFrame's
        // viewDidLoad registration from MainFrame's later disappearance.
        [self clearBrowsingControllerCallbacks];
#endif
        StreamFrameViewController* streamFrame = segue.destinationViewController;
        streamFrame.streamConfig = _streamConfig;
    }
}

- (void) showLoadingFrame:(void (^)(void))completion {
    [_loadingFrame showLoadingFrame:completion];
}

- (void) hideLoadingFrame:(void (^)(void))completion {
    [self enableNavigation];
    [_loadingFrame dismissLoadingFrame:completion];
}

- (void)adjustScrollViewForSafeArea:(UIScrollView*)view {
    if (view == nil) {
        return;
    }

    if (@available(iOS 11.0, *)) {
        view.contentInset = UIEdgeInsetsZero;
#if !TARGET_OS_TV
        // The grid already keeps cards inside the safe area through its section
        // insets. Letting UIKit apply those insets again to the indicator placed
        // the thumb over the last app column in landscape.
        if (@available(iOS 13.0, *)) {
            view.automaticallyAdjustsScrollIndicatorInsets = NO;
        }
        UIEdgeInsets safeArea = self.view.safeAreaInsets;
        view.verticalScrollIndicatorInsets = UIEdgeInsetsMake(10.0,
                                                               0,
                                                               MAX(10.0, safeArea.bottom + 8.0),
                                                               6.0);
        view.horizontalScrollIndicatorInsets = UIEdgeInsetsMake(0, 10.0, 6.0, 10.0);
#else
        view.scrollIndicatorInsets = self.view.safeAreaInsets;
#endif
    }
}

// Adjust the subviews for the safe area on the iPhone X.
- (void)viewSafeAreaInsetsDidChange {
    [super viewSafeAreaInsetsDidChange];
    
    [self adjustScrollViewForSafeArea:self.collectionView];
    [self adjustScrollViewForSafeArea:self->hostScrollView];
    _lastCollectionBoundsSize = CGSizeZero;
    [self.collectionView.collectionViewLayout invalidateLayout];
}

- (void)viewDidLoad
{
    [super viewDidLoad];

    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    _showingHosts = YES;
    self.collectionView.backgroundColor = [UIColor colorWithRed:0.055 green:0.060 blue:0.075 alpha:1.0];
#if !TARGET_OS_TV
    self.collectionView.indicatorStyle = UIScrollViewIndicatorStyleWhite;
#endif
    self.collectionView.alwaysBounceVertical = YES;
    self.collectionView.delaysContentTouches = NO;
    self.collectionView.allowsMultipleSelection = NO;

#if !TARGET_OS_TV
    if (@available(iOS 15.0, *)) {
        self.collectionView.allowsFocus = YES;
        self.collectionView.remembersLastFocusedIndexPath = YES;
        self.collectionView.selectionFollowsFocus = NO;
    }

    UICollectionViewFlowLayout *layout = (UICollectionViewFlowLayout *)self.collectionView.collectionViewLayout;
    if ([layout isKindOfClass:[UICollectionViewFlowLayout class]]) {
        layout.minimumInteritemSpacing = 16.0;
        layout.minimumLineSpacing = 20.0;
        layout.sectionInset = UIEdgeInsetsMake(24, 24, 28, 24);
    }
#endif
        
#if !TARGET_OS_TV
    [_settingsButton setTarget:self];
    [_settingsButton setAction:@selector(openSettingsOverlay)];
    
    // Set the host name button action. When it's tapped, it'll show the host selection view.
    [_upButton setTarget:self];
    [_upButton setAction:@selector(showHostSelectionView)];
    
    [self.revealViewController setDelegate:self];

    UINavigationBarAppearance *appearance = [[UINavigationBarAppearance alloc] init];
    [appearance configureWithOpaqueBackground];
    appearance.backgroundColor = [UIColor colorWithRed:0.055 green:0.060 blue:0.075 alpha:1.0];
    appearance.shadowColor = UIColor.clearColor;
    appearance.titleTextAttributes = @{
        NSForegroundColorAttributeName: UIColor.whiteColor,
        NSFontAttributeName: [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold],
    };
    self.navigationController.navigationBar.standardAppearance = appearance;
    self.navigationController.navigationBar.scrollEdgeAppearance = appearance;
    self.navigationController.navigationBar.compactAppearance = appearance;
    self.navigationController.navigationBar.tintColor = [UIColor colorWithRed:0.55 green:0.48 blue:0.96 alpha:1.0];

    _settingsButton.customView = [self navigationGlassControlWithImageName:@"gearshape.fill"
                                                                    action:@selector(openSettingsOverlay)
                                                        accessibilityLabel:@"Settings"
                                                   accessibilityIdentifier:@"settings.open"];
    if (@available(iOS 26.0, *)) {
        _settingsButton.hidesSharedBackground = YES;
    }
    _settingsButton.accessibilityLabel = @"Settings";
    _settingsButton.accessibilityIdentifier = @"settings.open";

    _upButton.customView = [self navigationGlassControlWithImageName:@"chevron.backward"
                                                               action:@selector(showHostSelectionView)
                                                   accessibilityLabel:@"Back to computers"
                                              accessibilityIdentifier:@"host.back"];
    if (@available(iOS 26.0, *)) {
        _upButton.hidesSharedBackground = YES;
    }
    _upButton.accessibilityLabel = @"Back to computers";
    _upButton.accessibilityIdentifier = @"host.back";
    _backButtonItem = _upButton;
    [self disableUpButton];
#else
    // The settings button will direct the user into the Settings app on tvOS
    [_settingsButton setTarget:self];
    [_settingsButton setAction:@selector(openTvSettings:)];
    
    // Restore focus on the selected app on view controller pop navigation
    self.restoresFocusAfterTransition = NO;
    self.collectionView.remembersLastFocusedIndexPath = YES;
    
    _menuRecognizer = [[UITapGestureRecognizer alloc] init];
    [_menuRecognizer addTarget:self action: @selector(showHostSelectionView)];
    _menuRecognizer.allowedPressTypes = [[NSArray alloc] initWithObjects:[NSNumber numberWithLong:UIPressTypeMenu], nil];
    
    self.navigationController.navigationBar.titleTextAttributes = [NSDictionary dictionaryWithObject:[UIColor whiteColor] forKey:NSForegroundColorAttributeName];
#endif
    
    _loadingFrame = [self.storyboard instantiateViewControllerWithIdentifier:@"loadingFrame"];
    
    // Set the current position to the center
    currentPosition = FrontViewPositionLeft;
    
    // Set up crypto
    [CryptoManager generateKeyPairUsingSSL];
    _uniqueId = [IdManager getUniqueId];
    _clientCert = [CryptoManager readCertFromFile];

    _appManager = [[AppAssetManager alloc] initWithCallback:self];
    _opQueue = [[NSOperationQueue alloc] init];
    
    // Only initialize the host picker list once
    if (hostList == nil) {
        hostList = [[NSMutableSet alloc] init];
    }
    
    _boxArtCache = [[NSCache alloc] init];
        
#if !TARGET_OS_TV
    self.collectionView.multipleTouchEnabled = NO;
#else
    hostScrollView = [[ComputerScrollView alloc] init];
    hostScrollView.frame = CGRectMake(0, self.navigationController.navigationBar.frame.origin.y + self.navigationController.navigationBar.frame.size.height, self.view.frame.size.width, self.view.frame.size.height / 2);
    [hostScrollView setShowsHorizontalScrollIndicator:NO];
    hostScrollView.delaysContentTouches = NO;

    // This is the only way to get long press events on a UICollectionViewCell :(
    UILongPressGestureRecognizer* cellLongPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleCollectionViewLongPress:)];
    cellLongPress.delaysTouchesBegan = YES;
    [self.collectionView addGestureRecognizer:cellLongPress];
#endif
    
    [self retrieveSavedHosts];
    _discMan = [[DiscoveryManager alloc] initWithHosts:[hostList allObjects] andCallback:self];
        
    [self updateTitle];
#if TARGET_OS_TV
    if ([hostList count] == 1) {
        [self hostClicked:[hostList anyObject] view:nil];
    } else {
        [self.view addSubview:hostScrollView];
    }
#else
    [self updateHosts];
#endif
}

#if TARGET_OS_TV
-(void)handleCollectionViewLongPress:(UILongPressGestureRecognizer *)gestureRecognizer
{
    // FIXME: Something is delaying touches so we only get to the Begin state
    // before we actually want to signal the long press.
    if (gestureRecognizer.state != UIGestureRecognizerStateBegan) {
        return;
    }
    
    CGPoint point = [gestureRecognizer locationInView:self.collectionView];
    NSIndexPath *indexPath = [self.collectionView indexPathForItemAtPoint:point];
    if (indexPath != nil) {
        [self appLongClicked:_sortedAppList[indexPath.row] view:nil];
    }
}

- (void)openTvSettings:(id)sender
{
    [[UIApplication sharedApplication] openURL:[NSURL URLWithString:UIApplicationOpenSettingsURLString] options:@{} completionHandler:nil];
}
#endif

-(void)beginForegroundRefresh
{
    if (!_background) {
        // This will kick off box art caching
        [self updateHosts];
        
        // Reset state first so we can rediscover hosts that were deleted before
        [_discMan resetDiscoveryState];
        [_discMan startDiscovery];
        
        // This will refresh the applist when a paired host is selected
        if (_selectedHost != nil && _selectedHost.pairState == PairStatePaired) {
            [self hostClicked:_selectedHost view:nil];
        }
    }
}

-(void)handlePendingShortcutAction
{
    // Check if we have a pending shortcut action
    AppDelegate* delegate = (AppDelegate*)[UIApplication sharedApplication].delegate;
    if (delegate.pcUuidToLoad != nil) {
        // Find the host it corresponds to
        TemporaryHost* matchingHost = nil;
        for (TemporaryHost* host in hostList) {
            if ([host.uuid isEqualToString:delegate.pcUuidToLoad]) {
                matchingHost = host;
                break;
            }
        }
        
        // Clear the pending shortcut action
        delegate.pcUuidToLoad = nil;
        
        // Complete the request
        if (delegate.shortcutCompletionHandler != nil) {
            delegate.shortcutCompletionHandler(matchingHost != nil);
            delegate.shortcutCompletionHandler = nil;
        }
        
        if (matchingHost != nil && _selectedHost != matchingHost) {
            // Navigate to the host page
            [self hostClicked:matchingHost view:nil];
        }
    }
}

#if !TARGET_OS_TV
-(void)handleShortcutItemReceived:(NSNotification *)notification
{
    (void)notification;
    [self handlePendingShortcutAction];
}
#endif

-(void)handleReturnToForeground
{
    _background = NO;

#if !TARGET_OS_TV
    if (self.presentedViewController == nil &&
        _settingsOverlayController.presentingViewController == nil) {
        [self configureBrowsingControllerCallbacks];
    }
#endif
    
    [self beginForegroundRefresh];
    
    // Check for a pending shortcut action when returning to foreground
    [self handlePendingShortcutAction];
}

-(void)handleEnterBackground
{
    _background = YES;
    
    [_discMan stopDiscovery];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    
#if !TARGET_OS_TV
    [[self revealViewController] setPrimaryViewController:self];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleShortcutItemReceived:)
                                                 name:MoonlightShortcutItemReceivedNotification
                                               object:nil];
#endif
    
    [self.navigationController setNavigationBarHidden:NO animated:NO];
    
    // Check for a pending shortcut action when appearing
    [self handlePendingShortcutAction];
    
    [[NSNotificationCenter defaultCenter] addObserver: self
                                             selector: @selector(handleReturnToForeground)
                                                 name: UIApplicationDidBecomeActiveNotification
                                               object: nil];
    
    [[NSNotificationCenter defaultCenter] addObserver: self
                                             selector: @selector(handleEnterBackground)
                                                 name: UIApplicationWillResignActiveNotification
                                               object: nil];

#if !TARGET_OS_TV
    [self configureBrowsingControllerCallbacks];
#endif
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    _streamLaunchInProgress = NO;
    self.collectionView.userInteractionEnabled = YES;
    [self.navigationController setNavigationBarHidden:NO animated:NO];
    
    // We can get here on home press while streaming
    // since the stream view segues to us just before
    // entering the background. We can't check the app
    // state here (since it's in transition), so we have
    // to use this function that will use our internal
    // state here to determine whether we're foreground.
    //
    // Note that this is neccessary here as we may enter
    // this view via an error dialog from the stream
    // view, so we won't get a return to active notification
    // for that which would normally fire beginForegroundRefresh.
    [self beginForegroundRefresh];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];

#if !TARGET_OS_TV
    // The legacy reveal container remains the storyboard root for compatibility,
    // but Settings is presented as a native overlay instead of resizing the browser.
#endif

    if (!CGSizeEqualToSize(_lastCollectionBoundsSize, self.collectionView.bounds.size)) {
        _lastCollectionBoundsSize = self.collectionView.bounds.size;
        [self.collectionView.collectionViewLayout invalidateLayout];
    }
}

- (BOOL)prefersStatusBarHidden {
    return YES;
}

- (void)viewDidDisappear:(BOOL)animated
{
    [super viewDidDisappear:animated];
    
    // when discovery stops, we must create a new instance because
    // you cannot restart an NSOperation when it is finished
    [_discMan stopDiscovery];
    
    // Purge the box art cache
    [_boxArtCache removeAllObjects];
    
    // Remove our lifetime observers to avoid triggering them
    // while streaming
    [[NSNotificationCenter defaultCenter] removeObserver:self];

}

#if !TARGET_OS_TV
- (UIView *)navigationGlassControlWithImageName:(NSString *)imageName
                                         action:(SEL)action
                             accessibilityLabel:(NSString *)accessibilityLabel
                        accessibilityIdentifier:(NSString *)accessibilityIdentifier {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    button.frame = CGRectMake(0, 0, 48, 48);
    button.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    button.accessibilityLabel = accessibilityLabel;
    button.accessibilityIdentifier = accessibilityIdentifier;

    UIImageSymbolConfiguration *symbolConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:20
                                                                                                        weight:UIImageSymbolWeightSemibold];
    UIImage *symbol = [UIImage systemImageNamed:imageName withConfiguration:symbolConfiguration];
    symbol = [symbol imageWithTintColor:UIColor.whiteColor renderingMode:UIImageRenderingModeAlwaysOriginal];
    [button setImage:symbol forState:UIControlStateNormal];
    [button addTarget:self action:action forControlEvents:UIControlEventPrimaryActionTriggered];

    if (@available(iOS 26.0, *)) {
        UIGlassEffect *effect = [UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular];
        effect.interactive = YES;
        effect.tintColor = [UIColor colorWithRed:0.035 green:0.040 blue:0.055 alpha:0.82];

        UIVisualEffectView *glassView = [[UIVisualEffectView alloc] initWithEffect:effect];
        glassView.frame = CGRectMake(0, 0, 48, 48);
        glassView.layer.cornerRadius = 24.0;
        glassView.layer.cornerCurve = kCACornerCurveContinuous;
        glassView.layer.masksToBounds = YES;
        glassView.layer.borderWidth = 1.0;
        glassView.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.12].CGColor;
        [glassView.contentView addSubview:button];
        button.frame = glassView.contentView.bounds;
        return glassView;
    }

    UIVisualEffectView *materialView = [[UIVisualEffectView alloc]
        initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterialDark]];
    materialView.frame = CGRectMake(0, 0, 48, 48);
    materialView.layer.cornerRadius = 24.0;
    materialView.layer.cornerCurve = kCACornerCurveContinuous;
    materialView.layer.masksToBounds = YES;
    materialView.layer.borderWidth = 1.0;
    materialView.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.13].CGColor;
    [materialView.contentView addSubview:button];
    button.frame = materialView.contentView.bounds;
    return materialView;
}

- (BOOL)browserControllerInputAvailable {
    return self.view.window != nil &&
           !_background &&
           UIApplication.sharedApplication.applicationState == UIApplicationStateActive &&
           ![_loadingFrame isShown] &&
           self.presentedViewController == nil &&
           _settingsOverlayController.presentingViewController == nil &&
           [self collectionView:self.collectionView numberOfItemsInSection:0] > 0;
}

- (void)resetBrowserControllerSelection {
    _browserControllerIndexPath = nil;
    for (MoonlightBrowserControllerState *state in _browserControllerStates.allValues) {
        state.horizontalStickLatch = 0;
        state.verticalStickLatch = 0;
    }
    for (UICollectionViewCell *cell in self.collectionView.visibleCells) {
        UIControl *control = (UIControl *)cell.contentView.subviews.firstObject;
        if ([control isKindOfClass:[UIAppView class]]) {
            [(UIAppView *)control setControllerHighlighted:NO];
        }
        else if ([control isKindOfClass:[UIComputerView class]]) {
            [(UIComputerView *)control setControllerHighlighted:NO];
        }
    }
}

- (void)updateBrowserControllerSelectionAtIndexPath:(NSIndexPath *)indexPath animated:(BOOL)animated {
    NSInteger itemCount = [self collectionView:self.collectionView numberOfItemsInSection:0];
    if (indexPath == nil || indexPath.item < 0 || indexPath.item >= itemCount) {
        return;
    }

    _browserControllerIndexPath = indexPath;

    [self.collectionView layoutIfNeeded];
    UICollectionViewLayoutAttributes *attributes =
        [self.collectionView.collectionViewLayout layoutAttributesForItemAtIndexPath:indexPath];
    CGRect visibleBounds = (CGRect){self.collectionView.contentOffset, self.collectionView.bounds.size};
    if (attributes != nil && !CGRectContainsRect(visibleBounds, attributes.frame)) {
        [self.collectionView scrollToItemAtIndexPath:indexPath
                                    atScrollPosition:UICollectionViewScrollPositionCenteredVertically
                                            animated:animated];
    }

    void (^refreshHighlights)(void) = ^{
        for (UICollectionViewCell *cell in self.collectionView.visibleCells) {
            NSIndexPath *visibleIndexPath = [self.collectionView indexPathForCell:cell];
            BOOL highlighted = [visibleIndexPath isEqual:self->_browserControllerIndexPath];
            UIControl *control = (UIControl *)cell.contentView.subviews.firstObject;
            if ([control isKindOfClass:[UIAppView class]]) {
                [(UIAppView *)control setControllerHighlighted:highlighted];
            }
            else if ([control isKindOfClass:[UIComputerView class]]) {
                [(UIComputerView *)control setControllerHighlighted:highlighted];
            }
        }
    };

    [UIView animateWithDuration:animated ? 0.16 : 0.0 animations:refreshHighlights];
    if (animated) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(180 * NSEC_PER_MSEC)),
                       dispatch_get_main_queue(), refreshHighlights);
    }
}

- (void)moveBrowserControllerSelectionHorizontal:(NSInteger)horizontal vertical:(NSInteger)vertical {
    if (![self browserControllerInputAvailable] || (horizontal == 0 && vertical == 0)) {
        return;
    }

    NSInteger itemCount = [self collectionView:self.collectionView numberOfItemsInSection:0];
    if (_browserControllerIndexPath == nil || _browserControllerIndexPath.item >= itemCount) {
        [self updateBrowserControllerSelectionAtIndexPath:[NSIndexPath indexPathForItem:0 inSection:0]
                                                 animated:NO];
        return;
    }

    [self.collectionView layoutIfNeeded];
    UICollectionViewLayout *layout = self.collectionView.collectionViewLayout;
    UICollectionViewLayoutAttributes *currentAttributes =
        [layout layoutAttributesForItemAtIndexPath:_browserControllerIndexPath];
    if (currentAttributes == nil) {
        return;
    }

    CGPoint currentCenter = currentAttributes.center;
    CGFloat bestScore = CGFLOAT_MAX;
    NSIndexPath *bestIndexPath = nil;
    for (NSInteger item = 0; item < itemCount; item++) {
        if (item == _browserControllerIndexPath.item) {
            continue;
        }
        NSIndexPath *candidateIndexPath = [NSIndexPath indexPathForItem:item inSection:0];
        UICollectionViewLayoutAttributes *candidateAttributes =
            [layout layoutAttributesForItemAtIndexPath:candidateIndexPath];
        if (candidateAttributes == nil) {
            continue;
        }

        CGFloat deltaX = candidateAttributes.center.x - currentCenter.x;
        CGFloat deltaY = candidateAttributes.center.y - currentCenter.y;
        CGFloat forwardDistance = deltaX * horizontal + deltaY * vertical;
        if (forwardDistance <= 1.0) {
            continue;
        }
        CGFloat crossDistance = fabs(deltaX * vertical - deltaY * horizontal);
        CGFloat score = forwardDistance + crossDistance * 4.0;
        if (score < bestScore) {
            bestScore = score;
            bestIndexPath = candidateIndexPath;
        }
    }

    if (bestIndexPath != nil) {
        [self updateBrowserControllerSelectionAtIndexPath:bestIndexPath animated:YES];
        UISelectionFeedbackGenerator *feedback = [[UISelectionFeedbackGenerator alloc] init];
        [feedback selectionChanged];
    }
}

- (void)activateBrowserControllerSelection {
    if (![self browserControllerInputAvailable]) {
        return;
    }

    if (_browserControllerIndexPath == nil) {
        [self updateBrowserControllerSelectionAtIndexPath:[NSIndexPath indexPathForItem:0 inSection:0]
                                                 animated:NO];
    }

    CFTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (now - _lastBrowserControllerActivationTime < 0.20) {
        return;
    }
    _lastBrowserControllerActivationTime = now;
    [self collectionView:self.collectionView didSelectItemAtIndexPath:_browserControllerIndexPath];
}

- (void)handleBrowserControllerSnapshotForController:(GCController *)controller
                                     buttonFlags:(int)buttonFlags
                                           menu:(BOOL)menuPressed
                                          stickX:(float)stickX
                                          stickY:(float)stickY {
    NSValue *controllerKey = [NSValue valueWithNonretainedObject:controller];
    MoonlightBrowserControllerState *state = _browserControllerStates[controllerKey];
    if (state == nil) {
        return;
    }

    if (state.awaitingNeutral) {
        state.lastButtonFlags = buttonFlags;
        state.menuPressed = menuPressed;
        if (buttonFlags == 0 && !menuPressed && stickX == 0 && stickY == 0) {
            state.awaitingNeutral = NO;
            state.horizontalStickLatch = 0;
            state.verticalStickLatch = 0;
        }
        return;
    }

    int changedButtons = state.lastButtonFlags ^ buttonFlags;
    int pressedButtons = changedButtons & buttonFlags;
    int releasedButtons = changedButtons & ~buttonFlags;
    BOOL menuReleased = state.menuPressed && !menuPressed;
    state.lastButtonFlags = buttonFlags;
    state.menuPressed = menuPressed;

    BOOL chromeVisible = self.view.window != nil &&
                         self.navigationController.visibleViewController == self &&
                         UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
    if (!chromeVisible) {
        return;
    }

    if (menuReleased &&
        self.presentedViewController == nil &&
        ![_loadingFrame isShown]) {
        [self toggleSettingsFromController];
    }
    if (releasedButtons & BrowserButtonB) {
        [self accessibilityPerformEscape];
    }
    if (![self browserControllerInputAvailable]) {
        return;
    }

    if (pressedButtons & BrowserButtonUp) {
        [self moveBrowserControllerSelectionHorizontal:0 vertical:-1];
    }
    else if (pressedButtons & BrowserButtonDown) {
        [self moveBrowserControllerSelectionHorizontal:0 vertical:1];
    }
    else if (pressedButtons & BrowserButtonLeft) {
        [self moveBrowserControllerSelectionHorizontal:-1 vertical:0];
    }
    else if (pressedButtons & BrowserButtonRight) {
        [self moveBrowserControllerSelectionHorizontal:1 vertical:0];
    }

    const float engageThreshold = 0.62f;
    const float releaseThreshold = 0.30f;
    if (fabsf(stickX) < releaseThreshold) {
        state.horizontalStickLatch = 0;
    }
    if (fabsf(stickY) < releaseThreshold) {
        state.verticalStickLatch = 0;
    }
    if (fabsf(stickX) >= fabsf(stickY) && fabsf(stickX) >= engageThreshold) {
        NSInteger direction = stickX > 0 ? 1 : -1;
        if (state.horizontalStickLatch != direction) {
            state.horizontalStickLatch = direction;
            [self moveBrowserControllerSelectionHorizontal:direction vertical:0];
        }
    }
    else if (fabsf(stickY) >= engageThreshold) {
        NSInteger direction = stickY > 0 ? -1 : 1;
        if (state.verticalStickLatch != direction) {
            state.verticalStickLatch = direction;
            [self moveBrowserControllerSelectionHorizontal:0 vertical:direction];
        }
    }

    if (releasedButtons & BrowserButtonA) {
        [self activateBrowserControllerSelection];
    }
}

- (void)configureBrowsingControllerCallbacks {
    _browserControllerOwnershipActive = YES;
    _browserControllerGeneration++;
    if (_browserControllerStates == nil) {
        _browserControllerStates = [[NSMutableDictionary alloc] init];
    }
    if (_browserControllerQueue == nil) {
        _browserControllerQueue = dispatch_queue_create("com.moonlight.browser-controller", DISPATCH_QUEUE_SERIAL);
    }

    __weak MainFrameViewController *weakSelf = self;
    int (^buttonFlagsForGamepad)(GCExtendedGamepad *) = ^int(GCExtendedGamepad *gamepad) {
        int flags = 0;
        if (gamepad.buttonA.pressed) flags |= BrowserButtonA;
        if (gamepad.buttonB.pressed) flags |= BrowserButtonB;
        if (gamepad.dpad.up.pressed) flags |= BrowserButtonUp;
        if (gamepad.dpad.down.pressed) flags |= BrowserButtonDown;
        if (gamepad.dpad.left.pressed) flags |= BrowserButtonLeft;
        if (gamepad.dpad.right.pressed) flags |= BrowserButtonRight;
        return flags;
    };

    void (^configureController)(GCController *) = ^(GCController *controller) {
        MainFrameViewController *strongSelf = weakSelf;
        GCExtendedGamepad *gamepad = controller.extendedGamepad;
        if (strongSelf == nil || gamepad == nil) {
            return;
        }
        uint64_t controllerGeneration = strongSelf->_browserControllerGeneration;
        controller.handlerQueue = strongSelf->_browserControllerQueue;

        // Chrome owns the complete controller profile. This deliberately avoids
        // mixing raw Menu/B callbacks with UIKit focus delivery for A/D-pad/sticks.
        gamepad.buttonMenu.pressedChangedHandler = nil;
        gamepad.buttonB.pressedChangedHandler = nil;
        gamepad.valueChangedHandler = nil;

        if (@available(iOS 14.0, *)) {
            for (GCControllerElement *element in controller.physicalInputProfile.allElements) {
                element.preferredSystemGestureState = GCSystemGestureStateDisabled;
            }
        }

        NSValue *controllerKey = [NSValue valueWithNonretainedObject:controller];
        MoonlightBrowserControllerState *state = strongSelf->_browserControllerStates[controllerKey];
        if (state == nil) {
            state = [[MoonlightBrowserControllerState alloc] init];
            strongSelf->_browserControllerStates[controllerKey] = state;
        }
        state.lastButtonFlags = buttonFlagsForGamepad(gamepad);
        state.menuPressed = gamepad.buttonMenu != nil && gamepad.buttonMenu.pressed;
        state.rawButtonFlags = state.lastButtonFlags;
        state.rawMenuPressed = state.menuPressed;
        float initialLeftX = gamepad.leftThumbstick.xAxis.value;
        float initialLeftY = gamepad.leftThumbstick.yAxis.value;
        float initialRightX = gamepad.rightThumbstick.xAxis.value;
        float initialRightY = gamepad.rightThumbstick.yAxis.value;
        BOOL useLeftStick = hypotf(initialLeftX, initialLeftY) >= hypotf(initialRightX, initialRightY);
        float initialStickX = useLeftStick ? initialLeftX : initialRightX;
        float initialStickY = useLeftStick ? initialLeftY : initialRightY;
        state.rawHorizontalStickDirection =
            fabsf(initialStickX) >= fabsf(initialStickY) && fabsf(initialStickX) >= 0.62f
                ? (initialStickX > 0 ? 1 : -1) : 0;
        state.rawVerticalStickDirection =
            fabsf(initialStickY) > fabsf(initialStickX) && fabsf(initialStickY) >= 0.62f
                ? (initialStickY > 0 ? 1 : -1) : 0;
        state.horizontalStickLatch = 0;
        state.verticalStickLatch = 0;
        state.awaitingNeutral = state.lastButtonFlags != 0 ||
                                state.menuPressed ||
                                state.rawHorizontalStickDirection != 0 ||
                                state.rawVerticalStickDirection != 0;

        gamepad.valueChangedHandler = ^(GCExtendedGamepad *changedGamepad, GCControllerElement *element) {
            int buttonFlags = buttonFlagsForGamepad(changedGamepad);
            BOOL menuPressed = changedGamepad.buttonMenu != nil && changedGamepad.buttonMenu.pressed;

            float leftX = changedGamepad.leftThumbstick.xAxis.value;
            float leftY = changedGamepad.leftThumbstick.yAxis.value;
            float rightX = changedGamepad.rightThumbstick.xAxis.value;
            float rightY = changedGamepad.rightThumbstick.yAxis.value;
            float leftMagnitude = hypotf(leftX, leftY);
            float rightMagnitude = hypotf(rightX, rightY);
            float stickX = leftMagnitude >= rightMagnitude ? leftX : rightX;
            float stickY = leftMagnitude >= rightMagnitude ? leftY : rightY;

            NSInteger horizontalDirection;
            NSInteger verticalDirection;
            BOOL inputStateChanged;
            @synchronized(state) {
                horizontalDirection = state.rawHorizontalStickDirection;
                verticalDirection = state.rawVerticalStickDirection;

                const float engageThreshold = 0.62f;
                const float releaseThreshold = 0.30f;
                if (fabsf(stickX) < releaseThreshold && fabsf(stickY) < releaseThreshold) {
                    horizontalDirection = 0;
                    verticalDirection = 0;
                }
                else if (fabsf(stickX) >= fabsf(stickY) && fabsf(stickX) >= engageThreshold) {
                    horizontalDirection = stickX > 0 ? 1 : -1;
                    verticalDirection = 0;
                }
                else if (fabsf(stickY) >= engageThreshold) {
                    horizontalDirection = 0;
                    verticalDirection = stickY > 0 ? 1 : -1;
                }

                inputStateChanged = state.rawButtonFlags != buttonFlags ||
                                    state.rawMenuPressed != menuPressed ||
                                    state.rawHorizontalStickDirection != horizontalDirection ||
                                    state.rawVerticalStickDirection != verticalDirection;
                state.rawButtonFlags = buttonFlags;
                state.rawMenuPressed = menuPressed;
                state.rawHorizontalStickDirection = horizontalDirection;
                state.rawVerticalStickDirection = verticalDirection;
            }
            if (!inputStateChanged) {
                // Ignore analog noise inside the same navigation zone.
                return;
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                MainFrameViewController *currentSelf = weakSelf;
                if (currentSelf == nil ||
                    !currentSelf->_browserControllerOwnershipActive ||
                    currentSelf->_browserControllerGeneration != controllerGeneration ||
                    currentSelf->_browserControllerStates[controllerKey] != state) {
                    return;
                }
                [weakSelf handleBrowserControllerSnapshotForController:changedGamepad.controller
                                                           buttonFlags:buttonFlags
                                                                 menu:menuPressed
                                                               stickX:(float)horizontalDirection
                                                               stickY:(float)verticalDirection];
            });
        };
    };

    for (GCController *controller in GCController.controllers) {
        configureController(controller);
    }

    if (_browserControllerConnectObserver == nil) {
        _browserControllerConnectObserver = [[NSNotificationCenter defaultCenter]
            addObserverForName:GCControllerDidConnectNotification
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification *notification) {
                        configureController((GCController *)notification.object);
                    }];
    }
    if (_browserControllerDisconnectObserver == nil) {
        _browserControllerDisconnectObserver = [[NSNotificationCenter defaultCenter]
            addObserverForName:GCControllerDidDisconnectNotification
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification *notification) {
                        MainFrameViewController *strongSelf = weakSelf;
                        if (strongSelf != nil) {
                            NSValue *controllerKey = [NSValue valueWithNonretainedObject:notification.object];
                            [strongSelf->_browserControllerStates removeObjectForKey:controllerKey];
                            if (strongSelf->_browserControllerStates.count == 0) {
                                [strongSelf resetBrowserControllerSelection];
                            }
                        }
                    }];
    }

    if (_browserControllerStates.count > 0 &&
        _browserControllerIndexPath == nil &&
        [self collectionView:self.collectionView numberOfItemsInSection:0] > 0) {
        [self updateBrowserControllerSelectionAtIndexPath:[NSIndexPath indexPathForItem:0 inSection:0]
                                                 animated:NO];
    }
}

- (void)clearBrowsingControllerCallbacks {
    _browserControllerOwnershipActive = NO;
    _browserControllerGeneration++;
    if (_browserControllerConnectObserver != nil) {
        [[NSNotificationCenter defaultCenter] removeObserver:_browserControllerConnectObserver];
        _browserControllerConnectObserver = nil;
    }
    if (_browserControllerDisconnectObserver != nil) {
        [[NSNotificationCenter defaultCenter] removeObserver:_browserControllerDisconnectObserver];
        _browserControllerDisconnectObserver = nil;
    }

    for (GCController *controller in GCController.controllers) {
        GCExtendedGamepad *gamepad = controller.extendedGamepad;
        gamepad.buttonMenu.pressedChangedHandler = nil;
        gamepad.buttonB.pressedChangedHandler = nil;
        gamepad.valueChangedHandler = nil;
        controller.handlerQueue = dispatch_get_main_queue();
        if (@available(iOS 14.0, *)) {
            for (GCControllerElement *element in controller.physicalInputProfile.allElements) {
                element.preferredSystemGestureState = GCSystemGestureStateEnabled;
            }
        }
    }
    [_browserControllerStates removeAllObjects];
}
- (void)toggleSettingsFromController {
    if (_settingsOverlayController.presentingViewController != nil) {
        [self dismissSettingsOverlay];
    }
    else if (self.presentedViewController == nil && ![_loadingFrame isShown]) {
        [self openSettingsOverlay];
    }
}

- (BOOL)accessibilityPerformEscape {
    if (_settingsOverlayController.presentingViewController != nil) {
        [self dismissSettingsOverlay];
        return YES;
    }

    UIViewController *presentedController = self.presentedViewController;
    if ([presentedController isKindOfClass:[UIAlertController class]]) {
        BOOL isPairingAlert = presentedController == _pairAlert;
        [presentedController dismissViewControllerAnimated:YES completion:^{
            if (isPairingAlert) {
                self->_pairAlert = nil;
                [self->_discMan startDiscovery];
                [self hideLoadingFrame:^{
                    [self showHostSelectionView];
                }];
            }
            else {
                [self configureBrowsingControllerCallbacks];
            }
        }];
        return YES;
    }
    if (presentedController != nil) {
        return YES;
    }
    if (!_showingHosts) {
        [self showHostSelectionView];
        return YES;
    }
    return [super accessibilityPerformEscape];
}

- (void)openSettingsOverlay {
    if (_settingsOverlayController.presentingViewController != nil) {
        return;
    }

    // Modal controls use UIKit's focus engine. Relinquish the raw browser
    // profile while the sheet is visible, then reacquire it on dismissal.
    [self clearBrowsingControllerCallbacks];

    SettingsViewController *settings = [self.storyboard instantiateViewControllerWithIdentifier:@"Settings"];
    settings.title = @"Settings";
    settings.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                             target:self
                             action:@selector(dismissSettingsOverlay)];

    UINavigationController *navigationController = [[UINavigationController alloc] initWithRootViewController:settings];
    navigationController.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    navigationController.modalPresentationStyle = UIModalPresentationFormSheet;
    navigationController.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    navigationController.preferredContentSize = CGSizeMake(MIN(680.0, self.view.bounds.size.width - 80.0),
                                                            MIN(760.0, self.view.bounds.size.height - 40.0));

    UINavigationBarAppearance *appearance = [[UINavigationBarAppearance alloc] init];
    [appearance configureWithOpaqueBackground];
    appearance.backgroundColor = [UIColor colorWithRed:0.055 green:0.060 blue:0.075 alpha:1.0];
    appearance.shadowColor = UIColor.clearColor;
    appearance.titleTextAttributes = @{NSForegroundColorAttributeName: UIColor.whiteColor};
    navigationController.navigationBar.standardAppearance = appearance;
    navigationController.navigationBar.scrollEdgeAppearance = appearance;
    navigationController.navigationBar.tintColor = [UIColor colorWithRed:0.55 green:0.48 blue:0.96 alpha:1.0];

    _settingsOverlayController = navigationController;
    navigationController.presentationController.delegate = self;
    [self presentViewController:navigationController animated:YES completion:^{
        UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, settings.view);
    }];
}

- (void)dismissSettingsOverlay {
    SettingsViewController *settings = (SettingsViewController *)_settingsOverlayController.topViewController;
    [settings saveSettings];
    [self dismissViewControllerAnimated:YES completion:^{
        self->_settingsOverlayController = nil;
        [self configureBrowsingControllerCallbacks];
    }];
}

- (void)presentationControllerDidDismiss:(UIPresentationController *)presentationController {
    if (_settingsOverlayController != nil &&
        presentationController.presentedViewController == _settingsOverlayController) {
        SettingsViewController *settings = (SettingsViewController *)_settingsOverlayController.topViewController;
        [settings saveSettings];
        _settingsOverlayController = nil;
    }
    if (self.presentedViewController == nil &&
        _settingsOverlayController.presentingViewController == nil &&
        ![_loadingFrame isShown]) {
        [self configureBrowsingControllerCallbacks];
    }
}

- (UIModalPresentationStyle)adaptivePresentationStyleForPresentationController:(UIPresentationController *)controller {
    return UIModalPresentationNone;
}

- (UIModalPresentationStyle)adaptivePresentationStyleForPresentationController:(UIPresentationController *)controller
                                                               traitCollection:(UITraitCollection *)traitCollection {
    return UIModalPresentationNone;
}
#endif

- (void) retrieveSavedHosts {
    DataManager* dataMan = [[DataManager alloc] init];
    NSArray* hosts = [dataMan getHosts];
    @synchronized(hostList) {
        [hostList addObjectsFromArray:hosts];
        
        // Initialize the non-persistent host state
        for (TemporaryHost* host in hostList) {
            if (host.activeAddress == nil) {
                host.activeAddress = host.localAddress;
            }
            if (host.activeAddress == nil) {
                host.activeAddress = host.externalAddress;
            }
            if (host.activeAddress == nil) {
                host.activeAddress = host.address;
            }
            if (host.activeAddress == nil) {
                host.activeAddress = host.ipv6Address;
            }
        }
    }
}

- (void) updateAllHosts:(NSArray *)hosts {
    // We must copy the array here because it could be modified
    // before our main thread dispatch happens.
    NSArray* hostsCopy = [NSArray arrayWithArray:hosts];
    dispatch_async(dispatch_get_main_queue(), ^{
        Log(LOG_D, @"New host list:");
        for (TemporaryHost* host in hostsCopy) {
            Log(LOG_D, @"Host: \n{\n\t name:%@ \n\t address:%@ \n\t localAddress:%@ \n\t externalAddress:%@ \n\t ipv6Address:%@ \n\t uuid:%@ \n\t mac:%@ \n\t pairState:%d \n\t online:%d \n\t activeAddress:%@ \n}", host.name, host.address, host.localAddress, host.externalAddress, host.ipv6Address, host.uuid, host.mac, host.pairState, host.state, host.activeAddress);
        }
        @synchronized(hostList) {
            [hostList removeAllObjects];
            [hostList addObjectsFromArray:hostsCopy];
        }
        [self updateHosts];
    });
}

- (void)updateHostShortcuts {
#if !TARGET_OS_TV
    NSMutableArray* quickActions = [[NSMutableArray alloc] init];
    
    @synchronized (hostList) {
        for (TemporaryHost* host in hostList) {
            // Pair state may be unknown if we haven't polled it yet, but the app list
            // count will persist from paired PCs
            if ([host.appList count] > 0) {
                UIApplicationShortcutItem* shortcut = [[UIApplicationShortcutItem alloc]
                                                       initWithType:@"PC"
                                                       localizedTitle:host.name
                                                       localizedSubtitle:nil
                                                       icon:[UIApplicationShortcutIcon iconWithType:UIApplicationShortcutIconTypePlay]
                                                       userInfo:[NSDictionary dictionaryWithObject:host.uuid forKey:@"UUID"]];
                [quickActions addObject: shortcut];
            }
        }
    }
    
    [UIApplication sharedApplication].shortcutItems = quickActions;
#endif
}

- (void)updateHosts {
    Log(LOG_I, @"Updating hosts...");
#if !TARGET_OS_TV
    @synchronized (hostList) {
        _sortedHostList = [[hostList allObjects] sortedArrayUsingSelector:@selector(compareName:)];
    }

    if (_showingHosts) {
        [self.collectionView reloadData];
    }

    for (TemporaryHost *host in _sortedHostList) {
        for (TemporaryApp *app in host.appList) {
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
                [self updateBoxArtCacheForApp:app];
            });
        }
    }

    [self updateHostShortcuts];
    [self updateTitle];
    return;
#else
    [[hostScrollView subviews] makeObjectsPerformSelector:@selector(removeFromSuperview)];
    UIComputerView* addComp = [[UIComputerView alloc] initForAddWithCallback:self];
    UIComputerView* compView;
    float prevEdge = -1;
    @synchronized (hostList) {
        // Sort the host list in alphabetical order
        NSArray* sortedHostList = [[hostList allObjects] sortedArrayUsingSelector:@selector(compareName:)];
        for (TemporaryHost* comp in sortedHostList) {
            compView = [[UIComputerView alloc] initWithComputer:comp andCallback:self];
            compView.center = CGPointMake([self getCompViewX:compView addComp:addComp prevEdge:prevEdge], hostScrollView.frame.size.height / 2);
            prevEdge = compView.frame.origin.x + compView.frame.size.width;
            [hostScrollView addSubview:compView];
            
            // Start jobs to decode the box art in advance
            for (TemporaryApp* app in comp.appList) {
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
                    [self updateBoxArtCacheForApp:app];
                });
            }
        }
    }
    
    // Create or delete host shortcuts as needed
    [self updateHostShortcuts];
    
    // Update the title in case we now have a PC
    [self updateTitle];
    
    prevEdge = [self getCompViewX:addComp addComp:addComp prevEdge:prevEdge];
    addComp.center = CGPointMake(prevEdge, hostScrollView.frame.size.height / 2);
    
    [hostScrollView addSubview:addComp];
    [hostScrollView setContentSize:CGSizeMake(prevEdge + addComp.frame.size.width, hostScrollView.frame.size.height)];
#endif
}

- (float) getCompViewX:(UIComputerView*)comp addComp:(UIComputerView*)addComp prevEdge:(float)prevEdge {
    float padding;
    
#if TARGET_OS_TV
    padding = 100;
#else
    padding = addComp.frame.size.width / 2;
#endif
    
    if (prevEdge == -1) {
        return hostScrollView.frame.origin.x + comp.frame.size.width / 2 + padding;
    } else {
        return prevEdge + comp.frame.size.width / 2 + padding;
    }
}

// This function forces immediate decoding of the UIImage, rather
// than the default lazy decoding that results in janky scrolling.
+ (UIImage*) loadBoxArtForCaching:(TemporaryApp*)app {
    NSString *boxArtPath = [AppAssetManager boxArtPathForApp:app];
    NSData* imageData = [NSData dataWithContentsOfFile:boxArtPath];
    if (imageData == nil) {
        // No box art on disk
        return nil;
    }
    
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)imageData, NULL);
    if (source == NULL) {
        [[NSFileManager defaultManager] removeItemAtPath:boxArtPath error:nil];
        return nil;
    }
    CGImageRef cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil);
    if (cgImage == NULL) {
        CFRelease(source);
        [[NSFileManager defaultManager] removeItemAtPath:boxArtPath error:nil];
        return nil;
    }
    
    size_t width = CGImageGetWidth(cgImage);
    size_t height = CGImageGetHeight(cgImage);
    if (width == 0 || height == 0 || width > SIZE_MAX / 4) {
        CGImageRelease(cgImage);
        CFRelease(source);
        [[NSFileManager defaultManager] removeItemAtPath:boxArtPath error:nil];
        return nil;
    }
    
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef imageContext = colorSpace == NULL ? NULL :
        CGBitmapContextCreate(NULL, width, height, 8, width * 4, colorSpace,
                             (CGBitmapInfo)kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    if (colorSpace != NULL) {
        CGColorSpaceRelease(colorSpace);
    }
    if (imageContext == NULL) {
        CGImageRelease(cgImage);
        CFRelease(source);
        return nil;
    }

    CGContextDrawImage(imageContext, CGRectMake(0, 0, width, height), cgImage);
    
    CGImageRef outputImage = CGBitmapContextCreateImage(imageContext);
    UIImage *boxArt = outputImage == NULL ? nil : [UIImage imageWithCGImage:outputImage];

    if (outputImage != NULL) {
        CGImageRelease(outputImage);
    }
    CGContextRelease(imageContext);
    
    CGImageRelease(cgImage);
    CFRelease(source);
    
    return boxArt;
}

- (void) updateBoxArtCacheForApp:(TemporaryApp*)app {
    if ([_boxArtCache objectForKey:app] == nil) {
        UIImage* image = [MainFrameViewController loadBoxArtForCaching:app];
        if (image != nil) {
            // Add the image to our cache if it was present
            [_boxArtCache setObject:image forKey:app];
        }
    }
}

- (void) updateAppsForHost:(TemporaryHost*)host {
    if (host != _selectedHost) {
        Log(LOG_W, @"Mismatched host during app update");
        return;
    }
    
    _sortedAppList = [host.appList allObjects];
    _sortedAppList = [_sortedAppList sortedArrayUsingSelector:@selector(compareName:)];
    
    if (!_showHiddenApps) {
        NSMutableArray* visibleAppList = [NSMutableArray array];
        for (TemporaryApp* app in _sortedAppList) {
            if (!app.hidden) {
                [visibleAppList addObject:app];
            }
        }
        _sortedAppList = visibleAppList;
    }
    
    _showingHosts = NO;
#if TARGET_OS_TV
    [hostScrollView removeFromSuperview];
#else
    [self resetBrowserControllerSelection];
#endif
    [self.collectionView reloadData];
#if !TARGET_OS_TV
    if (_browserControllerStates.count > 0 && _sortedAppList.count > 0) {
        [self updateBrowserControllerSelectionAtIndexPath:[NSIndexPath indexPathForItem:0 inSection:0]
                                                 animated:NO];
    }
#endif
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    UICollectionViewCell* cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"AppCell" forIndexPath:indexPath];

    for (UIView *subview in cell.contentView.subviews) {
        [subview removeFromSuperview];
    }

    UIControl *contentView;
    if (_showingHosts) {
        if (indexPath.item < _sortedHostList.count) {
            TemporaryHost *host = _sortedHostList[indexPath.item];
            contentView = [[UIComputerView alloc] initWithComputer:host andCallback:self];
        } else {
            contentView = [[UIComputerView alloc] initForAddWithCallback:self];
        }
    } else {
        TemporaryApp *app = _sortedAppList[indexPath.item];
        contentView = [[UIAppView alloc] initWithApp:app cache:_boxArtCache andCallback:self];
    }

#if TARGET_OS_TV
    CGFloat scale = cell.contentView.bounds.size.width / contentView.bounds.size.width;
    contentView.center = CGPointMake(CGRectGetMidX(cell.contentView.bounds), CGRectGetMidY(cell.contentView.bounds));
    contentView.transform = CGAffineTransformMakeScale(scale, scale);
    cell.contentView.layer.shadowColor = UIColor.blackColor.CGColor;
    cell.contentView.layer.shadowOffset = CGSizeMake(1.0, 5.0);
    cell.contentView.layer.shadowPath = [UIBezierPath bezierPathWithRect:cell.contentView.bounds].CGPath;
#else
    contentView.frame = cell.contentView.bounds;
    contentView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
#endif
    [cell.contentView addSubview:contentView];

    cell.backgroundColor = UIColor.clearColor;
    cell.contentView.backgroundColor = UIColor.clearColor;
    cell.contentView.clipsToBounds = NO;
    cell.layer.masksToBounds = NO;
    cell.exclusiveTouch = YES;

#if !TARGET_OS_TV
    BOOL controllerHighlighted = [_browserControllerIndexPath isEqual:indexPath];
    if ([contentView isKindOfClass:[UIAppView class]]) {
        [(UIAppView *)contentView setControllerHighlighted:controllerHighlighted];
    }
    else if ([contentView isKindOfClass:[UIComputerView class]]) {
        [(UIComputerView *)contentView setControllerHighlighted:controllerHighlighted];
    }
#endif

    return cell;
}

#if !TARGET_OS_TV
- (void)collectionView:(UICollectionView *)collectionView
       willDisplayCell:(UICollectionViewCell *)cell
    forItemAtIndexPath:(NSIndexPath *)indexPath {
    UIControl *control = (UIControl *)cell.contentView.subviews.firstObject;
    BOOL controllerHighlighted = [_browserControllerIndexPath isEqual:indexPath];
    if ([control isKindOfClass:[UIAppView class]]) {
        [(UIAppView *)control setControllerHighlighted:controllerHighlighted];
    }
    else if ([control isKindOfClass:[UIComputerView class]]) {
        [(UIComputerView *)control setControllerHighlighted:controllerHighlighted];
    }
}
#endif

- (NSInteger)numberOfSectionsInCollectionView:(UICollectionView *)collectionView {
    return 1; // App collection only
}

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    if (_showingHosts) {
#if TARGET_OS_TV
        // tvOS retains the established focus-driven horizontal host browser.
        return 0;
#else
        return _sortedHostList.count + 1;
#endif
    }
    else if (_selectedHost != nil && _sortedAppList != nil) {
        return _sortedAppList.count;
    }
    else {
        return 0;
    }
}

- (CGSize)collectionView:(UICollectionView *)collectionView
                   layout:(UICollectionViewLayout *)collectionViewLayout
   sizeForItemAtIndexPath:(NSIndexPath *)indexPath {
#if TARGET_OS_TV
    return ((UICollectionViewFlowLayout *)collectionViewLayout).itemSize;
#else
    UIEdgeInsets safeArea = self.view.safeAreaInsets;
    CGFloat leadingInset = MAX(24.0, safeArea.left + 12.0);
    CGFloat trailingInset = MAX(24.0, safeArea.right + 12.0);
    CGFloat availableWidth = MAX(1.0, collectionView.bounds.size.width - leadingInset - trailingInset);
    BOOL isPad = UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad;
    CGFloat desiredWidth = _showingHosts ? (isPad ? 210.0 : 176.0) : (isPad ? 160.0 : 132.0);
    CGFloat minimumWidth = _showingHosts ? (isPad ? 180.0 : 150.0) : (isPad ? 138.0 : 112.0);
    NSInteger columns = MAX(1, (NSInteger)floor((availableWidth + 16.0) / (desiredWidth + 16.0)));
    CGFloat width = floor((availableWidth - (columns - 1) * 16.0) / columns);
    width = MIN(desiredWidth, MAX(MIN(minimumWidth, availableWidth), width));
    BOOL accessibilityText = UIContentSizeCategoryIsAccessibilityCategory(self.traitCollection.preferredContentSizeCategory);
    CGFloat hostHeight = (isPad ? 180.0 : 156.0) + (accessibilityText ? 40.0 : 0.0);
    return _showingHosts ? CGSizeMake(width, hostHeight) : CGSizeMake(width, width * 1.40);
#endif
}

- (UIEdgeInsets)collectionView:(UICollectionView *)collectionView
                        layout:(UICollectionViewLayout *)collectionViewLayout
        insetForSectionAtIndex:(NSInteger)section {
#if TARGET_OS_TV
    return ((UICollectionViewFlowLayout *)collectionViewLayout).sectionInset;
#else
    UIEdgeInsets safeArea = self.view.safeAreaInsets;
    return UIEdgeInsetsMake(24.0,
                            MAX(24.0, safeArea.left + 12.0),
                            MAX(28.0, safeArea.bottom + 16.0),
                            MAX(24.0, safeArea.right + 12.0));
#endif
}

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
    
    // Purge the box art cache on low memory
    [_boxArtCache removeAllObjects];
}

- (void)dealloc {
#if !TARGET_OS_TV
    [self clearBrowsingControllerCallbacks];
#endif
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    [self.view endEditing:YES];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

- (void) disableNavigation {
    self.navigationController.navigationBar.topItem.rightBarButtonItem.enabled = NO;
    self.navigationController.navigationBar.topItem.leftBarButtonItem.enabled = NO;
}

- (void) enableNavigation {
    self.navigationController.navigationBar.topItem.rightBarButtonItem.enabled = YES;
    self.navigationController.navigationBar.topItem.leftBarButtonItem.enabled = YES;
}

#if TARGET_OS_TV
- (void)configureBrowsingControllerCallbacks {
}

- (void)clearBrowsingControllerCallbacks {
}

- (BOOL)canBecomeFocused {
    return YES;
}
#endif

- (void)didUpdateFocusInContext:(UIFocusUpdateContext *)context withAnimationCoordinator:(UIFocusAnimationCoordinator *)coordinator {
    [super didUpdateFocusInContext:context withAnimationCoordinator:coordinator];
}

@end
