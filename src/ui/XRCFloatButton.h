// © 雾月星辰 & MLXC · github@XingChenRS
// XRCFloatButton.h — 自绘悬浮窗：单击开菜单、长按切速度、可拖拽。
// 图标为 base64 内嵌 JPEG（构建期零外部资源）。
#pragma once

#import <UIKit/UIKit.h>

@interface XRCFloatButton : UIView

+ (instancetype)shared;

// block：单击 = 打开菜单；长按 = 切换速度预设。
@property (nonatomic, copy) void (^onTap)(void);
@property (nonatomic, copy) void (^onLongPress)(void);

- (void)attachToWindow:(UIWindow *)window;
- (void)setHiddenState:(BOOL)hidden;
- (void)reloadAppearance;

@end
