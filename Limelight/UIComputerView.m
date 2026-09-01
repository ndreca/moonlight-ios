//
//  UIComputerView.m
//  Moonlight
//
//  Created by Diego Waxemberg on 10/22/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "UIComputerView.h"

@implementation UIComputerView {
    TemporaryHost* _host;
    UIImageView* _hostIcon;
    UILabel* _hostLabel;
    UIImageView* _hostOverlay;
    UIActivityIndicatorView* _hostSpinner;
    UILabel* _hostStateLabel;
    id<HostCallback> _callback;
    CGSize _labelSize;
}
static const float REFRESH_CYCLE = 2.0f;

#if TARGET_OS_TV
static const int ITEM_PADDING = 50;
static const int LABEL_DY = 40;
#endif

- (id) init {
    self = [super init];
        
#if TARGET_OS_TV
    self.frame = CGRectMake(0, 0, 400, 400);
#else
    self.frame = CGRectMake(0, 0, 176, 156);
    self.backgroundColor = [UIColor colorWithRed:0.095 green:0.105 blue:0.130 alpha:1.0];
    self.layer.cornerRadius = 18.0;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.layer.borderWidth = 1.0;
    self.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.08].CGColor;
    self.clipsToBounds = NO;
#endif
    
    _hostIcon = [[UIImageView alloc] initWithFrame:self.frame];
    [_hostIcon setImage:[UIImage imageNamed:@"Computer"]];
    
    self.layer.shadowColor = [[UIColor blackColor] CGColor];
    self.layer.shadowOffset = CGSizeMake(0, 8);
    self.layer.shadowRadius = 14.0;
    self.layer.shadowOpacity = 0.24;

    [self addTarget:self action:@selector(hostButtonSelected:) forControlEvents:UIControlEventTouchDown];
    [self addTarget:self action:@selector(hostButtonDeselected:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchCancel | UIControlEventTouchDragExit];
    
    _hostLabel = [[UILabel alloc] init];
    _hostLabel.textColor = [UIColor whiteColor];
#if TARGET_OS_TV
    _hostLabel.font = [UIFont systemFontOfSize:24 weight:UIFontWeightSemibold];
#else
    _hostLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleHeadline]
        scaledFontForFont:[UIFont systemFontOfSize:15 weight:UIFontWeightSemibold]];
#endif
    _hostLabel.textAlignment = NSTextAlignmentCenter;
    _hostLabel.adjustsFontForContentSizeCategory = YES;
    _hostLabel.numberOfLines = 1;
    _hostLabel.lineBreakMode = NSLineBreakByTruncatingTail;

    _hostStateLabel = [[UILabel alloc] init];
    _hostStateLabel.textColor = [UIColor colorWithWhite:0.72 alpha:1.0];
    _hostStateLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption1]
        scaledFontForFont:[UIFont systemFontOfSize:12 weight:UIFontWeightMedium]];
    _hostStateLabel.textAlignment = NSTextAlignmentCenter;
    _hostStateLabel.adjustsFontForContentSizeCategory = YES;
#if TARGET_OS_TV
    _hostStateLabel.hidden = YES;
#endif
    
    _hostOverlay = [[UIImageView alloc] initWithFrame:CGRectMake(self.frame.size.width / 3, _hostIcon.frame.size.height / 4, _hostIcon.frame.size.width / 3, self.frame.size.height / 3)];
    _hostSpinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    _hostSpinner.color = [UIColor whiteColor];
    [_hostSpinner setFrame:_hostOverlay.frame];
    _hostSpinner.userInteractionEnabled = NO;
    _hostSpinner.hidesWhenStopped = YES;

    [self addSubview:_hostLabel];
    [self addSubview:_hostStateLabel];
    [self addSubview:_hostIcon];
    
#if TARGET_OS_TV
    _hostIcon.clipsToBounds = NO;
    _hostIcon.adjustsImageWhenAncestorFocused = YES;
    _hostIcon.masksFocusEffectToContents = YES;
    
    self.adjustsImageWhenHighlighted = NO;
    
    _hostOverlay.masksFocusEffectToContents = YES;
    _hostOverlay.adjustsImageWhenAncestorFocused = NO;
    
    [_hostIcon.overlayContentView addSubview:_hostOverlay];
    [_hostIcon.overlayContentView addSubview:_hostSpinner];
#else
    [self addSubview:_hostOverlay];
    [self addSubview:_hostSpinner];

    _hostIcon.isAccessibilityElement = NO;
    _hostOverlay.isAccessibilityElement = NO;
    _hostSpinner.isAccessibilityElement = NO;
    _hostLabel.isAccessibilityElement = NO;
    _hostStateLabel.isAccessibilityElement = NO;

    self.isAccessibilityElement = YES;
    self.accessibilityTraits = UIAccessibilityTraitButton;
    
    if (@available(iOS 13.4.1, *)) {
        // Allow the button style to change when moused over
        self.pointerInteractionEnabled = YES;
    }
