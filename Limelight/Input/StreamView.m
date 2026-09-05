//
//  StreamView.m
//  Moonlight
//
//  Created by Cameron Gutman on 10/19/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "StreamView.h"
#include <Limelight.h>
#import "DataManager.h"
#import "ControllerSupport.h"
#import "KeyboardSupport.h"
#import "RelativeTouchHandler.h"
#import "AbsoluteTouchHandler.h"
#import "KeyboardInputField.h"
#import <objc/runtime.h>
#include <stdatomic.h>

static const double X1_MOUSE_SPEED_DIVISOR = 2.5;

static char KeyboardButtonKeyCodeAssociation;
static char KeyboardButtonToggleAssociation;

#if !TARGET_OS_TV
@interface MoonlightKeyboardAccessoryScrollView : UIScrollView
@property (nonatomic, weak) UIView *centeredContentView;
@end

@implementation MoonlightKeyboardAccessoryScrollView
- (void)layoutSubviews {
    [super layoutSubviews];

    CGFloat contentWidth = CGRectGetWidth(self.centeredContentView.bounds) + 16.0;
    CGFloat centeringInset = MAX(0.0, (CGRectGetWidth(self.bounds) - contentWidth) * 0.5);
    self.contentInset = UIEdgeInsetsMake(0, centeringInset, 0, centeringInset);
    self.alwaysBounceHorizontal = contentWidth > CGRectGetWidth(self.bounds);
}
@end
#endif

@interface StreamView ()
- (void)activateHardwareInput;
#if !TARGET_OS_TV
- (void)dismissKeyboard;
- (void)releaseAccessoryKeys;
- (void)resetAccessoryKeyState;
#endif
@end

@implementation StreamView {
    OnScreenControls* onScreenControls;
    
    KeyboardInputField* keyInputField;
    BOOL isInputingText;
    NSMutableSet* keysDown;
    uint64_t keyboardSessionToken;
    BOOL keyboardSessionInvalidated;
    _Atomic(bool) inputSuspended;
#if !TARGET_OS_TV
    UITapGestureRecognizer* keyboardToggleGestureRecognizer;
    UIView* keyboardAccessoryView;
    NSArray<UIButton *> *keyboardAccessoryButtons;
#endif
    
    float streamAspectRatio;
    
    // iOS 13.4 mouse support
    NSInteger lastMouseButtonMask;
    float lastMouseX;
    float lastMouseY;
    CGPoint lastScrollTranslation;
    
    // Citrix X1 mouse support
    X1Mouse* x1mouse;
    double accumulatedMouseDeltaX;
    double accumulatedMouseDeltaY;
    
    UIResponder<MoonlightTouchHandler>* touchHandler;
    
    __weak id<UserInteractionDelegate> interactionDelegate;
    NSTimer* interactionTimer;
    BOOL hasUserInteracted;
    
    NSDictionary<NSString *, NSNumber *> *dictCodes;
}

- (void) setupStreamView:(ControllerSupport*)controllerSupport
     interactionDelegate:(id<UserInteractionDelegate>)interactionDelegate
                  config:(StreamConfiguration*)streamConfig {
    atomic_init(&inputSuspended, false);
    self->interactionDelegate = interactionDelegate;
    self->streamAspectRatio = (float)streamConfig.width / (float)streamConfig.height;
    
    TemporarySettings* settings = [[[DataManager alloc] init] getSettings];
    
    if (keysDown == nil) {
        keysDown = [[NSMutableSet alloc] init];
    }
    if (keyboardSessionToken == 0) {
        keyboardSessionToken = [KeyboardSupport beginKeyboardSession];
    }
    MoonlightSetMouseInputSuspended(NO);
    if (keyInputField == nil) {
        keyInputField = [[KeyboardInputField alloc] initWithFrame:CGRectZero];
        keyInputField.delegate = self;
        keyInputField.text = @"0";
        keyInputField.keyboardType = UIKeyboardTypeDefault;
#if !TARGET_OS_TV
        keyInputField.keyboardAppearance = UIKeyboardAppearanceDark;
#endif
        keyInputField.autocorrectionType = UITextAutocorrectionTypeNo;
        keyInputField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        keyInputField.spellCheckingType = UITextSpellCheckingTypeNo;
        keyInputField.backgroundColor = UIColor.clearColor;
        keyInputField.textColor = UIColor.clearColor;
        keyInputField.tintColor = UIColor.clearColor;
        keyInputField.accessibilityElementsHidden = YES;
        keyInputField.isAccessibilityElement = NO;
        [keyInputField addTarget:self
                          action:@selector(onKeyboardPressed:)
                forControlEvents:UIControlEventEditingChanged];
#if !TARGET_OS_TV
        keyboardAccessoryView = [self createKeyboardAccessoryView];
        keyInputField.inputAccessoryView = keyboardAccessoryView;
#endif
        [self addSubview:keyInputField];
    }

#if !TARGET_OS_TV
    if (keyboardToggleGestureRecognizer == nil) {
        keyboardToggleGestureRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                                   action:@selector(keyboardToggleGestureRecognized:)];
        keyboardToggleGestureRecognizer.numberOfTapsRequired = 1;
        keyboardToggleGestureRecognizer.numberOfTouchesRequired = 3;
        keyboardToggleGestureRecognizer.cancelsTouchesInView = YES;
        keyboardToggleGestureRecognizer.delegate = self;
        [self addGestureRecognizer:keyboardToggleGestureRecognizer];
    }
    self.isAccessibilityElement = YES;
    self.accessibilityLabel = @"Remote desktop";
    self.accessibilityHint = @"Three-finger tap opens the remote keyboard";
    self.accessibilityCustomActions = @[[[UIAccessibilityCustomAction alloc]
        initWithName:@"Toggle remote keyboard"
              target:self
            selector:@selector(accessibilityToggleKeyboard)]];
#endif
    
#if TARGET_OS_TV
    // tvOS requires RelativeTouchHandler to manage Apple Remote input
    self->touchHandler = [[RelativeTouchHandler alloc] initWithView:self];
