//
//  SettingsViewController.m
//  Moonlight
//
//  Created by Diego Waxemberg on 10/27/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "SettingsViewController.h"
#import "TemporarySettings.h"
#import "DataManager.h"
#import "SWRevealViewController.h"

#import <VideoToolbox/VideoToolbox.h>
#import <AVFoundation/AVFoundation.h>

@interface SettingsViewController ()

- (BOOL)isSettingsContentView:(UIView *)view;
- (void)layoutSettingsControls;
- (void)updateDisplayResolutionEntries;
- (void)controllerPointerPreferenceChanged:(UISegmentedControl *)sender;
- (void)resolutionHelpButtonPressed;

@end

@implementation SettingsViewController {
    NSInteger _bitrate;
    NSInteger _lastSelectedResolutionIndex;
    UILabel *_controllerPointerLabel;
    UISegmentedControl *_controllerPointerSelector;
    UILabel *_controllerPointerDetailLabel;
    UIButton *_resolutionHelpButton;
}

@dynamic overrideUserInterfaceStyle;

static NSString* bitrateFormat = @"Bitrate: %.1f Mbps";
static const int bitrateTable[] = {
    500,
    1000,
    1500,
    2000,
    2500,
    3000,
    4000,
    5000,
    6000,
    7000,
    8000,
    9000,
    10000,
    12000,
    15000,
    18000,
    20000,
    30000,
    40000,
    50000,
    60000,
    70000,
    80000,
    100000,
    120000,
    150000,
};

enum {
    RESOLUTION_TABLE_SIZE = 7,
    RESOLUTION_TABLE_CUSTOM_INDEX = RESOLUTION_TABLE_SIZE - 1,
};
CGSize resolutionTable[RESOLUTION_TABLE_SIZE];

-(int)getSliderValueForBitrate:(NSInteger)bitrate {
    int i;
    
    for (i = 0; i < (sizeof(bitrateTable) / sizeof(*bitrateTable)); i++) {
        if (bitrate <= bitrateTable[i]) {
            return i;
        }
    }
    
    // Return the last entry in the table
    return i - 1;
}

// This view is rooted at a ScrollView. To make it scrollable,
// we'll update content size here.
-(void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self updateDisplayResolutionEntries];
    [self layoutSettingsControls];
    [self updateResolutionDisplayViewText];

    CGFloat highestViewY = 0;
    
    // Enumerate the scroll view's subviews looking for the
    // highest view Y value to set our scroll view's content
    // size.
    for (UIView* view in self.scrollView.subviews) {
        // UIScrollViews have 2 default child views
        // which represent the horizontal and vertical scrolling
        // indicators. Ignore any views we don't recognize.
        if (![self isSettingsContentView:view]) {
            continue;
        }
        
        CGFloat currentViewY = view.frame.origin.y + view.frame.size.height;
        if (currentViewY > highestViewY) {
            highestViewY = currentViewY;
        }
    }
    
    // Add a bit of padding so the view doesn't end right at the button of the display
    self.scrollView.contentSize = CGSizeMake(self.scrollView.contentSize.width,
                                             highestViewY + MAX(28.0, self.view.safeAreaInsets.bottom + 20.0));
}

- (void)viewSafeAreaInsetsDidChange {
    [super viewSafeAreaInsetsDidChange];
    [self.view setNeedsLayout];
}

- (BOOL)isSettingsContentView:(UIView *)view {
    return [view isKindOfClass:[UILabel class]] ||
           [view isKindOfClass:[UISegmentedControl class]] ||
           [view isKindOfClass:[UISlider class]] ||
           view == self.resolutionDisplayView;
}