#endif
    
    return self;
}

- (void) hostButtonSelected:(id)sender {
#if TARGET_OS_TV
    _hostIcon.layer.opacity = 0.5f;
    _hostSpinner.layer.opacity = 0.5f;
    _hostOverlay.layer.opacity = 0.5f;
#else
    [UIView animateWithDuration:0.12 animations:^{
        self.transform = CGAffineTransformMakeScale(0.97, 0.97);
        self.alpha = 0.82;
    }];
#endif
}
- (void) hostButtonDeselected:(id)sender {
#if TARGET_OS_TV
    _hostIcon.layer.opacity = 1.0f;
    _hostSpinner.layer.opacity = 1.0f;
    _hostOverlay.layer.opacity = 1.0f;
#else
    [UIView animateWithDuration:0.18 animations:^{
        self.transform = self.isFocused ? CGAffineTransformMakeScale(1.045, 1.045) : CGAffineTransformIdentity;
        self.alpha = 1.0;
    }];
#endif
}

- (id) initForAddWithCallback:(id<HostCallback>)callback {
    self = [self init];
    _callback = callback;
    
    [self addTarget:self action:@selector(addClicked) forControlEvents:UIControlEventPrimaryActionTriggered];
    
#if TARGET_OS_TV
    [_hostLabel setText:@"Add Host Manually"];
    [_hostLabel sizeToFit];
#else
    [_hostLabel setText:@"Add computer"];
#endif
    _hostStateLabel.text = @"Enter an address";
    self.accessibilityLabel = @"Add computer";
    self.accessibilityHint = @"Enter a computer address manually";
    self.accessibilityIdentifier = @"host.add";
    
    [_hostOverlay setImage:[UIImage imageNamed:@"AddOverlayIcon"]];
    
    [self updateBounds];
        
    return self;
}

- (id) initWithComputer:(TemporaryHost*)host andCallback:(id<HostCallback>)callback {
    self = [self init];
    _host = host;
    _callback = callback;
    
    // Use UIContextMenuInteraction on iOS 13.0+ and a standard UILongPressGestureRecognizer
    // for tvOS devices and iOS prior to 13.0.
#if !TARGET_OS_TV
    if (@available(iOS 13.0, *)) {
        UIContextMenuInteraction* rightClickInteraction = [[UIContextMenuInteraction alloc] initWithDelegate:self];
        [self addInteraction:rightClickInteraction];
    }
    else
#endif
    {
        UILongPressGestureRecognizer* longPressRecognizer = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(hostLongClicked:)];
        [self addGestureRecognizer:longPressRecognizer];
    }
    
    [self addTarget:self action:@selector(hostClicked) forControlEvents:UIControlEventPrimaryActionTriggered];
    
    [self updateContentsForHost:host];

    return self;
}

- (void)didMoveToSuperview {
    // Start our update loop when we are added to our cell
    if (self.superview != nil && _host != nil) {
        [self updateLoop];
    }
}

- (void) updateBounds {
#if !TARGET_OS_TV
    [self setNeedsLayout];
    return;
#else
    float x = FLT_MAX;
    float y = FLT_MAX;
    float width = 0;
    float height;
    
    float iconX = _hostIcon.frame.origin.x + _hostIcon.frame.size.width / 2;
    _hostLabel.center = CGPointMake(iconX, _hostIcon.frame.origin.y + _hostIcon.frame.size.height + LABEL_DY);
    
    x = MIN(x, _hostIcon.frame.origin.x);
    x = MIN(x, _hostLabel.frame.origin.x);
    
    y = MIN(y, _hostIcon.frame.origin.y);
    y = MIN(y, _hostLabel.frame.origin.y);

    width = MAX(width, _hostIcon.frame.size.width);
    width = MAX(width, _hostLabel.frame.size.width);
    
    height = _hostIcon.frame.size.height +
        _hostLabel.frame.size.height +
        LABEL_DY / 2;
    
    self.bounds = CGRectMake(x - ITEM_PADDING, y - ITEM_PADDING, width + 2 * ITEM_PADDING, height + 2 * ITEM_PADDING);
#endif
}