#else
    // iOS uses RelativeTouchHandler or AbsoluteTouchHandler depending on user preference
    if (settings.absoluteTouchMode) {
        self->touchHandler = [[AbsoluteTouchHandler alloc] initWithView:self];
    }
    else {
        self->touchHandler = [[RelativeTouchHandler alloc] initWithView:self];
    }
    
    onScreenControls = [[OnScreenControls alloc] initWithView:self controllerSup:controllerSupport streamConfig:streamConfig];
    OnScreenControlsLevel level = (OnScreenControlsLevel)[settings.onscreenControls integerValue];
    if (settings.absoluteTouchMode) {
        Log(LOG_I, @"On-screen controls disabled in absolute touch mode");
        [onScreenControls setLevel:OnScreenControlsLevelOff];
    }
    else if (level == OnScreenControlsLevelAuto) {
        [controllerSupport initAutoOnScreenControlMode:onScreenControls];
    }
    else {
        Log(LOG_I, @"Setting manual on-screen controls level: %d", (int)level);
        [onScreenControls setLevel:level];
    }
    
    // It would be nice to just use GCMouse on iOS 14+ and the older API on iOS 13
    // but unfortunately that isn't possible today. GCMouse doesn't recognize many
    // mice correctly, but UIKit does. We will register for both and ignore UIKit
    // events if a GCMouse is connected.
    if (@available(iOS 13.4, *)) {
        [self addInteraction:[[UIPointerInteraction alloc] initWithDelegate:self]];

        // Magic Keyboard and many keyboard-case trackpads are delivered through
        // UIKit rather than GCMouse. Pointer-region callbacks are not guaranteed
        // for every movement, so use a hover recognizer as the continuous path.
        UIHoverGestureRecognizer *pointerHoverRecognizer =
            [[UIHoverGestureRecognizer alloc] initWithTarget:self action:@selector(mouseHovered:)];
        pointerHoverRecognizer.allowedTouchTypes = @[@(UITouchTypeIndirectPointer)];
        pointerHoverRecognizer.cancelsTouchesInView = NO;
        [self addGestureRecognizer:pointerHoverRecognizer];
        
        UIPanGestureRecognizer *discreteMouseWheelRecognizer = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(mouseWheelMovedDiscrete:)];
        discreteMouseWheelRecognizer.maximumNumberOfTouches = 0;
        discreteMouseWheelRecognizer.allowedScrollTypesMask = UIScrollTypeMaskDiscrete;
        discreteMouseWheelRecognizer.allowedTouchTypes = @[@(UITouchTypeIndirectPointer)];
        [self addGestureRecognizer:discreteMouseWheelRecognizer];
        
        UIPanGestureRecognizer *continuousMouseWheelRecognizer = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(mouseWheelMovedContinuous:)];
        continuousMouseWheelRecognizer.maximumNumberOfTouches = 0;
        continuousMouseWheelRecognizer.allowedScrollTypesMask = UIScrollTypeMaskContinuous;
        continuousMouseWheelRecognizer.allowedTouchTypes = @[@(UITouchTypeIndirectPointer)];
        [self addGestureRecognizer:continuousMouseWheelRecognizer];
    }
    
#if defined(__IPHONE_16_1) || defined(__TVOS_16_1)
    if (@available(iOS 16.1, *)) {
        UIHoverGestureRecognizer *stylusHoverRecognizer = [[UIHoverGestureRecognizer alloc] initWithTarget:self action:@selector(sendStylusHoverEvent:)];
        stylusHoverRecognizer.allowedTouchTypes = @[@(UITouchTypePencil)];
        [self addGestureRecognizer:stylusHoverRecognizer];
    }
#endif
#endif
    
    x1mouse = [[X1Mouse alloc] init];
    x1mouse.delegate = self;
    
    if (settings.btMouseSupport) {
        [x1mouse start];
    }
    
    // This is critical to ensure keyboard events are delivered to this
    // StreamView and not our parent UIView, especially on tvOS.
    [self activateHardwareInput];
}

- (void)activateHardwareInput {
    if (self.window == nil ||
        keyboardSessionInvalidated ||
        atomic_load(&inputSuspended) ||
        keyInputField.isFirstResponder ||
        UIApplication.sharedApplication.applicationState != UIApplicationStateActive) {
        return;
    }
    [self becomeFirstResponder];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (self.window != nil) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self activateHardwareInput];
        });
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];

#if !TARGET_OS_TV
    if (onScreenControls != nil) {
        [onScreenControls updateLayoutForBounds:self.bounds safeAreaInsets:self.safeAreaInsets];
    }
#endif
}

- (void)prepareForInactivity {
    atomic_store(&inputSuspended, true);
    MoonlightSetMouseInputSuspended(YES);
    [touchHandler cancelAllTouches];
    MoonlightReleaseMouseButtons(MoonlightMouseButtonSourceAbsoluteTouch);
    MoonlightReleaseMouseButtons(MoonlightMouseButtonSourceRelativeTouch);
    MoonlightReleaseMouseButtons(MoonlightMouseButtonSourceUIKitMouse);
    MoonlightReleaseMouseButtons(MoonlightMouseButtonSourceX1Mouse);
    if (keyboardSessionToken != 0) {
        [KeyboardSupport endKeyboardSession:keyboardSessionToken];
        keyboardSessionToken = 0;
    }
#if !TARGET_OS_TV
    isInputingText = NO;
    [self resetAccessoryKeyState];
    [keyInputField resignFirstResponder];
    [self resignFirstResponder];
#endif
}

- (void)resumeAfterInactivity {
    if (keyboardSessionInvalidated) {
        return;
    }
    atomic_store(&inputSuspended, false);
    MoonlightSetMouseInputSuspended(NO);
    if (keyboardSessionToken == 0) {
        keyboardSessionToken = [KeyboardSupport beginKeyboardSession];
    }
    [self activateHardwareInput];
}

- (void)invalidateKeyboardSession {
    keyboardSessionInvalidated = YES;
    [self prepareForInactivity];
}

- (void)dealloc {
    if (keyboardSessionToken != 0) {
        [KeyboardSupport endKeyboardSession:keyboardSessionToken];
    }
}

- (void)startInteractionTimer {
    // Restart user interaction tracking
    hasUserInteracted = NO;
    
    BOOL timerAlreadyRunning = interactionTimer != nil;
    
    // Start/restart the timer
    [interactionTimer invalidate];
    interactionTimer = [NSTimer scheduledTimerWithTimeInterval:2.0
                        target:self
                        selector:@selector(interactionTimerExpired:)
                        userInfo:nil
                        repeats:NO];
    
    // Notify the delegate if this was a new user interaction
    if (!timerAlreadyRunning) {
        [interactionDelegate userInteractionBegan];
    }
}

- (void)interactionTimerExpired:(NSTimer *)timer {
    if (!hasUserInteracted) {
        // User has finished touching the screen
        interactionTimer = nil;
        [interactionDelegate userInteractionEnded];
    }
    else {
        // User is still touching the screen. Restart the timer.
        [self startInteractionTimer];
    }
}

- (void) showOnScreenControls {
#if !TARGET_OS_TV
    [onScreenControls show];
#endif
}

- (OnScreenControlsLevel) getCurrentOscState {
    if (onScreenControls == nil) {
        return OnScreenControlsLevelOff;
    }
    else {
        return [onScreenControls getLevel];
    }
}

- (CGSize) getVideoAreaSize {
    if (self.bounds.size.width > self.bounds.size.height * streamAspectRatio) {
        return CGSizeMake(self.bounds.size.height * streamAspectRatio, self.bounds.size.height);
    } else {
        return CGSizeMake(self.bounds.size.width, self.bounds.size.width / streamAspectRatio);
    }
}

