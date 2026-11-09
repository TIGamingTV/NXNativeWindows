// A save moved by hand, as one file: the launcher's Export save and Import save (win/ios/Launcher.m). They are for an app that cannot be given a folder: the Cloud saves
// folder needs a document picker that opens a folder in place, and an app that a signing service re-signed (FlareStore, for one) gets nothing back from it (the picker
// logs Cocoa 257, "Could not resolve bookmark", and hands the app no URL: seedds/nxnative#1148); a tweak that turns every picker into a copy (FilePickerFix) closes the
// app instead, since iOS cannot copy a folder. A picker that copies one file works under any signature: an export copies the packed save out, an import copies one in.
// The file is the cloud's own format (save_sync.h, ss_pack / ss_read: the committed save and the device save, checked as a whole), so a file the Mac app or another
// device synced to <folder>/<title ID>/save.dmsync imports too, and an exported one can be put there.
// Only while the game is not running (the launcher, before Play): nothing commits a save meanwhile.
#include "save_transfer.h"
#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <time.h>
#include <dirent.h>
#include <unistd.h>

static void folder_of(const char *save, int i, char *out, size_t n) { snprintf(out, n, i ? "%s_device" : "%s", save); }   // DM_SAVE and DM_SAVE_device (save_sync.c folder_path)
static const char *const PACKED[2] = {"save", "save_device"};   // their names inside a packed save (save_sync.c FOLDERS)

static int mkdirs(const char *path) {   // mkdir -p
    char p[PATH_MAX]; if (snprintf(p, sizeof p, "%s", path) >= (int)sizeof p) return -1;
    for (char *s = p + 1; *s; s++) if (*s == '/') { *s = 0; mkdir(p, 0755); *s = '/'; }
    return mkdir(p, 0755) && errno != EEXIST ? -1 : 0;
}

static int rm_tree(const char *p) {   // rm -rf: 0 when nothing is left
    struct stat st; if (lstat(p, &st)) return errno == ENOENT ? 0 : -1;
    if (!S_ISDIR(st.st_mode)) return unlink(p);
    DIR *d = opendir(p); if (!d) return -1;
    int r = 0; struct dirent *e;
    while ((e = readdir(d))) {
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
        char c[PATH_MAX]; if (snprintf(c, sizeof c, "%s/%s", p, e->d_name) >= (int)sizeof c || rm_tree(c)) r = -1;
    }
    closedir(d);
    return rmdir(p) ? -1 : r;
}

static int has_entries(const char *dir) {   // anything but Finder's .DS_Store (save_sync.c has_entries: an empty folder is no save)
    DIR *d = opendir(dir); if (!d) return 0;
    int k = 0; struct dirent *e;
    while (!k && (e = readdir(d))) k = strcmp(e->d_name, ".") && strcmp(e->d_name, "..") && strcmp(e->d_name, ".DS_Store");
    closedir(d); return k;
}

static void strip(const char *save, char *out, size_t n) {   // DM_SAVE without trailing slashes, as h_fs_MountSave strips them (the same <save>-backups)
    snprintf(out, n, "%s", save); size_t L = strlen(out); while (L > 1 && out[L - 1] == '/') out[--L] = 0;
}

int nxw_save_export(const char *save, const char *title, const char *out, ss_meta *m) {
    char s[PATH_MAX]; strip(save, s, sizeof s);
    if (ss_scan(s, m)) { fprintf(stderr, "[RED] save export: the save %s cannot be read (errno=%d)\n", s, errno); return -1; }
    if (!m->files) { fprintf(stderr, "save export: there is no save yet in %s\n", s); return 0; }
    if (ss_pack(s, title, out, m)) { fprintf(stderr, "[RED] save export: packing %s into %s failed (errno=%d)\n", s, out, errno); return -1; }
    fprintf(stderr, "save export: %d files (hash %s) packed into %s\n", m->files, m->hash, out);
    return m->files;
}

int nxw_save_check(const char *bundle, const char *title, ss_meta *m) {
    if (ss_read(bundle, NULL, m)) { fprintf(stderr, "[RED] save import: %s is not a packed save, or it is damaged or cut off\n", bundle); return NXW_SAVE_DAMAGED; }
    if (title && strcasecmp(m->title, title)) { fprintf(stderr, "[RED] save import: %s is the save of %s, not of %s\n", bundle, m->title, title); return NXW_SAVE_OTHER_GAME; }
    if (!m->files) { fprintf(stderr, "[RED] save import: %s holds no save files\n", bundle); return NXW_SAVE_EMPTY; }
    return 0;
}

// This device's save goes to <save>-backups/<date> local, the name save_sync.c gives its own backups (is_backup), so the host's pruning counts it with them
static int backup_dir(const char *save, char *out, size_t n) {
    char stamp[32]; time_t t = time(NULL); struct tm tm; localtime_r(&t, &tm); strftime(stamp, sizeof stamp, "%Y-%m-%d %H.%M.%S", &tm);
    snprintf(out, n, "%s-backups/%s local", save, stamp);
    for (int k = 2; !access(out, F_OK); k++) snprintf(out, n, "%s-backups/%s local %d", save, stamp, k);
    return mkdirs(out);
}

int nxw_save_import(const char *save, const char *title, const char *bundle, ss_meta *m, char *kept, size_t kn) {
    char s[PATH_MAX], tmp[PATH_MAX]; strip(save, s, sizeof s);
    kept[0] = 0;
    int r = nxw_save_check(bundle, title, m); if (r) return r;
    // Unpacked beside the save first: an import that fails there leaves this device's save as it was
    snprintf(tmp, sizeof tmp, "%s.import-tmp", s);
    if (rm_tree(tmp) || mkdirs(tmp) || ss_read(bundle, tmp, m)) {
        fprintf(stderr, "[RED] save import: unpacking %s into %s failed (errno=%d)\n", bundle, tmp, errno); rm_tree(tmp); return NXW_SAVE_FAILED;
    }
    for (int i = 0; i < 2; i++) {
        char here[PATH_MAX], incoming[PATH_MAX], old[PATH_MAX];
        folder_of(s, i, here, sizeof here); snprintf(incoming, sizeof incoming, "%s/%s", tmp, PACKED[i]);
        int fresh = !access(incoming, F_OK), had = has_entries(here);
        if (had && !*kept && backup_dir(s, kept, kn)) { fprintf(stderr, "[RED] save import: cannot make a backup folder for %s (errno=%d): nothing imported\n", s, errno); rm_tree(tmp); return NXW_SAVE_FAILED; }
        snprintf(old, sizeof old, "%s/%s", kept, PACKED[i]);
        // this device's folder goes to the backup (an empty one is dropped), then the imported one takes its place; a folder the file does not have is not kept
        // here either, so the save is the file's whole
        if (!access(here, F_OK) && (had ? rename(here, old) : rm_tree(here))) { fprintf(stderr, "[RED] save import: cannot move %s aside (errno=%d)\n", here, errno); rm_tree(tmp); return NXW_SAVE_FAILED; }
        if (fresh && rename(incoming, here)) { fprintf(stderr, "[RED] save import: cannot move %s to %s (errno=%d)\n", incoming, here, errno); rm_tree(tmp); return NXW_SAVE_FAILED; }
    }
    rm_tree(tmp);
    fprintf(stderr, "save import: %d files from %s (saved on %s, hash %s) are now the save in %s%s%s\n", m->files, bundle, m->device, m->hash, s, *kept ? "; this device's is kept in " : "", kept);
    return 0;
}
