// A save exported to one file and imported from one (save_transfer.c says why), for the launcher's Export save / Import save (win/ios/Launcher.m).
#pragma once
#include <stddef.h>
#include "save_sync.h"

#ifdef __cplusplus
extern "C" {
#endif

enum { NXW_SAVE_DAMAGED = -1, NXW_SAVE_OTHER_GAME = -2, NXW_SAVE_EMPTY = -3, NXW_SAVE_FAILED = -4 };

// Packs the save (DM_SAVE and DM_SAVE_device) into `out`. The number of files packed; 0 when there is no save yet (nothing is written); -1 on failure
int nxw_save_export(const char *save, const char *title, const char *out, ss_meta *m);
// Checks a packed save without unpacking it: 0 when it is a whole save of `title` (NULL: any game), else one of the NXW_SAVE_ codes. m: what it holds
int nxw_save_check(const char *bundle, const char *title, ss_meta *m);
// Makes the packed save this device's save. This device's save, when it has one, is kept first in <save>-backups/<date> local (`kept`, "" when there was none).
// 0 on success, else one of the NXW_SAVE_ codes (the save is left as it was, unless a move failed halfway: then what was there is in `kept`)
int nxw_save_import(const char *save, const char *title, const char *bundle, ss_meta *m, char *kept, size_t kn);

#ifdef __cplusplus
}
#endif
