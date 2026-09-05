//
//  ControllerSupport.m
//  Moonlight
//
//  Created by Cameron Gutman on 10/20/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "ControllerSupport.h"
#import "Controller.h"

#import "OnScreenControls.h"

#import "DataManager.h"
#include "Limelight.h"

#include <math.h>
#include <stdatomic.h>

@import GameController;
@import AudioToolbox;
@import UIKit;

static const double MOUSE_SPEED_DIVISOR = 1.25;

// Keep this enabled in code until there is a user-facing preference for it.
static const BOOL CONTROLLER_POINTER_MODE_ENABLED_BY_DEFAULT = YES;
static NSString* const CONTROLLER_POINTER_MODE_PREFERENCE_KEY = @"ControllerPointerModeEnabled";
static NSString* const CONTROLLER_POINTER_MODE_STATE_KEY = @"ControllerPointerModeActiveForDesktop";
static const uint64_t CONTROLLER_POINTER_MODE_HOLD_TIME_MS = 750;
static const NSTimeInterval CONTROLLER_POINTER_MODE_REPORT_PERIOD = 1.0 / 60.0;
static const float CONTROLLER_POINTER_MODE_DEADZONE = 0.18f;
static const float CONTROLLER_POINTER_MODE_MAX_DELTA = 15.0f;
static const float CONTROLLER_POINTER_MODE_SMOOTHING = 0.42f;
static const short CONTROLLER_POINTER_MODE_SCROLL_DELTA = 120;

static BOOL MouseButtonOwners[MoonlightMouseButtonSourceCount][BUTTON_X2 + 1];
static NSUInteger MouseButtonOwnerCounts[BUTTON_X2 + 1];
static BOOL MouseInputSuspended;
static _Atomic(uint64_t) LastGCMouseMotionTimeMs;

BOOL MoonlightHasRecentGCMouseMotion(void) {
    uint64_t lastMotionTimeMs = atomic_load(&LastGCMouseMotionTimeMs);
    return lastMotionTimeMs != 0 && LiGetMillis() - lastMotionTimeMs < 500;
}

void MoonlightSendMouseButtonEvent(MoonlightMouseButtonSource source, int action, int button) {
    if (source >= MoonlightMouseButtonSourceCount || button < BUTTON_LEFT || button > BUTTON_X2) {
        return;
    }

    @synchronized([ControllerSupport class]) {
        BOOL pressed = action == BUTTON_ACTION_PRESS;
        if (MouseInputSuspended && pressed) {
            return;
        }
        if (pressed == MouseButtonOwners[source][button]) {
            return;
        }

        MouseButtonOwners[source][button] = pressed;
        if (pressed) {
            if (MouseButtonOwnerCounts[button]++ == 0) {
                LiSendMouseButtonEvent(BUTTON_ACTION_PRESS, button);
            }
        }
        else if (MouseButtonOwnerCounts[button] > 0 && --MouseButtonOwnerCounts[button] == 0) {
            LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, button);
        }
    }
}

void MoonlightReleaseMouseButtons(MoonlightMouseButtonSource source) {
    if (source >= MoonlightMouseButtonSourceCount) {
        return;
    }

    for (int button = BUTTON_LEFT; button <= BUTTON_X2; button++) {
        MoonlightSendMouseButtonEvent(source, BUTTON_ACTION_RELEASE, button);
    }
}

void MoonlightSetMouseInputSuspended(BOOL suspended) {
    @synchronized([ControllerSupport class]) {
        MouseInputSuspended = suspended;
        if (!suspended) {
            return;
        }

        for (int button = BUTTON_LEFT; button <= BUTTON_X2; button++) {
            if (MouseButtonOwnerCounts[button] > 0) {
                LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, button);
                MouseButtonOwnerCounts[button] = 0;
            }
            for (NSUInteger source = 0; source < MoonlightMouseButtonSourceCount; source++) {
                MouseButtonOwners[source][button] = NO;
            }
        }
    }
}

@interface ControllerSupport ()
- (void)updatePointerMouseButton:(int)mouseButton pressed:(BOOL)pressed;
- (void)autoEnableDesktopPointerForControllerIfNeeded:(Controller *)controller;
- (void)persistControllerPointerModePreference:(BOOL)enabled;
- (BOOL)controllerSupportsReliablePointerToggle:(GCController *)controller;
@end

@implementation ControllerSupport {
    id _controllerConnectObserver;
    id _controllerDisconnectObserver;
    id _mouseConnectObserver;
    id _mouseDisconnectObserver;
    id _keyboardConnectObserver;
    id _keyboardDisconnectObserver;
    id _applicationWillResignActiveObserver;
    id _applicationDidBecomeActiveObserver;
    
    NSLock *_controllerStreamLock;
    NSMutableDictionary *_controllers;
    __weak id<ControllerSupportDelegate> _delegate;
    
    float accumulatedDeltaX;
    float accumulatedDeltaY;
    float accumulatedScrollX;
    float accumulatedScrollY;
    
    __weak OnScreenControls *_osc;
    Controller *_oscController;
    
#define EMULATING_SELECT     0x1
#define EMULATING_SPECIAL    0x2
    
    bool _oscEnabled;
    char _controllerNumbers;
    bool _multiController;
    bool _swapABXYButtons;
    bool _controllerPointerModeAvailable;
    bool _autoEnableControllerPointerForDesktop;
    bool _connectionEstablished;
    _Atomic(bool) _controllerPointerModePreferredEnabled;
    bool _hasObservedGCMouseMotion;
    uint64_t _gcMouseMotionGeneration;
    bool _cleanupComplete;
    _Atomic(bool) _inputSuspended;
    NSUInteger _pointerMouseButtonRefCounts[BUTTON_X2 + 1];
}

// UPDATE_BUTTON_FLAG(controller, flag, pressed)
#define UPDATE_BUTTON_FLAG(controller, x, y) \
((y) ? [self setButtonFlag:controller flags:x] : [self clearButtonFlag:controller flags:x])

#define MAX_MAGNITUDE(x, y) (abs(x) > abs(y) ? (x) : (y))

-(void) rumble:(unsigned short)controllerNumber lowFreqMotor:(unsigned short)lowFreqMotor highFreqMotor:(unsigned short)highFreqMotor
{
    if (atomic_load_explicit(&_inputSuspended, memory_order_acquire)) {
        return;
    }
    Controller* controller;
    @synchronized(self) {
        controller = [_controllers objectForKey:[NSNumber numberWithInteger:controllerNumber]];
    }
    if (controller == nil && controllerNumber == 0 && _oscEnabled) {
        // TODO: Rumble emulation for OSC
    }
    if (controller == nil) {
        // No connected controller for this player
        return;
    }
    
    @synchronized(controller) {
        if (atomic_load_explicit(&_inputSuspended, memory_order_acquire)) {
            return;
        }
        [controller.lowFreqMotor setMotorAmplitude:lowFreqMotor];
        [controller.highFreqMotor setMotorAmplitude:highFreqMotor];
    }
}

-(void) rumbleTriggers:(uint16_t)controllerNumber leftTrigger:(uint16_t)leftTrigger rightTrigger:(uint16_t)rightTrigger
{
    if (atomic_load_explicit(&_inputSuspended, memory_order_acquire)) {
        return;
    }
    Controller* controller;
    @synchronized(self) {
        controller = [_controllers objectForKey:[NSNumber numberWithInteger:controllerNumber]];
    }
    if (controller == nil && controllerNumber == 0 && _oscEnabled) {
        // TODO: Trigger rumble emulation for OSC
    }
    if (controller == nil) {
        // No connected controller for this player
        return;
    }
    
    @synchronized(controller) {
        if (atomic_load_explicit(&_inputSuspended, memory_order_acquire)) {
            return;
        }
        [controller.leftTriggerMotor setMotorAmplitude:leftTrigger];
        [controller.rightTriggerMotor setMotorAmplitude:rightTrigger];
    }
}

- (void) setMotionEventState:(uint16_t)controllerNumber motionType:(uint8_t)motionType reportRateHz:(uint16_t)reportRateHz
{
    if (atomic_load_explicit(&_inputSuspended, memory_order_acquire)) {
        return;
    }
    if (@available(iOS 14.0, tvOS 14.0, *)) {
        Controller* controller;
        @synchronized(self) {
            if (atomic_load_explicit(&_inputSuspended, memory_order_acquire)) {
                return;
            }
            controller = [_controllers objectForKey:[NSNumber numberWithInteger:controllerNumber]];
        }
        if (controller == nil) {
            // No connected controller for this player
            return;
        }
        
        if (controller.gamepad.motion == nil) {
            // No motion supported for this controller
            return;
        }
        
        switch (motionType) {
            case LI_MOTION_TYPE_ACCEL:
                [controller.accelTimer invalidate];
                controller.accelTimer = nil;
                                                                
                if (reportRateHz && controller.gamepad.motion.hasGravityAndUserAcceleration) {
                    // Reset the last motion sample
                    GCAcceleration emptyAccelSample = {};
                    controller.lastAccelSample = emptyAccelSample;
                    
                    void (^scheduleAccelerometer)(void) = ^{
                        if (atomic_load_explicit(&self->_inputSuspended, memory_order_acquire)) {
                            return;
                        }
                        controller.accelTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 / reportRateHz repeats:YES block:^(NSTimer *timer) {
                            if (atomic_load(&self->_inputSuspended)) {
                                return;
                            }
                            // Don't send duplicate samples
                            GCAcceleration lastAccelSample = controller.lastAccelSample;
                            GCAcceleration accelSample = controller.gamepad.motion.acceleration;
                            if (memcmp(&accelSample, &lastAccelSample, sizeof(accelSample)) == 0) {
                                return;
                            }
                            controller.lastAccelSample = accelSample;
                            
                            // Convert g to m/s^2
                            LiSendControllerMotionEvent((uint8_t)controllerNumber,
                                                        LI_MOTION_TYPE_ACCEL,
                                                        accelSample.x * -9.80665f,
                                                        accelSample.y * -9.80665f,
                                                        accelSample.z * -9.80665f);
                        }];
                    };
                    if (NSThread.isMainThread) {
                        scheduleAccelerometer();
                    }
                    else {
                        dispatch_sync(dispatch_get_main_queue(), scheduleAccelerometer);
                    }
                }
                break;
                
            case LI_MOTION_TYPE_GYRO:
                [controller.gyroTimer invalidate];
                controller.gyroTimer = nil;
                
                if (reportRateHz && controller.gamepad.motion.hasRotationRate) {
                    // Reset the last motion sample
                    GCRotationRate emptyGyroSample = {};
                    controller.lastGyroSample = emptyGyroSample;
                    
                    void (^scheduleGyroscope)(void) = ^{
                        if (atomic_load_explicit(&self->_inputSuspended, memory_order_acquire)) {
                            return;
                        }
                        controller.gyroTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 / reportRateHz repeats:YES block:^(NSTimer *timer) {
                            if (atomic_load(&self->_inputSuspended)) {
                                return;
                            }
                            // Don't send duplicate samples
                            GCRotationRate lastGyroSample = controller.lastGyroSample;
                            GCRotationRate gyroSample = controller.gamepad.motion.rotationRate;
                            if (memcmp(&gyroSample, &lastGyroSample, sizeof(gyroSample)) == 0) {
                                return;
                            }
                            controller.lastGyroSample = gyroSample;
                            
                            // Convert rad/s to deg/s
                            LiSendControllerMotionEvent((uint8_t)controllerNumber,
                                                        LI_MOTION_TYPE_GYRO,
                                                        gyroSample.x * 57.2957795f,
                                                        gyroSample.z * 57.2957795f,
                                                        gyroSample.y * -57.2957795f);
                        }];
                    };
                    if (NSThread.isMainThread) {
                        scheduleGyroscope();
                    }
                    else {
                        dispatch_sync(dispatch_get_main_queue(), scheduleGyroscope);
                    }
                }
                break;
        }
        
        // Set the motion sensor state if they require manual activation
        if (controller.gamepad.motion.sensorsRequireManualActivation) {
            if (controller.gyroTimer || controller.accelTimer) {
                controller.gamepad.motion.sensorsActive = YES;
            }
            else {
                controller.gamepad.motion.sensorsActive = NO;
            }
        }
    }
}

