//
//  LoadingFrameViewController.m
//  Moonlight
//
//  Created by Diego Waxemberg on 2/24/15.
//  Copyright (c) 2015 Moonlight Stream. All rights reserved.
//

#import "LoadingFrameViewController.h"
#import "AppDelegate.h"

@implementation LoadingFrameViewController {
    BOOL presented;
    UIVisualEffectView *_loadingCard;
    UILabel *_loadingLabel;
};

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.34];
    self.view.accessibilityViewIsModal = YES;

#if TARGET_OS_TV
    CGFloat cardWidth = 520.0;
    CGFloat cardHeight = 220.0;
    CGFloat cardCornerRadius = 28.0;
    CGFloat spinnerTop = 38.0;
    CGFloat labelSpacing = 18.0;
    CGFloat labelFontSize = 30.0;
#else
    CGFloat cardWidth = 230.0;
    CGFloat cardHeight = 112.0;
    CGFloat cardCornerRadius = 20.0;
    CGFloat spinnerTop = 20.0;
    CGFloat labelSpacing = 10.0;
    CGFloat labelFontSize = 16.0;
#endif

    UIBlurEffect *effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterialDark];
    _loadingCard = [[UIVisualEffectView alloc] initWithEffect:effect];
    _loadingCard.translatesAutoresizingMaskIntoConstraints = NO;
    _loadingCard.layer.cornerRadius = cardCornerRadius;
    _loadingCard.layer.cornerCurve = kCACornerCurveContinuous;
    _loadingCard.layer.masksToBounds = YES;
    _loadingCard.layer.borderWidth = 1.0;
    _loadingCard.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.10].CGColor;
    [self.view addSubview:_loadingCard];

    [self.loadingSpinner removeFromSuperview];
    self.loadingSpinner.translatesAutoresizingMaskIntoConstraints = NO;
    self.loadingSpinner.color = [UIColor colorWithRed:0.55 green:0.48 blue:0.96 alpha:1.0];
    self.loadingSpinner.hidesWhenStopped = YES;
#if TARGET_OS_TV
    self.loadingSpinner.activityIndicatorViewStyle = UIActivityIndicatorViewStyleLarge;
#endif
    [_loadingCard.contentView addSubview:self.loadingSpinner];

    _loadingLabel = [[UILabel alloc] init];
    _loadingLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _loadingLabel.text = @"Just a moment…";
    _loadingLabel.textColor = UIColor.labelColor;
    UIFontTextStyle loadingTextStyle = TARGET_OS_TV ? UIFontTextStyleTitle2 : UIFontTextStyleHeadline;
    _loadingLabel.font = [[UIFontMetrics metricsForTextStyle:loadingTextStyle]
        scaledFontForFont:[UIFont systemFontOfSize:labelFontSize weight:UIFontWeightSemibold]];
    _loadingLabel.adjustsFontForContentSizeCategory = YES;
    _loadingLabel.textAlignment = NSTextAlignmentCenter;
    [_loadingCard.contentView addSubview:_loadingLabel];

    [NSLayoutConstraint activateConstraints:@[
        [_loadingCard.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_loadingCard.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [_loadingCard.widthAnchor constraintEqualToConstant:cardWidth],
        [_loadingCard.heightAnchor constraintEqualToConstant:cardHeight],
        [self.loadingSpinner.centerXAnchor constraintEqualToAnchor:_loadingCard.contentView.centerXAnchor],
        [self.loadingSpinner.topAnchor constraintEqualToAnchor:_loadingCard.contentView.topAnchor constant:spinnerTop],
        [_loadingLabel.leadingAnchor constraintEqualToAnchor:_loadingCard.contentView.leadingAnchor constant:16.0],
        [_loadingLabel.trailingAnchor constraintEqualToAnchor:_loadingCard.contentView.trailingAnchor constant:-16.0],
        [_loadingLabel.topAnchor constraintEqualToAnchor:self.loadingSpinner.bottomAnchor constant:labelSpacing],
    ]];

    self.view.accessibilityLabel = @"Loading";
    self.view.accessibilityHint = @"Please wait";
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

- (void)showLoadingFrame:(void (^)(void))completion {
    if (!presented) {
        Log(LOG_I, @"Loading frame presenting start");
        presented = YES;
        [self.loadingSpinner startAnimating];
        [[self activeViewController] presentViewController:self animated:NO completion:^{
            Log(LOG_I, @"Loading frame presenting complete");
            UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, self->_loadingLabel);
            if (completion) {
                completion();
            }
        }];
    }
    else if (completion) {
        Log(LOG_E, @"Loading frame already shown!");
        completion();
    }
}

- (void)dismissLoadingFrame:(void (^)(void))completion {
    if (presented) {
        Log(LOG_I, @"Loading frame hiding start");
        [self dismissViewControllerAnimated:NO completion:^{
            Log(LOG_I, @"Loading frame hiding complete");
            
            // Since presented is set to NO here rather than
            // immediately in dismissLoadingFrame, we may
            // falsely avoid displaying the loading frame if
            // a dismiss is in progress while attempting to show
            // the frame. That's preferable to crashing due to
            // displaying the same VC twice though.
            //
            // This scenario can happen if the app is suspended
            // while the dismiss is in progress then on resume
            // it attempts to display it again before the dismiss
            // completes. It can be reproduced by rapidly pressing
            // Home and switching back to Moonlight while in the app grid.
            // It reproduces more easily if the VC transitions are animated.
            self->presented = NO;
            [self.loadingSpinner stopAnimating];
            
            if (completion) {
                completion();
            }
        }];
    }
    else if (completion) {
        completion();
    }
}

- (BOOL)isShown {
    return presented;
}

@end
