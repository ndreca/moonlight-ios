//
//  KeyboardSupport.h
//  Moonlight
//
//  Created by Diego Waxemberg on 8/25/18.
//  Copyright © 2018 Moonlight Game Streaming Project. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface KeyboardSupport : NSObject

struct KeyEvent {
    u_short keycode;
    u_short modifierKeycode;
    u_char modifier;
};

+ (BOOL)sendKeyEventForPress:(UIPress*)press down:(BOOL)down API_AVAILABLE(ios(13.4));
+ (BOOL)sendKeyEvent:(UIKey*)key down:(BOOL)down API_AVAILABLE(ios(13.4));
+ (struct KeyEvent) translateKeyEvent:(unichar) inputChar withModifierFlags:(UIKeyModifierFlags)modifierFlags;
+ (void)sendKeyCode:(u_short)keyCode down:(BOOL)down modifiers:(u_char)modifiers;
+ (void)sendKeyStroke:(u_short)keyCode modifiers:(u_char)modifiers;
+ (void)sendTranslatedKeyEvent:(struct KeyEvent)event;
+ (void)sendUtf8Text:(NSString *)text;
+ (uint64_t)beginKeyboardSession;
+ (void)endKeyboardSession:(uint64_t)sessionToken;

@end