-(void) setControllerLed:(uint16_t)controllerNumber r:(uint8_t)r g:(uint8_t)g b:(uint8_t)b {
    if (atomic_load_explicit(&_inputSuspended, memory_order_acquire)) {
        return;
    }
    if (@available(iOS 14.0, tvOS 14.0, *)) {
        Controller* controller;
        @synchronized(self) {
            if (atomic_load_explicit(&_inputSuspended, memory_order_acquire)) {
                return;
            }
            controller = [_controllers objectForKey:[NSNumber numberWithInteger:controllerNumber]];
        }
        if (controller == nil) {
            // No connected controller for this player
            return;
        }
        
        if (controller.gamepad.light == nil) {
            // No LED control supported for this controller
            return;
        }
        
        controller.gamepad.light.color = [[GCColor alloc] initWithRed:(r / 255.0f) green:(g / 255.0f) blue:(b / 255.0f)];
    }
}

-(void) updateLeftStick:(Controller*)controller x:(short)x y:(short)y
{
    @synchronized(controller) {
        controller.lastLeftStickX = x;
        controller.lastLeftStickY = y;
    }
}

-(void) updateRightStick:(Controller*)controller x:(short)x y:(short)y
{
    @synchronized(controller) {
        controller.lastRightStickX = x;
        controller.lastRightStickY = y;
    }
}

-(void) updateLeftTrigger:(Controller*)controller left:(unsigned char)left
{
    @synchronized(controller) {
        controller.lastLeftTrigger = left;
    }
}

-(void) updateRightTrigger:(Controller*)controller right:(unsigned char)right
{
    @synchronized(controller) {
        controller.lastRightTrigger = right;
    }
}

-(void) updateTriggers:(Controller*) controller left:(unsigned char)left right:(unsigned char)right
{
    @synchronized(controller) {
        controller.lastLeftTrigger = left;
        controller.lastRightTrigger = right;
    }
}

-(void) notifyControllerPointerModeChanged:(Controller*)controller enabled:(BOOL)enabled
{
    if (![_delegate respondsToSelector:@selector(controllerPointerModeChanged:playerIndex:)]) {
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        [self->_delegate controllerPointerModeChanged:enabled playerIndex:controller.playerIndex];
    });
}

-(void) persistControllerPointerModePreference:(BOOL)enabled
{
    atomic_store_explicit(&_controllerPointerModePreferredEnabled, enabled, memory_order_release);
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:CONTROLLER_POINTER_MODE_STATE_KEY];
}

-(void) sendNeutralControllerEvent:(Controller*)controller
{
    [_controllerStreamLock lock];
    @synchronized(controller) {
        if ([self reportControllerArrival:controller]) {
            LiSendMultiControllerEvent(_multiController ? controller.playerIndex : 0,
                                       [self getActiveGamepadMask],
                                       0, 0, 0, 0, 0, 0, 0);
        }
    }
    [_controllerStreamLock unlock];
}

-(void) releaseControllerPointerButtons:(Controller*)controller
{
    int buttonFlags;

    @synchronized(controller) {
        buttonFlags = controller.pointerModeLastButtonFlags;
        controller.pointerModeLastButtonFlags = 0;
    }

    if (buttonFlags & A_FLAG) {
        [self updatePointerMouseButton:BUTTON_LEFT pressed:NO];
    }
    if (buttonFlags & B_FLAG) {
        [self updatePointerMouseButton:BUTTON_RIGHT pressed:NO];
    }
    if (buttonFlags & X_FLAG) {
        [self updatePointerMouseButton:BUTTON_MIDDLE pressed:NO];
    }
    if (buttonFlags & LB_FLAG) {
        [self updatePointerMouseButton:BUTTON_X1 pressed:NO];
    }
    if (buttonFlags & RB_FLAG) {
        [self updatePointerMouseButton:BUTTON_X2 pressed:NO];
    }
}

-(void) updatePointerMouseButton:(int)mouseButton pressed:(BOOL)pressed
{
    if (mouseButton < BUTTON_LEFT || mouseButton > BUTTON_X2) {
        return;
    }

    @synchronized(self) {
        NSUInteger previousCount = _pointerMouseButtonRefCounts[mouseButton];
        if (pressed) {
            _pointerMouseButtonRefCounts[mouseButton] = previousCount + 1;
            if (previousCount == 0) {
                MoonlightSendMouseButtonEvent(MoonlightMouseButtonSourceControllerPointer, BUTTON_ACTION_PRESS, mouseButton);
            }
        }
        else if (previousCount > 0) {
            NSUInteger newCount = previousCount - 1;
            _pointerMouseButtonRefCounts[mouseButton] = newCount;
            if (newCount == 0) {
                MoonlightSendMouseButtonEvent(MoonlightMouseButtonSourceControllerPointer, BUTTON_ACTION_RELEASE, mouseButton);
            }
        }
    }
}

-(void) updateControllerPointerButtons:(Controller*)controller
{
    if (atomic_load(&_inputSuspended)) {
        return;
    }
    @synchronized(controller) {
        if (!controller.pointerModeEnabled) {
            return;
        }

        const int pointerButtonMask = A_FLAG | B_FLAG | X_FLAG | LB_FLAG | RB_FLAG |
                                      UP_FLAG | DOWN_FLAG | LEFT_FLAG | RIGHT_FLAG;
        int currentButtonFlags = controller.lastButtonFlags & pointerButtonMask;
        int changedButtonFlags = currentButtonFlags ^ controller.pointerModeLastButtonFlags;
        controller.pointerModeLastButtonFlags = currentButtonFlags;

#define SEND_POINTER_BUTTON_EDGE(flag, mouseButton) \
        if (changedButtonFlags & (flag)) { \
            [self updatePointerMouseButton:(mouseButton) pressed:(currentButtonFlags & (flag)) != 0]; \
        }

        SEND_POINTER_BUTTON_EDGE(A_FLAG, BUTTON_LEFT);
        SEND_POINTER_BUTTON_EDGE(B_FLAG, BUTTON_RIGHT);
        SEND_POINTER_BUTTON_EDGE(X_FLAG, BUTTON_MIDDLE);
        SEND_POINTER_BUTTON_EDGE(LB_FLAG, BUTTON_X1);
        SEND_POINTER_BUTTON_EDGE(RB_FLAG, BUTTON_X2);

#undef SEND_POINTER_BUTTON_EDGE

        // Scroll once on each d-pad press edge. This makes app and browser
        // navigation predictable and avoids key-repeat bursts from controllers.
        if ((changedButtonFlags & UP_FLAG) && (currentButtonFlags & UP_FLAG)) {
            LiSendHighResScrollEvent(CONTROLLER_POINTER_MODE_SCROLL_DELTA);
        }
        if ((changedButtonFlags & DOWN_FLAG) && (currentButtonFlags & DOWN_FLAG)) {
            LiSendHighResScrollEvent(-CONTROLLER_POINTER_MODE_SCROLL_DELTA);
        }
        if ((changedButtonFlags & RIGHT_FLAG) && (currentButtonFlags & RIGHT_FLAG)) {
            LiSendHighResHScrollEvent(CONTROLLER_POINTER_MODE_SCROLL_DELTA);
        }
        if ((changedButtonFlags & LEFT_FLAG) && (currentButtonFlags & LEFT_FLAG)) {
            LiSendHighResHScrollEvent(-CONTROLLER_POINTER_MODE_SCROLL_DELTA);
        }
    }
}

-(void) sendControllerPointerMotion:(Controller*)controller
{
    if (atomic_load(&_inputSuspended)) {
        return;
    }
    @synchronized(controller) {
        if (!controller.pointerModeEnabled) {
            return;
        }

        float leftX = controller.lastLeftStickX / 32766.0f;
        float leftY = controller.lastLeftStickY / 32766.0f;
        float rightX = controller.lastRightStickX / 32766.0f;
        float rightY = controller.lastRightStickY / 32766.0f;

        float leftMagnitudeSquared = leftX * leftX + leftY * leftY;
        float rightMagnitudeSquared = rightX * rightX + rightY * rightY;
        float x = leftMagnitudeSquared >= rightMagnitudeSquared ? leftX : rightX;
        float y = leftMagnitudeSquared >= rightMagnitudeSquared ? leftY : rightY;
        float magnitude = hypotf(x, y);

        if (magnitude <= CONTROLLER_POINTER_MODE_DEADZONE) {
            // Stop immediately in the deadzone so smoothing never produces
            // cursor drift after the stick returns to center.
            controller.pointerModeSmoothedDeltaX = 0;
            controller.pointerModeSmoothedDeltaY = 0;
            controller.pointerModeAccumulatedDeltaX = 0;
            controller.pointerModeAccumulatedDeltaY = 0;
            return;
        }

        // Remove the radial deadzone, then apply a symmetric cubic response.
        // This preserves fine control near center while still reaching desktop
        // traversal speed at the edge of either stick.
        float normalizedMagnitude = MIN((magnitude - CONTROLLER_POINTER_MODE_DEADZONE) /
                                        (1.0f - CONTROLLER_POINTER_MODE_DEADZONE), 1.0f);
        float cubicMagnitude = normalizedMagnitude * normalizedMagnitude * normalizedMagnitude;
        float scale = CONTROLLER_POINTER_MODE_MAX_DELTA * cubicMagnitude / magnitude;

        float targetDeltaX = x * scale;
        float targetDeltaY = -y * scale;
        controller.pointerModeSmoothedDeltaX +=
            (targetDeltaX - controller.pointerModeSmoothedDeltaX) * CONTROLLER_POINTER_MODE_SMOOTHING;
        controller.pointerModeSmoothedDeltaY +=
            (targetDeltaY - controller.pointerModeSmoothedDeltaY) * CONTROLLER_POINTER_MODE_SMOOTHING;

        controller.pointerModeAccumulatedDeltaX += controller.pointerModeSmoothedDeltaX;
        controller.pointerModeAccumulatedDeltaY += controller.pointerModeSmoothedDeltaY;

        short deltaX = (short)truncf(controller.pointerModeAccumulatedDeltaX);
        short deltaY = (short)truncf(controller.pointerModeAccumulatedDeltaY);

        if (deltaX != 0 || deltaY != 0) {
            LiSendMouseMoveEvent(deltaX, deltaY);
            controller.pointerModeAccumulatedDeltaX -= deltaX;
            controller.pointerModeAccumulatedDeltaY -= deltaY;
        }
    }
}

