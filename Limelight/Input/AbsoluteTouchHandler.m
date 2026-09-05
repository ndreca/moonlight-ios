//
//  AbsoluteTouchHandler.m
//  Moonlight
//
//  Created by Cameron Gutman on 11/1/20.
//  Copyright © 2020 Moonlight Game Streaming Project. All rights reserved.
//

#import "AbsoluteTouchHandler.h"
#import "ControllerSupport.h"

#include <Limelight.h>

// How long the fingers must be stationary to start a right click
#define LONG_PRESS_ACTIVATION_DELAY 0.650f

// How far the finger can move before it cancels a right click
#define LONG_PRESS_ACTIVATION_DELTA 0.01f

// How long the double tap deadzone stays in effect between touch up and touch down
#define DOUBLE_TAP_DEAD_ZONE_DELAY 0.250f

// How far the finger can move before it can override the double tap deadzone
#define DOUBLE_TAP_DEAD_ZONE_DELTA 0.025f

// Briefly defer absolute left-down so a near-simultaneous three-finger
// keyboard gesture does not click the remote desktop on its first finger.
#define MULTITOUCH_DISAMBIGUATION_DELAY 0.090f

@implementation AbsoluteTouchHandler {
    __weak StreamView* view;
    
    NSTimer* longPressTimer;
    NSTimer* primaryPressTimer;
    BOOL leftButtonPressed;
    BOOL suppressCurrentTouch;
    BOOL shouldRepositionOnPress;
    BOOL longPressActivated;
    BOOL clickPulseActive;
    uint64_t clickPulseGeneration;
    UITouch* lastTouchDown;
    CGPoint lastTouchDownLocation;
    UITouch* lastTouchUp;
    CGPoint lastTouchUpLocation;
}

- (id)initWithView:(StreamView*)view {
    self = [self init];
    self->view = view;
    return self;
}

- (void)onLongPressStart:(NSTimer*)timer {
    if (suppressCurrentTouch) {
        return;
    }
    // Raise the left click and start a right click
    MoonlightSendMouseButtonEvent(MoonlightMouseButtonSourceAbsoluteTouch, BUTTON_ACTION_RELEASE, BUTTON_LEFT);
    leftButtonPressed = NO;
    MoonlightSendMouseButtonEvent(MoonlightMouseButtonSourceAbsoluteTouch, BUTTON_ACTION_PRESS, BUTTON_RIGHT);
    longPressActivated = YES;
}

