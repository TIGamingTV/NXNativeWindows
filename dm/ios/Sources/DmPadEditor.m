// The touch controls' layout editor: the saved layouts, the toolbar and the shortcut sheet (DmPadEditor.h). DmGamepad.m places, draws and drags the controls.
#import "DmPadEditor.h"

static NSString *const k_control_names[PC_N] = {@"ZL", @"L", @"ZR", @"R", @"−", @"+", @"L3", @"R3", @"A B X Y", @"D-pad", @"Left stick", @"Menu button"};
NSString *dm_pad_control_name(DmPadControl c) { return c >= 0 && c < PC_N ? k_control_names[c] : @"?"; }
static NSString *const k_button_names[DM_PAD_SHORTCUT_BUTTONS] = {@"A", @"B", @"X", @"Y", @"L3", @"R3", @"L", @"R", @"ZL", @"ZR", @"+", @"−", @"←", @"↑", @"→", @"↓"};
NSString *dm_pad_button_name(int bit) { return bit >= 0 && bit < DM_PAD_SHORTCUT_BUTTONS ? k_button_names[bit] : @"?"; }

@implementation DmPadItem
- (instancetype)init { if ((self = [super init])) { _pos = CGPointMake(-1, -1); _scale = 1; } return self; }
@end

@implementation DmPadShortcut
- (instancetype)init { if ((self = [super init])) { _title = @""; _scale = 1; _pos = CGPointMake(0.5, 0.5); } return self; }
- (NSString *)shownTitle {
    if (self.title.length) return self.title;
    NSMutableArray *n = [NSMutableArray array];
    for (int b = 0; b < DM_PAD_SHORTCUT_BUTTONS; b++) if (self.buttons >> b & 1) [n addObject:dm_pad_button_name(b)];
    return n.count ? [n componentsJoinedByString:@"+"] : @"?";
}
@end

static CGFloat num(id v, CGFloat def) { return [v isKindOfClass:NSNumber.class] && isfinite([v doubleValue]) ? [v doubleValue] : def; }
static CGFloat clamp01(CGFloat v) { return fmin(fmax(v, 0), 1); }
static CGFloat clamp_scale(CGFloat v) { return fmin(fmax(v, 0.5), 2.0); }