-(void) startControllerPointerTimer:(Controller*)controller
{
    void (^startTimer)(void) = ^{
        if (atomic_load_explicit(&self->_inputSuspended, memory_order_acquire)) {
            return;
        }
        @synchronized(controller) {
            if (!controller.pointerModeEnabled || controller.pointerModeTimer != nil) {
                return;
            }

            __weak ControllerSupport* weakSelf = self;
            __weak Controller* weakController = controller;
            controller.pointerModeTimer = [NSTimer timerWithTimeInterval:CONTROLLER_POINTER_MODE_REPORT_PERIOD
                                                                  repeats:YES
                                                                    block:^(NSTimer *timer) {
                ControllerSupport* strongSelf = weakSelf;
                Controller* strongController = weakController;
                if (strongSelf == nil || strongController == nil) {
                    [timer invalidate];
                    return;
                }

                [strongSelf sendControllerPointerMotion:strongController];
            }];
            [[NSRunLoop mainRunLoop] addTimer:controller.pointerModeTimer forMode:NSRunLoopCommonModes];
        }
    };

    if ([NSThread isMainThread]) {
        startTimer();
    }
    else {
        dispatch_async(dispatch_get_main_queue(), startTimer);
    }
}

-(void) stopControllerPointerTimer:(Controller*)controller
{
    NSTimer* timer;

    @synchronized(controller) {
        timer = controller.pointerModeTimer;
        controller.pointerModeTimer = nil;
    }

    // NSTimer permits invalidation from any thread. Clearing the property first
    // also prevents a queued main-thread start from surviving teardown.
    [timer invalidate];
}

-(void) setControllerPointerMode:(Controller*)controller enabled:(BOOL)enabled notifyDelegate:(BOOL)notifyDelegate
{
    if (enabled && atomic_load_explicit(&_inputSuspended, memory_order_acquire)) {
        return;
    }
    BOOL changed;

    @synchronized(controller) {
        changed = controller.pointerModeEnabled != enabled;
        controller.pointerModeEnabled = enabled;
        controller.pointerModeAccumulatedDeltaX = 0;
        controller.pointerModeAccumulatedDeltaY = 0;
        controller.pointerModeSmoothedDeltaX = 0;
        controller.pointerModeSmoothedDeltaY = 0;
    }

    if (enabled) {
        if (!changed) {
            return;
        }

        // Explicitly release the virtual gamepad before suppressing packets from
        // this controller, otherwise held controls can remain stuck on the host.
        [self sendNeutralControllerEvent:controller];
        [self startControllerPointerTimer:controller];
    }
    else {
        // Always perform teardown, even when state already says disabled. This
        // makes disconnect, cleanup, and app-background paths idempotent.
        [self stopControllerPointerTimer:controller];
        [self releaseControllerPointerButtons:controller];
    }

    if (changed && notifyDelegate) {
        Log(LOG_I, @"Controller %ld pointer mode %@",
            (long)controller.playerIndex,
            enabled ? @"enabled" : @"disabled");
        [self notifyControllerPointerModeChanged:controller enabled:enabled];
    }
}

-(void) autoEnableDesktopPointerForControllerIfNeeded:(Controller *)controller
{
    if (!_connectionEstablished ||
        !_autoEnableControllerPointerForDesktop ||
        !atomic_load_explicit(&_controllerPointerModePreferredEnabled, memory_order_acquire) ||
        atomic_load(&_inputSuspended) ||
        controller == nil) {
        return;
    }

    // Reliable Menu controllers use the hold gesture. Controllers represented
    // by iOS as a single-event MFi profile use controllerPausedHandler below as
    // an immediate Desktop-only toggle.
    if (controller.gamepad.extendedGamepad == nil) {
        return;
    }

    // Desktop is mouse-first, but only one controller should own the pointer.
    // Other connected controllers continue forwarding normal gamepad packets.
    for (Controller *existingController in [_controllers allValues]) {
        @synchronized(existingController) {
            if (existingController.pointerModeEnabled) {
                return;
            }
        }
    }

    [self setControllerPointerMode:controller enabled:YES notifyDelegate:YES];
}

-(void) resetControllerPointerMode:(Controller*)controller notifyDelegate:(BOOL)notifyDelegate
{
    BOOL releaseForwardedMenu;
    @synchronized(controller) {
        releaseForwardedMenu = controller.pointerModeMenuPressed || (controller.lastButtonFlags & PLAY_FLAG) != 0;
        controller.pointerModeMenuPressed = NO;
        controller.pointerModeToggleEligible = NO;
        controller.pointerModeMenuDownTimeMs = 0;
        controller.pointerModeHoldGeneration++;
        controller.pointerModeHoldActivated = NO;
        controller.pointerModeMenuPulseGeneration++;
        controller.pointerModeMenuPulseActive = NO;
    }

    if (releaseForwardedMenu) {
        [self clearButtonFlag:controller flags:PLAY_FLAG];
        [self sendNeutralControllerEvent:controller];
    }

    [self setControllerPointerMode:controller enabled:NO notifyDelegate:notifyDelegate];
}

-(BOOL) isControllerNeutralForPointerToggle:(Controller*)controller
{
    return controller.lastButtonFlags == 0 &&
           controller.lastLeftTrigger < 8 &&
           controller.lastRightTrigger < 8;
}

-(BOOL) updateControllerPointerModeToggle:(Controller*)controller menuPressed:(BOOL)menuPressed
{
    BOOL shouldToggle = NO;
    BOOL enablePointerMode = NO;
    BOOL forwardMenuDown = NO;
    BOOL forwardMenuUp = NO;
    BOOL emitShortMenuTap = NO;
    BOOL scheduleHoldActivation = NO;
    uint64_t holdGeneration = 0;

    @synchronized(controller) {
        if (menuPressed != controller.pointerModeMenuPressed) {
            controller.pointerModeMenuPressed = menuPressed;

            if (menuPressed) {
                if (controller.pointerModeMenuPulseActive) {
                    controller.pointerModeMenuPulseActive = NO;
                    controller.pointerModeMenuPulseGeneration++;
                }

                // Start/Menu is a toggle gesture, not a chord with the sticks.
                // Ignore stick position and allow the user to begin moving as
                // soon as the hold threshold enables pointer mode.
                controller.pointerModeToggleEligible = [self isControllerNeutralForPointerToggle:controller];
                controller.pointerModeMenuDownTimeMs = LiGetMillis();
                controller.pointerModeHoldActivated = NO;
                holdGeneration = ++controller.pointerModeHoldGeneration;
                scheduleHoldActivation = controller.pointerModeToggleEligible;
                forwardMenuDown = !controller.pointerModeToggleEligible;
            }
            else if (controller.pointerModeHoldActivated) {
                // The scheduled hold already toggled mode. Releasing Menu must
                // not emit a delayed Start press to the host.
                controller.pointerModeHoldActivated = NO;
                controller.pointerModeToggleEligible = NO;
                controller.pointerModeMenuDownTimeMs = 0;
                controller.pointerModeHoldGeneration++;
            }
            else {
                uint64_t heldTimeMs = LiGetMillis() - controller.pointerModeMenuDownTimeMs;
                shouldToggle = controller.pointerModeToggleEligible &&
                               heldTimeMs >= CONTROLLER_POINTER_MODE_HOLD_TIME_MS;
                enablePointerMode = !controller.pointerModeEnabled;
                emitShortMenuTap = controller.pointerModeToggleEligible && !shouldToggle;
                forwardMenuUp = !controller.pointerModeToggleEligible;
                controller.pointerModeToggleEligible = NO;
                controller.pointerModeMenuDownTimeMs = 0;
                controller.pointerModeHoldGeneration++;
            }
        }
        else if (menuPressed && controller.pointerModeToggleEligible &&
                 ![self isControllerNeutralForPointerToggle:controller]) {
            // A real digital/trigger chord cancels the pointer shortcut and
            // forwards Menu immediately. Stick movement alone never cancels.
            controller.pointerModeToggleEligible = NO;
            controller.pointerModeHoldGeneration++;
            forwardMenuDown = YES;
        }
    }

    if (scheduleHoldActivation) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(CONTROLLER_POINTER_MODE_HOLD_TIME_MS * NSEC_PER_MSEC)),
                       dispatch_get_main_queue(), ^{
            BOOL activate = NO;
            BOOL enabled = NO;
            @synchronized(controller) {
                if (controller.pointerModeMenuPressed &&
                    controller.pointerModeToggleEligible &&
                    !controller.pointerModeHoldActivated &&
                    controller.pointerModeHoldGeneration == holdGeneration) {
                    controller.pointerModeHoldActivated = YES;
                    controller.pointerModeToggleEligible = NO;
                    enabled = !controller.pointerModeEnabled;
                    activate = YES;
                }
            }
            if (activate) {
                [self persistControllerPointerModePreference:enabled];
                [self setControllerPointerMode:controller enabled:enabled notifyDelegate:YES];
            }
        });
    }

    if (forwardMenuDown) {
        [self setButtonFlag:controller flags:PLAY_FLAG];
    }
    if (emitShortMenuTap) {
        uint64_t pulseGeneration;
        @synchronized(controller) {
            pulseGeneration = ++controller.pointerModeMenuPulseGeneration;
            controller.pointerModeMenuPulseActive = YES;
        }
        [self setButtonFlag:controller flags:PLAY_FLAG];
        [self updateFinished:controller];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(75 * NSEC_PER_MSEC)),
                       dispatch_get_main_queue(), ^{
            @synchronized(controller) {
                if (!controller.pointerModeMenuPulseActive ||
                    controller.pointerModeMenuPulseGeneration != pulseGeneration) {
                    return;
                }
                controller.pointerModeMenuPulseActive = NO;
            }
            [self clearButtonFlag:controller flags:PLAY_FLAG];
            [self updateFinished:controller];
        });
    }
    if (forwardMenuUp) {
        [self clearButtonFlag:controller flags:PLAY_FLAG];
    }
    if (shouldToggle) {
        [self persistControllerPointerModePreference:enablePointerMode];
        [self setControllerPointerMode:controller enabled:enablePointerMode notifyDelegate:YES];
    }
    return emitShortMenuTap;
}
-(void) handleSpecialCombosReleased:(Controller*)controller releasedButtons:(int)releasedButtons
{
    if ((controller.emulatingButtonFlags & EMULATING_SELECT) && (releasedButtons & (LB_FLAG | PLAY_FLAG))) {
        controller.lastButtonFlags &= ~BACK_FLAG;
        controller.emulatingButtonFlags &= ~EMULATING_SELECT;
    }
    
    if (controller.emulatingButtonFlags & EMULATING_SPECIAL) {
        // If Select is emulated, we use RB+Start to emulate special, otherwise we use Start+Select
        if (controller.supportedEmulationFlags & EMULATING_SELECT) {
            if (releasedButtons & (RB_FLAG | PLAY_FLAG)) {
                controller.lastButtonFlags &= ~SPECIAL_FLAG;
                controller.emulatingButtonFlags &= ~EMULATING_SPECIAL;
            }
        }
        else {
            if (releasedButtons & (BACK_FLAG | PLAY_FLAG)) {
                controller.lastButtonFlags &= ~SPECIAL_FLAG;
                controller.emulatingButtonFlags &= ~EMULATING_SPECIAL;
            }
        }
    }
}