- (void) updateContentsForHost:(TemporaryHost*)host {
    _hostLabel.text = _host.name;
#if TARGET_OS_TV
    [_hostLabel sizeToFit];
#endif
    self.accessibilityLabel = _host.name;
    self.accessibilityIdentifier = [NSString stringWithFormat:@"host.%@", _host.uuid ?: _host.name];
    
    if (host.state == StateOnline) {
        [_hostSpinner stopAnimating];

        if (host.pairState == PairStateUnpaired) {
            [_hostOverlay setImage:[UIImage imageNamed:@"LockedOverlayIcon"]];
            _hostStateLabel.text = @"Needs pairing";
            self.accessibilityValue = @"Online, not paired";
        }
        else {
            [_hostOverlay setImage:nil];
            _hostStateLabel.text = @"Ready";
            self.accessibilityValue = @"Online and ready";
        }
    }
    else if (host.state == StateOffline) {
        [_hostSpinner stopAnimating];
        [_hostOverlay setImage:[UIImage imageNamed:@"ErrorOverlayIcon"]];
        _hostStateLabel.text = @"Offline";
        self.accessibilityValue = @"Offline";
    }
    else {
        [_hostSpinner startAnimating];
        _hostStateLabel.text = @"Checking…";
        self.accessibilityValue = @"Checking connection";
    }
    
    [self updateBounds];
}

- (void)layoutSubviews {
    [super layoutSubviews];

#if !TARGET_OS_TV
    CGFloat textWidth = self.bounds.size.width - 24.0;
    CGFloat labelHeight = MAX(21.0, ceil([_hostLabel sizeThatFits:CGSizeMake(textWidth, CGFLOAT_MAX)].height));
    CGFloat stateHeight = MAX(18.0, ceil([_hostStateLabel sizeThatFits:CGSizeMake(textWidth, CGFLOAT_MAX)].height));
    CGFloat availableIconHeight = self.bounds.size.height - labelHeight - stateHeight - 28.0;
    CGFloat iconSize = MIN(88.0, MAX(48.0, availableIconHeight));
    _hostIcon.frame = CGRectMake((self.bounds.size.width - iconSize) * 0.5, 14.0, iconSize, iconSize);
    _hostIcon.contentMode = UIViewContentModeScaleAspectFit;

    CGFloat overlaySize = iconSize * 0.34;
    _hostOverlay.frame = CGRectMake(CGRectGetMidX(_hostIcon.frame) - overlaySize * 0.5,
                                    CGRectGetMidY(_hostIcon.frame) - overlaySize * 0.5,
                                    overlaySize,
                                    overlaySize);
    _hostOverlay.contentMode = UIViewContentModeScaleAspectFit;
    _hostSpinner.frame = _hostOverlay.frame;

    _hostLabel.frame = CGRectMake(12.0, CGRectGetMaxY(_hostIcon.frame) + 5.0, textWidth, labelHeight);
    _hostStateLabel.frame = CGRectMake(12.0, CGRectGetMaxY(_hostLabel.frame) + 1.0, textWidth, stateHeight);

    self.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:self.bounds cornerRadius:self.layer.cornerRadius].CGPath;
#endif
}

- (BOOL)canBecomeFocused {
    return self.enabled && !self.hidden;
}

- (void)setControllerHighlighted:(BOOL)highlighted {
#if !TARGET_OS_TV
    self.transform = highlighted ? CGAffineTransformMakeScale(1.045, 1.045) : CGAffineTransformIdentity;
    self.layer.borderWidth = highlighted ? 3.0 : 1.0;
    self.layer.borderColor = highlighted
        ? [UIColor colorWithRed:0.55 green:0.48 blue:0.96 alpha:1.0].CGColor
        : [UIColor colorWithWhite:1.0 alpha:0.08].CGColor;
    self.layer.shadowOpacity = highlighted ? 0.48 : 0.24;
#endif
}

- (void)didUpdateFocusInContext:(UIFocusUpdateContext *)context withAnimationCoordinator:(UIFocusAnimationCoordinator *)coordinator {
    [super didUpdateFocusInContext:context withAnimationCoordinator:coordinator];

#if !TARGET_OS_TV
    BOOL focused = context.nextFocusedView == self;
    [coordinator addCoordinatedAnimations:^{
        [self setControllerHighlighted:focused];
    } completion:nil];
#endif
}

- (void) updateLoop {
    // Stop immediately if the view has been detached
    if (self.superview == nil) {
        return;
    }
    
    [self updateContentsForHost:_host];
    
    // Queue the next refresh cycle
    [self performSelector:@selector(updateLoop) withObject:self afterDelay:REFRESH_CYCLE];
}

- (void) hostLongClicked:(UILongPressGestureRecognizer*)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) {
        [_callback hostLongClicked:_host view:self];
    }
}

#if !TARGET_OS_TV
- (UIContextMenuConfiguration *)contextMenuInteraction:(UIContextMenuInteraction *)interaction
                        configurationForMenuAtLocation:(CGPoint)location {
    // We don't want to trigger the primary action at this point, so cancel
    // tracking touch on this view now. This will also have the (intended)
    // effect of removing the touch highlight on this view.
    [self cancelTrackingWithEvent:nil];
    
    [_callback hostLongClicked:_host view:self];
    return nil;
}
#endif

- (void) hostClicked {
    [_callback hostClicked:_host view:self];
}

- (void) addClicked {
    [_callback addHostClicked];
}

@end