@implementation DmPadCustom
+ (instancetype)loadForLayout:(int)layout separated:(BOOL)separated {
    DmPadCustom *c = [DmPadCustom new];
    c.key = [NSString stringWithFormat:@"DmPadCustom.%@.%@", layout == 1 ? @"3D" : @"2D", separated ? @"split" : @"overlay"];
    c.items = [NSMutableArray array]; c.shortcuts = [NSMutableArray array];
    for (int i = 0; i < PC_N; i++) [c.items addObject:[DmPadItem new]];
    NSDictionary *d = [NSUserDefaults.standardUserDefaults dictionaryForKey:c.key];
    NSDictionary *items = [d[@"items"] isKindOfClass:NSDictionary.class] ? d[@"items"] : nil;
    for (int i = 0; i < PC_N; i++) {   // by name, so a control added later keeps the standard place
        NSDictionary *e = items[k_control_names[i]]; if (![e isKindOfClass:NSDictionary.class]) continue;
        DmPadItem *it = c.items[i];
        CGFloat x = num(e[@"x"], -1), y = num(e[@"y"], -1);
        if (x >= 0 && y >= 0) it.pos = CGPointMake(clamp01(x), clamp01(y));
        it.scale = clamp_scale(num(e[@"s"], 1));
        it.hidden = i != PC_MENU && [e[@"h"] isKindOfClass:NSNumber.class] && [e[@"h"] boolValue];   // the menu button always stays: it opens the menu that brings the others back
    }
    for (NSDictionary *e in [d[@"shortcuts"] isKindOfClass:NSArray.class] ? d[@"shortcuts"] : @[]) {
        if (![e isKindOfClass:NSDictionary.class]) continue;
        DmPadShortcut *s = [DmPadShortcut new];
        s.title = [e[@"t"] isKindOfClass:NSString.class] ? e[@"t"] : @"";
        s.buttons = (uint32_t)num(e[@"b"], 0) & ((1u << DM_PAD_SHORTCUT_BUTTONS) - 1);
        s.toggle = [e[@"m"] isKindOfClass:NSNumber.class] && [e[@"m"] boolValue];
        s.pos = CGPointMake(clamp01(num(e[@"x"], 0.5)), clamp01(num(e[@"y"], 0.5)));
        s.scale = clamp_scale(num(e[@"s"], 1));
        if (s.buttons) [c.shortcuts addObject:s];
    }
    return c;
}
- (void)save {
    NSMutableDictionary *items = [NSMutableDictionary dictionary];
    for (int i = 0; i < PC_N; i++) {
        DmPadItem *it = self.items[i]; NSMutableDictionary *e = [NSMutableDictionary dictionary];
        if (it.pos.x >= 0) { e[@"x"] = @(it.pos.x); e[@"y"] = @(it.pos.y); }
        if (fabs(it.scale - 1) > 1e-3) e[@"s"] = @(it.scale);
        if (it.hidden) e[@"h"] = @YES;
        if (e.count) items[k_control_names[i]] = e;
    }
    NSMutableArray *shortcuts = [NSMutableArray array];
    for (DmPadShortcut *s in self.shortcuts)
        [shortcuts addObject:@{@"t": s.title ?: @"", @"b": @(s.buttons), @"m": @(s.toggle), @"x": @(s.pos.x), @"y": @(s.pos.y), @"s": @(s.scale)}];
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    if (self.isStandard) [ud removeObjectForKey:self.key];
    else [ud setObject:@{@"items": items, @"shortcuts": shortcuts} forKey:self.key];
    NSLog(@"touch controls: layout %@ saved (%lu moved or resized, %lu shortcuts)", self.key, (unsigned long)items.count, (unsigned long)shortcuts.count);
}
- (void)resetAll {
    for (int i = 0; i < PC_N; i++) self.items[i] = [DmPadItem new];
    [self.shortcuts removeAllObjects];
}
- (BOOL)isStandard {
    if (self.shortcuts.count) return NO;
    for (DmPadItem *it in self.items) if (it.pos.x >= 0 || it.hidden || fabs(it.scale - 1) > 1e-3) return NO;
    return YES;
}
@end