- (CGPoint) adjustCoordinatesForVideoArea:(CGPoint)point {
    // These are now relative to the StreamView, however we need to scale them
    // further to make them relative to the actual video portion.
    float x = point.x - self.bounds.origin.x;
    float y = point.y - self.bounds.origin.y;
    
    // For some reason, we don't seem to always get to the bounds of the window
    // so we'll subtract 1 pixel if we're to the left/below of the origin and
    // and add 1 pixel if we're to the right/above. It should be imperceptible
    // to the user but it will allow activation of gestures that require contact
    // with the edge of the screen (like Aero Snap).
    if (x < self.bounds.size.width / 2) {
        x--;
    }
    else {
        x++;
    }
    if (y < self.bounds.size.height / 2) {
        y--;
    }
    else {
        y++;
    }
    
    // This logic mimics what iOS does with AVLayerVideoGravityResizeAspect
    CGSize videoSize = [self getVideoAreaSize];
    CGPoint videoOrigin = CGPointMake(self.bounds.size.width / 2 - videoSize.width / 2,
                                      self.bounds.size.height / 2 - videoSize.height / 2);
    
    // Confine the cursor to the video region. We don't just discard events outside
    // the region because we won't always get one exactly when the mouse leaves the region.
    return CGPointMake(MIN(MAX(x, videoOrigin.x), videoOrigin.x + videoSize.width) - videoOrigin.x,
                       MIN(MAX(y, videoOrigin.y), videoOrigin.y + videoSize.height) - videoOrigin.y);
}

#if !TARGET_OS_TV

- (uint16_t)getRotationFromAzimuthAngle:(float)azimuthAngle {
    // iOS reports azimuth of 0 when the stylus is pointing west, but Moonlight expects
    // rotation of 0 to mean the stylus is pointing north. Rotate the azimuth angle
    // clockwise by 90 degrees to convert from iOS to Moonlight rotation conventions.
    int32_t rotationAngle = (azimuthAngle - M_PI_2) * (180.f / M_PI);
    if (rotationAngle < 0) {
        rotationAngle += 360;
    }
    return (uint16_t)rotationAngle;
}

- (uint8_t)getTiltFromAltitudeAngle:(float)altitudeAngle {
    // iOS reports an altitude of 0 when the stylus is parallel to the touch surface,
    // while Moonlight expects a tilt of 0 when the stylus is perpendicular to the surface.
    // Subtract the tilt angle from 90 to convert from iOS to Moonlight tilt conventions.
    uint8_t altitudeDegs = abs((int16_t)(altitudeAngle * (180.f / M_PI)));
    return 90 - MIN(90, altitudeDegs);
}

- (BOOL)sendStylusEvent:(UITouch*)event {
    if (atomic_load_explicit(&inputSuspended, memory_order_acquire)) {
        return YES;
    }
    uint8_t type;
    
    // Don't touch stylus events if the host doesn't support them. We want to pass
    // them as normal touches for legacy hosts that don't understand pen events.
    if (!(LiGetHostFeatureFlags() & LI_FF_PEN_TOUCH_EVENTS)) {
        return NO;
    }
    
    switch (event.phase) {
        case UITouchPhaseBegan:
            type = LI_TOUCH_EVENT_DOWN;
            break;
        case UITouchPhaseMoved:
            type = LI_TOUCH_EVENT_MOVE;
            break;
        case UITouchPhaseEnded:
            type = LI_TOUCH_EVENT_UP;
            break;
        case UITouchPhaseCancelled:
            type = LI_TOUCH_EVENT_CANCEL;
            break;
        default:
            return YES;
    }

    CGPoint location = [self adjustCoordinatesForVideoArea:[event locationInView:self]];
    CGSize videoSize = [self getVideoAreaSize];
    
    return LiSendPenEvent(type, LI_TOOL_TYPE_PEN, 0, location.x / videoSize.width, location.y / videoSize.height,
                          (event.force / event.maximumPossibleForce) / sin(event.altitudeAngle),
                          0.0f, 0.0f,
                          [self getRotationFromAzimuthAngle:[event azimuthAngleInView:self]],
                          [self getTiltFromAltitudeAngle:event.altitudeAngle]) != LI_ERR_UNSUPPORTED;
}

- (void)sendStylusHoverEvent:(UIHoverGestureRecognizer*)gesture API_AVAILABLE(ios(13.0)) {
    if (atomic_load_explicit(&inputSuspended, memory_order_acquire)) {
        return;
    }
    uint8_t type;
    
    switch (gesture.state) {
        case UIGestureRecognizerStateBegan:
        case UIGestureRecognizerStateChanged:
            type = LI_TOUCH_EVENT_HOVER;
            break;

        case UIGestureRecognizerStateEnded:
            type = LI_TOUCH_EVENT_HOVER_LEAVE;
            break;

        default:
            return;
    }

    CGPoint location = [self adjustCoordinatesForVideoArea:[gesture locationInView:self]];
    CGSize videoSize = [self getVideoAreaSize];
    
    float distance = 0.0f;
#if defined(__IPHONE_16_1) || defined(__TVOS_16_1)
    if (@available(iOS 16.1, *)) {
        distance = gesture.zOffset;
    }
#endif
    
    uint16_t rotationAngle = LI_ROT_UNKNOWN;
    uint8_t tiltAngle = LI_TILT_UNKNOWN;
#if defined(__IPHONE_16_4) || defined(__TVOS_16_4)
    if (@available(iOS 16.4, *)) {
        rotationAngle = [self getRotationFromAzimuthAngle:[gesture azimuthAngleInView:self]];
        tiltAngle = [self getTiltFromAltitudeAngle:gesture.altitudeAngle];
    }
#endif
    
    LiSendPenEvent(type, LI_TOOL_TYPE_PEN, 0, location.x / videoSize.width, location.y / videoSize.height,
                   distance, 0.0f, 0.0f, rotationAngle, tiltAngle);
}

#endif

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    if (atomic_load_explicit(&inputSuspended, memory_order_acquire)) {
        return;
    }
    if ([self handleMouseButtonEvent:BUTTON_ACTION_PRESS
                          forTouches:touches
                           withEvent:event]) {
        // If it's a mouse event, we're done
        return;
    }
    
    Log(LOG_D, @"Touch down");
    
    // Notify of user interaction and start expiration timer
    [self startInteractionTimer];
    
#if !TARGET_OS_TV
    if (@available(iOS 13.4, *)) {
        for (UITouch* touch in touches) {
            if (touch.type == UITouchTypePencil) {
                if ([self sendStylusEvent:touch]) {
                    return;
                }
            }
        }
    }
#endif
    
    if (![onScreenControls handleTouchDownEvent:touches]) {
        // The three-finger keyboard gesture is handled by a tap recognizer. We
        // still forward the touches so the active touch handler gets a complete
        // begin/cancel sequence when that recognizer succeeds.
        [touchHandler touchesBegan:touches withEvent:event];
    }
}