-(void) handleSpecialCombosPressed:(Controller*)controller pressedButtons:(int)pressedButtons
{
    // Special button combos for select and special
    if (controller.lastButtonFlags & PLAY_FLAG) {
        // If LB and start are down, trigger select
        if (controller.lastButtonFlags & LB_FLAG) {
            if (controller.supportedEmulationFlags & EMULATING_SELECT) {
                controller.lastButtonFlags |= BACK_FLAG;
                controller.lastButtonFlags &= ~(pressedButtons & (PLAY_FLAG | LB_FLAG));
                controller.emulatingButtonFlags |= EMULATING_SELECT;
            }
        }
        else if (controller.supportedEmulationFlags & EMULATING_SPECIAL) {
            // If Select is emulated too, use RB+Start to emulate special
            if (controller.supportedEmulationFlags & EMULATING_SELECT) {
                if (controller.lastButtonFlags & RB_FLAG) {
                    controller.lastButtonFlags |= SPECIAL_FLAG;
                    controller.lastButtonFlags &= ~(pressedButtons & (PLAY_FLAG | RB_FLAG));
                    controller.emulatingButtonFlags |= EMULATING_SPECIAL;
                }
            }
            else {
                // If Select is physical, use Start+Select to emulate special
                if (controller.lastButtonFlags & BACK_FLAG) {
                    controller.lastButtonFlags |= SPECIAL_FLAG;
                    controller.lastButtonFlags &= ~(pressedButtons & (PLAY_FLAG | BACK_FLAG));
                    controller.emulatingButtonFlags |= EMULATING_SPECIAL;
                }
            }
        }
    }
}

-(void) updateButtonFlags:(Controller*)controller flags:(int)flags
{
    @synchronized(controller) {
        controller.lastButtonFlags = flags;
        
        // This must be called before handleSpecialCombosPressed
        // because we clear the original button flags there
        int releasedButtons = (controller.lastButtonFlags ^ flags) & ~flags;
        int pressedButtons = (controller.lastButtonFlags ^ flags) & flags;
        
        [self handleSpecialCombosReleased:controller releasedButtons:releasedButtons];
        
        [self handleSpecialCombosPressed:controller pressedButtons:pressedButtons];
    }
}

-(void) setButtonFlag:(Controller*)controller flags:(int)flags
{
    @synchronized(controller) {
        controller.lastButtonFlags |= flags;
        [self handleSpecialCombosPressed:controller pressedButtons:flags];
    }
}

-(void) clearButtonFlag:(Controller*)controller flags:(int)flags
{
    @synchronized(controller) {
        controller.lastButtonFlags &= ~flags;
        [self handleSpecialCombosReleased:controller releasedButtons:flags];
    }
}

-(uint16_t) getActiveGamepadMask
{
    return (_multiController ? _controllerNumbers : 1) | (_oscEnabled ? 1 : 0);
}

-(void) updateFinished:(Controller*)controller
{
    BOOL exitRequested = NO;
    
    [_controllerStreamLock lock];
    @synchronized(controller) {
        // Handle Start+Select+L1+R1 gamepad quit combo
        if (controller.lastButtonFlags == (PLAY_FLAG | BACK_FLAG | LB_FLAG | RB_FLAG)) {
            controller.lastButtonFlags = 0;
            controller.pointerModeToggleEligible = NO;
            exitRequested = YES;
        }
        
        // Only send controller events if we successfully reported controller arrival
        if (!atomic_load(&_inputSuspended) && [self reportControllerArrival:controller] && !controller.pointerModeEnabled) {
            // Pointer mode suppresses packets only from the controller that owns
            // it. Other physical controllers and OSC input continue normally.
            uint32_t buttonFlags = controller.lastButtonFlags;
            uint8_t leftTrigger = controller.lastLeftTrigger;
            uint8_t rightTrigger = controller.lastRightTrigger;
            int16_t leftStickX = controller.lastLeftStickX;
            int16_t leftStickY = controller.lastLeftStickY;
            int16_t rightStickX = controller.lastRightStickX;
            int16_t rightStickY = controller.lastRightStickY;
            
            // If this is merged with another controller, combine the inputs
            if (controller.mergedWithController && !controller.mergedWithController.pointerModeEnabled) {
                buttonFlags |= controller.mergedWithController.lastButtonFlags;
                leftTrigger = MAX(leftTrigger, controller.mergedWithController.lastLeftTrigger);
                rightTrigger = MAX(rightTrigger, controller.mergedWithController.lastRightTrigger);
                leftStickX = MAX_MAGNITUDE(leftStickX, controller.mergedWithController.lastLeftStickX);
                leftStickY = MAX_MAGNITUDE(leftStickY, controller.mergedWithController.lastLeftStickY);
                rightStickX = MAX_MAGNITUDE(rightStickX, controller.mergedWithController.lastRightStickX);
                rightStickY = MAX_MAGNITUDE(rightStickY, controller.mergedWithController.lastRightStickY);
            }
            
            // Player 1 is always present for OSC
            LiSendMultiControllerEvent(_multiController ? controller.playerIndex : 0, [self getActiveGamepadMask],
                                       buttonFlags, leftTrigger, rightTrigger,
                                       leftStickX, leftStickY, rightStickX, rightStickY);
        }
    }
    [_controllerStreamLock unlock];
    
    if (exitRequested) {
        [self resetControllerPointerMode:controller notifyDelegate:NO];

        // Invoke the delegate callback on the main thread
        dispatch_async(dispatch_get_main_queue(), ^{
            [self->_delegate streamExitRequested];
        });
    }
}

