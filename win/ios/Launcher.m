// Launcher for the Windows build: a UIKit port of dm/ios/Sources/Launcher.swift and LauncherSettings.swift (SwiftUI), so the app builds with clang alone (no Swift toolchain).
// Its look follows the SwiftUI launcher (upstream c13ddcf, the single settings screen): the game card on the left third (icon, name, version, Play); on the right two thirds an
// inset-grouped list with one section per settings section (Game, Controls, Performance) in table order, each row with its note under its label, choices as a menu button,
// ranges as a slider with a percentage, toggles as switches; then "Reset to tested defaults" and the memory available. Same contract: dm_show_launcher(view controller, done)
// shows the screen over the root view controller, puts every setting into the environment when Play is pressed and then calls done; it returns false (done is not called)
// when there is no launcher (no dm/launcher.json, DM_LAUNCHER=0, or a file it cannot read). Settings come from the app's dm/launcher.json (dm/games/settings.py): kind "choice"
// (options [[value, label]]), "range" (min / max / step, shown as a percentage) or "toggle" (on / off: the two values the variable takes, "1" / "0" when absent).
// A variable an env file set (DM_ENV_FILE_KEYS, main.m) is shown but kept. A row marked "disabled" (settings.tsv always/<condition>: listed for every game, but this one has
// nothing it acts on) is shown greyed out and never applied. Only a choice that differs from the game's default is kept, in NSUserDefaults under "launcher.<ENV>", as the Swift launcher does.
// Also a port of upstream's later additions: sub-settings drawn only while the row they need has its value ("needs"), values fixed by the launch environment (DM_ENV_LAUNCH_KEYS),
// DM_SAVED_CHOICES=0, DM_LAUNCHER=0 applying the saved choices, an app of several programs (DM_APP_DM: the running program's dm/p<N>), cloud saves (CloudSaves.h) and the model
// the in-game menu shows and saves (win/ios/GameMenu.m, GameMenu.swift's counterpart)
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "Launcher.h"
#import "CloudSaves.h"
#include <math.h>
#include <os/proc.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

@implementation DmSetting
- (NSString *)sectionTitle { return self.section.length ? self.section : @"Game"; }
- (NSString *)onValue { return self.on ?: @"1"; }
- (NSString *)offValue { return self.off ?: @"0"; }
- (BOOL)isDefault:(NSString *)v {   // a range compares as numbers (a slider writes 1.00 for 1.0)
    if ([self.kind isEqualToString:@"range"]) return fabs(v.doubleValue - self.def.doubleValue) < 1e-6;
    return [v isEqualToString:self.def];
}
- (BOOL)accepts:(NSString *)v {   // a saved choice the game still offers
    if ([self.kind isEqualToString:@"choice"]) return [self.options indexOfObjectPassingTest:^BOOL(NSArray *o, NSUInteger i, BOOL *stop) { return [o[0] isEqualToString:v]; }] != NSNotFound;
    if ([self.kind isEqualToString:@"range"]) {
        NSScanner *sc = [NSScanner scannerWithString:v]; double d;
        return [sc scanDouble:&d] && sc.isAtEnd && isfinite(d) && self.hasMin && self.hasMax && d >= self.min && d <= self.max;
    }
    if ([self.kind isEqualToString:@"toggle"]) return [v isEqualToString:self.onValue] || [v isEqualToString:self.offValue];
    return YES;
}
@end

static NSString *str(NSDictionary *d, NSString *k) { id v = d[k]; return [v isKindOfClass:NSString.class] ? v : nil; }

static NSArray<DmSetting *> *load_settings(NSData *data) {   // nil when the file does not decode (every row needs env, kind, label, note and default, as Launcher.swift's Decodable)
    id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![root isKindOfClass:NSDictionary.class] || ![root[@"settings"] isKindOfClass:NSArray.class]) return nil;
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *d in root[@"settings"]) {
        if (![d isKindOfClass:NSDictionary.class]) return nil;
        DmSetting *s = [DmSetting new];
        s.env = str(d, @"env"); s.kind = str(d, @"kind"); s.label = str(d, @"label"); s.note = str(d, @"note"); s.def = str(d, @"default");
        s.section = str(d, @"section"); s.on = str(d, @"on"); s.off = str(d, @"off"); s.needs = str(d, @"needs");
        if (!s.env || !s.kind || !s.label || !s.note || !s.def) return nil;
        if ([d[@"options"] isKindOfClass:NSArray.class]) {
            NSMutableArray *opts = [NSMutableArray array];
            for (id o in d[@"options"]) {
                if (![o isKindOfClass:NSArray.class] || [o count] < 2 || ![o[0] isKindOfClass:NSString.class] || ![o[1] isKindOfClass:NSString.class]) return nil;
                [opts addObject:@[o[0], o[1]]];
            }
            s.options = opts;
        }
        if ([d[@"min"] isKindOfClass:NSNumber.class]) { s.min = [d[@"min"] doubleValue]; s.hasMin = YES; }
        if ([d[@"max"] isKindOfClass:NSNumber.class]) { s.max = [d[@"max"] doubleValue]; s.hasMax = YES; }
        if ([d[@"step"] isKindOfClass:NSNumber.class]) { s.step = [d[@"step"] doubleValue]; s.hasStep = YES; }
        s.disabled = [d[@"disabled"] isKindOfClass:NSNumber.class] && [d[@"disabled"] boolValue];
        [out addObject:s];
    }
    return out;
}

