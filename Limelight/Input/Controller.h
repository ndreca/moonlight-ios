//
//  Controller.h
//  Moonlight
//
//  Created by Cameron Gutman on 2/11/19.
//  Copyright © 2019 Moonlight Game Streaming Project. All rights reserved.
//

#import "HapticContext.h"

@import GameController;
@import CoreHaptics;

@interface Controller : NSObject

typedef struct {
    float lastX;
    float lastY;
} controller_touch_context_t;

@property (nullable, nonatomic, retain) GCController* gamepad;
@property (nonatomic)                   int playerIndex;
@property (nonatomic)                   int lastButtonFlags;
@property (nonatomic)                   int emulatingButtonFlags;
@property (nonatomic)                   int supportedEmulationFlags;
@property (nonatomic)                   unsigned char lastLeftTrigger;
@property (nonatomic)                   unsigned char lastRightTrigger;
@property (nonatomic)                   short lastLeftStickX;
@property (nonatomic)                   short lastLeftStickY;
@property (nonatomic)                   short lastRightStickX;
@property (nonatomic)                   short lastRightStickY;

// Controller-driven pointer mode state is kept per physical controller so one
// controller can navigate the remote desktop without suppressing the others.
@property (nonatomic)                   BOOL pointerModeEnabled;
@property (nonatomic)                   BOOL pointerModeMenuPressed;
@property (nonatomic)                   BOOL pointerModeToggleEligible;
@property (nonatomic)                   uint64_t pointerModeMenuDownTimeMs;
@property (nonatomic)                   uint64_t pointerModeHoldGeneration;
@property (nonatomic)                   BOOL pointerModeHoldActivated;
@property (nonatomic)                   uint64_t pointerModeMenuPulseGeneration;
@property (nonatomic)                   BOOL pointerModeMenuPulseActive;
@property (nonatomic)                   BOOL pointerModeWasEnabledBeforeResign;
@property (nonatomic)                   int pointerModeLastButtonFlags;
@property (nonatomic)                   float pointerModeAccumulatedDeltaX;
@property (nonatomic)                   float pointerModeAccumulatedDeltaY;
@property (nonatomic)                   float pointerModeSmoothedDeltaX;
@property (nonatomic)                   float pointerModeSmoothedDeltaY;
@property (nonatomic)                   NSTimer* _Nullable pointerModeTimer;

@property (nonatomic)                   controller_touch_context_t primaryTouch;
@property (nonatomic)                   controller_touch_context_t secondaryTouch;
@property (nonatomic)                   BOOL primaryTouchNeedsLift;
@property (nonatomic)                   BOOL secondaryTouchNeedsLift;

@property (nonatomic)                   HapticContext* _Nullable lowFreqMotor;
@property (nonatomic)                   HapticContext* _Nullable highFreqMotor;
@property (nonatomic)                   HapticContext* _Nullable leftTriggerMotor;
@property (nonatomic)                   HapticContext* _Nullable rightTriggerMotor;

@property (nonatomic)                   NSTimer* _Nullable accelTimer;
@property (nonatomic)                   GCAcceleration lastAccelSample;
@property (nonatomic)                   NSTimer* _Nullable gyroTimer;
@property (nonatomic)                   GCRotationRate lastGyroSample;

@property (nonatomic)                   NSTimer* _Nullable batteryTimer;
@property (nonatomic)                   GCDeviceBatteryState lastBatteryState;
@property (nonatomic)                   float lastBatteryLevel;

@property (nonatomic)                   BOOL reportedArrival;
@property (nonatomic)                   Controller* _Nullable mergedWithController;

@end