- (void)layoutSettingsControls {
    UIEdgeInsets safeArea = self.view.safeAreaInsets;
    // Use one symmetric inset so the form remains optically centered. The
    // scroll indicator has its own edge lane and must not steal form width.
    // Align the form edge with the navigation control axis in compact
    // landscape while still clearing the Dynamic Island and rounded corners.
    CGFloat horizontalInset = MAX(24.0, MAX(safeArea.left, safeArea.right));
    CGFloat visibleWidth = self.view.bounds.size.width;
    SWRevealViewController *revealController = self.revealViewController;
    if (revealController != nil) {
        visibleWidth = MIN(visibleWidth, revealController.rearViewRevealWidth);
    }
    CGFloat availableWidth = MAX(1.0, visibleWidth - horizontalInset * 2.0);

    NSMutableArray<UIView *> *contentViews = [NSMutableArray array];
    for (UIView *view in self.scrollView.subviews) {
        if ([self isSettingsContentView:view]) {
            [contentViews addObject:view];
        }
    }
    [contentViews sortUsingComparator:^NSComparisonResult(UIView *left, UIView *right) {
        CGFloat leftY = CGRectGetMinY(left.frame);
        CGFloat rightY = CGRectGetMinY(right.frame);
        if (leftY < rightY) return NSOrderedAscending;
        if (leftY > rightY) return NSOrderedDescending;
        return NSOrderedSame;
    }];

    CGFloat currentY = 20.0;
    UIView *previousView = nil;
    for (UIView *view in contentViews) {
        BOOL isLabel = [view isKindOfClass:[UILabel class]];
        BOOL previousWasLabel = [previousView isKindOfClass:[UILabel class]];

        if (previousView != nil) {
            currentY += isLabel ? (previousWasLabel ? 4.0 : 14.0) : 6.0;
        }

        CGRect frame = view.frame;
        frame.origin.x = floor((visibleWidth - availableWidth) * 0.5);
        frame.origin.y = currentY;
        frame.size.width = availableWidth;
        if (isLabel) {
            CGSize fittingSize = [(UILabel *)view sizeThatFits:CGSizeMake(availableWidth, CGFLOAT_MAX)];
            frame.size.height = MAX(21.0, ceil(fittingSize.height));
        }
        else if ([view isKindOfClass:[UISlider class]]) {
            frame.size.height = 44.0;
        }
        else if (view == self.resolutionDisplayView) {
            frame.size.height = 48.0;
        }
        else {
            frame.size.height = 44.0;
        }
        view.frame = frame;
        currentY = CGRectGetMaxY(frame);
        previousView = view;
    }

    if (@available(iOS 13.0, tvOS 13.0, *)) {
        self.scrollView.automaticallyAdjustsScrollIndicatorInsets = NO;
    }
    self.scrollView.verticalScrollIndicatorInsets = UIEdgeInsetsMake(12.0,
                                                                      0,
                                                                      safeArea.bottom + 12.0,
                                                                      6.0);
}

- (void)updateDisplayResolutionEntries {
    UIWindow *window = self.view.window;
    if (window == nil) {
        AppDelegate *appDelegate = (AppDelegate *)UIApplication.sharedApplication.delegate;
        window = appDelegate.activeWindow;
    }
    if (window == nil) {
        return;
    }

    CGFloat screenScale = window.screen.scale;
    CGRect bounds = window.bounds;
    UIEdgeInsets safeAreaInsets = window.safeAreaInsets;
    resolutionTable[4] = CGSizeMake((bounds.size.width - safeAreaInsets.left - safeAreaInsets.right) * screenScale,
                                   (bounds.size.height - safeAreaInsets.top - safeAreaInsets.bottom) * screenScale);
    resolutionTable[5] = CGSizeMake(bounds.size.width * screenScale, bounds.size.height * screenScale);
}