static int increased_memory_limit(void);

// ---- model (LauncherSettings.swift's LauncherModel) ----
@interface DmLauncherModel ()
- (instancetype)initWith:(NSArray<DmSetting *> *)settings;
- (BOOL)changed;
- (void)reset;
- (void)apply;
- (void)applySaved;
@end
static DmLauncherModel *g_model;   // the in-game menu's (nxw_launcher_model)
DmLauncherModel *nxw_launcher_model(void) { return g_model; }
@implementation DmLauncherModel
- (instancetype)initWith:(NSArray<DmSetting *> *)settings {
    if (!(self = [super init])) return nil;
    _settings = settings; _values = [NSMutableDictionary dictionary];
    NSMutableArray *secs = [NSMutableArray array];
    for (DmSetting *s in settings) if (![secs containsObject:s.sectionTitle]) [secs addObject:s.sectionTitle];
    _sections = secs;
    NSDictionary *env = NSProcessInfo.processInfo.environment;
    NSMutableSet *fl = [NSMutableSet set], *ff = [NSMutableSet set];
    for (NSString *k in [env[@"DM_ENV_LAUNCH_KEYS"] ?: @"" componentsSeparatedByString:@" "]) if (k.length) [fl addObject:k];   // set at launch (main.m): shown, not changed
    [ff unionSet:fl];
    for (NSString *k in [env[@"DM_ENV_FILE_KEYS"] ?: @"" componentsSeparatedByString:@" "]) if (k.length) [ff addObject:k];
    _fromFile = ff; _fromLaunch = fl;
    _ignoreSaved = [env[@"DM_SAVED_CHOICES"] isEqualToString:@"0"];   // start from the defaults, and leave the saved choices as they are
    if (_ignoreSaved) fprintf(stderr, "launcher: saved choices ignored (DM_SAVED_CHOICES=0)\n");
    // A device with 6 GB of memory or less (an A16 iPad, an iPhone 15): the defaults that hold the least memory, Handheld (most games render 720p instead of 1080p) and,
    // where the game has a render-scale hook, 75 % of its 3D size. Only the defaults change: a choice the player made stays, and Reset brings back these
    if (NSProcessInfo.processInfo.physicalMemory <= 6.5 * 1024 * 1024 * 1024) {
        for (DmSetting *s in settings) {
            if (s.disabled) continue;
            NSString *was = s.def;
            if ([s.env isEqualToString:@"DM_OPMODE"] && [s.def isEqualToString:@"1"]) s.def = @"0";
            else if ([s.env isEqualToString:@"DM_RENDER_SCALE"] && s.def.doubleValue > 0.75) s.def = @"0.75";
            else if ([s.env isEqualToString:@"DM_NVN_TEX_DISCARD"] && ![s.def isEqualToString:@"1"] && !increased_memory_limit()) s.def = @"1";   // the textures' second copy ran TotK out of memory; with Increased Memory Limit, Automatic is enough
            // A 60 fps patch (Tears of the Kingdom: GPU p95 24-28 ms on an A16 iPad) swings between 40 and 60 there: the game's own 30 holds steady
            // Metal 4 pipelines keep an archive and prebuild every shader pair before the first frame ("Preparing pipelines": 20,017 pairs and about 850 MB more for TotK), past a 6 GB device's limit
            else if (([s.env isEqualToString:@"DM_PSO_MTL4"] || [s.env isEqualToString:@"DM_PSO_PREBUILD"]) && ![s.def isEqualToString:@"0"]) s.def = @"0";
            else if ([s.env isEqualToString:@"DM_FPS_TARGET"] && [s.def isEqualToString:@"60"] && [s.options indexOfObjectPassingTest:^BOOL(NSArray *o, NSUInteger i, BOOL *stop) { return [o[0] isEqualToString:@"30"]; }] != NSNotFound) s.def = @"30";
            if (![was isEqualToString:s.def]) {
                s.note = [s.note.length ? [s.note stringByAppendingString:@" "] : @"" stringByAppendingString:@"Lowered for this device's memory."];
                fprintf(stderr, "launcher: %s default %s → %s (%.1f GB device)\n", s.env.UTF8String, was.UTF8String, s.def.UTF8String, NSProcessInfo.processInfo.physicalMemory / 1073741824.0);
            }
        }
    }
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    // Once on a 6 GB device: a Metal 4 / prebuild choice saved by an earlier build goes back to the light default (it closed TotK for memory); the player can turn it on again
    if (NSProcessInfo.processInfo.physicalMemory <= 6.5 * 1024 * 1024 * 1024 && ![ud boolForKey:@"launcher.nxw_lowmem_v1"]) {
        for (NSString *k in @[@"DM_PSO_MTL4", @"DM_PSO_PREBUILD"]) [ud removeObjectForKey:[@"launcher." stringByAppendingString:k]];
        [ud setBool:YES forKey:@"launcher.nxw_lowmem_v1"];
    }
    for (DmSetting *s in settings) {
        NSString *envv = NSProcessInfo.processInfo.environment[s.env];
        if ([ff containsObject:s.env] && envv) { _values[s.env] = envv; continue; }
        id so = _ignoreSaved ? nil : [ud objectForKey:[@"launcher." stringByAppendingString:s.env]];
        NSString *saved = [so isKindOfClass:NSString.class] ? so : nil;   // a string, as launcher.c reads it
        _values[s.env] = (saved && [s accepts:saved]) ? saved : s.def;   // a saved choice the game no longer offers: its default
    }
    return self;
}
// A row with "needs" is a sub-setting of the row it names: drawn only while that setting has that value (LauncherSettings.swift visible); a row naming a setting this game does not
// have stays drawn
- (BOOL)visible:(DmSetting *)s {
    NSRange eq = s.needs ? [s.needs rangeOfString:@"="] : NSMakeRange(NSNotFound, 0);
    if (eq.location == NSNotFound) return YES;
    NSString *v = self.values[[s.needs substringToIndex:eq.location]];
    return !v || [v isEqualToString:[s.needs substringFromIndex:eq.location + 1]];
}
- (NSArray<DmSetting *> *)inSection:(NSString *)sec {
    return [self.settings filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(DmSetting *s, NSDictionary *b) { return [s.sectionTitle isEqualToString:sec] && [self visible:s]; }]];
}
- (NSString *)value:(DmSetting *)s { return self.values[s.env] ?: s.def; }
- (BOOL)locked:(DmSetting *)s { return s.disabled || [self.fromFile containsObject:s.env]; }
- (NSString *)note:(DmSetting *)s {
    if (s.disabled || ![self.fromFile containsObject:s.env]) return s.note;
    return [NSString stringWithFormat:@"%@Set by %@", s.note.length ? [s.note stringByAppendingString:@" · "] : @"", [self.fromLaunch containsObject:s.env] ? @"the launch environment" : @"an env file"];
}
- (double)rangeValue:(DmSetting *)s {
    NSString *v = [self value:s]; NSScanner *sc = [NSScanner scannerWithString:v]; double d;
    return ([sc scanDouble:&d] && sc.isAtEnd) ? d : (s.hasMax ? s.max : 1);
}
- (NSString *)percentage:(DmSetting *)s { return [NSString stringWithFormat:@"%ld %%", lround([self rangeValue:s] * 100)]; }
- (NSString *)choiceLabel:(DmSetting *)s {
    NSString *cur = [self value:s];
    for (NSArray *o in s.options) if ([o[0] isEqualToString:cur]) return o[1];
    return cur;
}
- (BOOL)changed {
    for (DmSetting *s in self.settings) if (!s.disabled && ![self.fromFile containsObject:s.env] && ![s isDefault:[self value:s]]) return YES;
    return NO;
}
// Every launcher choice back to the game's defaults on the screen; values fixed by an env file or at launch stay. The saved choices are forgotten when Play applies the defaults
// (apply keeps no default), so a choice a launch override hides is kept
- (void)reset {
    for (DmSetting *s in self.settings) if (![self.fromFile containsObject:s.env]) self.values[s.env] = s.def;
    fprintf(stderr, "launcher: settings reset to the game's defaults\n");
}
// Before the game starts: every setting not set by an env file goes into the environment (DM_LANG replaces the packed language main.m set as a default). Only a choice that
// differs from the game's default is stored: a setting the player left at its default follows the defaults of a later build (the settings it was tested with)
- (void)store:(DmSetting *)s value:(NSString *)v {
    if (self.ignoreSaved) return;
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults; NSString *key = [@"launcher." stringByAppendingString:s.env];
    if ([s isDefault:v]) [ud removeObjectForKey:key]; else [ud setObject:v forKey:key];
}
- (void)apply {
    for (DmSetting *s in self.settings) {
        NSString *v = [self value:s];
        if (s.disabled) continue;   // nothing in this game reads it
        if ([self.fromFile containsObject:s.env]) { fprintf(stderr, "launcher: %s kept at %s (%s)\n", s.env.UTF8String, v.UTF8String, [self.fromLaunch containsObject:s.env] ? "launch environment" : "env file"); continue; }
        [self store:s value:v];
        setenv(s.env.UTF8String, v.UTF8String, 1); fprintf(stderr, "launcher: %s=%s%s\n", s.env.UTF8String, v.UTF8String, [s isDefault:v] ? "" : " (changed)");
    }
}
// A choice made while the game runs (the in-game menu, GameMenu.m): saved as Play saves it, so the settings screen shows it at the next start, and put in the environment.
// A value an env file or the launch fixed stays
- (void)choose:(DmSetting *)s value:(NSString *)v {
    if ([self locked:s] || ![s accepts:v]) return;
    self.values[s.env] = v; [self store:s value:v]; setenv(s.env.UTF8String, v.UTF8String, 1);
    fprintf(stderr, "launcher: %s=%s (in-game menu)\n", s.env.UTF8String, v.UTF8String);
}
// DM_LAUNCHER=0: no screen, but the saved choices still apply (only DM_SAVED_CHOICES=0 ignores them); nothing is written
- (void)applySaved {
    for (DmSetting *s in self.settings) {
        if (s.disabled || [self.fromFile containsObject:s.env]) continue;
        NSString *v = [self value:s];
        if (![s isDefault:v]) { setenv(s.env.UTF8String, v.UTF8String, 1); fprintf(stderr, "launcher: %s=%s (saved choice)\n", s.env.UTF8String, v.UTF8String); }
    }
}
@end

