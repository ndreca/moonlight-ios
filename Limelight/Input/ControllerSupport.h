//
//  ControllerSupport.h
//  Moonlight
//
//  Created by Cameron Gutman on 10/20/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "StreamConfiguration.h"
#import "Controller.h"

@class OnScreenControls;

typedef NS_ENUM(NSUInteger, MoonlightMouseButtonSource) {
    MoonlightMouseButtonSourceControllerPointer = 0,
    MoonlightMouseButtonSourcePhysicalMouse,
    MoonlightMouseButtonSourceAbsoluteTouch,
    MoonlightMouseButtonSourceRelativeTouch,
    MoonlightMouseButtonSourceUIKitMouse,
    MoonlightMouseButtonSourceX1Mouse,
    MoonlightMouseButtonSourceCount,
};

FOUNDATION_EXPORT void MoonlightSendMouseButtonEvent(MoonlightMouseButtonSource source, int action, int button);
FOUNDATION_EXPORT void MoonlightReleaseMouseButtons(MoonlightMouseButtonSource source);
FOUNDATION_EXPORT void MoonlightSetMouseInputSuspended(BOOL suspended);
FOUNDATION_EXPORT BOOL MoonlightHasRecentGCMouseMotion(void);

@protocol ControllerSupportDelegate <NSObject>

- (void) gamepadPresenceChanged;
- (void) mousePresenceChanged;
- (void) streamExitRequested;

@optional
- (void) controllerPointerModeChanged:(BOOL)enabled playerIndex:(NSInteger)playerIndex;

@end

@interface ControllerSupport : NSObject

-(id) initWithConfig:(StreamConfiguration*)streamConfig delegate:(id<ControllerSupportDelegate>)delegate;
-(void) connectionEstablished;

-(void) initAutoOnScreenControlMode:(OnScreenControls*)osc;
-(void) cleanup;
-(Controller*) getOscController;

-(void) updateLeftStick:(Controller*)controller x:(short)x y:(short)y;
-(void) updateRightStick:(Controller*)controller x:(short)x y:(short)y;

-(void) updateLeftTrigger:(Controller*)controller left:(unsigned char)left;
-(void) updateRightTrigger:(Controller*)controller right:(unsigned char)right;
-(void) updateTriggers:(Controller*)controller left:(unsigned char)left right:(unsigned char)right;

-(void) updateButtonFlags:(Controller*)controller flags:(int)flags;
-(void) setButtonFlag:(Controller*)controller flags:(int)flags;
-(void) clearButtonFlag:(Controller*)controller flags:(int)flags;

-(void) updateFinished:(Controller*)controller;

-(void) rumble:(unsigned short)controllerNumber lowFreqMotor:(unsigned short)lowFreqMotor highFreqMotor:(unsigned short)highFreqMotor;
-(void) rumbleTriggers:(uint16_t)controllerNumber leftTrigger:(uint16_t)leftTrigger rightTrigger:(uint16_t)rightTrigger;
-(void) setMotionEventState:(uint16_t)controllerNumber motionType:(uint8_t)motionType reportRateHz:(uint16_t)reportRateHz;
-(void) setControllerLed:(uint16_t)controllerNumber r:(uint8_t)r g:(uint8_t)g b:(uint8_t)b;

+(int) getConnectedGamepadMask:(StreamConfiguration*)streamConfig;

-(NSUInteger) getConnectedGamepadCount;

@end