BOOL isCustomResolution(CGSize res) {
    if (res.width == 0 && res.height == 0) {
        return NO;
    }
    
    for (int i = 0; i < RESOLUTION_TABLE_CUSTOM_INDEX; i++) {
        if (res.width == resolutionTable[i].width && res.height == resolutionTable[i].height) {
            return NO;
        }
    }
    
    return YES;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    // Always run settings in dark mode because we want the light fonts
    if (@available(iOS 13.0, tvOS 13.0, *)) {
        self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    }

    self.view.backgroundColor = [UIColor colorWithRed:0.055 green:0.060 blue:0.075 alpha:1.0];
    self.scrollView.backgroundColor = self.view.backgroundColor;
    self.scrollView.indicatorStyle = UIScrollViewIndicatorStyleWhite;
    self.scrollView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    self.edgesForExtendedLayout = UIRectEdgeNone;
    self.scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentAutomatic;

    for (UIView *view in self.scrollView.subviews) {
        if ([view isKindOfClass:[UILabel class]]) {
            UILabel *label = (UILabel *)view;
            label.textColor = UIColor.labelColor;
            label.adjustsFontForContentSizeCategory = YES;
            if (label.font.pointSize >= 16.0) {
                UIFont *baseFont = [UIFont systemFontOfSize:16.0 weight:UIFontWeightSemibold];
                label.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleHeadline] scaledFontForFont:baseFont];
            }
        }
        else if ([view isKindOfClass:[UISegmentedControl class]]) {
            UISegmentedControl *control = (UISegmentedControl *)view;
            UIColor *accentColor = [UIColor colorWithRed:0.55 green:0.48 blue:0.96 alpha:1.0];
            control.selectedSegmentTintColor = accentColor;
            control.backgroundColor = UIColor.tertiarySystemBackgroundColor;
            [control setTitleTextAttributes:@{NSForegroundColorAttributeName: [UIColor colorWithWhite:0.76 alpha:1.0]}
                                   forState:UIControlStateNormal];
            [control setTitleTextAttributes:@{NSForegroundColorAttributeName: UIColor.whiteColor,
                                              NSFontAttributeName: [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold]}
                                   forState:UIControlStateSelected];
        }
        else if ([view isKindOfClass:[UISlider class]]) {
            ((UISlider *)view).minimumTrackTintColor = [UIColor colorWithRed:0.55 green:0.48 blue:0.96 alpha:1.0];
        }
    }

    self.resolutionDisplayView.backgroundColor = UIColor.tertiarySystemBackgroundColor;
    self.resolutionDisplayView.layer.cornerRadius = 12.0;
    self.resolutionDisplayView.layer.cornerCurve = kCACornerCurveContinuous;

    self.resolutionSelector.accessibilityIdentifier = @"settings.resolution";
    self.framerateSelector.accessibilityIdentifier = @"settings.framerate";
    self.bitrateSlider.accessibilityIdentifier = @"settings.bitrate";
    self.touchModeSelector.accessibilityIdentifier = @"settings.touchMode";
    self.onscreenControlSelector.accessibilityIdentifier = @"settings.onscreenControls";

#if !TARGET_OS_TV
    CGFloat highestControlY = 0;
    for (UIView *view in self.scrollView.subviews) {
        if ([self isSettingsContentView:view]) {
            highestControlY = MAX(highestControlY, CGRectGetMaxY(view.frame));
        }
    }

    _controllerPointerLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, highestControlY + 26.0, 400, 22.0)];
    _controllerPointerLabel.text = @"Gamepad mouse";
    _controllerPointerLabel.textColor = UIColor.labelColor;
    _controllerPointerLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleHeadline]
        scaledFontForFont:[UIFont systemFontOfSize:16 weight:UIFontWeightSemibold]];
    _controllerPointerLabel.adjustsFontForContentSizeCategory = YES;
    [self.scrollView addSubview:_controllerPointerLabel];

    _controllerPointerSelector = [[UISegmentedControl alloc] initWithItems:@[@"Off", @"Automatic"]];
    _controllerPointerSelector.frame = CGRectMake(20, highestControlY + 54.0, 400, 38.0);
    NSNumber *pointerPreference = [NSUserDefaults.standardUserDefaults objectForKey:@"ControllerPointerModeEnabled"];
    _controllerPointerSelector.selectedSegmentIndex = pointerPreference == nil || pointerPreference.boolValue ? 1 : 0;
    _controllerPointerSelector.selectedSegmentTintColor = [UIColor colorWithRed:0.55 green:0.48 blue:0.96 alpha:1.0];
    _controllerPointerSelector.backgroundColor = UIColor.tertiarySystemBackgroundColor;
    [_controllerPointerSelector setTitleTextAttributes:@{NSForegroundColorAttributeName: [UIColor colorWithWhite:0.76 alpha:1.0]}
                                                forState:UIControlStateNormal];
    [_controllerPointerSelector setTitleTextAttributes:@{NSForegroundColorAttributeName: UIColor.whiteColor,
                                                          NSFontAttributeName: [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold]}
                                                forState:UIControlStateSelected];
    _controllerPointerSelector.accessibilityIdentifier = @"settings.controllerPointer";
    [_controllerPointerSelector addTarget:self action:@selector(controllerPointerPreferenceChanged:) forControlEvents:UIControlEventValueChanged];
    [self.scrollView addSubview:_controllerPointerSelector];

    _controllerPointerDetailLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, highestControlY + 102.0, 400, 44.0)];
    _controllerPointerDetailLabel.text = @"Desktop streams start in mouse mode. Hold Start/Menu to toggle; controllers without a hold event use a quick press. Either stick moves, A/B click, and the D-pad scrolls.";
    _controllerPointerDetailLabel.textColor = [UIColor colorWithWhite:0.72 alpha:1.0];
    _controllerPointerDetailLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleFootnote]
        scaledFontForFont:[UIFont systemFontOfSize:13 weight:UIFontWeightRegular]];
    _controllerPointerDetailLabel.adjustsFontForContentSizeCategory = YES;
    _controllerPointerDetailLabel.numberOfLines = 0;
    _controllerPointerDetailLabel.accessibilityIdentifier = @"settings.controllerPointerHint";
    [self.scrollView addSubview:_controllerPointerDetailLabel];
