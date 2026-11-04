// The UIKit launcher's settings model (win/ios/Launcher.m), shared with the in-game menu (win/ios/GameMenu.m): the Objective-C counterparts of LauncherSettings.swift's Setting and
// LauncherModel, so the Windows build needs no Swift toolchain.
#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface DmSetting : NSObject
@property (copy) NSString *env, *kind, *label, *note, *def;
@property (copy, nullable) NSString *section, *on, *off;
@property (copy, nullable) NSString *needs;   // "<VAR>=<value>": a sub-setting, drawn only while that setting has that value
@property (copy, nullable) NSArray<NSArray<NSString *> *> *options;   // choice: [value, label]
@property double min, max, step; @property BOOL hasMin, hasMax, hasStep;
@property BOOL disabled;
- (NSString *)sectionTitle;
- (NSString *)onValue;
- (NSString *)offValue;
- (BOOL)isDefault:(NSString *)v;
- (BOOL)accepts:(NSString *)v;
@end

@interface DmLauncherModel : NSObject
@property (strong) NSArray<DmSetting *> *settings;
@property (strong) NSArray<NSString *> *sections;
@property (strong) NSSet<NSString *> *fromFile;     // set by an env file or by the launch environment: shown, not changed
@property (strong) NSSet<NSString *> *fromLaunch;   // of those, the ones the launch environment set (DM_ENV_LAUNCH_KEYS)
@property BOOL ignoreSaved;                          // DM_SAVED_CHOICES=0
@property (strong) NSMutableDictionary<NSString *, NSString *> *values;
- (NSArray<DmSetting *> *)inSection:(NSString *)sec;   // the section's rows that are drawn (needs)
- (NSString *)value:(DmSetting *)s;
- (BOOL)locked:(DmSetting *)s;
- (NSString *)choiceLabel:(DmSetting *)s;
- (void)choose:(DmSetting *)s value:(NSString *)v;   // the in-game menu's pick: saved and put in the environment
@end

DmLauncherModel *_Nullable nxw_launcher_model(void);   // the model of the settings screen this run showed (or applied with DM_LAUNCHER=0); nil without one

NS_ASSUME_NONNULL_END