static UILabel *body_label(NSString *text) {
    UILabel *l = [UILabel new]; l.text = text; l.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody]; l.textColor = UIColor.labelColor; l.numberOfLines = 0;
    l.translatesAutoresizingMaskIntoConstraints = NO;
    return l;
}

static UILabel *value_label(NSString *text) {
    UILabel *l = [UILabel new]; l.text = text; l.textColor = UIColor.secondaryLabelColor; l.textAlignment = NSTextAlignmentRight;
    l.font = [UIFont monospacedDigitSystemFontOfSize:[UIFont preferredFontForTextStyle:UIFontTextStyleBody].pointSize weight:UIFontWeightRegular];
    l.translatesAutoresizingMaskIntoConstraints = NO; [l setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [l setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    return l;
}

// The label column of a row: the setting's name, and its note in footnote style under it (SwiftUI's settingLabel)
static UIStackView *label_stack(NSString *title, NSString *note, BOOL locked) {
    UIStackView *st = [UIStackView new]; st.axis = UILayoutConstraintAxisVertical; st.spacing = 4; st.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *l = body_label(title); if (locked) l.textColor = UIColor.tertiaryLabelColor; [st addArrangedSubview:l];
    if (note.length) {
        UILabel *n = body_label(note); n.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote]; n.textColor = UIColor.secondaryLabelColor; [st addArrangedSubview:n];
    }
    return st;
}

// Increased Memory Limit: whether the signature the app was installed with carries com.apple.developer.kernel.increased-memory-limit (true). Read from the entitlements blob in the
// executable's own code signature, which is what iOS goes by: a signing tool for a free Apple ID (SideStore, AltStore) drops the entitlement, a paid developer account keeps it
static int increased_memory_limit(void) {
    static int v = -1;
    if (v >= 0) return v;
    NSData *d = [NSData dataWithContentsOfFile:NSBundle.mainBundle.executablePath options:NSDataReadingMappedIfSafe error:nil];
    NSData *key = [@"com.apple.developer.kernel.increased-memory-limit</key>" dataUsingEncoding:NSUTF8StringEncoding];
    v = 0;
    if (d.length) {
        NSRange r = [d rangeOfData:key options:NSDataSearchBackwards range:NSMakeRange(0, d.length)];   // the signature is at the end of the file
        if (r.location != NSNotFound) {
            NSUInteger at = NSMaxRange(r), n = MIN((NSUInteger)64, d.length - at);
            NSString *after = [[NSString alloc] initWithData:[d subdataWithRange:NSMakeRange(at, n)] encoding:NSASCIIStringEncoding];
            v = [[after stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] hasPrefix:@"<true/>"];
        }
    }
    fprintf(stderr, "launcher: Increased Memory Limit %s (the app's signature)\n", v ? "on" : "off");
    return v;
}

// ---- the settings list ----
@interface DmSettingsVC : UITableViewController <UIDocumentPickerDelegate>
@property (strong) DmLauncherModel *m; @property (strong) NSTimer *timer; @property (strong) UILabel *memory;
@property (copy) NSString *cloudNote;   // the Cloud saves footer after a pick (Launcher.swift CloudSavesSection)
@end
@implementation DmSettingsVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.backgroundColor = UIColor.clearColor;
    self.tableView.rowHeight = UITableViewAutomaticDimension; self.tableView.estimatedRowHeight = 56;
    __weak DmSettingsVC *w = self;
    self.timer = [NSTimer scheduledTimerWithTimeInterval:2 repeats:YES block:^(NSTimer *t) { w.memory.text = [NSByteCountFormatter stringFromByteCount:(long long)os_proc_available_memory() countStyle:NSByteCountFormatterCountStyleMemory]; }];
}
- (void)dealloc { [self.timer invalidate]; }
- (NSInteger)resetSection { return self.m.sections.count; }
- (NSInteger)cloudSection { return self.resetSection + 1; }
- (NSInteger)memorySection { return self.resetSection + 2; }
- (NSString *)cloudFolder:(BOOL *)stale { BOOL st = NO; NSString *f = dm_cloud_saves_path(&st); if (stale) *stale = st; return f ?: @""; }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return self.m.sections.count + 3; }   // the sections, Reset, Cloud saves, Memory available
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)sec {
    if (sec < (NSInteger)self.m.sections.count) return (NSInteger)[self.m inSection:self.m.sections[sec]].count;
    if (sec == self.cloudSection) return [self cloudFolder:NULL].length ? 3 : 2;
    return sec == self.memorySection ? 2 : 1;
}
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)sec { return sec < (NSInteger)self.m.sections.count ? self.m.sections[sec] : nil; }
- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)sec {
    if (sec == self.resetSection) return @"Brings back all settings this game was tested with.";
    if (sec == self.cloudSection) {
        BOOL stale = NO; NSString *f = [self cloudFolder:&stale];
        if (self.cloudNote.length) return self.cloudNote;
        if (stale && !f.length) return @"The folder you chose before is no longer readable (the app was signed differently). Please choose it again.";
        return @"Choose a folder in iCloud Drive, and the same one in the Mac app's Cloud saves. The save comes in when the game starts and goes out after each save; a save that is replaced is kept in save-backups.";
    }
    if (sec == self.memorySection && !increased_memory_limit())
        return @"Increased Memory Limit is off: iOS gives this app less memory, and a big game can be closed when an area loads. A free Apple ID cannot turn it on (the signing app drops it); a paid developer account can. Texture memory saver (Performance) helps meanwhile.";
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    c.selectionStyle = UITableViewCellSelectionStyleNone;
    UIView *v = c.contentView; UILayoutGuide *g = v.layoutMarginsGuide;
    if (ip.section == self.resetSection) {   // Reset to tested defaults: a button row, enabled while a choice differs from the defaults
        UIButtonConfiguration *cfg = [UIButtonConfiguration plainButtonConfiguration]; cfg.title = @"Reset to tested defaults"; cfg.contentInsets = NSDirectionalEdgeInsetsZero;
        __weak DmSettingsVC *w = self;
        UIButton *b = [UIButton buttonWithConfiguration:cfg primaryAction:[UIAction actionWithHandler:^(UIAction *a) { [w.m reset]; [w.tableView reloadData]; }]];
        b.enabled = self.m.changed; b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading; b.translatesAutoresizingMaskIntoConstraints = NO; [v addSubview:b];
        [NSLayoutConstraint activateConstraints:@[[b.leadingAnchor constraintEqualToAnchor:g.leadingAnchor], [b.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],
            [b.centerYAnchor constraintEqualToAnchor:v.centerYAnchor], [v.heightAnchor constraintGreaterThanOrEqualToConstant:48]]];
        return c;
    }
    if (ip.section == self.cloudSection) {   // Cloud saves: the folder, Choose, Turn off (Launcher.swift CloudSavesSection)
        NSString *f = [self cloudFolder:NULL];
        if (ip.row == 0) {
            UILabel *l = body_label(@"Cloud saves"), *st = value_label(f.length ? f.lastPathComponent : @"Off");
            st.lineBreakMode = NSLineBreakByTruncatingMiddle; [st setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
            [v addSubview:l]; [v addSubview:st];
            [NSLayoutConstraint activateConstraints:@[[l.leadingAnchor constraintEqualToAnchor:g.leadingAnchor], [l.centerYAnchor constraintEqualToAnchor:v.centerYAnchor],
                [st.leadingAnchor constraintGreaterThanOrEqualToAnchor:l.trailingAnchor constant:12],
                [st.trailingAnchor constraintEqualToAnchor:g.trailingAnchor], [st.centerYAnchor constraintEqualToAnchor:v.centerYAnchor], [v.heightAnchor constraintGreaterThanOrEqualToConstant:48]]];
            return c;
        }
        BOOL off = ip.row == 2;
        UIButtonConfiguration *cfg = [UIButtonConfiguration plainButtonConfiguration]; cfg.contentInsets = NSDirectionalEdgeInsetsZero;
        cfg.title = off ? @"Turn off cloud saves" : f.length ? @"Choose a different folder…" : @"Choose a folder in iCloud Drive…";
        if (off) cfg.baseForegroundColor = UIColor.systemRedColor;
        __weak DmSettingsVC *w = self;
        UIButton *b = [UIButton buttonWithConfiguration:cfg primaryAction:[UIAction actionWithHandler:^(UIAction *a) {
            DmSettingsVC *me = w; if (!me) return;
            if (off) { dm_clear_cloud_saves(); me.cloudNote = nil; [me.tableView reloadData]; return; }
            // .open (not a copy): the folder stays where it is and the bookmark keeps pointing at it
            UIDocumentPickerViewController *pk = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeFolder] asCopy:NO];
            pk.allowsMultipleSelection = NO; pk.delegate = me;
            [me presentViewController:pk animated:YES completion:nil];
        }]];
        b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading; b.translatesAutoresizingMaskIntoConstraints = NO; [v addSubview:b];
        [NSLayoutConstraint activateConstraints:@[[b.leadingAnchor constraintEqualToAnchor:g.leadingAnchor], [b.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],
            [b.centerYAnchor constraintEqualToAnchor:v.centerYAnchor], [v.heightAnchor constraintGreaterThanOrEqualToConstant:48]]];
        return c;
    }
    if (ip.section == self.memorySection && ip.row == 1) {   // Increased Memory Limit: On (green) / Off (orange)
        UILabel *l = body_label(@"Increased Memory Limit");
        int on = increased_memory_limit();
        UILabel *st = value_label(on ? @"● On" : @"● Off"); st.textColor = on ? UIColor.systemGreenColor : UIColor.systemOrangeColor;
        [v addSubview:l]; [v addSubview:st];
        [NSLayoutConstraint activateConstraints:@[[l.leadingAnchor constraintEqualToAnchor:g.leadingAnchor], [l.centerYAnchor constraintEqualToAnchor:v.centerYAnchor],
            [st.trailingAnchor constraintEqualToAnchor:g.trailingAnchor], [st.centerYAnchor constraintEqualToAnchor:v.centerYAnchor],
            [v.heightAnchor constraintGreaterThanOrEqualToConstant:48]]];
        return c;
    }
    if (ip.section == self.memorySection) {   // Memory available
        UILabel *l = body_label(@"Memory available");
        self.memory = value_label([NSByteCountFormatter stringFromByteCount:(long long)os_proc_available_memory() countStyle:NSByteCountFormatterCountStyleMemory]);
        [v addSubview:l]; [v addSubview:self.memory];
        [NSLayoutConstraint activateConstraints:@[[l.leadingAnchor constraintEqualToAnchor:g.leadingAnchor], [l.centerYAnchor constraintEqualToAnchor:v.centerYAnchor],
            [self.memory.trailingAnchor constraintEqualToAnchor:g.trailingAnchor], [self.memory.centerYAnchor constraintEqualToAnchor:v.centerYAnchor],
            [v.heightAnchor constraintGreaterThanOrEqualToConstant:48]]];
        return c;
    }
    DmSetting *s = [self.m inSection:self.m.sections[ip.section]][ip.row]; BOOL locked = [self.m locked:s];
    NSInteger tag = [self.m.settings indexOfObject:s];
    UIStackView *lab = label_stack(s.label, [self.m note:s], locked);
    NSMutableArray *cs = [NSMutableArray array];
    if ([s.kind isEqualToString:@"range"]) {   // label and percentage on one line, the slider under them (SwiftUI's VStack)
        UILabel *pct = value_label([self.m percentage:s]); pct.tag = 1000 + tag;
        UISlider *sl = [UISlider new]; sl.translatesAutoresizingMaskIntoConstraints = NO;
        sl.minimumValue = s.hasMin ? s.min : 0; sl.maximumValue = s.hasMax ? s.max : 1; sl.value = [self.m rangeValue:s];
        sl.enabled = !locked; sl.accessibilityLabel = s.label; sl.accessibilityValue = pct.text; sl.tag = tag;
        [sl addTarget:self action:@selector(slid:) forControlEvents:UIControlEventValueChanged];
        [sl addTarget:self action:@selector(slidEnd:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside];
        [v addSubview:lab]; [v addSubview:pct]; [v addSubview:sl];
        [cs addObjectsFromArray:@[[lab.leadingAnchor constraintEqualToAnchor:g.leadingAnchor], [lab.topAnchor constraintEqualToAnchor:g.topAnchor],
            [pct.leadingAnchor constraintGreaterThanOrEqualToAnchor:lab.trailingAnchor constant:12], [pct.trailingAnchor constraintEqualToAnchor:g.trailingAnchor], [pct.firstBaselineAnchor constraintEqualToAnchor:lab.firstBaselineAnchor],
            [sl.topAnchor constraintEqualToAnchor:lab.bottomAnchor constant:8], [sl.leadingAnchor constraintEqualToAnchor:g.leadingAnchor], [sl.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],
            [sl.bottomAnchor constraintEqualToAnchor:g.bottomAnchor]]];
    } else {
        UIView *ctl;
        if ([s.kind isEqualToString:@"choice"]) {   // SwiftUI's .menu Picker: the value with up / down chevrons, opening a menu
            UIButtonConfiguration *cfg = [UIButtonConfiguration plainButtonConfiguration];
            cfg.title = [self.m choiceLabel:s]; cfg.baseForegroundColor = UIColor.secondaryLabelColor;
            cfg.image = [UIImage systemImageNamed:@"chevron.up.chevron.down" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightSemibold]];
            cfg.imagePlacement = NSDirectionalRectEdgeTrailing; cfg.imagePadding = 5; cfg.contentInsets = NSDirectionalEdgeInsetsMake(6, 6, 6, 0);
            cfg.titleTextAttributesTransformer = ^NSDictionary *(NSDictionary *a) { NSMutableDictionary *m = [a mutableCopy]; m[NSFontAttributeName] = [UIFont preferredFontForTextStyle:UIFontTextStyleBody]; return m; };
            UIButton *b = [UIButton buttonWithConfiguration:cfg primaryAction:nil];
            b.showsMenuAsPrimaryAction = YES; b.changesSelectionAsPrimaryAction = NO; b.enabled = !locked;
            b.menu = [self menuFor:s button:b];
            ctl = b;
        } else {
            UISwitch *sw = [UISwitch new]; sw.on = [[self.m value:s] isEqualToString:s.onValue]; sw.enabled = !locked; sw.tag = tag;
            [sw addTarget:self action:@selector(toggled:) forControlEvents:UIControlEventValueChanged];
            ctl = sw;
        }
        ctl.translatesAutoresizingMaskIntoConstraints = NO;
        [ctl setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [v addSubview:lab]; [v addSubview:ctl];
        [cs addObjectsFromArray:@[[lab.leadingAnchor constraintEqualToAnchor:g.leadingAnchor], [lab.topAnchor constraintEqualToAnchor:g.topAnchor], [lab.bottomAnchor constraintEqualToAnchor:g.bottomAnchor],
            [ctl.leadingAnchor constraintGreaterThanOrEqualToAnchor:lab.trailingAnchor constant:12], [ctl.trailingAnchor constraintEqualToAnchor:g.trailingAnchor], [ctl.centerYAnchor constraintEqualToAnchor:v.centerYAnchor]]];
    }
    [cs addObject:[v.heightAnchor constraintGreaterThanOrEqualToConstant:48]];
    [NSLayoutConstraint activateConstraints:cs];
    return c;
}