// ---- The toolbar ----
@implementation DmPadEditorBar {
    __weak id<DmPadEditorHost> _host;
    UILabel *_name; UISlider *_size; UIButton *_hide, *_edit, *_delete;
}
static UIButton *bar_button(NSString *title, NSString *symbol, void (^act)(void)) {
    UIButtonConfiguration *c = [UIButtonConfiguration tintedButtonConfiguration];
    c.title = title; c.image = symbol ? [UIImage systemImageNamed:symbol] : nil; c.imagePadding = 4; c.buttonSize = UIButtonConfigurationSizeSmall;
    c.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    UIButton *b = [UIButton buttonWithConfiguration:c primaryAction:[UIAction actionWithHandler:^(UIAction *a) { act(); }]];
    return b;
}
- (instancetype)initWithHost:(id<DmPadEditorHost>)host {
    if (!(self = [super initWithFrame:CGRectZero])) return nil;
    _host = host;
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    UIVisualEffectView *bg = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterialDark]];
    bg.frame = self.bounds; bg.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    bg.layer.cornerRadius = 14; bg.clipsToBounds = YES; [self addSubview:bg];
    __weak DmPadEditorBar *w = self;
    _name = [UILabel new]; _name.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold]; _name.textColor = UIColor.whiteColor;
    _name.text = @"Drag a control to move it"; [_name setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    _size = [UISlider new]; _size.minimumValue = 0.5; _size.maximumValue = 2.0; _size.value = 1;
    [_size.widthAnchor constraintEqualToConstant:120].active = YES;
    [_size addAction:[UIAction actionWithHandler:^(UIAction *a) { DmPadEditorBar *me = w; if (me) [me->_host editorScale:me->_size.value]; }] forControlEvents:UIControlEventValueChanged];
    _hide = bar_button(@"Hide", @"eye.slash", ^{ DmPadEditorBar *me = w; [me->_host editorToggleHidden]; });
    _edit = bar_button(@"Buttons…", @"slider.horizontal.3", ^{ DmPadEditorBar *me = w; [me->_host editorEditSelected]; });
    _delete = bar_button(@"Delete", @"trash", ^{ DmPadEditorBar *me = w; [me->_host editorDeleteSelected]; });
    UIButton *add = bar_button(@"Shortcut", @"plus.circle", ^{ DmPadEditorBar *me = w; [me->_host editorAddShortcut]; });
    UIButton *reset = bar_button(@"Reset", @"arrow.counterclockwise", ^{ DmPadEditorBar *me = w; [me->_host editorResetAll]; });
    UIButton *done = bar_button(@"Done", @"checkmark", ^{ DmPadEditorBar *me = w; [me->_host editorDone]; });
    UIButtonConfiguration *dc = done.configuration; dc.baseBackgroundColor = UIColor.systemGreenColor; done.configuration = dc;
    UIStackView *row1 = [[UIStackView alloc] initWithArrangedSubviews:@[_name, _size, _hide, _edit, _delete]];
    UIStackView *row2 = [[UIStackView alloc] initWithArrangedSubviews:@[add, reset, done]];
    for (UIStackView *r in @[row1, row2]) { r.axis = UILayoutConstraintAxisHorizontal; r.spacing = 8; r.alignment = UIStackViewAlignmentCenter; }
    UIStackView *col = [[UIStackView alloc] initWithArrangedSubviews:@[row1, row2]];
    col.axis = UILayoutConstraintAxisVertical; col.spacing = 6; col.alignment = UIStackViewAlignmentCenter; col.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:col];
    [NSLayoutConstraint activateConstraints:@[[col.topAnchor constraintEqualToAnchor:self.topAnchor constant:8], [col.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-8],
        [col.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:10], [col.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-10]]];
    [self showSelection:nil scale:1 hideable:NO shortcut:NO hidden:NO];
    return self;
}
- (void)showSelection:(NSString *)name scale:(CGFloat)scale hideable:(BOOL)hideable shortcut:(BOOL)shortcut hidden:(BOOL)hidden {
    _name.text = name ?: @"Drag a control to move it";
    _size.hidden = !name; _size.value = (float)scale;
    _hide.hidden = !name || !hideable || shortcut;
    UIButtonConfiguration *c = _hide.configuration; c.title = hidden ? @"Show" : @"Hide"; c.image = [UIImage systemImageNamed:hidden ? @"eye" : @"eye.slash"]; _hide.configuration = c;
    _edit.hidden = _delete.hidden = !shortcut;
}
@end