#if !TARGET_OS_TV
- (UIView *)createKeyboardAccessoryView {
    UIVisualEffectView *accessory = [[UIVisualEffectView alloc]
        initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterialDark]];
    accessory.frame = CGRectMake(0, 0, self.bounds.size.width, 60.0);
    accessory.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    UIView *topSeparator = [[UIView alloc] initWithFrame:CGRectZero];
    topSeparator.translatesAutoresizingMaskIntoConstraints = NO;
    topSeparator.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.12];
    [accessory.contentView addSubview:topSeparator];

    MoonlightKeyboardAccessoryScrollView *scrollView = [[MoonlightKeyboardAccessoryScrollView alloc] initWithFrame:CGRectZero];
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    scrollView.showsHorizontalScrollIndicator = NO;
    scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    [accessory.contentView addSubview:scrollView];

    UIStackView *buttonStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    buttonStack.translatesAutoresizingMaskIntoConstraints = NO;
    buttonStack.axis = UILayoutConstraintAxisHorizontal;
    buttonStack.alignment = UIStackViewAlignmentCenter;
    buttonStack.distribution = UIStackViewDistributionFill;
    buttonStack.spacing = 8.0;
    [scrollView addSubview:buttonStack];
    scrollView.centeredContentView = buttonStack;

    NSArray<NSDictionary<NSString *, id> *> *buttonDescriptions = @[
        @{@"label": @"Dismiss keyboard", @"symbol": @"keyboard.chevron.compact.down", @"keyCode": @0x00, @"toggle": @NO},
        @{@"label": @"Esc", @"keyCode": @0x1B, @"toggle": @NO},
        @{@"label": @"Super", @"keyCode": @0x5B, @"toggle": @YES},
        @{@"label": @"Tab", @"keyCode": @0x09, @"toggle": @NO},
        @{@"label": @"Shift", @"keyCode": @0xA0, @"toggle": @YES},
        @{@"label": @"Ctrl", @"keyCode": @0xA2, @"toggle": @YES},
        @{@"label": @"Alt", @"keyCode": @0xA4, @"toggle": @YES},
        @{@"label": @"Del", @"keyCode": @0x2E, @"toggle": @NO},
    ];

    NSMutableArray<UIButton *> *buttons = [NSMutableArray arrayWithCapacity:buttonDescriptions.count];
    [buttonDescriptions enumerateObjectsUsingBlock:^(NSDictionary<NSString *, id> *description,
                                                      NSUInteger index,
                                                      BOOL *stop) {
        UIButton *button = [self createKeyboardAccessoryButtonWithLabel:description[@"label"]
                                                              symbolName:description[@"symbol"]
                                                                 keyCode:[description[@"keyCode"] unsignedShortValue]
                                                            isToggleable:[description[@"toggle"] boolValue]];
        [buttons addObject:button];
        [buttonStack addArrangedSubview:button];

        // Separate utility, navigation, and modifier keys without adding more
        // text or visual weight to this compact accessory.
        if (index == 0 || index == 3) {
            UIView *separator = [[UIView alloc] initWithFrame:CGRectZero];
            separator.translatesAutoresizingMaskIntoConstraints = NO;
            separator.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.13];
            separator.layer.cornerRadius = 0.5;
            [separator.widthAnchor constraintEqualToConstant:1.0].active = YES;
            [separator.heightAnchor constraintEqualToConstant:26.0].active = YES;
            [buttonStack addArrangedSubview:separator];
        }
    }];
    keyboardAccessoryButtons = [buttons copy];

    [NSLayoutConstraint activateConstraints:@[
        [topSeparator.leadingAnchor constraintEqualToAnchor:accessory.contentView.leadingAnchor],
        [topSeparator.trailingAnchor constraintEqualToAnchor:accessory.contentView.trailingAnchor],
        [topSeparator.topAnchor constraintEqualToAnchor:accessory.contentView.topAnchor],
        [topSeparator.heightAnchor constraintEqualToConstant:0.5],
        [scrollView.leadingAnchor constraintEqualToAnchor:accessory.contentView.safeAreaLayoutGuide.leadingAnchor],
        [scrollView.trailingAnchor constraintEqualToAnchor:accessory.contentView.safeAreaLayoutGuide.trailingAnchor],
        [scrollView.topAnchor constraintEqualToAnchor:accessory.contentView.topAnchor constant:4.0],
        [scrollView.bottomAnchor constraintEqualToAnchor:accessory.contentView.bottomAnchor constant:-4.0],
        [buttonStack.leadingAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.leadingAnchor constant:12.0],
        [buttonStack.trailingAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.trailingAnchor constant:-12.0],
        [buttonStack.centerYAnchor constraintEqualToAnchor:scrollView.frameLayoutGuide.centerYAnchor],
        [buttonStack.heightAnchor constraintEqualToConstant:42.0],
    ]];

    return accessory;
}

