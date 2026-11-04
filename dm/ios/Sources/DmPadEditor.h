// The touch controls' layout editor (DmGamepad.m draws and moves the controls; DmPadEditor.m holds the saved layouts, the editor's toolbar and the shortcut sheet).
// Opened from the in-game menu ("Edit touch controls…", GameMenu.swift / win/ios/GameMenu.m): every control of the current layout (2D or 3D) can be dragged anywhere,
// resized and hidden, and shortcut buttons can be added that press a combination of buttons (held while the finger is down, or latched on and off with a tap).
// A layout is saved per controller layout (2D, 3D) and per arrangement (controls over the picture, or beside it: portrait and an iPhone Duo half folded), in NSUserDefaults
// (each game is its own app, so per game). Positions are kept as fractions of the view, so a layout follows the screen it is shown on; sizes as factors of the standard size.
#pragma once
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// The controls the editor moves, one each (the diamond, the D-pad and the stick move as one piece). The right stick of the 3D layout is not drawn and needs no place
typedef NS_ENUM(int, DmPadControl) { PC_ZL, PC_L, PC_ZR, PC_R, PC_MINUS, PC_PLUS, PC_LS, PC_RS, PC_FACE, PC_DPAD, PC_STICK, PC_MENU, PC_N };
NSString *dm_pad_control_name(DmPadControl c);

// The buttons a shortcut can press: the bit numbers DmGamepad.m and dm_input.h use (A, B, X, Y, L3, R3, L, R, ZL, ZR, +, −, then the D-pad)
enum { DM_PAD_SHORTCUT_BUTTONS = 16 };
NSString *dm_pad_button_name(int bit);

@interface DmPadItem : NSObject
@property CGPoint pos;   // centre as a fraction of the view; x < 0: the standard place
@property CGFloat scale; // 1: the standard size
@property BOOL hidden;
@end

@interface DmPadShortcut : NSObject
@property (copy) NSString *title;
@property uint32_t buttons;   // 1 << bit for each button pressed
@property BOOL toggle;        // a tap latches it on, the next tap off; otherwise held while touched
@property CGPoint pos;        // centre as a fraction of the view
@property CGFloat scale;
@property BOOL latched;       // toggle: on now (not saved)
- (NSString *)shownTitle;     // the title, or the buttons joined with + when it has none
@end

// One saved layout: the controls' places and the shortcuts
@interface DmPadCustom : NSObject
@property (strong) NSMutableArray<DmPadItem *> *items;   // PC_N, by DmPadControl
@property (strong) NSMutableArray<DmPadShortcut *> *shortcuts;
@property (copy) NSString *key;
+ (instancetype)loadForLayout:(int)layout separated:(BOOL)separated;   // layout: 0 = 2D, 1 = 3D
- (void)save;
- (void)resetAll;
- (BOOL)isStandard;
@end

// The editor's toolbar, shown over the controls while editing; DmGamepad.m owns it and answers its buttons
@protocol DmPadEditorHost <NSObject>
- (void)editorAddShortcut;
- (void)editorEditSelected;
- (void)editorDeleteSelected;
- (void)editorToggleHidden;
- (void)editorScale:(CGFloat)scale;
- (void)editorResetAll;
- (void)editorDone;
@end
@interface DmPadEditorBar : UIView
- (instancetype)initWithHost:(id<DmPadEditorHost>)host;
// what is selected: its name, its size, whether it can be hidden (not the menu button), whether it is a shortcut (edit, delete) and whether it is hidden now
- (void)showSelection:(nullable NSString *)name scale:(CGFloat)scale hideable:(BOOL)hideable shortcut:(BOOL)shortcut hidden:(BOOL)hidden;
@end

// The shortcut sheet: its title, buttons and mode. done is called with the edited shortcut (the same object), or not at all when the player cancels
void dm_pad_shortcut_sheet(UIView *from, DmPadShortcut *shortcut, BOOL isNew, void (^done)(DmPadShortcut *shortcut));

NS_ASSUME_NONNULL_END