#endif
    
    DataManager* dataMan = [[DataManager alloc] init];
    TemporarySettings* currentSettings = [dataMan getSettings];
    
    // Ensure we pick a bitrate that falls exactly onto a slider notch
    _bitrate = bitrateTable[[self getSliderValueForBitrate:[currentSettings.bitrate intValue]]];

    self.resolutionDisplayView.layer.cornerRadius = 10;
    self.resolutionDisplayView.clipsToBounds = YES;
    _resolutionHelpButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _resolutionHelpButton.frame = self.resolutionDisplayView.bounds;
    _resolutionHelpButton.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _resolutionHelpButton.backgroundColor = UIColor.clearColor;
    _resolutionHelpButton.accessibilityLabel = @"Stream resolution";
    _resolutionHelpButton.accessibilityHint = @"Opens help for custom resolutions";
    _resolutionHelpButton.accessibilityIdentifier = @"settings.resolutionHelp";
    [_resolutionHelpButton addTarget:self action:@selector(resolutionHelpButtonPressed) forControlEvents:UIControlEventPrimaryActionTriggered];
    [self.resolutionDisplayView addSubview:_resolutionHelpButton];
    
    resolutionTable[0] = CGSizeMake(640, 360);
    resolutionTable[1] = CGSizeMake(1280, 720);
    resolutionTable[2] = CGSizeMake(1920, 1080);
    resolutionTable[3] = CGSizeMake(3840, 2160);
    [self updateDisplayResolutionEntries];
    resolutionTable[6] = CGSizeMake([currentSettings.width integerValue], [currentSettings.height integerValue]); // custom initial value
    
    // Don't populate the custom entry unless we have a custom resolution
    if (!isCustomResolution(resolutionTable[6])) {
        resolutionTable[6] = CGSizeMake(0, 0);
    }
    
    NSInteger framerate;
    switch ([currentSettings.framerate integerValue]) {
        case 30:
            framerate = 0;
            break;
        default:
        case 60:
            framerate = 1;
            break;
        case 120:
            framerate = 2;
            break;
    }

    NSInteger resolution = 1;
    for (int i = 0; i < RESOLUTION_TABLE_SIZE; i++) {
        if ((int) resolutionTable[i].height == [currentSettings.height intValue]
            && (int) resolutionTable[i].width == [currentSettings.width intValue]) {
            resolution = i;
            break;
        }
    }

    // Only show the 120 FPS option if we have a > 60-ish Hz display
    bool enable120Fps = false;
    if (@available(iOS 10.3, tvOS 10.3, *)) {
        if ([UIScreen mainScreen].maximumFramesPerSecond > 62) {
            enable120Fps = true;
        }
    }
    if (!enable120Fps) {
        [self.framerateSelector removeSegmentAtIndex:2 animated:NO];
    }

    // Disable codec selector segments for unsupported codecs
#if defined(__IPHONE_16_0) || defined(__TVOS_16_0)
    if (!VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1))