+(BOOL) hasKeyboardOrMouse {
    if (@available(iOS 14.0, tvOS 14.0, *)) {
        return GCMouse.mice.count > 0 || GCKeyboard.coalescedKeyboard != nil;
    }
    else {
        return NO;
    }
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

-(void) unregisterControllerCallbacks:(GCController*) controller
{
    if (controller != NULL) {
        controller.controllerPausedHandler = NULL;
        
        if (controller.extendedGamepad != NULL) {
            // Re-enable system gestures on the gamepad buttons now
            if (@available(iOS 14.0, tvOS 14.0, *)) {
                for (GCControllerElement* element in controller.physicalInputProfile.allElements) {
                    element.preferredSystemGestureState = GCSystemGestureStateEnabled;
                }
            }
            
            controller.extendedGamepad.valueChangedHandler = NULL;
        }
    }
}

-(void) initializeControllerHaptics:(Controller*) controller
{
    controller.lowFreqMotor = [HapticContext createContextForLowFreqMotor:controller.gamepad];
    controller.highFreqMotor = [HapticContext createContextForHighFreqMotor:controller.gamepad];
    controller.leftTriggerMotor = [HapticContext createContextForLeftTrigger:controller.gamepad];
    controller.rightTriggerMotor = [HapticContext createContextForRightTrigger:controller.gamepad];
}

-(void) cleanupControllerHaptics:(Controller*) controller
{
    @synchronized(controller) {
        [controller.lowFreqMotor cleanup];
        [controller.highFreqMotor cleanup];
        [controller.leftTriggerMotor cleanup];
        [controller.rightTriggerMotor cleanup];
    }
}

-(void) cleanupControllerMotion:(Controller*) controller
{
    if (@available(iOS 14.0, tvOS 14.0, *)) {
        // Stop sensor sampling timers
        [controller.gyroTimer invalidate];
        [controller.accelTimer invalidate];
        
        // Disable motion sensors if they require manual activation
        if (controller.gamepad && controller.gamepad.motion && controller.gamepad.motion.sensorsRequireManualActivation) {
            controller.gamepad.motion.sensorsActive = NO;
        }
    }
}

-(void) initializeControllerBattery:(Controller*) controller
{
    if (@available(iOS 14.0, tvOS 14.0, *)) {
        if (controller.gamepad.battery) {
            // Poll for updated battery status every 30 seconds
            controller.batteryTimer = [NSTimer scheduledTimerWithTimeInterval:30 repeats:YES block:^(NSTimer *timer) {
                if (atomic_load_explicit(&self->_inputSuspended, memory_order_acquire)) {
                    return;
                }
                if (controller.lastBatteryState != controller.gamepad.battery.batteryState ||
                    controller.lastBatteryLevel != controller.gamepad.battery.batteryLevel) {
                    uint8_t batteryState;
                    
                    switch (controller.gamepad.battery.batteryState) {
                        case GCDeviceBatteryStateFull:
                            batteryState = LI_BATTERY_STATE_FULL;
                            break;
                        case GCDeviceBatteryStateCharging:
                            batteryState = LI_BATTERY_STATE_CHARGING;
                            break;
                        case GCDeviceBatteryStateDischarging:
                            batteryState = LI_BATTERY_STATE_DISCHARGING;
                            break;
                        case GCDeviceBatteryStateUnknown:
                        default:
                            batteryState = LI_BATTERY_STATE_UNKNOWN;
                            break;
                    }
                    
                    LiSendControllerBatteryEvent(controller.playerIndex, batteryState, (uint8_t)(controller.gamepad.battery.batteryLevel * 100));
                    
                    controller.lastBatteryState = controller.gamepad.battery.batteryState;
                    controller.lastBatteryLevel = controller.gamepad.battery.batteryLevel;
                }
            }];
            
            // Fire the timer immediately to send the initial battery state
            [controller.batteryTimer fire];
        }
    }
}

-(void) cleanupControllerBattery:(Controller*) controller
{
    if (@available(iOS 14.0, tvOS 14.0, *)) {
        [controller.batteryTimer invalidate];
    }
}

-(BOOL) reportControllerArrival:(Controller*) limeController
{
    // Only report arrival once
    if (limeController.reportedArrival) {
        return YES;
    }
    
    uint8_t type = LI_CTYPE_UNKNOWN;
    uint16_t capabilities = 0;
    uint32_t supportedButtonFlags = 0;
    
    GCController *controller = limeController.gamepad;
    if (controller) {
        // This is a physical controller with a corresponding GCController object
        
        // Start is always present
        supportedButtonFlags |= PLAY_FLAG;
        
        // Detect buttons present in the GCExtendedGamepad profile
        if (controller.extendedGamepad.dpad) {
            supportedButtonFlags |= UP_FLAG | DOWN_FLAG | LEFT_FLAG | RIGHT_FLAG;
        }
        if (controller.extendedGamepad.leftShoulder) {
            supportedButtonFlags |= LB_FLAG;
        }
        if (controller.extendedGamepad.rightShoulder) {
            supportedButtonFlags |= RB_FLAG;
        }
        if (@available(iOS 13.0, tvOS 13.0, *)) {
            if (controller.extendedGamepad.buttonOptions) {
                supportedButtonFlags |= BACK_FLAG;
            }
        }
        if (@available(iOS 14.0, tvOS 14.0, *)) {
            if (controller.extendedGamepad.buttonHome) {
                supportedButtonFlags |= SPECIAL_FLAG;
            }
        }
        if (controller.extendedGamepad.buttonA) {
            supportedButtonFlags |= A_FLAG;
        }
        if (controller.extendedGamepad.buttonB) {
            supportedButtonFlags |= B_FLAG;
        }
        if (controller.extendedGamepad.buttonX) {
            supportedButtonFlags |= X_FLAG;
        }
        if (controller.extendedGamepad.buttonY) {
            supportedButtonFlags |= Y_FLAG;
        }
        if (@available(iOS 12.1, tvOS 12.1, *)) {
            if (controller.extendedGamepad.leftThumbstickButton) {
                supportedButtonFlags |= LS_CLK_FLAG;
            }
            if (controller.extendedGamepad.rightThumbstickButton) {
                supportedButtonFlags |= RS_CLK_FLAG;
            }
        }
        
        if (@available(iOS 14.0, tvOS 14.0, *)) {
            // Xbox One/Series controller
            if (controller.physicalInputProfile.buttons[GCInputXboxPaddleOne]) {
                supportedButtonFlags |= PADDLE1_FLAG;
            }
            if (controller.physicalInputProfile.buttons[GCInputXboxPaddleTwo]) {
                supportedButtonFlags |= PADDLE2_FLAG;
            }
            if (controller.physicalInputProfile.buttons[GCInputXboxPaddleThree]) {
                supportedButtonFlags |= PADDLE3_FLAG;
            }
            if (controller.physicalInputProfile.buttons[GCInputXboxPaddleFour]) {
                supportedButtonFlags |= PADDLE4_FLAG;
            }
            if (@available(iOS 15.0, tvOS 15.0, *)) {
                if (controller.physicalInputProfile.buttons[GCInputButtonShare]) {
                    supportedButtonFlags |= MISC_FLAG;
                }
            }
            
            // DualShock/DualSense controller
            if (controller.physicalInputProfile.buttons[GCInputDualShockTouchpadButton]) {
                supportedButtonFlags |= TOUCHPAD_FLAG;
            }
            if (controller.physicalInputProfile.dpads[GCInputDualShockTouchpadOne]) {
                capabilities |= LI_CCAP_TOUCHPAD;
            }
            
            if ([controller.extendedGamepad isKindOfClass:[GCXboxGamepad class]]) {
                type = LI_CTYPE_XBOX;
            }
            else if ([controller.extendedGamepad isKindOfClass:[GCDualShockGamepad class]]) {
                type = LI_CTYPE_PS;
            }
            
            if (@available(iOS 14.5, tvOS 14.5, *)) {
                if ([controller.extendedGamepad isKindOfClass:[GCDualSenseGamepad class]]) {
                    type = LI_CTYPE_PS;
                }
            }
            
            // Detect supported haptics localities
            if (controller.haptics) {
                if ([controller.haptics.supportedLocalities containsObject:GCHapticsLocalityHandles]) {
                    capabilities |= LI_CCAP_RUMBLE;
                }
                if ([controller.haptics.supportedLocalities containsObject:GCHapticsLocalityTriggers]) {
                    capabilities |= LI_CCAP_TRIGGER_RUMBLE;
                }
            }
            
            // Detect supported motion sensors
            if (controller.motion) {
                if (controller.motion.hasGravityAndUserAcceleration) {
                    capabilities |= LI_CCAP_ACCEL;
                }
                if (controller.motion.hasRotationRate) {
                    capabilities |= LI_CCAP_GYRO;
                }
            }
            
            // Detect RGB LED support
            if (controller.light) {
                capabilities |= LI_CCAP_RGB_LED;
            }
            
            // Detect battery support
            if (controller.battery) {
                capabilities |= LI_CCAP_BATTERY_STATE;
            }
        }
        else {
            // This is a virtual controller corresponding to our OSC

            // TODO: Support various layouts and button labels on the OSC
            type = LI_CTYPE_XBOX;
            capabilities = 0;
            supportedButtonFlags =
                PLAY_FLAG | BACK_FLAG | UP_FLAG | DOWN_FLAG | LEFT_FLAG | RIGHT_FLAG |
                LB_FLAG | RB_FLAG | LS_CLK_FLAG | RS_CLK_FLAG | A_FLAG | B_FLAG | X_FLAG | Y_FLAG;
        }
    }

    // Report the new controller to the host
    // NB: This will fail if the connection hasn't been fully established yet
    // and we will try again later.
    if (LiSendControllerArrivalEvent(controller.playerIndex,
                                     [self getActiveGamepadMask],
                                     type,
                                     supportedButtonFlags,
                                     capabilities) != 0) {
        return NO;
    }
    
    // Begin polling for battery status
    [self initializeControllerBattery:limeController];
    
    // Remember that we've reported arrival already
    limeController.reportedArrival = YES;
    return YES;
}

-(void) handleControllerTouchpad:(Controller*)controller touch:(GCControllerDirectionPad*)touch index:(int)index
{
    controller_touch_context_t context = index == 0 ? controller.primaryTouch : controller.secondaryTouch;
    BOOL needsLift = index == 0 ? controller.primaryTouchNeedsLift : controller.secondaryTouchNeedsLift;

    if (atomic_load(&_inputSuspended)) {
        if (index == 0) {
            controller.primaryTouch = (controller_touch_context_t){ 0, 0 };
            controller.primaryTouchNeedsLift = touch.xAxis.value != 0 || touch.yAxis.value != 0;
        }
        else {
            controller.secondaryTouch = (controller_touch_context_t){ 0, 0 };
            controller.secondaryTouchNeedsLift = touch.xAxis.value != 0 || touch.yAxis.value != 0;
        }
        return;
    }

    if (needsLift) {
        if (!touch.xAxis.value && !touch.yAxis.value) {
            if (index == 0) {
                controller.primaryTouchNeedsLift = NO;
            }
            else {
                controller.secondaryTouchNeedsLift = NO;
            }
        }
        return;
    }
    
    // This magic is courtesy of SDL
    float normalizedX = (1.0f + touch.xAxis.value) * 0.5f;
    float normalizedY = 1.0f - (1.0f + touch.yAxis.value) * 0.5f;
    
    // If we went from a touch to no touch, generate a touch up event
    if ((context.lastX || context.lastY) && (!touch.xAxis.value && !touch.yAxis.value)) {
        LiSendControllerTouchEvent(controller.playerIndex, LI_TOUCH_EVENT_UP, index, normalizedX, normalizedY, 1.0f);
    }
    else if (touch.xAxis.value || touch.yAxis.value) {
        // If we went from no touch to a touch, generate a touch down event
        if (!context.lastX && !context.lastY) {
            LiSendControllerTouchEvent(controller.playerIndex, LI_TOUCH_EVENT_DOWN, index, normalizedX, normalizedY, 1.0f);
        }
        else if (context.lastX != touch.xAxis.value || context.lastY != touch.yAxis.value) {
            // Otherwise it's just a move
            LiSendControllerTouchEvent(controller.playerIndex, LI_TOUCH_EVENT_MOVE, index, normalizedX, normalizedY, 1.0f);
        }
    }
    
    // We have to assign the whole struct because this is a property rather than a standard
    // field that we could modify through a pointer.
    if (index == 0) {
        controller.primaryTouch = (controller_touch_context_t) {
            touch.xAxis.value,
            touch.yAxis.value
        };
    }
    else {
        controller.secondaryTouch = (controller_touch_context_t) {
            touch.xAxis.value,
            touch.yAxis.value
        };
    }
}

-(void) releaseControllerTouchpadTouches:(Controller*)controller
{
    controller_touch_context_t primary;
    controller_touch_context_t secondary;
    @synchronized(controller) {
        primary = controller.primaryTouch;
        secondary = controller.secondaryTouch;
        controller.primaryTouch = (controller_touch_context_t){ 0, 0 };
        controller.secondaryTouch = (controller_touch_context_t){ 0, 0 };
        controller.primaryTouchNeedsLift = primary.lastX != 0 || primary.lastY != 0;
        controller.secondaryTouchNeedsLift = secondary.lastX != 0 || secondary.lastY != 0;
    }

    controller_touch_context_t touches[] = { primary, secondary };
    for (int index = 0; index < 2; index++) {
        if (touches[index].lastX || touches[index].lastY) {
            float normalizedX = (1.0f + touches[index].lastX) * 0.5f;
            float normalizedY = 1.0f - (1.0f + touches[index].lastY) * 0.5f;
            LiSendControllerTouchEvent(controller.playerIndex,
                                       LI_TOUCH_EVENT_UP,
                                       index,
                                       normalizedX,
                                       normalizedY,
                                       1.0f);
        }
    }
}

-(BOOL) controllerSupportsReliablePointerToggle:(GCController *)controller
{
    if (@available(iOS 13.0, tvOS 13.0, *)) {
        GCExtendedGamepad *gamepad = controller.extendedGamepad;
        if (gamepad == nil || gamepad.buttonMenu == nil) {
            return NO;
        }
        if (gamepad.buttonOptions != nil) {
            return YES;
        }

        // Some modern Xbox/PlayStation controllers expose a reliable Menu
        // down/up input through the simulator even when Options is omitted.
        NSString *identity = [NSString stringWithFormat:@"%@ %@",
                              controller.vendorName ?: @"",
                              controller.productCategory ?: @""].lowercaseString;
        return [identity containsString:@"xbox"] ||
               [identity containsString:@"playstation"] ||
               [identity containsString:@"dualshock"] ||
               [identity containsString:@"dualsense"];
    }
    return NO;
}

-(void) registerControllerCallbacks:(GCController*) controller
{
    if (controller != NULL) {
        // iOS 13 allows the Start button to behave like a normal button, however
        // older MFi controllers can send an instant down+up event for the start button
        // which means the button will not be down long enough to register on the PC.
        // To work around this issue, use the old controllerPausedHandler if the controller
        // doesn't have a Select button (which indicates it probably doesn't have a proper
        // Start button either).
        BOOL reliablePointerToggle = [self controllerSupportsReliablePointerToggle:controller];
        BOOL usePausedHandlerFallback = !reliablePointerToggle;
        Log(LOG_I, @"Controller profile: %@ (%@), Menu: %d, Options: %d, hold toggle: %d",
            controller.vendorName ?: @"Unknown",
            controller.productCategory ?: @"Unknown",
            controller.extendedGamepad.buttonMenu != nil,
            controller.extendedGamepad.buttonOptions != nil,
            reliablePointerToggle);
        
        if (usePausedHandlerFallback) {
            controller.controllerPausedHandler = ^(GCController *controller) {
                Controller* limeController = [self->_controllers objectForKey:[NSNumber numberWithInteger:controller.playerIndex]];
                if (limeController == nil || limeController.gamepad != controller) {
                    return;
                }

                if (self->_autoEnableControllerPointerForDesktop &&
                    self->_connectionEstablished &&
                    !atomic_load(&self->_inputSuspended)) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (atomic_load_explicit(&self->_inputSuspended, memory_order_acquire)) {
                            return;
                        }
                        Controller *currentController =
                            [self->_controllers objectForKey:@(limeController.playerIndex)];
                        if (currentController != limeController || limeController.gamepad != controller) {
                            return;
                        }
                        BOOL enablePointerMode;
                        @synchronized(limeController) {
                            enablePointerMode = !limeController.pointerModeEnabled;
                        }
                        [self persistControllerPointerModePreference:enablePointerMode];
                        [self setControllerPointerMode:limeController
                                               enabled:enablePointerMode
                                        notifyDelegate:YES];
                    });
                    return;
                }
                
                // Get off the main thread
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
                    [self setButtonFlag:limeController flags:PLAY_FLAG];
                    [self updateFinished:limeController];
                    
                    // Pause for 100 ms
                    usleep(100 * 1000);
                    
                    [self clearButtonFlag:limeController flags:PLAY_FLAG];
                    [self updateFinished:limeController];
                });
            };
        }
        
        if (controller.extendedGamepad != NULL) {
            // Disable system gestures on the gamepad to avoid interfering
            // with in-game controller actions
            if (@available(iOS 14.0, tvOS 14.0, *)) {
                for (GCControllerElement* element in controller.physicalInputProfile.allElements) {
                    element.preferredSystemGestureState = GCSystemGestureStateDisabled;
                }
            }
            
            controller.extendedGamepad.valueChangedHandler = ^(GCExtendedGamepad *gamepad, GCControllerElement *element) {
                Controller* limeController = [self->_controllers objectForKey:[NSNumber numberWithInteger:gamepad.controller.playerIndex]];
                if (limeController == nil || limeController.gamepad != gamepad.controller) {
                    return;
                }
                short leftStickX, leftStickY;
                short rightStickX, rightStickY;
                unsigned char leftTrigger, rightTrigger;
                BOOL canTogglePointerMode = NO;
                BOOL menuPressed = NO;
                BOOL menuPulseDeferred = NO;
                
                if (self->_swapABXYButtons) {
                    UPDATE_BUTTON_FLAG(limeController, B_FLAG, gamepad.buttonA.pressed);
                    UPDATE_BUTTON_FLAG(limeController, A_FLAG, gamepad.buttonB.pressed);
                    UPDATE_BUTTON_FLAG(limeController, Y_FLAG, gamepad.buttonX.pressed);
                    UPDATE_BUTTON_FLAG(limeController, X_FLAG, gamepad.buttonY.pressed);
                }
                else {
                    UPDATE_BUTTON_FLAG(limeController, A_FLAG, gamepad.buttonA.pressed);
                    UPDATE_BUTTON_FLAG(limeController, B_FLAG, gamepad.buttonB.pressed);
                    UPDATE_BUTTON_FLAG(limeController, X_FLAG, gamepad.buttonX.pressed);
                    UPDATE_BUTTON_FLAG(limeController, Y_FLAG, gamepad.buttonY.pressed);
                }
                
                UPDATE_BUTTON_FLAG(limeController, UP_FLAG, gamepad.dpad.up.pressed);
                UPDATE_BUTTON_FLAG(limeController, DOWN_FLAG, gamepad.dpad.down.pressed);
                UPDATE_BUTTON_FLAG(limeController, LEFT_FLAG, gamepad.dpad.left.pressed);
                UPDATE_BUTTON_FLAG(limeController, RIGHT_FLAG, gamepad.dpad.right.pressed);
                
                UPDATE_BUTTON_FLAG(limeController, LB_FLAG, gamepad.leftShoulder.pressed);
                UPDATE_BUTTON_FLAG(limeController, RB_FLAG, gamepad.rightShoulder.pressed);
                
                // Yay, iOS 12.1 now supports analog stick buttons
                if (@available(iOS 12.1, tvOS 12.1, *)) {
                    if (gamepad.leftThumbstickButton != nil) {
                        UPDATE_BUTTON_FLAG(limeController, LS_CLK_FLAG, gamepad.leftThumbstickButton.pressed);
                    }
                    if (gamepad.rightThumbstickButton != nil) {
                        UPDATE_BUTTON_FLAG(limeController, RS_CLK_FLAG, gamepad.rightThumbstickButton.pressed);
                    }
                }
                
                if (@available(iOS 13.0, tvOS 13.0, *)) {
                    // Options/Select is independent from Start/Menu.
                    if (gamepad.buttonOptions != nil) {
                        UPDATE_BUTTON_FLAG(limeController, BACK_FLAG, gamepad.buttonOptions.pressed);
                    }

                    // Single-event MFi profiles use controllerPausedHandler
                    // because they don't provide a reliable Menu down/up pair.
                    if (!usePausedHandlerFallback) {
                        if (self->_controllerPointerModeAvailable) {
                            canTogglePointerMode = YES;
                            menuPressed = gamepad.buttonMenu.pressed;
                        }
                        else {
                            UPDATE_BUTTON_FLAG(limeController, PLAY_FLAG, gamepad.buttonMenu.pressed);
                        }
                    }
                }
                
                if (@available(iOS 14.0, tvOS 14.0, *)) {
                    // Home/Guide button is optional (only present on Xbox One S and PS4 gamepads)
                    if (gamepad.buttonHome != nil) {
                        UPDATE_BUTTON_FLAG(limeController, SPECIAL_FLAG, gamepad.buttonHome.pressed);
                    }
                    
                    // Xbox One/Series controllers
                    if (gamepad.controller.physicalInputProfile.buttons[GCInputXboxPaddleOne]) {
                        UPDATE_BUTTON_FLAG(limeController, PADDLE1_FLAG, gamepad.controller.physicalInputProfile.buttons[GCInputXboxPaddleOne].pressed);
                    }
                    if (gamepad.controller.physicalInputProfile.buttons[GCInputXboxPaddleTwo]) {
                        UPDATE_BUTTON_FLAG(limeController, PADDLE2_FLAG, gamepad.controller.physicalInputProfile.buttons[GCInputXboxPaddleTwo].pressed);
                    }
                    if (gamepad.controller.physicalInputProfile.buttons[GCInputXboxPaddleThree]) {
                        UPDATE_BUTTON_FLAG(limeController, PADDLE3_FLAG, gamepad.controller.physicalInputProfile.buttons[GCInputXboxPaddleThree].pressed);
                    }
                    if (gamepad.controller.physicalInputProfile.buttons[GCInputXboxPaddleFour]) {
                        UPDATE_BUTTON_FLAG(limeController, PADDLE4_FLAG, gamepad.controller.physicalInputProfile.buttons[GCInputXboxPaddleFour].pressed);
                    }
                    if (@available(iOS 15.0, tvOS 15.0, *)) {
                        if (gamepad.controller.physicalInputProfile.buttons[GCInputButtonShare]) {
                            UPDATE_BUTTON_FLAG(limeController, MISC_FLAG, gamepad.controller.physicalInputProfile.buttons[GCInputButtonShare].pressed);
                        }
                    }
                    
                    // DualShock/DualSense controllers
                    if (gamepad.controller.physicalInputProfile.buttons[GCInputDualShockTouchpadButton]) {
                        UPDATE_BUTTON_FLAG(limeController, TOUCHPAD_FLAG, gamepad.controller.physicalInputProfile.buttons[GCInputDualShockTouchpadButton].pressed);
                    }
                    if (gamepad.controller.physicalInputProfile.dpads[GCInputDualShockTouchpadOne]) {
                        [self handleControllerTouchpad:limeController
                                                 touch:gamepad.controller.physicalInputProfile.dpads[GCInputDualShockTouchpadOne]
                                                 index:0];
                    }
                    if (gamepad.controller.physicalInputProfile.dpads[GCInputDualShockTouchpadTwo]) {
                        [self handleControllerTouchpad:limeController
                                                 touch:gamepad.controller.physicalInputProfile.dpads[GCInputDualShockTouchpadTwo]
                                                 index:1];
                    }
                }
                
                leftStickX = gamepad.leftThumbstick.xAxis.value * 0x7FFE;
                leftStickY = gamepad.leftThumbstick.yAxis.value * 0x7FFE;
                
                rightStickX = gamepad.rightThumbstick.xAxis.value * 0x7FFE;
                rightStickY = gamepad.rightThumbstick.yAxis.value * 0x7FFE;
                
                leftTrigger = gamepad.leftTrigger.value * 0xFF;
                rightTrigger = gamepad.rightTrigger.value * 0xFF;
                
                [self updateLeftStick:limeController x:leftStickX y:leftStickY];
                [self updateRightStick:limeController x:rightStickX y:rightStickY];
                [self updateTriggers:limeController left:leftTrigger right:rightTrigger];

                if (canTogglePointerMode && !atomic_load(&self->_inputSuspended)) {
                    menuPulseDeferred = [self updateControllerPointerModeToggle:limeController menuPressed:menuPressed];
                }

                if (!menuPulseDeferred) {
                    [self updateFinished:limeController];
                }
                [self updateControllerPointerButtons:limeController];
            };
        }
    } else {
        Log(LOG_W, @"Tried to register controller callbacks on NULL controller");
    }
}