- (UIMenu *)menuFor:(DmSetting *)s button:(UIButton *)b {
    NSMutableArray *items = [NSMutableArray array];
    NSString *cur = [self.m value:s];
    __weak DmSettingsVC *w = self; __weak UIButton *wb = b;
    for (NSArray *o in s.options) {
        UIAction *a = [UIAction actionWithTitle:o[1] image:nil identifier:nil handler:^(UIAction *act) {
            DmSettingsVC *me = w; if (!me) return;
            me.m.values[s.env] = o[0];
            UIButtonConfiguration *cfg = wb.configuration; cfg.title = o[1]; wb.configuration = cfg;
            wb.menu = [me menuFor:s button:wb];
            [me changedSetting:s];
        }];
        a.state = [o[0] isEqualToString:cur] ? UIMenuElementStateOn : UIMenuElementStateOff;
        [items addObject:a];
    }
    return [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsSingleSelection children:items];
}
- (void)documentPicker:(UIDocumentPickerViewController *)c didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (!urls.firstObject) return;
    self.cloudNote = dm_store_cloud_saves(urls.firstObject) ? @"Saved. The game uses this folder when you press Play." : @"That folder could not be remembered — try a different one.";
    [self.tableView reloadData];
}
- (void)refreshReset { [self.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:0 inSection:self.resetSection]] withRowAnimation:UITableViewRowAnimationNone]; }

