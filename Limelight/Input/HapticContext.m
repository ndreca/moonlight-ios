//
//  HapticContext.m
//  Moonlight
//
//  Created by Cameron Gutman on 9/17/20.
//  Copyright © 2020 Moonlight Game Streaming Project. All rights reserved.
//

#import "HapticContext.h"

@import CoreHaptics;
@import GameController;

@implementation HapticContext {
    GCControllerPlayerIndex _playerIndex;
    CHHapticEngine* _hapticEngine API_AVAILABLE(ios(13.0), tvos(14.0));
    id<CHHapticPatternPlayer> _hapticPlayer API_AVAILABLE(ios(13.0), tvos(14.0));
    BOOL _playing;
}

-(void)cleanup API_AVAILABLE(ios(14.0), tvos(14.0)) {
    @synchronized(self) {
        if (_hapticPlayer != nil) {
            [_hapticPlayer cancelAndReturnError:nil];
            _hapticPlayer = nil;
        }
        if (_hapticEngine != nil) {
            [_hapticEngine stopWithCompletionHandler:nil];
            _hapticEngine = nil;
        }
        _playing = NO;
    }
}

-(void)setMotorAmplitude:(unsigned short)amplitude API_AVAILABLE(ios(14.0), tvos(14.0)) {
    @synchronized(self) {
        NSError* error = nil;

        // Check if the haptic engine died
        if (_hapticEngine == nil) {
            return;
        }
    
        // Stop the effect entirely if the amplitude is 0
        if (amplitude == 0) {
            if (_playing) {
                if (![_hapticPlayer stopAtTime:0 error:&error]) {
                    Log(LOG_W, @"Controller %ld: Haptic playback stop failed: %@", (long)_playerIndex, error);
                }
                _playing = NO;
            }
            return;
        }

        if (_hapticPlayer == nil) {
            // We must initialize the intensity to 1.0f because the dynamic parameters are multiplied by this value before being applied
            CHHapticEventParameter* intensityParameter = [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity value:1.0f];
            CHHapticEvent* hapticEvent = [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticContinuous parameters:@[intensityParameter] relativeTime:0 duration:GCHapticDurationInfinite];
            CHHapticPattern* hapticPattern = [[CHHapticPattern alloc] initWithEvents:@[hapticEvent] parameters:@[] error:&error];
            if (hapticPattern == nil || error != nil) {
                Log(LOG_W, @"Controller %ld: Haptic pattern creation failed: %@", (long)_playerIndex, error);
                return;
            }

            error = nil;
            _hapticPlayer = [_hapticEngine createPlayerWithPattern:hapticPattern error:&error];
            if (_hapticPlayer == nil || error != nil) {
                Log(LOG_W, @"Controller %ld: Haptic player creation failed: %@", (long)_playerIndex, error);
                _hapticPlayer = nil;
                return;
            }
        }

        CHHapticDynamicParameter* intensityParameter = [[CHHapticDynamicParameter alloc] initWithParameterID:CHHapticDynamicParameterIDHapticIntensityControl value:amplitude / 65535.0f relativeTime:0];
        error = nil;
        if (![_hapticPlayer sendParameters:@[intensityParameter] atTime:CHHapticTimeImmediate error:&error]) {
            Log(LOG_W, @"Controller %ld: Haptic player parameter update failed: %@", (long)_playerIndex, error);
            return;
        }
    
        if (!_playing) {
            error = nil;
            if (![_hapticPlayer startAtTime:0 error:&error]) {
                _hapticPlayer = nil;
                Log(LOG_W, @"Controller %ld: Haptic playback start failed: %@", (long)_playerIndex, error);
                return;
            }

            _playing = YES;
        }
    }
}

-(id) initWithGamepad:(GCController*)gamepad locality:(GCHapticsLocality)locality API_AVAILABLE(ios(14.0), tvos(14.0)) {
    self = [super init];
    if (self == nil) {
        return nil;
    }

    if (gamepad.haptics == nil) {
        Log(LOG_W, @"Controller %d does not support haptics", gamepad.playerIndex);
        return nil;
    }
    
    if (![[gamepad.haptics supportedLocalities] containsObject:locality]) {
        Log(LOG_W, @"Controller %d does not support haptic locality: %@", gamepad.playerIndex, locality);
        return nil;
    }
    
    _playerIndex = gamepad.playerIndex;
    _hapticEngine = [gamepad.haptics createEngineWithLocality:locality];
    if (_hapticEngine == nil) {
        Log(LOG_W, @"Controller %ld: Failed to create haptic engine for %@", (long)gamepad.playerIndex, locality);
        return nil;
    }
    
    NSError* error = nil;
    if (![_hapticEngine startAndReturnError:&error]) {
        Log(LOG_W, @"Controller %ld: Haptic engine failed to start: %@", (long)gamepad.playerIndex, error);
        _hapticEngine = nil;
        return nil;
    }
    
    __weak typeof(self) weakSelf = self;
    _hapticEngine.stoppedHandler = ^(CHHapticEngineStoppedReason stoppedReason) {
        HapticContext* me = weakSelf;
        if (me == nil) {
            return;
        }
        
        @synchronized(me) {
            Log(LOG_W, @"Controller %ld: Haptic engine stopped: %ld", (long)me->_playerIndex, (long)stoppedReason);
            me->_hapticPlayer = nil;
            me->_hapticEngine = nil;
            me->_playing = NO;
        }
    };
    _hapticEngine.resetHandler = ^{
        HapticContext* me = weakSelf;
        if (me == nil) {
            return;
        }
        
        @synchronized(me) {
            Log(LOG_W, @"Controller %ld: Haptic engine reset", (long)me->_playerIndex);
            me->_hapticPlayer = nil;
            me->_playing = NO;
            NSError *restartError = nil;
            if (![me->_hapticEngine startAndReturnError:&restartError]) {
                Log(LOG_W, @"Controller %ld: Haptic engine restart failed: %@", (long)me->_playerIndex, restartError);
                me->_hapticEngine = nil;
            }
        }
    };
    
    return self;
}

+(HapticContext*) createContextForHighFreqMotor:(GCController*)gamepad {
    if (@available(iOS 14.0, tvOS 14.0, *)) {
        return [[HapticContext alloc] initWithGamepad:gamepad locality:GCHapticsLocalityRightHandle];
    }
    else {
        return nil;
    }
}

+(HapticContext*) createContextForLowFreqMotor:(GCController*)gamepad {
    if (@available(iOS 14.0, tvOS 14.0, *)) {
        return [[HapticContext alloc] initWithGamepad:gamepad locality:GCHapticsLocalityLeftHandle];
    }
    else {
        return nil;
    }
}

+(HapticContext*) createContextForLeftTrigger:(GCController*)gamepad {
    if (@available(iOS 14.0, tvOS 14.0, *)) {
        return [[HapticContext alloc] initWithGamepad:gamepad locality:GCHapticsLocalityLeftTrigger];
    }
    else {
        return nil;
    }
}

+(HapticContext*) createContextForRightTrigger:(GCController*)gamepad {
    if (@available(iOS 14.0, tvOS 14.0, *)) {
        return [[HapticContext alloc] initWithGamepad:gamepad locality:GCHapticsLocalityRightTrigger];
    }
    else {
        return nil;
    }
}

@end