-(void) unregisterMouseCallbacks:(GCMouse*)mouse API_AVAILABLE(ios(14.0)) {
    mouse.mouseInput.mouseMovedHandler = nil;
    
    mouse.mouseInput.leftButton.pressedChangedHandler = nil;
    mouse.mouseInput.middleButton.pressedChangedHandler = nil;
    mouse.mouseInput.rightButton.pressedChangedHandler = nil;
    
    for (GCControllerButtonInput* auxButton in mouse.mouseInput.auxiliaryButtons) {
        auxButton.pressedChangedHandler = nil;
    }
    MoonlightReleaseMouseButtons(MoonlightMouseButtonSourcePhysicalMouse);
    @synchronized(self) {
        _hasObservedGCMouseMotion = false;
        _gcMouseMotionGeneration++;
    }
    atomic_store(&LastGCMouseMotionTimeMs, 0);
    
#if TARGET_OS_TV
    mouse.mouseInput.scroll.xAxis.valueChangedHandler = nil;
    mouse.mouseInput.scroll.yAxis.valueChangedHandler = nil;
#endif
}

-(void) registerMouseCallbacks:(GCMouse*) mouse API_AVAILABLE(ios(14.0)) {
    mouse.mouseInput.mouseMovedHandler = ^(GCMouseInput * _Nonnull mouse, float deltaX, float deltaY) {
        if (atomic_load(&self->_inputSuspended)) {
            return;
        }
        atomic_store(&LastGCMouseMotionTimeMs, LiGetMillis());
        BOOL notifyPointerLock = NO;
        uint64_t motionGeneration;
        @synchronized(self) {
            notifyPointerLock = !self->_hasObservedGCMouseMotion;
            self->_hasObservedGCMouseMotion = true;
            motionGeneration = ++self->_gcMouseMotionGeneration;
        }
        if (notifyPointerLock) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self->_delegate mousePresenceChanged];
            });
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(550 * NSEC_PER_MSEC)),
                       dispatch_get_main_queue(), ^{
            @synchronized(self) {
                if (self->_gcMouseMotionGeneration != motionGeneration ||
                    MoonlightHasRecentGCMouseMotion()) {
                    return;
                }
                self->_hasObservedGCMouseMotion = false;
            }
            [self->_delegate mousePresenceChanged];
        });
        self->accumulatedDeltaX += deltaX / MOUSE_SPEED_DIVISOR;
        self->accumulatedDeltaY += -deltaY / MOUSE_SPEED_DIVISOR;
        
        short truncatedDeltaX = (short)self->accumulatedDeltaX;
        short truncatedDeltaY = (short)self->accumulatedDeltaY;
        
        if (truncatedDeltaX != 0 || truncatedDeltaY != 0) {
            LiSendMouseMoveEvent(truncatedDeltaX, truncatedDeltaY);
            
            self->accumulatedDeltaX -= truncatedDeltaX;
            self->accumulatedDeltaY -= truncatedDeltaY;
        }
    };
    
    mouse.mouseInput.leftButton.pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
        if (atomic_load(&self->_inputSuspended)) return;
        MoonlightSendMouseButtonEvent(MoonlightMouseButtonSourcePhysicalMouse, pressed ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE, BUTTON_LEFT);
    };
    mouse.mouseInput.middleButton.pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
        if (atomic_load(&self->_inputSuspended)) return;
        MoonlightSendMouseButtonEvent(MoonlightMouseButtonSourcePhysicalMouse, pressed ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE, BUTTON_MIDDLE);
    };
    mouse.mouseInput.rightButton.pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
        if (atomic_load(&self->_inputSuspended)) return;
        MoonlightSendMouseButtonEvent(MoonlightMouseButtonSourcePhysicalMouse, pressed ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE, BUTTON_RIGHT);
    };
    
    if (mouse.mouseInput.auxiliaryButtons != nil) {
        if (mouse.mouseInput.auxiliaryButtons.count >= 1) {
            mouse.mouseInput.auxiliaryButtons[0].pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
                if (atomic_load(&self->_inputSuspended)) return;
                MoonlightSendMouseButtonEvent(MoonlightMouseButtonSourcePhysicalMouse, pressed ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE, BUTTON_X1);
            };
        }
        if (mouse.mouseInput.auxiliaryButtons.count >= 2) {
            mouse.mouseInput.auxiliaryButtons[1].pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
                if (atomic_load(&self->_inputSuspended)) return;
                MoonlightSendMouseButtonEvent(MoonlightMouseButtonSourcePhysicalMouse, pressed ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE, BUTTON_X2);
            };
        }
    }
    
    // We use UIPanGestureRecognizer on iPadOS because it allows us to distinguish
    // between discrete and continuous scroll events and also works around a bug
    // in iPadOS 15 where discrete scroll events are dropped. tvOS only supports
    // GCMouse for mice, so we will have to just use it and hope for the best.