#endif
    {
        [self.codecSelector removeSegmentAtIndex:2 animated:NO];
    }
    if (!VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)) {
        [self.codecSelector removeSegmentAtIndex:1 animated:NO];

        // Only enable the 4K option for "recent" devices. We'll judge that by whether
        // they support HEVC decoding (A9 or later).
        [self.resolutionSelector setEnabled:NO forSegmentAtIndex:3];
    }
    switch (currentSettings.preferredCodec) {
        case CODEC_PREF_AUTO:
            [self.codecSelector setSelectedSegmentIndex:self.codecSelector.numberOfSegments - 1];
            break;
            
        case CODEC_PREF_AV1:
            [self.codecSelector setSelectedSegmentIndex:2];
            break;
            
        case CODEC_PREF_HEVC:
            [self.codecSelector setSelectedSegmentIndex:1];
            break;
            
        case CODEC_PREF_H264:
            [self.codecSelector setSelectedSegmentIndex:0];
            break;
    }
    
    if (!VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) || !(AVPlayer.availableHDRModes & AVPlayerHDRModeHDR10)) {
        [self.hdrSelector removeAllSegments];
        [self.hdrSelector insertSegmentWithTitle:@"Unsupported on this device" atIndex:0 animated:NO];
        [self.hdrSelector setEnabled:NO];
    }
    else {
        [self.hdrSelector setSelectedSegmentIndex:currentSettings.enableHdr ? 1 : 0];
    }
    
    [self.touchModeSelector setSelectedSegmentIndex:currentSettings.absoluteTouchMode ? 1 : 0];
    [self.touchModeSelector addTarget:self action:@selector(touchModeChanged) forControlEvents:UIControlEventValueChanged];
    [self.statsOverlaySelector setSelectedSegmentIndex:currentSettings.statsOverlay ? 1 : 0];
    [self.btMouseSelector setSelectedSegmentIndex:currentSettings.btMouseSupport ? 1 : 0];
    [self.optimizeSettingsSelector setSelectedSegmentIndex:currentSettings.optimizeGames ? 1 : 0];
    [self.framePacingSelector setSelectedSegmentIndex:currentSettings.useFramePacing ? 1 : 0];
    [self.multiControllerSelector setSelectedSegmentIndex:currentSettings.multiController ? 1 : 0];
    [self.swapABXYButtonsSelector setSelectedSegmentIndex:currentSettings.swapABXYButtons ? 1 : 0];
    [self.audioOnPCSelector setSelectedSegmentIndex:currentSettings.playAudioOnPC ? 1 : 0];
    NSInteger onscreenControls = [currentSettings.onscreenControls integerValue];
    _lastSelectedResolutionIndex = resolution;
    [self.resolutionSelector setSelectedSegmentIndex:resolution];
    [self.resolutionSelector addTarget:self action:@selector(newResolutionChosen) forControlEvents:UIControlEventValueChanged];
    [self.framerateSelector setSelectedSegmentIndex:framerate];
    [self.framerateSelector addTarget:self action:@selector(updateBitrate) forControlEvents:UIControlEventValueChanged];
    [self.onscreenControlSelector setSelectedSegmentIndex:onscreenControls];
    [self.onscreenControlSelector setEnabled:!currentSettings.absoluteTouchMode];
    [self.bitrateSlider setMinimumValue:0];
    [self.bitrateSlider setMaximumValue:(sizeof(bitrateTable) / sizeof(*bitrateTable)) - 1];
    [self.bitrateSlider setValue:[self getSliderValueForBitrate:_bitrate] animated:YES];
    [self.bitrateSlider addTarget:self action:@selector(bitrateSliderMoved) forControlEvents:UIControlEventValueChanged];
    [self updateBitrateText];
    [self updateResolutionDisplayViewText];
}

- (void) touchModeChanged {
    // Disable on-screen controls in absolute touch mode
    [self.onscreenControlSelector setEnabled:[self.touchModeSelector selectedSegmentIndex] == 0];
}