- (void)onPrimaryPressStart:(NSTimer*)timer {
    primaryPressTimer = nil;
    if (suppressCurrentTouch) {
        return;
    }
    if (shouldRepositionOnPress) {
        [view updateCursorLocation:lastTouchDownLocation isMouse:NO];
    }
    MoonlightSendMouseButtonEvent(MoonlightMouseButtonSourceAbsoluteTouch, BUTTON_ACTION_PRESS, BUTTON_LEFT);
    leftButtonPressed = YES;
}

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    if (clickPulseActive) {
        clickPulseActive = NO;
        clickPulseGeneration++;
        MoonlightSendMouseButtonEvent(MoonlightMouseButtonSourceAbsoluteTouch, BUTTON_ACTION_RELEASE, BUTTON_LEFT);
    }
    // Ignore touch down events with more than one finger
    if ([[event allTouches] count] > 1) {
        suppressCurrentTouch = YES;
        if (leftButtonPressed) {
            MoonlightSendMouseButtonEvent(MoonlightMouseButtonSourceAbsoluteTouch, BUTTON_ACTION_RELEASE, BUTTON_LEFT);
            leftButtonPressed = NO;
        }
        MoonlightSendMouseButtonEvent(MoonlightMouseButtonSourceAbsoluteTouch, BUTTON_ACTION_RELEASE, BUTTON_RIGHT);
        [primaryPressTimer invalidate];
        primaryPressTimer = nil;
        [longPressTimer invalidate];
        longPressTimer = nil;
        return;
    }

    suppressCurrentTouch = NO;
    leftButtonPressed = NO;
    longPressActivated = NO;
    
    UITouch* touch = [touches anyObject];
    CGPoint touchLocation = [touch locationInView:view];
    
    // Defer cursor repositioning with left-down so a three-finger keyboard tap
    // neither clicks nor moves the remote cursor.
    shouldRepositionOnPress = touch.timestamp - lastTouchUp.timestamp > DOUBLE_TAP_DEAD_ZONE_DELAY ||
        sqrt(pow((touchLocation.x / view.bounds.size.width) - (lastTouchUpLocation.x / view.bounds.size.width), 2) +
             pow((touchLocation.y / view.bounds.size.height) - (lastTouchUpLocation.y / view.bounds.size.height), 2)) > DOUBLE_TAP_DEAD_ZONE_DELTA;
    
    primaryPressTimer = [NSTimer scheduledTimerWithTimeInterval:MULTITOUCH_DISAMBIGUATION_DELAY
                                                         target:self
                                                       selector:@selector(onPrimaryPressStart:)
                                                       userInfo:nil
                                                        repeats:NO];
    
    // Start the long press timer
    longPressTimer = [NSTimer scheduledTimerWithTimeInterval:LONG_PRESS_ACTIVATION_DELAY
                                                      target:self
                                                    selector:@selector(onLongPressStart:)
                                                    userInfo:nil
                                                     repeats:NO];
    
    lastTouchDown = touch;
    lastTouchDownLocation = touchLocation;
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event {
    // Ignore touch move events with more than one finger
    if ([[event allTouches] count] > 1) {
        suppressCurrentTouch = YES;
        if (leftButtonPressed) {
            MoonlightSendMouseButtonEvent(MoonlightMouseButtonSourceAbsoluteTouch, BUTTON_ACTION_RELEASE, BUTTON_LEFT);
            leftButtonPressed = NO;
        }
        MoonlightSendMouseButtonEvent(MoonlightMouseButtonSourceAbsoluteTouch, BUTTON_ACTION_RELEASE, BUTTON_RIGHT);
        [primaryPressTimer invalidate];
        primaryPressTimer = nil;
        [longPressTimer invalidate];
        longPressTimer = nil;
        return;
    }
    
    UITouch* touch = [touches anyObject];
    CGPoint touchLocation = [touch locationInView:view];
    
    if (sqrt(pow((touchLocation.x / view.bounds.size.width) - (lastTouchDownLocation.x / view.bounds.size.width), 2) +
             pow((touchLocation.y / view.bounds.size.height) - (lastTouchDownLocation.y / view.bounds.size.height), 2)) > LONG_PRESS_ACTIVATION_DELTA) {
        // Moved too far since touch down. Cancel the long press timer.
        [longPressTimer invalidate];
        longPressTimer = nil;

        if (!leftButtonPressed && primaryPressTimer != nil) {
            [primaryPressTimer invalidate];
            primaryPressTimer = nil;
            [view updateCursorLocation:touchLocation isMouse:NO];
            shouldRepositionOnPress = NO;
            MoonlightSendMouseButtonEvent(MoonlightMouseButtonSourceAbsoluteTouch, BUTTON_ACTION_PRESS, BUTTON_LEFT);
            leftButtonPressed = YES;
        }
    }

    // The cursor has already followed this movement, so the delayed button-down
    // must not snap it back to the original touch-down point.
    shouldRepositionOnPress = NO;
    
    [view updateCursorLocation:[[touches anyObject] locationInView:view] isMouse:NO];
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event {
    // Only fire this logic if all touches have ended
    if ([[event allTouches] count] == [touches count]) {
        // Cancel the long press timer
        [longPressTimer invalidate];
        longPressTimer = nil;
        [primaryPressTimer invalidate];
        primaryPressTimer = nil;

        if (!suppressCurrentTouch) {
            if (!leftButtonPressed && !longPressActivated) {
                if (shouldRepositionOnPress) {
                    [view updateCursorLocation:lastTouchDownLocation isMouse:NO];
                }
                MoonlightSendMouseButtonEvent(MoonlightMouseButtonSourceAbsoluteTouch, BUTTON_ACTION_PRESS, BUTTON_LEFT);
                uint64_t pulseGeneration = ++clickPulseGeneration;
                clickPulseActive = YES;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(50 * NSEC_PER_MSEC)),
                               dispatch_get_main_queue(), ^{
                    if (!self->clickPulseActive || self->clickPulseGeneration != pulseGeneration) {
                        return;
                    }
                    self->clickPulseActive = NO;
                    MoonlightSendMouseButtonEvent(MoonlightMouseButtonSourceAbsoluteTouch, BUTTON_ACTION_RELEASE, BUTTON_LEFT);
                });
            }
            else if (leftButtonPressed) {
                MoonlightSendMouseButtonEvent(MoonlightMouseButtonSourceAbsoluteTouch, BUTTON_ACTION_RELEASE, BUTTON_LEFT);
            }
        }
        leftButtonPressed = NO;

        // Raise right button too in case we triggered a long press gesture
        MoonlightSendMouseButtonEvent(MoonlightMouseButtonSourceAbsoluteTouch, BUTTON_ACTION_RELEASE, BUTTON_RIGHT);
        suppressCurrentTouch = NO;
        shouldRepositionOnPress = NO;
        longPressActivated = NO;
        
        // Remember this last touch for touch-down deadzoning
        lastTouchUp = [touches anyObject];
        lastTouchUpLocation = [lastTouchUp locationInView:view];
    }
}

- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event {
    [self cancelAllTouches];
}

- (void)cancelAllTouches {
    [primaryPressTimer invalidate];
    primaryPressTimer = nil;
    [longPressTimer invalidate];
    longPressTimer = nil;
    MoonlightSendMouseButtonEvent(MoonlightMouseButtonSourceAbsoluteTouch, BUTTON_ACTION_RELEASE, BUTTON_LEFT);
    MoonlightSendMouseButtonEvent(MoonlightMouseButtonSourceAbsoluteTouch, BUTTON_ACTION_RELEASE, BUTTON_RIGHT);
    clickPulseActive = NO;
    clickPulseGeneration++;
    leftButtonPressed = NO;
    suppressCurrentTouch = NO;
    shouldRepositionOnPress = NO;
    longPressActivated = NO;
    lastTouchDown = nil;
}

@end