#if TARGET_OS_TV
    mouse.mouseInput.scroll.xAxis.valueChangedHandler = ^(GCControllerAxisInput * _Nonnull axis, float value) {
        if (atomic_load(&self->_inputSuspended)) return;
        self->accumulatedScrollX += value;
        
        short truncatedScrollX = (short)self->accumulatedScrollX;
        
        if (truncatedScrollX != 0) {
            // Direction is reversed from vertical scrolling
            LiSendHighResHScrollEvent(-truncatedScrollX * 20);
            
            self->accumulatedScrollX -= truncatedScrollX;
        }
    };
    mouse.mouseInput.scroll.yAxis.valueChangedHandler = ^(GCControllerAxisInput * _Nonnull axis, float value) {
        if (atomic_load(&self->_inputSuspended)) return;
        self->accumulatedScrollY += value;
        
        short truncatedScrollY = (short)self->accumulatedScrollY;
        
        if (truncatedScrollY != 0) {
            LiSendHighResScrollEvent(truncatedScrollY * 20);
            
            self->accumulatedScrollY -= truncatedScrollY;
        }
    };
#endif
}

-(void) updateAutoOnScreenControlMode
{
    // Auto on-screen control support may not be enabled
    if (_osc == NULL) {
        return;
    }
    
    OnScreenControlsLevel level = OnScreenControlsLevelFull;
    
    // We currently stop after the first controller we find.
    // Maybe we'll want to change that logic later.
    for (int i = 0; i < [[GCController controllers] count]; i++) {
        GCController *controller = [GCController controllers][i];
        
        if (controller != NULL) {
            if (controller.extendedGamepad != NULL) {
                level = OnScreenControlsLevelAutoGCExtendedGamepad;
                if (@available(iOS 12.1, tvOS 12.1, *)) {
                    if (controller.extendedGamepad.leftThumbstickButton != nil &&
                        controller.extendedGamepad.rightThumbstickButton != nil) {
                        level = OnScreenControlsLevelAutoGCExtendedGamepadWithStickButtons;
                        if (@available(iOS 13.0, tvOS 13.0, *)) {
                            if (controller.extendedGamepad.buttonOptions != nil) {
                                // Has L3/R3 and Select, so we can show nothing :)
                                level = OnScreenControlsLevelOff;
                            }
                        }
                    }
                }
                break;
            }
        }
    }
    
    // If we didn't find a gamepad present and we have a keyboard or mouse, turn
    // the on-screen controls off to get the overlays out of the way.
    if (level == OnScreenControlsLevelFull && [ControllerSupport hasKeyboardOrMouse]) {
        level = OnScreenControlsLevelOff;
        
        // Ensure the virtual gamepad disappears to avoid confusing some games.
        // If the mouse and keyboard disconnect later, it will reappear when the
        // first OSC input is received.
        LiSendMultiControllerEvent(0, 0, 0, 0, 0, 0, 0, 0, 0);
    }
    
    [_osc setLevel:level];
}

-(void) initAutoOnScreenControlMode:(OnScreenControls*)osc
{
    _osc = osc;
    
    [self updateAutoOnScreenControlMode];
}

-(Controller*) assignController:(GCController*)controller {
    for (int i = 0; i < 4; i++) {
        if (!(_controllerNumbers & (1 << i))) {
            _controllerNumbers |= (1 << i);
            controller.playerIndex = i;
            
            Controller* limeController = [[Controller alloc] init];
            limeController.playerIndex = i;
            limeController.supportedEmulationFlags = EMULATING_SPECIAL | EMULATING_SELECT;
            limeController.gamepad = controller;

            // If this is player 0, it shares state with the OSC
            limeController.mergedWithController = _oscController;
            _oscController.mergedWithController = limeController;
            
            if (@available(iOS 13.0, tvOS 13.0, *)) {
                if (controller.extendedGamepad != nil &&
                    controller.extendedGamepad.buttonOptions != nil) {
                    // Disable select button emulation since we have a physical select button
                    limeController.supportedEmulationFlags &= ~EMULATING_SELECT;
                }
            }
            
            if (@available(iOS 14.0, tvOS 14.0, *)) {
                if (controller.extendedGamepad != nil &&
                    controller.extendedGamepad.buttonHome != nil) {
                    // Disable special button emulation since we have a physical special button
                    limeController.supportedEmulationFlags &= ~EMULATING_SPECIAL;
                }
            }
            
            // Prepare controller haptics for use
            [self initializeControllerHaptics:limeController];

            [_controllers setObject:limeController forKey:[NSNumber numberWithInteger:controller.playerIndex]];
            
            Log(LOG_I, @"Assigning controller index: %d", i);
            return limeController;
        }
    }
    
    return nil;
}

-(Controller*) getOscController {
    return _oscController;
}

+(bool) isSupportedGamepad:(GCController*) controller {
    return controller.extendedGamepad != nil;
}

#pragma clang diagnostic pop

+(int) getGamepadCount {
    int count = 0;
    
    for (GCController* controller in [GCController controllers]) {
        if ([ControllerSupport isSupportedGamepad:controller]) {
            count++;
        }
    }
    
    return count;
}

+(int) getConnectedGamepadMask:(StreamConfiguration*)streamConfig {
    int mask = 0;
    
    if (streamConfig.multiController) {
        int i = 0;
        for (GCController* controller in [GCController controllers]) {
            if ([ControllerSupport isSupportedGamepad:controller]) {
                mask |= 1 << i++;
            }
        }
    }
    else {
        // Some games don't deal with having controller reconnected
        // properly so always report controller 1 if not in MC mode
        mask = 0x1;
    }
    
    DataManager* dataMan = [[DataManager alloc] init];
    TemporarySettings* settings = [dataMan getSettings];
    OnScreenControlsLevel level = (OnScreenControlsLevel)[settings.onscreenControls integerValue];
    
    // Even if no gamepads are present, we will always count one if OSC is enabled,
    // or it's set to auto and no keyboard or mouse is present. Absolute touch mode
    // disables the OSC.
    if (level != OnScreenControlsLevelOff && (![ControllerSupport hasKeyboardOrMouse] || level != OnScreenControlsLevelAuto) && !settings.absoluteTouchMode) {
        mask |= 0x1;
    }
    
    return mask;
}

-(NSUInteger) getConnectedGamepadCount
{
    return _controllers.count;
}