- (void)slid:(UISlider *)sl {
    DmSetting *s = self.m.settings[sl.tag];
    double step = s.hasStep ? s.step : 0.05, lo = s.hasMin ? s.min : 0;
    double v = step > 0 ? lo + round((sl.value - lo) / step) * step : sl.value;   // SwiftUI's Slider(step:) snaps the same way
    self.m.values[s.env] = [NSString stringWithFormat:@"%.2f", v];
    UILabel *pct = [sl.superview viewWithTag:1000 + sl.tag];
    pct.text = [self.m percentage:s]; sl.accessibilityValue = pct.text;
}
- (void)slidEnd:(UISlider *)sl { [self refreshReset]; }
- (void)toggled:(UISwitch *)sw { DmSetting *s = self.m.settings[sw.tag]; self.m.values[s.env] = sw.on ? s.onValue : s.offValue; [self changedSetting:s]; }
- (void)changedSetting:(DmSetting *)s {   // a row another row needs: the sub-settings come and go, so the list is drawn again
    for (DmSetting *o in self.m.settings) if ([o.needs hasPrefix:[s.env stringByAppendingString:@"="]]) { [self.tableView reloadData]; return; }
    [self refreshReset];
}
@end

// ---- the screen: game card on the left third, settings on the right two thirds ----
@interface DmLauncherVC : UIViewController
@property (strong) DmLauncherModel *m; @property (copy) void (^play)(void);
@end
@implementation DmLauncherVC
static id info(NSString *k) { return [NSBundle.mainBundle objectForInfoDictionaryKey:k]; }
static UIImage *app_icon(void) {
    UIImage *i = [UIImage imageNamed:@"AppIcon"]; if (i) return i;
    NSDictionary *icons = info(@"CFBundleIcons"); NSArray *files = [icons isKindOfClass:NSDictionary.class] ? icons[@"CFBundlePrimaryIcon"][@"CFBundleIconFiles"] : nil;
    for (NSString *f in [files reverseObjectEnumerator]) { UIImage *im = [f isKindOfClass:NSString.class] ? [UIImage imageNamed:f] : nil; if (im) return im; }
    return [UIImage imageNamed:@"AppIcon60x60"];
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    UIStackView *card = [UIStackView new]; card.axis = UILayoutConstraintAxisVertical; card.alignment = UIStackViewAlignmentCenter; card.spacing = 16;
    UIImage *icon = app_icon();
    if (icon) {
        UIImageView *iv = [[UIImageView alloc] initWithImage:icon]; iv.layer.cornerRadius = 22; iv.layer.cornerCurve = kCACornerCurveContinuous; iv.clipsToBounds = YES;
        iv.isAccessibilityElement = NO; [iv.widthAnchor constraintEqualToConstant:96].active = YES; [iv.heightAnchor constraintEqualToConstant:96].active = YES;
        [card addArrangedSubview:iv];
    }
    UILabel *name = [UILabel new]; name.text = [info(@"CFBundleDisplayName") isKindOfClass:NSString.class] ? info(@"CFBundleDisplayName") : @"Game";
    UIFontDescriptor *fd = [[UIFont preferredFontForTextStyle:UIFontTextStyleTitle1].fontDescriptor fontDescriptorWithSymbolicTraits:UIFontDescriptorTraitBold];
    name.font = [UIFont fontWithDescriptor:fd size:0]; name.numberOfLines = 0; name.textAlignment = NSTextAlignmentCenter; [card addArrangedSubview:name];
    UILabel *ver = [UILabel new]; ver.text = [NSString stringWithFormat:@"Version %@", info(@"CFBundleShortVersionString") ?: @""];
    ver.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCallout]; ver.textColor = UIColor.secondaryLabelColor; [card addArrangedSubview:ver];
    UIButtonConfiguration *cfg = nil;
    SEL glass = NSSelectorFromString(@"prominentGlassButtonConfiguration");   // iOS 26's .glassProminent, as Launcher.swift; the filled style before it
    if ([UIButtonConfiguration respondsToSelector:glass]) cfg = ((UIButtonConfiguration *(*)(id, SEL))[UIButtonConfiguration methodForSelector:glass])(UIButtonConfiguration.class, glass);
    if (!cfg) cfg = [UIButtonConfiguration filledButtonConfiguration];
    cfg.buttonSize = UIButtonConfigurationSizeLarge; cfg.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    UIFontDescriptor *pd = [[UIFont preferredFontForTextStyle:UIFontTextStyleTitle3].fontDescriptor fontDescriptorWithSymbolicTraits:UIFontDescriptorTraitBold];
    cfg.attributedTitle = [[NSAttributedString alloc] initWithString:@"Play" attributes:@{NSFontAttributeName: [UIFont fontWithDescriptor:pd size:0]}];
    __weak DmLauncherVC *w = self;
    UIButton *b = [UIButton buttonWithConfiguration:cfg primaryAction:[UIAction actionWithHandler:^(UIAction *a) { if (w.play) w.play(); }]];
    [b.widthAnchor constraintEqualToConstant:220].active = YES; [card addArrangedSubview:b];
    card.translatesAutoresizingMaskIntoConstraints = NO; [self.view addSubview:card];

    DmSettingsVC *list = [[DmSettingsVC alloc] initWithStyle:UITableViewStyleInsetGrouped]; list.m = self.m;
    [self addChildViewController:list]; list.view.translatesAutoresizingMaskIntoConstraints = NO; [self.view addSubview:list.view]; [list didMoveToParentViewController:self];
    UIView *v = self.view; UILayoutGuide *safe = v.safeAreaLayoutGuide;
    UILayoutGuide *left = [UILayoutGuide new]; [v addLayoutGuide:left];   // the card in a third, the list in two thirds (Launcher.swift's GeometryReader split)
    [NSLayoutConstraint activateConstraints:@[
        [list.view.topAnchor constraintEqualToAnchor:v.topAnchor], [list.view.bottomAnchor constraintEqualToAnchor:v.bottomAnchor],
        [list.view.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor], [list.view.widthAnchor constraintEqualToAnchor:safe.widthAnchor multiplier:2.0 / 3.0],
        [left.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor], [left.trailingAnchor constraintEqualToAnchor:list.view.leadingAnchor],
        [card.centerXAnchor constraintEqualToAnchor:left.centerXAnchor], [card.centerYAnchor constraintEqualToAnchor:v.centerYAnchor],
        [card.widthAnchor constraintLessThanOrEqualToAnchor:left.widthAnchor constant:-32]]];
}
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
@end