- (UIButton *)createKeyboardAccessoryButtonWithLabel:(NSString *)label
                                           symbolName:(NSString *)symbolName
                                              keyCode:(u_short)keyCode
                                         isToggleable:(BOOL)isToggleable {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.accessibilityLabel = label;
    button.accessibilityIdentifier = [NSString stringWithFormat:@"stream.keyboard.%@", label.lowercaseString];
    button.accessibilityHint = isToggleable ? @"Double tap to toggle this remote modifier" : @"Double tap to send this key to the remote computer";

    if (@available(iOS 15.0, *)) {
        UIButtonConfiguration *configuration = [UIButtonConfiguration filledButtonConfiguration];
        configuration.cornerStyle = UIButtonConfigurationCornerStyleMedium;
        configuration.contentInsets = NSDirectionalEdgeInsetsMake(5, 12, 5, 12);
        configuration.baseForegroundColor = UIColor.whiteColor;
        configuration.baseBackgroundColor = [UIColor colorWithRed:0.17 green:0.18 blue:0.22 alpha:0.96];
        configuration.background.strokeWidth = 1.0;
        configuration.background.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.12];
        configuration.preferredSymbolConfigurationForImage =
            [UIImageSymbolConfiguration configurationWithPointSize:17.0 weight:UIImageSymbolWeightSemibold];
        configuration.titleTextAttributesTransformer = ^NSDictionary<NSAttributedStringKey, id> *
            (NSDictionary<NSAttributedStringKey, id> *incomingAttributes) {
                NSMutableDictionary<NSAttributedStringKey, id> *attributes = [incomingAttributes mutableCopy];
                attributes[NSFontAttributeName] = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
                return attributes;
            };
        if (symbolName != nil) {
            configuration.image = [UIImage systemImageNamed:symbolName];
            if (configuration.image == nil) {
                configuration.image = [UIImage systemImageNamed:@"chevron.down"];
            }
        }
        else {
            configuration.title = label;
        }
        button.configuration = configuration;

        button.configurationUpdateHandler = ^(UIButton *updatedButton) {
            UIButtonConfiguration *updatedConfiguration = updatedButton.configuration;
            updatedConfiguration.baseForegroundColor = UIColor.whiteColor;
            UIColor *accentColor = [UIColor colorWithRed:0.55 green:0.48 blue:0.96 alpha:1.0];
            if (updatedButton.selected) {
                updatedConfiguration.baseBackgroundColor = [accentColor colorWithAlphaComponent:0.72];
                updatedConfiguration.background.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.28];
            }
            else if (updatedButton.highlighted) {
                updatedConfiguration.baseBackgroundColor = [UIColor colorWithRed:0.25 green:0.26 blue:0.31 alpha:0.98];
                updatedConfiguration.background.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.20];
            }
            else {
                updatedConfiguration.baseBackgroundColor = [UIColor colorWithRed:0.17 green:0.18 blue:0.22 alpha:0.96];
                updatedConfiguration.background.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.12];
            }
            updatedButton.configuration = updatedConfiguration;
        };
    }
    else {
        UIImage *image = nil;
        if (symbolName != nil) {
            if (@available(iOS 13.0, *)) {
                image = [UIImage systemImageNamed:symbolName];
            }
        }
        if (image != nil) {
            [button setImage:image forState:UIControlStateNormal];
        }
        else {
            [button setTitle:symbolName != nil ? @"Done" : label forState:UIControlStateNormal];
        }
        button.layer.cornerRadius = 10.0;
        button.layer.cornerCurve = kCACornerCurveContinuous;
        button.layer.borderWidth = 1.0;
        button.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.12].CGColor;
    }

    button.titleLabel.numberOfLines = 1;
    button.titleLabel.adjustsFontSizeToFitWidth = YES;
    button.titleLabel.minimumScaleFactor = 0.85;

    [button addTarget:self action:@selector(toolbarButtonClicked:) forControlEvents:UIControlEventTouchUpInside];
    objc_setAssociatedObject(button, &KeyboardButtonKeyCodeAssociation, @(keyCode), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(button, &KeyboardButtonToggleAssociation, @(isToggleable), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    [button.heightAnchor constraintEqualToConstant:42.0].active = YES;
    UIFont *titleFont = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
    CGFloat titleWidth = ceil([label sizeWithAttributes:@{NSFontAttributeName: titleFont}].width);
    CGFloat buttonWidth = symbolName != nil ? 48.0 : MAX(56.0, titleWidth + 24.0);
    [button.widthAnchor constraintEqualToConstant:buttonWidth].active = YES;
    [self updateKeyboardAccessoryButtonState:button];
    return button;
}

- (void)updateKeyboardAccessoryButtonState:(UIButton *)button {
    BOOL isToggleable = [objc_getAssociatedObject(button, &KeyboardButtonToggleAssociation) boolValue];
    button.accessibilityValue = isToggleable ? (button.selected ? @"On" : @"Off") : nil;
    if (button.selected) {
        button.accessibilityTraits |= UIAccessibilityTraitSelected;
    }
    else {
        button.accessibilityTraits &= ~UIAccessibilityTraitSelected;
    }
    if (@available(iOS 15.0, *)) {
        [button setNeedsUpdateConfiguration];
    }
    else {
        button.backgroundColor = button.selected
            ? [button.tintColor colorWithAlphaComponent:0.18]
            : UIColor.clearColor;
    }
}

- (void)keyboardToggleGestureRecognized:(UITapGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateRecognized) {
        return;
    }

    [self toggleKeyboard];
}

- (BOOL)accessibilityToggleKeyboard {
    [self toggleKeyboard];
    return YES;
}

- (void)toggleKeyboard {

    if (isInputingText || keyInputField.isFirstResponder) {
        Log(LOG_D, @"Closing the keyboard");
        [self dismissKeyboard];
    }
    else {
        Log(LOG_D, @"Opening the keyboard");
        [self showKeyboard];
    }
}

- (void)showKeyboard {
    [self resumeAfterInactivity];
    keyInputField.text = @"0";
    UITextRange *endRange = [keyInputField textRangeFromPosition:keyInputField.endOfDocument
                                                     toPosition:keyInputField.endOfDocument];
    keyInputField.selectedTextRange = endRange;

    isInputingText = [keyInputField becomeFirstResponder];
    if (isInputingText) {
        // Undo causes issues for our sentinel-based state management.
        [keyInputField.undoManager disableUndoRegistration];
    }
    else {
        [self activateHardwareInput];
    }
}

- (void)dismissKeyboard {
    isInputingText = NO;
    [self releaseAccessoryKeys];
    [keyInputField resignFirstResponder];
    [self activateHardwareInput];
}

- (void)releaseAccessoryKeys {
    for (NSNumber *keyCode in [keysDown allObjects]) {
        [KeyboardSupport sendKeyCode:keyCode.unsignedShortValue down:NO modifiers:0];
    }
    [self resetAccessoryKeyState];
}

- (void)resetAccessoryKeyState {
    for (UIButton *button in keyboardAccessoryButtons) {
        if (button.selected) {
            button.selected = NO;
            [self updateKeyboardAccessoryButtonState:button];
        }
    }
    [keysDown removeAllObjects];
}

- (void)toolbarButtonClicked:(UIButton *)sender {
    BOOL isToggleable = [objc_getAssociatedObject(sender, &KeyboardButtonToggleAssociation) boolValue];
    u_short keyCode = [objc_getAssociatedObject(sender, &KeyboardButtonKeyCodeAssociation) unsignedShortValue];
    if (keyCode == 0) {
        [self dismissKeyboard];
        return;
    }

    if (isToggleable) {
        sender.selected = !sender.selected;
        [self updateKeyboardAccessoryButtonState:sender];
        [KeyboardSupport sendKeyCode:keyCode down:sender.selected modifiers:0];
        if (sender.selected) {
            [keysDown addObject:@(keyCode)];
        }
        else {
            [keysDown removeObject:@(keyCode)];
        }
    }
    else {
        [KeyboardSupport sendKeyStroke:keyCode modifiers:0];
    }
}
#endif