-(id) initWithConfig:(StreamConfiguration*)streamConfig delegate:(id<ControllerSupportDelegate>)delegate
{
    self = [super init];
    
    _controllerStreamLock = [[NSLock alloc] init];
    _controllers = [[NSMutableDictionary alloc] init];
    atomic_init(&_inputSuspended, false);
    NSNumber *pointerModeState = [NSUserDefaults.standardUserDefaults objectForKey:CONTROLLER_POINTER_MODE_STATE_KEY];
    atomic_init(&_controllerPointerModePreferredEnabled,
                pointerModeState != nil ? pointerModeState.boolValue : true);
    MoonlightSetMouseInputSuspended(NO);
    _controllerNumbers = 0;
    _multiController = streamConfig.multiController;
    _swapABXYButtons = streamConfig.swapABXYButtons;
    NSNumber *pointerModePreference = [NSUserDefaults.standardUserDefaults objectForKey:CONTROLLER_POINTER_MODE_PREFERENCE_KEY];
    _controllerPointerModeAvailable = pointerModePreference != nil
        ? pointerModePreference.boolValue
        : CONTROLLER_POINTER_MODE_ENABLED_BY_DEFAULT;
    _autoEnableControllerPointerForDesktop =
        _controllerPointerModeAvailable &&
        streamConfig.appName != nil &&
        [streamConfig.appName rangeOfString:@"desktop" options:NSCaseInsensitiveSearch].location != NSNotFound;
    _delegate = delegate;

    _oscController = [[Controller alloc] init];
    _oscController.playerIndex = 0;

    DataManager* dataMan = [[DataManager alloc] init];
    TemporarySettings *settings = [dataMan getSettings];
    _oscEnabled = !settings.absoluteTouchMode &&
        (OnScreenControlsLevel)[settings.onscreenControls integerValue] != OnScreenControlsLevelOff;
    
    Log(LOG_I, @"Number of supported controllers connected: %d", [ControllerSupport getGamepadCount]);
    Log(LOG_I, @"Multi-controller: %d", _multiController);
    
    for (GCController* controller in [GCController controllers]) {
        if ([ControllerSupport isSupportedGamepad:controller]) {
            [self assignController:controller];
            [self registerControllerCallbacks:controller];
            
            // Note: We cannot report controller arrival to the host here,
            // because the connection has not been established yet.
        }
    }
    
    if (@available(iOS 14.0, tvOS 14.0, *)) {
        for (GCMouse* mouse in [GCMouse mice]) {
            [self registerMouseCallbacks:mouse];
        }
    }
    
    _controllerConnectObserver = [[NSNotificationCenter defaultCenter] addObserverForName:GCControllerDidConnectNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        Log(LOG_I, @"Controller connected!");
        
        GCController* controller = note.object;
        
        if (![ControllerSupport isSupportedGamepad:controller]) {
            // Ignore micro gamepads and motion controllers
            return;
        }
        
        Controller* limeController = [self assignController:controller];
        if (limeController) {
            // Register callbacks on the new controller
            [self registerControllerCallbacks:controller];
            
            // Report the controller arrival to the host if we're connected
            BOOL controllerReported = [self reportControllerArrival:limeController];
            if (controllerReported) {
                [self autoEnableDesktopPointerForControllerIfNeeded:limeController];
            }
            
            // Re-evaluate the on-screen control mode
            [self updateAutoOnScreenControlMode];
            
            // Notify the delegate
            [self->_delegate gamepadPresenceChanged];
        }
    }];
    _controllerDisconnectObserver = [[NSNotificationCenter defaultCenter] addObserverForName:GCControllerDidDisconnectNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        Log(LOG_I, @"Controller disconnected!");
        
        GCController* controller = note.object;
        
        NSNumber *controllerKey = nil;
        Controller *limeController = nil;
        for (NSNumber *candidateKey in self->_controllers) {
            Controller *candidate = self->_controllers[candidateKey];
            if (candidate.gamepad == controller) {
                controllerKey = candidateKey;
                limeController = candidate;
                break;
            }
        }

        [self unregisterControllerCallbacks:controller];
        if (limeController == nil) {
            Log(LOG_W, @"Disconnected controller was not assigned");
            return;
        }

        NSInteger savedPlayerIndex = limeController.playerIndex;
        if (savedPlayerIndex >= 0 && savedPlayerIndex < 8) {
            self->_controllerNumbers &= (char)~(1u << savedPlayerIndex);
        }
        else {
            Log(LOG_W, @"Ignoring invalid saved controller index: %ld", (long)savedPlayerIndex);
        }
        Log(LOG_I, @"Unassigning controller index: %ld", (long)savedPlayerIndex);

        if (limeController) {
            [self releaseControllerTouchpadTouches:limeController];
            // Release any emulated mouse buttons and stop the pointer timer
            // before this controller disappears.
            [self resetControllerPointerMode:limeController notifyDelegate:NO];

            // Stop haptics on this controller
            [self cleanupControllerHaptics:limeController];
            
            // Stop motion reports on this controller
            [self cleanupControllerMotion:limeController];
            
            // Stop battery reports on this controller
            [self cleanupControllerBattery:limeController];
            
            // Disassociate this controller from any controllers merged with it
            if (limeController.mergedWithController) {
                assert(limeController.mergedWithController.mergedWithController == limeController);
                limeController.mergedWithController.mergedWithController = nil;
            }
            
            // Inform the server of the updated active gamepads before removing this controller
            [self updateFinished:limeController];
            [self->_controllers removeObjectForKey:controllerKey];

            NSArray<NSNumber *> *remainingControllerNumbers =
                [[self->_controllers allKeys] sortedArrayUsingSelector:@selector(compare:)];
            for (NSNumber *controllerNumber in remainingControllerNumbers) {
                [self autoEnableDesktopPointerForControllerIfNeeded:self->_controllers[controllerNumber]];
            }
            
            // Re-evaluate the on-screen control mode
            [self updateAutoOnScreenControlMode];
            
            // Notify the delegate
            [self->_delegate gamepadPresenceChanged];
        }
    }];
    
    if (@available(iOS 14.0, tvOS 14.0, *)) {
        _mouseConnectObserver = [[NSNotificationCenter defaultCenter] addObserverForName:GCMouseDidConnectNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
            Log(LOG_I, @"Mouse connected!");
            
            GCMouse* mouse = note.object;
            
            // Register for mouse events
            [self registerMouseCallbacks: mouse];

            // Re-evaluate the on-screen control mode
            [self updateAutoOnScreenControlMode];
            
            // Notify the delegate
            [self->_delegate mousePresenceChanged];
        }];
        _mouseDisconnectObserver = [[NSNotificationCenter defaultCenter] addObserverForName:GCMouseDidDisconnectNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
            Log(LOG_I, @"Mouse disconnected!");
            
            GCMouse* mouse = note.object;
            
            // Unregister for mouse events
            [self unregisterMouseCallbacks: mouse];

            // Re-evaluate the on-screen control mode
            [self updateAutoOnScreenControlMode];
            
            // Notify the delegate
            [self->_delegate mousePresenceChanged];
        }];
        _keyboardConnectObserver = [[NSNotificationCenter defaultCenter] addObserverForName:GCKeyboardDidConnectNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
            Log(LOG_I, @"Keyboard connected!");
            
            // Re-evaluate the on-screen control mode
            [self updateAutoOnScreenControlMode];
        }];
        _keyboardDisconnectObserver = [[NSNotificationCenter defaultCenter] addObserverForName:GCKeyboardDidDisconnectNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
            Log(LOG_I, @"Keyboard disconnected!");

            // Re-evaluate the on-screen control mode
            [self updateAutoOnScreenControlMode];
        }];
    }

    _applicationWillResignActiveObserver = [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        // Never leave a host mouse button held or a run-loop timer active while
        // the client is backgrounded or interrupted by system UI.
        atomic_store(&self->_inputSuspended, true);
        MoonlightSetMouseInputSuspended(YES);
        @synchronized(self->_oscController) {
            self->_oscController.lastButtonFlags = 0;
            self->_oscController.lastLeftTrigger = 0;
            self->_oscController.lastRightTrigger = 0;
            self->_oscController.lastLeftStickX = 0;
            self->_oscController.lastLeftStickY = 0;
            self->_oscController.lastRightStickX = 0;
            self->_oscController.lastRightStickY = 0;
        }
        if (self->_oscEnabled && self->_oscController.reportedArrival) {
            [self sendNeutralControllerEvent:self->_oscController];
        }
        for (Controller* controller in [self->_controllers allValues]) {
            @synchronized(controller) {
                controller.pointerModeWasEnabledBeforeResign = controller.pointerModeEnabled;
            }
            [self releaseControllerTouchpadTouches:controller];
            [self resetControllerPointerMode:controller notifyDelegate:NO];
            [self sendNeutralControllerEvent:controller];
        }
    }];
    _applicationDidBecomeActiveObserver = [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        atomic_store(&self->_inputSuspended, false);
        MoonlightSetMouseInputSuspended(NO);
        for (Controller* controller in [self->_controllers allValues]) {
            BOOL restorePointerMode;
            @synchronized(controller) {
                restorePointerMode = controller.pointerModeWasEnabledBeforeResign;
                controller.pointerModeWasEnabledBeforeResign = NO;
                GCExtendedGamepad *gamepad = controller.gamepad.extendedGamepad;
                if (gamepad != nil) {
                    // Re-sample live axes in case release callbacks were coalesced
                    // while inactive; never restart pointer motion from stale values.
                    controller.lastLeftStickX = gamepad.leftThumbstick.xAxis.value * 0x7FFE;
                    controller.lastLeftStickY = gamepad.leftThumbstick.yAxis.value * 0x7FFE;
                    controller.lastRightStickX = gamepad.rightThumbstick.xAxis.value * 0x7FFE;
                    controller.lastRightStickY = gamepad.rightThumbstick.yAxis.value * 0x7FFE;
                    controller.lastLeftTrigger = gamepad.leftTrigger.value * 0xFF;
                    controller.lastRightTrigger = gamepad.rightTrigger.value * 0xFF;
                }
            }
            if (restorePointerMode) {
                [self setControllerPointerMode:controller enabled:YES notifyDelegate:YES];
            }
        }

        NSArray<NSNumber *> *controllerNumbers =
            [[self->_controllers allKeys] sortedArrayUsingSelector:@selector(compare:)];
        for (NSNumber *controllerNumber in controllerNumbers) {
            [self autoEnableDesktopPointerForControllerIfNeeded:self->_controllers[controllerNumber]];
        }
    }];
    
    return self;
}

-(void) connectionEstablished
{
    if (atomic_load_explicit(&_inputSuspended, memory_order_acquire)) {
        return;
    }
    _connectionEstablished = true;
    NSArray<NSNumber *> *controllerNumbers =
        [[_controllers allKeys] sortedArrayUsingSelector:@selector(compare:)];
    for (NSNumber *controllerNumber in controllerNumbers) {
        Controller *controller = _controllers[controllerNumber];
        // Report the controller arrival to the host if we haven't done so yet
        [self reportControllerArrival:controller];
        [self autoEnableDesktopPointerForControllerIfNeeded:controller];
    }
}

-(void) cleanup
{
    @synchronized(self) {
        if (_cleanupComplete) {
            return;
        }
        _cleanupComplete = true;
        atomic_store_explicit(&_inputSuspended, true, memory_order_release);
    }
    MoonlightSetMouseInputSuspended(YES);
    _delegate = nil;

    [[NSNotificationCenter defaultCenter] removeObserver:_controllerConnectObserver];
    [[NSNotificationCenter defaultCenter] removeObserver:_controllerDisconnectObserver];
    [[NSNotificationCenter defaultCenter] removeObserver:_mouseConnectObserver];
    [[NSNotificationCenter defaultCenter] removeObserver:_mouseDisconnectObserver];
    [[NSNotificationCenter defaultCenter] removeObserver:_keyboardConnectObserver];
    [[NSNotificationCenter defaultCenter] removeObserver:_keyboardDisconnectObserver];
    [[NSNotificationCenter defaultCenter] removeObserver:_applicationWillResignActiveObserver];
    [[NSNotificationCenter defaultCenter] removeObserver:_applicationDidBecomeActiveObserver];
    
    _controllerConnectObserver = nil;
    _controllerDisconnectObserver = nil;
    _mouseConnectObserver = nil;
    _mouseDisconnectObserver = nil;
    _keyboardConnectObserver = nil;
    _keyboardDisconnectObserver = nil;
    _applicationWillResignActiveObserver = nil;
    _applicationDidBecomeActiveObserver = nil;
    
    _controllerNumbers = 0;
    
    NSArray<Controller*>* controllersToClean;
    @synchronized(self) {
        controllersToClean = [_controllers.allValues copy];
    }
    for (Controller* controller in controllersToClean) {
        [self releaseControllerTouchpadTouches:controller];
        [self resetControllerPointerMode:controller notifyDelegate:NO];
        [self cleanupControllerHaptics:controller];
        [self cleanupControllerMotion:controller];
        [self cleanupControllerBattery:controller];
    }
    @synchronized(self) {
        for (int mouseButton = BUTTON_LEFT; mouseButton <= BUTTON_X2; mouseButton++) {
            if (_pointerMouseButtonRefCounts[mouseButton] > 0) {
                MoonlightSendMouseButtonEvent(MoonlightMouseButtonSourceControllerPointer, BUTTON_ACTION_RELEASE, mouseButton);
                _pointerMouseButtonRefCounts[mouseButton] = 0;
            }
        }
    }
    @synchronized(self) {
        [_controllers removeAllObjects];
    }
    
    for (GCController* controller in [GCController controllers]) {
        if ([ControllerSupport isSupportedGamepad:controller]) {
            [self unregisterControllerCallbacks:controller];
        }
    }
    
    if (@available(iOS 14.0, tvOS 14.0, *)) {
        for (GCMouse* mouse in [GCMouse mice]) {
            [self unregisterMouseCallbacks:mouse];
        }
    }
}

- (void)dealloc {
    [self cleanup];
}

@end
