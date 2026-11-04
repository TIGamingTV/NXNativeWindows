// The in-game menu for the Windows build: a UIKit port of dm/ios/Sources/GameMenu.swift (the menu button at the top centre of the touch controls opens it, DmGamepad.m).
// It holds the controller layout, the touch controls' layout editor (DmPadEditor.m), then the settings-screen settings the running game takes at once (front_ios.m dm_setting_live),
// grouped as on the settings screen but without its headings, one row each. A pick is saved as Play saves it (DmLauncherModel choose:), so the settings screen shows it at the
// next start; a setting an env file fixes is shown, not changed. Settings that need the next start, and the sliders, stay on the settings screen, which the menu's title points to.
#import <UIKit/UIKit.h>
#import "Launcher.h"
#import "DmGameMenu.h"

static UIMenuElement *menu_row(DmLauncherModel *m, DmSetting *s) {
    NSString *now = [m value:s]; BOOL fixed = [m locked:s];
    UIMenuElementAttributes at = fixed ? UIMenuElementAttributesDisabled : 0;
    if ([s.kind isEqualToString:@"toggle"]) {
        BOOL on = [now isEqualToString:s.onValue];
        UIAction *a = [UIAction actionWithTitle:s.label image:nil identifier:nil handler:^(UIAction *x) {
            NSString *v = on ? s.offValue : s.onValue; [m choose:s value:v]; dm_setting_live(s.env.UTF8String, v.UTF8String);
        }];
        a.attributes = at; a.state = on ? UIMenuElementStateOn : UIMenuElementStateOff;
        if (fixed) a.subtitle = @"Set in env.txt";
        return a;
    }
    NSMutableArray *acts = [NSMutableArray array];
    for (NSArray<NSString *> *o in s.options) {
        UIAction *a = [UIAction actionWithTitle:o[1] image:nil identifier:nil handler:^(UIAction *x) { [m choose:s value:o[0]]; dm_setting_live(s.env.UTF8String, o[0].UTF8String); }];
        a.attributes = at; a.state = [o[0] isEqualToString:now] ? UIMenuElementStateOn : UIMenuElementStateOff;
        [acts addObject:a];
    }
    UIMenu *mn = [UIMenu menuWithTitle:s.label image:nil identifier:nil options:UIMenuOptionsSingleSelection children:acts];
    if (fixed) mn.subtitle = [NSString stringWithFormat:@"%@, set in env.txt", [m choiceLabel:s]];
    return mn;
}

static NSArray<UIMenuElement *> *menu_items(void) {
    static NSString *const names[] = {@"2D", @"3D", @"Tap"};
    NSMutableArray *layouts = [NSMutableArray array];
    for (int l = 0; l < 3; l++) {
        if (!dm_pad_layout_offered(l)) continue;
        UIAction *a = [UIAction actionWithTitle:names[l] image:nil identifier:nil handler:^(UIAction *x) { dm_pad_layout_set(l); }];
        a.state = dm_pad_layout() == l ? UIMenuElementStateOn : UIMenuElementStateOff;
        [layouts addObject:a];
    }
    // a choice's value shows in its submenu: a subtitle would make each row two lines
    UIMenu *layout = [UIMenu menuWithTitle:@"Controller layout" image:nil identifier:nil options:UIMenuOptionsSingleSelection children:layouts];
    UIAction *edit = [UIAction actionWithTitle:@"Edit touch controls…" image:[UIImage systemImageNamed:@"square.and.pencil"] identifier:nil handler:^(UIAction *x) { dm_pad_edit_begin(); }];
    if (!dm_pad_edit_offered()) edit.attributes = UIMenuElementAttributesDisabled;
    NSArray *controls = @[layout, edit];
    NSMutableArray *items = [NSMutableArray array];
    BOOL placed = NO;
    DmLauncherModel *m = nxw_launcher_model();
    for (NSString *sec in m.sections) {
        NSMutableArray *rows = [NSMutableArray array];
        if ([sec isEqualToString:@"Controls"]) { [rows addObjectsFromArray:controls]; placed = YES; }
        for (DmSetting *s in [m inSection:sec])
            if (([s.kind isEqualToString:@"choice"] || [s.kind isEqualToString:@"toggle"]) && !s.disabled && dm_setting_live(s.env.UTF8String, NULL)) [rows addObject:menu_row(m, s)];
        if (rows.count) [items addObject:[UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:rows]];
    }
    if (!placed) [items insertObject:[UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:controls] atIndex:0];
    return items;
}

void *dm_game_menu(void) {   // a retained UIMenu, its items built each time it opens, so it shows the current choices
    NSString *title = nxw_launcher_model() ? @"More settings on the start screen" : @"";
    UIDeferredMenuElement *d = [UIDeferredMenuElement elementWithUncachedProvider:^(void (^done)(NSArray<UIMenuElement *> *)) { done(menu_items()); }];
    return (__bridge_retained void *)[UIMenu menuWithTitle:title children:@[d]];
}