- (BOOL)handleMouseButtonEvent:(int)buttonAction forTouches:(NSSet *)touches withEvent:(UIEvent *)event {
#if !TARGET_OS_TV
    if (@available(iOS 13.4, *)) {
        UITouch* touch = [touches anyObject];
        if (touch.type == UITouchTypeIndirectPointer) {
            UIEventButtonMask normalizedButtonMask;
            
            // iOS 14 includes the released button in the buttonMask for the release
            // event, while iOS 13 does not. Normalize that behavior here.
            if (@available(iOS 14.0, *)) {
                if (buttonAction == BUTTON_ACTION_RELEASE) {
                    normalizedButtonMask = lastMouseButtonMask & ~event.buttonMask;
                }
                else {
                    normalizedButtonMask = event.buttonMask;
                }
            }
            else {
                normalizedButtonMask = event.buttonMask;
            }
            
            UIEventButtonMask changedButtons = lastMouseButtonMask ^ normalizedButtonMask;
                        
            for (int i = BUTTON_LEFT; i <= BUTTON_X2; i++) {
                UIEventButtonMask buttonFlag;
                
                switch (i) {
                    // Right and Middle are reversed from what iOS uses
                    case BUTTON_RIGHT:
                        buttonFlag = UIEventButtonMaskForButtonNumber(2);
                        break;
                    case BUTTON_MIDDLE:
                        buttonFlag = UIEventButtonMaskForButtonNumber(3);
                        break;
                        
                    default:
                        buttonFlag = UIEventButtonMaskForButtonNumber(i);
                        break;
                }
                
                if (changedButtons & buttonFlag) {
                    MoonlightSendMouseButtonEvent(MoonlightMouseButtonSourceUIKitMouse, buttonAction, i);
                }
            }
            
            lastMouseButtonMask = normalizedButtonMask;
            return YES;
        }
    }
#endif
    
    return NO;
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event {
    if (atomic_load_explicit(&inputSuspended, memory_order_acquire)) {
        return;
    }
#if !TARGET_OS_TV
    if (@available(iOS 13.4, *)) {
        for (UITouch* touch in touches) {
            if (touch.type == UITouchTypePencil) {
                if ([self sendStylusEvent:touch]) {
                    return;
                }
            }
        }
        
        UITouch *touch = [touches anyObject];
        if (touch.type == UITouchTypeIndirectPointer) {
            if (MoonlightHasRecentGCMouseMotion()) {
                // Relative GCMouse motion is active for this device.
                return;
            }
            
            // We must handle this event to properly support
            // drags while the middle, X1, or X2 mouse buttons are
            // held down. For some reason, left and right buttons
            // don't require this, but we do it anyway for them too.
            // Cursor movement without a button held down is handled
            // in pointerInteraction:regionForRequest:defaultRegion.
            [self updateCursorLocation:[touch locationInView:self] isMouse:YES];
            return;
        }
    }
#endif
    
    hasUserInteracted = YES;
    
    if (![onScreenControls handleTouchMovedEvent:touches]) {
        [touchHandler touchesMoved:touches withEvent:event];
    }
}

- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    BOOL handled = NO;
    
    if (@available(iOS 13.4, tvOS 13.4, *)) {
        for (UIPress* press in presses) {
            // For now, we'll treated it as handled if we handle at least one of the
            // UIPress events inside the set.
            if ([KeyboardSupport sendKeyEventForPress:press down:YES]) {
                // This will prevent the legacy UITextField from receiving the event
                handled = YES;
            }
        }
    }
    
    if (!handled) {
        [super pressesBegan:presses withEvent:event];
    }
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    BOOL handled = NO;
    
    if (@available(iOS 13.4, tvOS 13.4, *)) {
        for (UIPress* press in presses) {
            // For now, we'll treated it as handled if we handle at least one of the
            // UIPress events inside the set.
            if ([KeyboardSupport sendKeyEventForPress:press down:NO]) {
                // This will prevent the legacy UITextField from receiving the event
                handled = YES;
            }
        }
    }
    
    if (!handled) {
        [super pressesEnded:presses withEvent:event];
    }
}

- (void)pressesCancelled:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    BOOL handled = NO;

    if (@available(iOS 13.4, tvOS 13.4, *)) {
        for (UIPress *press in presses) {
            if ([KeyboardSupport sendKeyEventForPress:press down:NO]) {
                handled = YES;
            }
        }
    }

    if (!handled) {
        [super pressesCancelled:presses withEvent:event];
    }
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event {
    if (atomic_load_explicit(&inputSuspended, memory_order_acquire)) {
        return;
    }
    if ([self handleMouseButtonEvent:BUTTON_ACTION_RELEASE
                          forTouches:touches
                           withEvent:event]) {
        // If it's a mouse event, we're done
        return;
    }
    
    Log(LOG_D, @"Touch up");
    
    hasUserInteracted = YES;
    
#if !TARGET_OS_TV
    if (@available(iOS 13.4, *)) {
        for (UITouch* touch in touches) {
            if (touch.type == UITouchTypePencil) {
                if ([self sendStylusEvent:touch]) {
                    return;
                }
            }
        }
    }
#endif
    
    if (![onScreenControls handleTouchUpEvent:touches]) {
        [touchHandler touchesEnded:touches withEvent:event];
    }
}

- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event {
    if (atomic_load_explicit(&inputSuspended, memory_order_acquire)) {
        return;
    }
    if (![onScreenControls handleTouchUpEvent:touches]) {
        [touchHandler touchesCancelled:touches withEvent:event];
    }
    [self handleMouseButtonEvent:BUTTON_ACTION_RELEASE
                      forTouches:touches
                       withEvent:event];
#if !TARGET_OS_TV
    if (@available(iOS 13.4, *)) {
        for (UITouch* touch in touches) {
            if (touch.type == UITouchTypePencil) {
                [self sendStylusEvent:touch];
            }
        }
    }
#endif
}

#if !TARGET_OS_TV
- (void) updateCursorLocation:(CGPoint)location isMouse:(BOOL)isMouse {
    if (atomic_load_explicit(&inputSuspended, memory_order_acquire)) {
        return;
    }
    CGPoint normalizedLocation = [self adjustCoordinatesForVideoArea:location];
    CGSize videoSize = [self getVideoAreaSize];
    
    // Send the mouse position relative to the video region if it has changed
    // if we're receiving coordinates from a real mouse.
    //
    // NB: It is important for functionality (not just optimization) to only
    // send it if the value has changed. We will receive one of these events
    // any time the user presses a modifier key, which can result in errant
    // mouse motion when using a Citrix X1 mouse.
    if (normalizedLocation.x != lastMouseX || normalizedLocation.y != lastMouseY || !isMouse) {
        if (lastMouseX != 0 || lastMouseY != 0 || !isMouse) {
            LiSendMousePositionEvent(normalizedLocation.x, normalizedLocation.y, videoSize.width, videoSize.height);
        }
        
        if (isMouse) {
            lastMouseX = normalizedLocation.x;
            lastMouseY = normalizedLocation.y;
        }
    }
}

- (UIPointerRegion *)pointerInteraction:(UIPointerInteraction *)interaction
                       regionForRequest:(UIPointerRegionRequest *)request
                          defaultRegion:(UIPointerRegion *)defaultRegion API_AVAILABLE(ios(13.4)) {
    if (MoonlightHasRecentGCMouseMotion()) {
        // Relative GCMouse motion is active for this device.
        return nil;
    }
    
    // This logic mimics what iOS does with AVLayerVideoGravityResizeAspect
    CGSize videoSize;
    CGPoint videoOrigin;
    if (self.bounds.size.width > self.bounds.size.height * streamAspectRatio) {
        videoSize = CGSizeMake(self.bounds.size.height * streamAspectRatio, self.bounds.size.height);
    } else {
        videoSize = CGSizeMake(self.bounds.size.width, self.bounds.size.width / streamAspectRatio);
    }
    videoOrigin = CGPointMake(self.bounds.size.width / 2 - videoSize.width / 2,
                              self.bounds.size.height / 2 - videoSize.height / 2);
    
    // Move the cursor on the host if no buttons are pressed.
    // Motion with buttons pressed in handled in touchesMoved:
    if (lastMouseButtonMask == 0) {
        [self updateCursorLocation:request.location isMouse:YES];
    }
    
    // The pointer interaction should cover the video region only
    return [UIPointerRegion regionWithRect:CGRectMake(videoOrigin.x, videoOrigin.y, videoSize.width, videoSize.height) identifier:nil];
}