- (void) updateBitrate {
    NSInteger fps = [self getChosenFrameRate];
    NSInteger width = [self getChosenStreamWidth];
    NSInteger height = [self getChosenStreamHeight];
    NSInteger defaultBitrate;
    
    // This logic is shamelessly stolen from Moonlight Qt:
    // https://github.com/moonlight-stream/moonlight-qt/blob/master/app/settings/streamingpreferences.cpp
    
    // Don't scale bitrate linearly beyond 60 FPS. It's definitely not a linear
    // bitrate increase for frame rate once we get to values that high.
    float frameRateFactor = (fps <= 60 ? fps : (sqrtf(fps / 60.f) * 60.f)) / 30.f;

    // TODO: Collect some empirical data to see if these defaults make sense.
    // We're just using the values that the Shield used, as we have for years.
    struct {
        NSInteger pixels;
        int factor;
    } resTable[] = {
        { 640 * 360, 1 },
        { 854 * 480, 2 },
        { 1280 * 720, 5 },
        { 1920 * 1080, 10 },
        { 2560 * 1440, 20 },
        { 3840 * 2160, 40 },
        { -1, -1 }
    };

    // Calculate the resolution factor by linear interpolation of the resolution table
    float resolutionFactor;
    NSInteger pixels = width * height;
    for (int i = 0;; i++) {
        if (pixels == resTable[i].pixels) {
            // We can bail immediately for exact matches
            resolutionFactor = resTable[i].factor;
            break;
        }
        else if (pixels < resTable[i].pixels) {
            if (i == 0) {
                // Never go below the lowest resolution entry
                resolutionFactor = resTable[i].factor;
            }
            else {
                // Interpolate between the entry greater than the chosen resolution (i) and the entry less than the chosen resolution (i-1)
                resolutionFactor = ((float)(pixels - resTable[i-1].pixels) / (resTable[i].pixels - resTable[i-1].pixels)) * (resTable[i].factor - resTable[i-1].factor) + resTable[i-1].factor;
            }
            break;
        }
        else if (resTable[i].pixels == -1) {
            // Never go above the highest resolution entry
            resolutionFactor = resTable[i-1].factor;
            break;
        }
    }

    defaultBitrate = round(resolutionFactor * frameRateFactor) * 1000;
    _bitrate = MIN(defaultBitrate, 100000);
    [self.bitrateSlider setValue:[self getSliderValueForBitrate:_bitrate] animated:YES];
    
    [self updateBitrateText];
}

- (void) newResolutionChosen {
    BOOL lastSegmentSelected = [self.resolutionSelector selectedSegmentIndex] + 1 == [self.resolutionSelector numberOfSegments];
    if (lastSegmentSelected) {
        [self promptCustomResolutionDialog];
    }
    else {
        [self updateBitrate];
        [self updateResolutionDisplayViewText];
        _lastSelectedResolutionIndex = [self.resolutionSelector selectedSegmentIndex];
    }
}