// A capture IPA (win/build_ipa_windows.py: the run-time shader or NRO capture done on the device instead of a Mac) sets DM_GLSLC_CAPTURE / DM_VK_CAPTURE / DM_GL_CAPTURE / DM_NRO_CAPTURE in its dm/env.txt
// to a folder relative to Documents (main.m makes Documents the working directory); the Vulkan and GL captures write into the folder without making it, so it is made here, before the game starts
static void make_capture_folders(void) {
    static const char *const keys[] = {"DM_GLSLC_CAPTURE", "DM_VK_CAPTURE", "DM_GL_CAPTURE", "DM_NRO_CAPTURE"};   // DM_NRO_CAPTURE: a game that decodes its code at run time (hle_ro.c)
    for (int i = 0; i < 4; i++) {
        const char *k = keys[i], *d = getenv(k);
        if (d && *d) { [NSFileManager.defaultManager createDirectoryAtPath:@(d) withIntermediateDirectories:YES attributes:nil error:nil]; fprintf(stderr, "capture: %s → Documents/%s\n", k, d); }
    }
}

bool dm_show_launcher(void *view_controller, void (*done)(void)) {
    make_capture_folders();
    const char *off = getenv("DM_LAUNCHER");
    const char *appdm = getenv("DM_APP_DM");   // a game of several programs (main.m): the running program's settings, in its dm/p<N>
    NSString *dir = appdm ? @(appdm) : [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"dm"];
    NSData *data = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:@"launcher.json"]];
    if (!data) return false;
    NSArray<DmSetting *> *settings = load_settings(data);
    if (!settings.count) { fprintf(stderr, "[RED] launcher: dm/launcher.json cannot be read; starting the game\n"); return false; }
    DmLauncherModel *model = [[DmLauncherModel alloc] initWith:settings];
    g_model = model;   // the in-game menu shows and saves the same choices (GameMenu.m)
    if (off && !strcmp(off, "0")) { fprintf(stderr, "launcher: off (DM_LAUNCHER=0)\n"); [model applySaved]; return false; }
    UIViewController *parent = (__bridge UIViewController *)view_controller;
    DmLauncherVC *vc = [DmLauncherVC new]; vc.m = model; vc.modalPresentationStyle = UIModalPresentationFullScreen;
    __weak DmLauncherVC *wvc = vc; __block BOOL started = NO;
    vc.play = ^{
        if (started || !wvc) return;
        started = YES;
        [model apply];
        [wvc dismissViewControllerAnimated:NO completion:^{ done(); }];
    };
    [parent presentViewController:vc animated:NO completion:nil];
    fprintf(stderr, "launcher: %lu settings shown\n", (unsigned long)settings.count);
    return true;
}