- (UIPointerStyle *)pointerInteraction:(UIPointerInteraction *)interaction styleForRegion:(UIPointerRegion *)region  API_AVAILABLE(ios(13.4)) {
    // Always hide the mouse cursor over our stream view
    return [UIPointerStyle hiddenPointerStyle];
}

- (void)mouseHovered:(UIHoverGestureRecognizer *)gesture API_AVAILABLE(ios(13.4)) {
    if (atomic_load_explicit(&inputSuspended, memory_order_acquire)) {
        return;
    }
    if (MoonlightHasRecentGCMouseMotion()) {
        // Relative movement is already delivered by ControllerSupport.
        return;
    }

    if (gesture.state == UIGestureRecognizerStateBegan ||
        gesture.state == UIGestureRecognizerStateChanged) {
        [self updateCursorLocation:[gesture locationInView:self] isMouse:YES];
    }
}

- (void)mouseWheelMovedContinuous:(UIPanGestureRecognizer *)gesture {
    if (atomic_load_explicit(&inputSuspended, memory_order_acquire)) {
        lastScrollTranslation = CGPointZero;
        return;
    }
    switch (gesture.state) {
        case UIGestureRecognizerStateBegan:
        case UIGestureRecognizerStateChanged:
            break;
        
        case UIGestureRecognizerStateEnded:
        default:
            // Ignore recognition failure and other states
            lastScrollTranslation = CGPointMake(0, 0);
            return;
    }
    
    CGPoint currentScrollTranslation = [gesture translationInView:self];
    const short translationMultiplier = 120 * 20; // WHEEL_DELTA * 20
    
    {
        short translationDeltaY = ((currentScrollTranslation.y - lastScrollTranslation.y) / self.bounds.size.height) * translationMultiplier;
        if (translationDeltaY != 0) {
            LiSendHighResScrollEvent(translationDeltaY);
            lastScrollTranslation = currentScrollTranslation;
        }
    }

    {
        short translationDeltaX = ((currentScrollTranslation.x - lastScrollTranslation.x) / self.bounds.size.width) * translationMultiplier;
        if (translationDeltaX != 0) {
            // Direction is reversed from vertical scrolling
            LiSendHighResHScrollEvent(-translationDeltaX);
            lastScrollTranslation = currentScrollTranslation;
        }
    }
}

- (void)mouseWheelMovedDiscrete:(UIPanGestureRecognizer *)gesture {
    if (atomic_load_explicit(&inputSuspended, memory_order_acquire)) {
        lastScrollTranslation = CGPointZero;
        return;
    }
    switch (gesture.state) {
        case UIGestureRecognizerStateBegan:
        case UIGestureRecognizerStateChanged:
            break;
        
        case UIGestureRecognizerStateEnded:
        default:
            // Ignore recognition failure and other states
            lastScrollTranslation = CGPointMake(0, 0);
            return;
    }
    
    // Using velocityInView is 0 for discrete scroll events
    // when scrolling very slowly, but translationInView does work.
    CGPoint currentScrollTranslation = [gesture translationInView:self];
    
    {
        short translationDeltaY = currentScrollTranslation.y - lastScrollTranslation.y;
        if (translationDeltaY != 0) {
            LiSendScrollEvent(translationDeltaY > 0 ? 1 : -1);
        }
    }

    {
        short translationDeltaX = currentScrollTranslation.x - lastScrollTranslation.x;
        if (translationDeltaX != 0) {
            // Direction is reversed from vertical scrolling
            LiSendHScrollEvent(translationDeltaX < 0 ? 1 : -1);
        }
    }
    
    lastScrollTranslation = currentScrollTranslation;
}

#endif

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (@available(iOS 13.0, *)) {
        // Disable the 3 finger tap gestures that trigger the copy/paste/undo toolbar on iOS 13+
        return gestureRecognizer.name == nil || ![gestureRecognizer.name hasPrefix:@"kbProductivity."];
    }
    else {
        return YES;
    }
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
#if !TARGET_OS_TV
    if (gestureRecognizer == keyboardToggleGestureRecognizer) {
        CGRect safeBounds = UIEdgeInsetsInsetRect(self.bounds, self.safeAreaInsets);
        CGRect keyboardGestureArea = CGRectInset(safeBounds,
                                                 CGRectGetWidth(safeBounds) * 0.16,
                                                 CGRectGetHeight(safeBounds) * 0.12);
        return CGRectContainsPoint(keyboardGestureArea, [touch locationInView:self]);
    }
#endif
    return YES;
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    // This method is called when the "Return" key is pressed.
    [KeyboardSupport sendKeyStroke:0x0D modifiers:0];
    return NO;
}

- (void)textFieldDidEndEditing:(UITextField *)textField {
    isInputingText = NO;
#if !TARGET_OS_TV
    [self releaseAccessoryKeys];
#endif
    [self activateHardwareInput];
}

- (void)onKeyboardPressed:(UITextField *)textField {
    // Wait for IME/dictation composition to commit before consuming and
    // resetting the sentinel field. Resetting marked text mid-composition
    // breaks CJK, Arabic, dictation, and multi-scalar emoji input.
    if (textField.markedTextRange != nil) {
        return;
    }

    NSString* inputText = textField.text;

    // Reset text field back to known state
    textField.text = @"0";

    // Move the insertion point back to the end of the text box
    UITextRange *textRange = [textField textRangeFromPosition:textField.endOfDocument toPosition:textField.endOfDocument];
    [textField setSelectedTextRange:textRange];

    // If the text became empty, we know the user pressed the backspace key.
    if ([inputText isEqual:@""]) {
        [KeyboardSupport sendKeyStroke:0x08 modifiers:0];
        return;
    }
    if (inputText.length <= 1) {
        return;
    }

    NSString *committedText = [inputText substringFromIndex:1];
    if (committedText.length > 1) {
        // Paste, dictation, and multi-character IME commits should be sent as
        // one UTF-8 payload instead of building a 50 ms-per-character backlog.
        [KeyboardSupport sendUtf8Text:committedText];
        return;
    }

    // Character 0 is our sentinel value. Check the payload for characters
    // that cannot be represented as basic key events.
    for (NSUInteger i = 1; i < inputText.length; i++) {
        struct KeyEvent event = [KeyboardSupport translateKeyEvent:[inputText characterAtIndex:i]
                                                 withModifierFlags:0];
        if (event.keycode == 0) {
            [KeyboardSupport sendUtf8Text:committedText];
            return;
        }
    }

    for (NSUInteger i = 1; i < inputText.length; i++) {
        struct KeyEvent event = [KeyboardSupport translateKeyEvent:[inputText characterAtIndex:i]
                                                 withModifierFlags:0];
        [self sendLowLevelEvent:event];
    }
}