- (void) promptCustomResolutionDialog {
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"Enter Custom Resolution" message:nil preferredStyle:UIAlertControllerStyleAlert];

    [alertController addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"Video Width";
        textField.clearButtonMode = UITextFieldViewModeAlways;
        textField.borderStyle = UITextBorderStyleRoundedRect;
        textField.keyboardType = UIKeyboardTypeNumberPad;
        
        if (resolutionTable[RESOLUTION_TABLE_CUSTOM_INDEX].width == 0) {
            textField.text = @"";
        }
        else {
            textField.text = [NSString stringWithFormat:@"%d", (int) resolutionTable[RESOLUTION_TABLE_CUSTOM_INDEX].width];
        }
    }];

    [alertController addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"Video Height";
        textField.clearButtonMode = UITextFieldViewModeAlways;
        textField.borderStyle = UITextBorderStyleRoundedRect;
        textField.keyboardType = UIKeyboardTypeNumberPad;
        
        if (resolutionTable[RESOLUTION_TABLE_CUSTOM_INDEX].height == 0) {
            textField.text = @"";
        }
        else {
            textField.text = [NSString stringWithFormat:@"%d", (int) resolutionTable[RESOLUTION_TABLE_CUSTOM_INDEX].height];
        }
    }];

    [alertController addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSArray * textfields = alertController.textFields;
        UITextField *widthField = textfields[0];
        UITextField *heightField = textfields[1];
        
        long width = [widthField.text integerValue];
        long height = [heightField.text integerValue];
        if (width <= 0 || height <= 0) {
            // Restore the previous selection
            [self.resolutionSelector setSelectedSegmentIndex:self->_lastSelectedResolutionIndex];
            return;
        }
        
        // H.264 maximum
        int maxResolutionDimension = 4096;
        if (@available(iOS 11.0, tvOS 11.0, *)) {
            if (VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)) {
                // HEVC maximum
                maxResolutionDimension = 8192;
            }
        }
        
        // Cap to maximum valid dimensions
        width = MIN(width, maxResolutionDimension);
        height = MIN(height, maxResolutionDimension);
        
        // Cap to minimum valid dimensions
        width = MAX(width, 256);
        height = MAX(height, 256);

        resolutionTable[RESOLUTION_TABLE_CUSTOM_INDEX] = CGSizeMake(width, height);
        [self updateBitrate];
        [self updateResolutionDisplayViewText];
        self->_lastSelectedResolutionIndex = [self.resolutionSelector selectedSegmentIndex];
        
        UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"Custom Resolution Selected" message: @"Custom resolutions are not officially supported by GeForce Experience, so it will not set your host display resolution. You will need to set it manually while in game.\n\nResolutions that are not supported by your client or host PC may cause streaming errors." preferredStyle:UIAlertControllerStyleAlert];
        [alertController addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alertController animated:YES completion:nil];
    }]];

    [alertController addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
        // Restore the previous selection
        [self.resolutionSelector setSelectedSegmentIndex:self->_lastSelectedResolutionIndex];
    }]];

    [self presentViewController:alertController animated:YES completion:nil];
}

- (void)resolutionDisplayViewTapped:(UITapGestureRecognizer *)sender {
    NSURL *url = [NSURL URLWithString:@"https://moonlight-stream.org/custom-resolution"];
    if ([[UIApplication sharedApplication] canOpenURL:url]) {
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    }
}

- (void) updateResolutionDisplayViewText {
    NSInteger width = [self getChosenStreamWidth];
    NSInteger height = [self getChosenStreamHeight];
    CGFloat viewFrameWidth = self.resolutionDisplayView.frame.size.width;
    CGFloat viewFrameHeight = self.resolutionDisplayView.frame.size.height;
    CGFloat padding = 10;
    CGFloat fontSize = [UIFont smallSystemFontSize];
    
    for (UIView *subview in self.resolutionDisplayView.subviews) {
        [subview removeFromSuperview];
    }
    UILabel *label1 = [[UILabel alloc] init];
    label1.isAccessibilityElement = NO;
    label1.text = @"Set PC/Game resolution: ";
    label1.font = [UIFont systemFontOfSize:fontSize];
    [label1 sizeToFit];
    label1.frame = CGRectMake(padding, (viewFrameHeight - label1.frame.size.height) / 2, label1.frame.size.width, label1.frame.size.height);

    UILabel *label2 = [[UILabel alloc] init];
    label2.isAccessibilityElement = NO;
    label2.text = [NSString stringWithFormat:@"%ld x %ld", (long)width, (long)height];
    [label2 sizeToFit];
    label2.frame = CGRectMake(viewFrameWidth - label2.frame.size.width - padding, (viewFrameHeight - label2.frame.size.height) / 2, label2.frame.size.width, label2.frame.size.height);

    [self.resolutionDisplayView addSubview:label1];
    [self.resolutionDisplayView addSubview:label2];
    _resolutionHelpButton.frame = self.resolutionDisplayView.bounds;
    _resolutionHelpButton.accessibilityValue = [NSString stringWithFormat:@"%ld by %ld", (long)width, (long)height];
    [self.resolutionDisplayView addSubview:_resolutionHelpButton];
}

- (void)resolutionHelpButtonPressed {
    [self resolutionDisplayViewTapped:nil];
}

- (void) bitrateSliderMoved {
    assert(self.bitrateSlider.value < (sizeof(bitrateTable) / sizeof(*bitrateTable)));
    _bitrate = bitrateTable[(int)self.bitrateSlider.value];
    [self updateBitrateText];
}