// ---- The shortcut sheet ----
@interface DmShortcutSheet : UITableViewController <UITextFieldDelegate>
@property (strong) DmPadShortcut *shortcut; @property BOOL isNew;
@property uint32_t buttons; @property BOOL toggle; @property (copy) NSString *name;
@property (copy) void (^done)(DmPadShortcut *);
@end
@implementation DmShortcutSheet
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.isNew ? @"New shortcut" : @"Shortcut";
    self.buttons = self.shortcut.buttons; self.toggle = self.shortcut.toggle; self.name = self.shortcut.title;
    __weak DmShortcutSheet *w = self;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel primaryAction:[UIAction actionWithHandler:^(UIAction *a) {
        [w dismissViewControllerAnimated:YES completion:nil]; }] menu:nil];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone primaryAction:[UIAction actionWithHandler:^(UIAction *a) {
        DmShortcutSheet *me = w; if (!me || !me.buttons) return;
        [me.view endEditing:YES];
        me.shortcut.buttons = me.buttons; me.shortcut.toggle = me.toggle; me.shortcut.title = [me.name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] ?: @"";
        void (^d)(DmPadShortcut *) = me.done; DmPadShortcut *s = me.shortcut;
        [me dismissViewControllerAnimated:YES completion:^{ if (d) d(s); }];
    }] menu:nil];
    [self updateDone];
}
- (void)updateDone { self.navigationItem.rightBarButtonItem.enabled = self.buttons != 0; }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 3; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return s == 0 ? 1 : s == 1 ? 2 : DM_PAD_SHORTCUT_BUTTONS; }
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s { return s == 0 ? @"Label" : s == 1 ? @"When touched" : @"Buttons it presses"; }
- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    if (s == 0) return @"Empty: the buttons it presses, joined with +.";
    if (s == 1) return @"Hold presses the buttons while your finger is on the shortcut. Toggle presses them with one tap and releases them with the next.";
    return @"Every button chosen is pressed at the same moment.";
}
static NSString *const k_button_long[DM_PAD_SHORTCUT_BUTTONS] = {@"A", @"B", @"X", @"Y", @"L3 (left stick press)", @"R3 (right stick press)", @"L", @"R", @"ZL", @"ZR", @"+ (Plus)", @"− (Minus)",
    @"D-pad left", @"D-pad up", @"D-pad right", @"D-pad down"};
static const int k_button_order[DM_PAD_SHORTCUT_BUTTONS] = {0, 1, 2, 3, 6, 7, 8, 9, 10, 11, 4, 5, 13, 15, 12, 14};   // A B X Y, L R ZL ZR, + −, L3 R3, up down left right
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    if (ip.section == 0) {
        UITextField *f = [UITextField new]; f.placeholder = @"For example: Dash"; f.text = self.name; f.delegate = self; f.clearButtonMode = UITextFieldViewModeWhileEditing;
        f.returnKeyType = UIReturnKeyDone; f.translatesAutoresizingMaskIntoConstraints = NO;
        [f addAction:[UIAction actionWithHandler:^(UIAction *a) { self.name = f.text; }] forControlEvents:UIControlEventEditingChanged];
        c.selectionStyle = UITableViewCellSelectionStyleNone; [c.contentView addSubview:f];
        UILayoutGuide *g = c.contentView.layoutMarginsGuide;
        [NSLayoutConstraint activateConstraints:@[[f.leadingAnchor constraintEqualToAnchor:g.leadingAnchor], [f.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],
            [f.topAnchor constraintEqualToAnchor:g.topAnchor], [f.bottomAnchor constraintEqualToAnchor:g.bottomAnchor], [c.contentView.heightAnchor constraintGreaterThanOrEqualToConstant:44]]];
        return c;
    }
    UIListContentConfiguration *cc = c.defaultContentConfiguration;
    if (ip.section == 1) { cc.text = ip.row ? @"Toggle" : @"Hold"; c.accessoryType = (ip.row == 1) == self.toggle ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone; }
    else { int b = k_button_order[ip.row]; cc.text = k_button_long[b]; c.accessoryType = self.buttons >> b & 1 ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone; }
    c.contentConfiguration = cc;
    return c;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == 1) self.toggle = ip.row == 1;
    else if (ip.section == 2) self.buttons ^= 1u << k_button_order[ip.row];
    else return;
    [tv reloadSections:[NSIndexSet indexSetWithIndex:ip.section] withRowAnimation:UITableViewRowAnimationNone];
    [self updateDone];
}
- (BOOL)textFieldShouldReturn:(UITextField *)f { [f resignFirstResponder]; return YES; }
@end

void dm_pad_shortcut_sheet(UIView *from, DmPadShortcut *shortcut, BOOL isNew, void (^done)(DmPadShortcut *)) {
    UIViewController *top = from.window.rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;
    if (!top) return;
    DmShortcutSheet *s = [[DmShortcutSheet alloc] initWithStyle:UITableViewStyleInsetGrouped];
    s.shortcut = shortcut; s.isNew = isNew; s.done = done;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:s];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    nav.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    [top presentViewController:nav animated:YES completion:nil];
}