- (void)specialCharPressed:(UIKeyCommand *)cmd {
    struct KeyEvent event = [KeyboardSupport translateKeyEvent:0x20 withModifierFlags:[cmd modifierFlags]];
    event.keycode = [[dictCodes valueForKey:[cmd input]] intValue];
    [self sendLowLevelEvent:event];
}

- (void)keyPressed:(UIKeyCommand *)cmd {
    struct KeyEvent event = [KeyboardSupport translateKeyEvent:[[cmd input] characterAtIndex:0] withModifierFlags:[cmd modifierFlags]];
    [self sendLowLevelEvent:event];
}

- (void)sendLowLevelEvent:(struct KeyEvent)event {
    [KeyboardSupport sendTranslatedKeyEvent:event];
}

- (BOOL)canBecomeFirstResponder {
    return YES;
}

- (NSArray<UIKeyCommand *> *)keyCommands
{
    NSString *charset = @"qwertyuiopasdfghjklzxcvbnm1234567890\t§[]\\'\"/.,`<>-´ç+`¡'º;ñ= ";
    
    NSMutableArray<UIKeyCommand *> * commands = [NSMutableArray<UIKeyCommand *> array];
    dictCodes = [[NSDictionary alloc] initWithObjectsAndKeys: [NSNumber numberWithInt: 0x0d], @"\r", [NSNumber numberWithInt: 0x08], @"\b", [NSNumber numberWithInt: 0x1b], UIKeyInputEscape, [NSNumber numberWithInt: 0x28], UIKeyInputDownArrow, [NSNumber numberWithInt: 0x26], UIKeyInputUpArrow, [NSNumber numberWithInt: 0x25], UIKeyInputLeftArrow, [NSNumber numberWithInt: 0x27], UIKeyInputRightArrow, nil];
    
    [charset enumerateSubstringsInRange:NSMakeRange(0, charset.length)
                                options:NSStringEnumerationByComposedCharacterSequences
                             usingBlock:^(NSString *substring, NSRange substringRange, NSRange enclosingRange, BOOL *stop) {
                                 [commands addObject:[UIKeyCommand keyCommandWithInput:substring modifierFlags:0 action:@selector(keyPressed:)]];
                                 [commands addObject:[UIKeyCommand keyCommandWithInput:substring modifierFlags:UIKeyModifierShift action:@selector(keyPressed:)]];
                                 [commands addObject:[UIKeyCommand keyCommandWithInput:substring modifierFlags:UIKeyModifierControl action:@selector(keyPressed:)]];
                                 [commands addObject:[UIKeyCommand keyCommandWithInput:substring modifierFlags:UIKeyModifierAlternate action:@selector(keyPressed:)]];
                             }];
    
    for (NSString *c in [dictCodes keyEnumerator]) {
        [commands addObject:[UIKeyCommand keyCommandWithInput:c
                                                modifierFlags:0
                                                       action:@selector(specialCharPressed:)]];
        [commands addObject:[UIKeyCommand keyCommandWithInput:c
                                                modifierFlags:UIKeyModifierShift
                                                       action:@selector(specialCharPressed:)]];
        [commands addObject:[UIKeyCommand keyCommandWithInput:c
                                                modifierFlags:UIKeyModifierShift | UIKeyModifierAlternate
                                                       action:@selector(specialCharPressed:)]];
        [commands addObject:[UIKeyCommand keyCommandWithInput:c
                                                modifierFlags:UIKeyModifierShift | UIKeyModifierControl
                                                       action:@selector(specialCharPressed:)]];
        [commands addObject:[UIKeyCommand keyCommandWithInput:c
                                                modifierFlags:UIKeyModifierControl
                                                       action:@selector(specialCharPressed:)]];
        [commands addObject:[UIKeyCommand keyCommandWithInput:c
                                                modifierFlags:UIKeyModifierControl | UIKeyModifierAlternate
                                                       action:@selector(specialCharPressed:)]];
        [commands addObject:[UIKeyCommand keyCommandWithInput:c
                                                modifierFlags:UIKeyModifierAlternate
                                                       action:@selector(specialCharPressed:)]];
    }
    
    return commands;
}

- (void)connectedStateDidChangeWithIdentifier:(NSUUID * _Nonnull)identifier isConnected:(BOOL)isConnected {
    NSLog(@"Citrix X1 mouse state change: %@ -> %s",
          identifier, isConnected ? "connected" : "disconnected");
}

- (void)mouseDidMoveWithIdentifier:(NSUUID * _Nonnull)identifier deltaX:(int16_t)deltaX deltaY:(int16_t)deltaY {
    if (atomic_load(&inputSuspended)) {
        return;
    }
    accumulatedMouseDeltaX += deltaX / X1_MOUSE_SPEED_DIVISOR;
    accumulatedMouseDeltaY += deltaY / X1_MOUSE_SPEED_DIVISOR;
    
    short shortX = (short)accumulatedMouseDeltaX;
    short shortY = (short)accumulatedMouseDeltaY;
    
    if (shortX == 0 && shortY == 0) {
        return;
    }
    
    LiSendMouseMoveEvent(shortX, shortY);
    
    accumulatedMouseDeltaX -= shortX;
    accumulatedMouseDeltaY -= shortY;
}

- (int) buttonFromX1ButtonCode:(enum X1MouseButton)button {
    switch (button) {
        case X1MouseButtonLeft:
            return BUTTON_LEFT;
        case X1MouseButtonRight:
            return BUTTON_RIGHT;
        case X1MouseButtonMiddle:
            return BUTTON_MIDDLE;
        default:
            return -1;
    }
}

- (void)mouseDownWithIdentifier:(NSUUID * _Nonnull)identifier button:(enum X1MouseButton)button {
    if (atomic_load(&inputSuspended)) return;
    MoonlightSendMouseButtonEvent(MoonlightMouseButtonSourceX1Mouse, BUTTON_ACTION_PRESS, [self buttonFromX1ButtonCode:button]);
}

- (void)mouseUpWithIdentifier:(NSUUID * _Nonnull)identifier button:(enum X1MouseButton)button {
    if (atomic_load(&inputSuspended)) return;
    MoonlightSendMouseButtonEvent(MoonlightMouseButtonSourceX1Mouse, BUTTON_ACTION_RELEASE, [self buttonFromX1ButtonCode:button]);
}

- (void)wheelDidScrollWithIdentifier:(NSUUID * _Nonnull)identifier deltaZ:(int8_t)deltaZ {
    if (atomic_load(&inputSuspended)) return;
    LiSendScrollEvent(deltaZ);
}

#if !TARGET_OS_TV
- (BOOL)isMultipleTouchEnabled {
    return YES;
}
#endif

@end