- (void) updateBitrateText {
    // Display bitrate in Mbps
    [self.bitrateLabel setText:[NSString stringWithFormat:bitrateFormat, _bitrate / 1000.]];
}

- (NSInteger) getChosenFrameRate {
    switch ([self.framerateSelector selectedSegmentIndex]) {
        case 0:
            return 30;
        case 1:
            return 60;
        case 2:
            return 120;
        default:
            abort();
    }
}

- (uint32_t) getChosenCodecPreference {
    // Auto is always the last segment
    if (self.codecSelector.selectedSegmentIndex == self.codecSelector.numberOfSegments - 1) {
        return CODEC_PREF_AUTO;
    }
    else {
        switch (self.codecSelector.selectedSegmentIndex) {
            case 0:
                return CODEC_PREF_H264;
                
            case 1:
                return CODEC_PREF_HEVC;
                
            case 2:
                return CODEC_PREF_AV1;
                
            default:
                abort();
        }
    }
}

- (NSInteger) getChosenStreamHeight {
    // because the 4k resolution can be removed
    BOOL lastSegmentSelected = [self.resolutionSelector selectedSegmentIndex] + 1 == [self.resolutionSelector numberOfSegments];
    if (lastSegmentSelected) {
        return resolutionTable[RESOLUTION_TABLE_CUSTOM_INDEX].height;
    }

    return resolutionTable[[self.resolutionSelector selectedSegmentIndex]].height;
}

- (NSInteger) getChosenStreamWidth {
    // because the 4k resolution can be removed
    BOOL lastSegmentSelected = [self.resolutionSelector selectedSegmentIndex] + 1 == [self.resolutionSelector numberOfSegments];
    if (lastSegmentSelected) {
        return resolutionTable[RESOLUTION_TABLE_CUSTOM_INDEX].width;
    }

    return resolutionTable[[self.resolutionSelector selectedSegmentIndex]].width;
}

- (void)controllerPointerPreferenceChanged:(UISegmentedControl *)sender {
    [NSUserDefaults.standardUserDefaults setBool:sender.selectedSegmentIndex == 1
                                          forKey:@"ControllerPointerModeEnabled"];
}

- (void) saveSettings {
    DataManager* dataMan = [[DataManager alloc] init];
    NSInteger framerate = [self getChosenFrameRate];
    NSInteger height = [self getChosenStreamHeight];
    NSInteger width = [self getChosenStreamWidth];
    NSInteger onscreenControls = [self.onscreenControlSelector selectedSegmentIndex];
    BOOL optimizeGames = [self.optimizeSettingsSelector selectedSegmentIndex] == 1;
    BOOL multiController = [self.multiControllerSelector selectedSegmentIndex] == 1;
    BOOL swapABXYButtons = [self.swapABXYButtonsSelector selectedSegmentIndex] == 1;
    BOOL audioOnPC = [self.audioOnPCSelector selectedSegmentIndex] == 1;
    uint32_t preferredCodec = [self getChosenCodecPreference];
    BOOL btMouseSupport = [self.btMouseSelector selectedSegmentIndex] == 1;
    BOOL useFramePacing = [self.framePacingSelector selectedSegmentIndex] == 1;
    BOOL absoluteTouchMode = [self.touchModeSelector selectedSegmentIndex] == 1;
    BOOL statsOverlay = [self.statsOverlaySelector selectedSegmentIndex] == 1;
    BOOL enableHdr = [self.hdrSelector selectedSegmentIndex] == 1;
    [dataMan saveSettingsWithBitrate:_bitrate
                           framerate:framerate
                              height:height
                               width:width
                         audioConfig:2 // Stereo
                    onscreenControls:onscreenControls
                       optimizeGames:optimizeGames
                     multiController:multiController
                     swapABXYButtons:swapABXYButtons
                           audioOnPC:audioOnPC
                      preferredCodec:preferredCodec
                      useFramePacing:useFramePacing
                           enableHdr:enableHdr
                      btMouseSupport:btMouseSupport
                   absoluteTouchMode:absoluteTouchMode
                        statsOverlay:statsOverlay];
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}


#pragma mark - Navigation

- (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender {
}


@end
