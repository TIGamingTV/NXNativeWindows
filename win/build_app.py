#!/usr/bin/env python3
# Windows replacement for dm/ios/tools/build_ipa.sh: the same unsigned all-in-one IPA (rewritten modules compiled into the executable, iOS shader libraries at DmIOS.app/msl,
# add-on content at DmIOS.app/aoc, the RomFS at DmIOS.app/romfs), built without Xcode:
#   xcodegen + xcodebuild   → LLVM clang (-target arm64-apple-ios26.0 -isysroot <iPhoneOS SDK>) per source file, linked by ld64.lld
#   Launcher.swift (SwiftUI) → win/ios/Launcher.m (UIKit, same dm_show_launcher contract), so no Swift toolchain is needed
#   actool (asset catalog)  → loose PNG icons named in CFBundleIcons (Pillow scales the game's icon.jpg)
#   sips / plutil           → Pillow / plistlib
#   make -n -B dmhost       → the source list of dm/host/Makefile, reproduced in host_sources() (checked against the Makefile text so an upstream change is noticed)
# Inputs: the same environment as build_ipa.sh (GAME, W, PATCHED, ROMFS, MSL_IOS, AOC, GFXAPI, DM_DISPLAY_NAME, DM_APP_VERSION, DM_BUNDLE_ID, DM_SHOW_FPS, DM_LANG, DM_ENV_FILE, DM_ICON, STD_FONT).
# Usage: win/build_app.py [output.ipa]   (--prepare-xcode is a Mac-only mode)
# It never signs: the sideloading tool (Sideloadly, AltStore, ...) signs the IPA, as with the upstream build.
import concurrent.futures as cf, hashlib, json, os, plistlib, re, shutil, subprocess, sys, time
from pathlib import Path
WIN = Path(__file__).resolve().parent
sys.path.insert(0, str(WIN))
import toolchain as tc

REPO = tc.REPO
DM = REPO / 'dm'
IOS = DM / 'ios'
HOST = DM / 'host'
sys.path.insert(0, str(DM / 'tools'))
import romfs as rfs   # the RomFS as a folder or as one DMROMFS1 image (nx_extract --romfs-image), read alike


def t(msg): print(f'[{time.strftime("%H:%M:%S")}] {msg}', flush=True)
def die(msg): t(f'FAIL: {msg}'); sys.exit(1)


def py(*args, env=None, capture=True):
    r = subprocess.run([sys.executable, *map(str, args)], capture_output=capture, text=True, env=env)
    if r.returncode: die(f'{Path(str(args[0])).name} {" ".join(map(str, args[1:]))}: {(r.stderr or r.stdout or "").strip()[-2000:]}')
    return (r.stdout or '').strip() if capture else ''


# ---- dm/host/Makefile, reproduced ----
def host_sources(game_h_dir, msl_h_dir=None):
    """(sources, include dirs) exactly as `make -n -B dmhost` lists them: SRC, GFX and the libvpx objects' sources; the include order of the host's link line, then libvpx's.
    dav1d is a library of its own with its own flags: dav1d_sources()"""
    mk = (HOST / 'Makefile').read_text(encoding='utf-8')
    names = 'main.c loader.c hle.c crash.c probe.c thread.c save_sync.c memstat.m haptics_apple.m'
    want_src = f'SRC={names} $(sort $(wildcard hle_*.c)) front_mac.m web_apple.m entry.S'
    want_gfx = 'GFX=$(sort $(wildcard ../gfx/*.c ../gfx/nvn/*.c ../gfx/nvn/*.m ../gfx/nvn/*.S ../gfx/tex/*.c ../gfx/tex/*.m ../gfx/vk/*.m ../gfx/gl/*.m))'
    want_inc = '-I../gfx/nvn/include -I$(dir $(MSL_H)) -I../third_party/vulkan-headers/include -I$(dir $(GAME_H)) -I$(VPX) -I$(DAV1D)/include -I../third_party/stb_vorbis'
    for w in (want_src, want_gfx, want_inc):
        if w not in mk: die(f'dm/host/Makefile changed ({w.split("=")[0][:40]} line): update host_sources() in win/build_app.py')
    src = [HOST / n for n in names.split()]
    src += sorted(HOST.glob('hle_*.c'), key=lambda p: p.name)
    src += [HOST / 'front_mac.m', HOST / 'web_apple.m', HOST / 'entry.S']
    gfx = []
    for pat in ('../gfx/*.c', '../gfx/nvn/*.c', '../gfx/nvn/*.m', '../gfx/nvn/*.S', '../gfx/tex/*.c', '../gfx/tex/*.m', '../gfx/vk/*.m', '../gfx/gl/*.m'):
        d, g = pat.rsplit('/', 1)
        gfx += [(HOST / d / p.name) for p in (HOST / d).glob(g)]
    gfx = sorted(gfx, key=lambda p: os.path.relpath(p, HOST).replace('\\', '/'))   # make's $(sort) orders the words as text
    vpx = DM / 'third_party/libvpx'
    vpx_src = sorted(vpx.rglob('*.c'), key=lambda p: p.as_posix())
    incs = [DM / 'gfx/nvn/include', *([msl_h_dir] if msl_h_dir else []), DM / 'third_party/vulkan-headers/include', game_h_dir, vpx, DM / 'third_party/dav1d/include',
            DM / 'third_party/stb_vorbis', vpx / 'config']
    files = []
    for s in src + gfx + vpx_src:
        s = s.resolve()
        if s.stem.endswith('_mac'): continue   # Mac-only sources (front_mac.m): front_ios.m implements front.h
        if s.parent == (IOS / 'Sources').resolve(): continue   # iOS sources the host borrows are compiled once, as iOS sources
        files.append(s)
    dirs = []
    for s in files:
        if s.parent not in dirs: dirs.append(s.parent)
    dirs.append((IOS / 'Sources').resolve())   # the iOS front end's headers (DmGameMenu.h, CloudSaves.h, ...), which win/ios's stand-ins include
    return files, [Path(i).resolve() for i in incs] + [d for d in dirs if d not in incs]


DAV1D_FLAGS = ['-fvisibility=hidden', '-fomit-frame-pointer', '-fno-align-functions']   # dm/host/Makefile's gen/dav1d/%.o rule


def dav1d_sources():
    """(sources, include dirs) of dav1d, the AV1 decoder (hle_movie_av1.c), as dm/host/Makefile's DAV1D_SRC: its C files but the *_tmpl.c ones (built through config/tmpl's
    per-bit-depth wrappers), src/arm/cpu.c, and the arm64 assembly but the files other assembly files include (*_tmpl.S, util.S)"""
    mk = (HOST / 'Makefile').read_text(encoding='utf-8')
    if 'DAV1D_SRC=$(sort $(filter-out %_tmpl.c,$(wildcard $(DAV1D)/src/*.c)) $(DAV1D)/src/arm/cpu.c $(wildcard $(DAV1D)/config/tmpl/*.c)' not in mk:
        die('dm/host/Makefile changed (DAV1D_SRC= line): update dav1d_sources() in win/build_app.py')
    d = DM / 'third_party/dav1d'
    src = sorted([p for p in (d / 'src').glob('*.c') if not p.name.endswith('_tmpl.c')] + [d / 'src/arm/cpu.c'] + list((d / 'config/tmpl').glob('*.c'))
                 + [p for p in (d / 'src/arm/64').glob('*.S') if not p.name.endswith('_tmpl.S') and p.name != 'util.S'], key=lambda p: p.as_posix())
    return [p.resolve() for p in src], [d.resolve(), (d / 'include').resolve(), (d / 'config').resolve()]


def host_msl(out_dir):
    """The host's own Metal shaders compiled for iOS into <out_dir>/host_msl_gen.h (dm/gfx/tools/host_msl.py through win/xcrun.py; Makefile MSL_H with MSL_SDK=iphoneos), so the
    host compiles no MSL at run time. Without the Metal tools the header holds the sources only and the host compiles them on the device (a [RED] line says so)"""
    srcs = sorted((DM / 'gfx/msl').glob('*.metal'), key=lambda p: p.name)
    out_dir.mkdir(parents=True, exist_ok=True)
    r = subprocess.run([sys.executable, str(DM / 'gfx/tools/host_msl.py'), '--sdk', 'iphoneos', '--min', tc.setting('ios_deployment', tc.IOS_DEPLOYMENT),
                        str(out_dir / 'host_msl_gen.h'), *map(str, srcs)], capture_output=True, text=True)
    if r.returncode: die(f'host_msl.py: {(r.stderr or r.stdout).strip()[-2000:]}')
    t((r.stderr or r.stdout).strip().splitlines()[-1] if (r.stderr or r.stdout).strip() else 'host shaders: header up to date')
    return out_dir


FRAMEWORKS_BASE = ['WebKit', 'UserNotifications', 'QuartzCore', 'Metal', 'MetalFX', 'GameController', 'CoreHaptics', 'AudioToolbox', 'VideoToolbox', 'CoreMedia', 'CoreVideo', 'ImageIO', 'UniformTypeIdentifiers',   # dm/host/Makefile minus Cocoa and IOKit
                   'UIKit', 'Foundation', 'CoreGraphics', 'CoreFoundation']   # what the UIKit side and the launcher use (Xcode would add UIKit through Swift / module autolinking)
IMPORT = re.compile(r'^\s*#\s*(?:import|include)\s*<(\w+)/', re.M)


def frameworks(sdk, files):
    fw_dir = sdk / 'System/Library/Frameworks'
    out = list(FRAMEWORKS_BASE)
    for f in files:
        if f.suffix not in ('.m', '.c', '.h'): continue
        for name in IMPORT.findall(f.read_text(encoding='utf-8', errors='replace')):
            if name not in out and (fw_dir / f'{name}.framework').is_dir(): out.append(name)
    return [n for n in out if (fw_dir / f'{n}.framework').is_dir()]


# ---- compile + link ----
def compile_all(clang, sdk, files, incs, obj_dir, extra_defs):
    target = f'arm64-apple-ios{tc.setting("ios_deployment", tc.IOS_DEPLOYMENT)}'
    common = ['-target', target, '-isysroot', str(sdk), '-Os', f'-mcpu={tc.setting("mcpu", "apple-a18")}', '-w', '-fno-common', '-DNS_BLOCK_ASSERTIONS=1', *extra_defs] + [f'-I{i}' for i in incs]
    obj_dir.mkdir(parents=True, exist_ok=True)
    jobs, objs = [], []
    for f in files:
        name = f.name
        if f == (HOST / 'main.c').resolve(): flags = common + ['-std=gnu11', '-Dmain=dm_main']   # the host's main, started by main.m (project.yml compilerFlags)
        elif f.suffix == '.c': flags = common + ['-std=gnu11']
        elif f.suffix == '.m': flags = common + ['-std=gnu11', '-fobjc-arc']
        elif f.suffix == '.S': flags = common
        else: continue
        key = hashlib.sha256((str(f) + '\0' + '\0'.join(flags)).encode()).hexdigest()[:12]
        o = obj_dir / f'{f.stem}-{key}.o'
        objs.append(o)
        if o.exists() and o.stat().st_mtime >= f.stat().st_mtime and not dep_newer(o): continue
        jobs.append((f, o, flags))
    t(f'compile: {len(jobs)} of {len(objs)} files (clang {target})')
    def one(j):
        f, o, flags = j
        d = o.with_suffix('.d')
        r = subprocess.run([str(clang), *flags, '-MMD', '-MF', str(d), '-c', str(f), '-o', str(o) + '.tmp'], capture_output=True, text=True)
        if r.returncode == 0: os.replace(str(o) + '.tmp', o)
        return f, r
    bad = []
    with cf.ThreadPoolExecutor(max_workers=os.cpu_count() or 4) as ex:
        for i, (f, r) in enumerate(ex.map(one, jobs), 1):
            if r.returncode: bad.append((f, r.stderr))
            if i % 50 == 0 or i == len(jobs): t(f'compile: {i}/{len(jobs)}')
    if bad:
        for f, err in bad[:5]: print(f'---- {f}\n' + '\n'.join(l for l in err.splitlines() if 'error' in l)[:3000], file=sys.stderr)
        die(f'{len(bad)} file(s) did not compile')
    return objs


def dep_newer(o):
    """True when a header the object was built from (its .d file) is newer than the object"""
    d = o.with_suffix('.d')
    if not d.exists(): return True
    mt = o.stat().st_mtime
    text = d.read_text(errors='replace').replace('\\\n', ' ')
    for dep in re.split(r'(?<!\\)\s+', text.split(':', 1)[-1]):
        dep = dep.replace('\\ ', ' ').strip()
        if dep and os.path.exists(dep) and os.path.getmtime(dep) > mt: return True
    return False


def link(clang, sdk, objs, fws, embed_flags, out):
    target = f'arm64-apple-ios{tc.setting("ios_deployment", tc.IOS_DEPLOYMENT)}'
    args = [str(clang), '-target', target, '-isysroot', str(sdk), '-fuse-ld=lld', '-fobjc-arc', *(['-Wl,-adhoc_codesign'] if os.environ.get('NXW_ENTITLEMENTS', '1') != '0' else []), '-o', str(out), *map(str, objs),
            '-Wl,-rpath,@executable_path/Frameworks', '-lobjc', '-lz', *[x for f in fws for x in ('-framework', f)], *embed_flags]
    rt = compat_rt_needed(clang)
    if rt: args.append(str(rt))
    t(f'link: {len(objs)} objects, {len(fws)} frameworks (ld64.lld)')
    # The arguments go in a response file (clang @file): a game's objects and embed flags make a command line longer than Windows' 32,767 characters (WinError 206 on Mario Kart
    # World's 268 objects). Quoted by clang's GNU rules, which clang (not clang-cl) uses for a response file on Windows too: each argument in double quotes, \\ and \" escaped
    # (Windows' own rules, as subprocess.list2cmdline writes them, lost every backslash of the paths)
    rsp = Path(out).parents[2] / 'link.rsp'   # beside Payload/, outside the app (the IPA packs DmIOS.app)
    gnu = lambda a: '"' + a.replace('\\', '\\\\').replace('"', '\\"') + '"'
    rsp.write_text(' '.join(map(gnu, args[1:])), encoding='utf-8')
    r = subprocess.run([args[0], '--rsp-quoting=posix', f'@{rsp}'], capture_output=True, text=True)
    if r.returncode: print(r.stderr[-6000:], file=sys.stderr); die('link failed')


def compat_rt_needed(clang):
    """LLVM for Windows ships no Darwin compiler-rt (libclang_rt.ios.a), which provides __isPlatformVersionAtLeast for @available; win/ios/compat_rt.c stands in for it"""
    r = subprocess.run([str(clang), '-print-resource-dir'], capture_output=True, text=True)
    res = Path(r.stdout.strip()) if r.returncode == 0 else None
    if res and list(res.glob('lib/darwin/libclang_rt.ios.a')): return None
    return WIN / 'build' / 'compat_rt.o'


# ---- bundle ----
def info_plist(bundle_id, name, version, category, show_fps, lang, sdk_ver, sdk_build, icons):
    p = {
        'CFBundleDevelopmentRegion': 'en', 'CFBundleExecutable': 'DmIOS', 'CFBundleIdentifier': bundle_id, 'CFBundleInfoDictionaryVersion': '6.0',
        'CFBundleName': 'DmIOS', 'CFBundleDisplayName': name, 'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': version, 'CFBundleVersion': version,
        'CFBundleSupportedPlatforms': ['iPhoneOS'], 'DTPlatformName': 'iphoneos', 'DTPlatformVersion': sdk_ver, 'DTSDKName': f'iphoneos{sdk_ver}', 'DTSDKBuild': sdk_build,
        'MinimumOSVersion': tc.setting('ios_deployment', tc.IOS_DEPLOYMENT), 'LSRequiresIPhoneOS': True, 'UIDeviceFamily': [1, 2], 'UIRequiredDeviceCapabilities': ['arm64'],
        # dm/ios/project.yml info.properties
        'UILaunchScreen': {}, 'UIFileSharingEnabled': True, 'LSSupportsOpeningDocumentsInPlace': True,
        'UISupportedInterfaceOrientations': ['UIInterfaceOrientationLandscapeRight', 'UIInterfaceOrientationLandscapeLeft'],
        'UISupportedInterfaceOrientations~ipad': ['UIInterfaceOrientationPortrait', 'UIInterfaceOrientationPortraitUpsideDown', 'UIInterfaceOrientationLandscapeRight', 'UIInterfaceOrientationLandscapeLeft'],
        'UIStatusBarHidden': True, 'UIViewControllerBasedStatusBarAppearance': False, 'LSApplicationCategoryType': category,
        'DMShowFPS': show_fps, 'DMLanguage': lang, 'LSSupportsGameMode': True, 'GCSupportsControllerUserInteraction': True,
        'GCSupportedGameControllers': [{'ProfileName': 'ExtendedGamepad'}], 'CADisableMinimumFrameDurationOnPhone': True,
        'UIApplicationSceneManifest': {'UIApplicationSupportsMultipleScenes': False, 'UISceneConfigurations': {'UIWindowSceneSessionRoleApplication': [
            {'UISceneConfigurationName': 'Default', 'UISceneDelegateClassName': 'SceneDelegate'}],
            # a TV by cable or AirPlay: the game's picture goes there, the phone keeps the pad (front_ios.m DmTVSceneDelegate)
            'UIWindowSceneSessionRoleExternalDisplayNonInteractive': [{'UISceneConfigurationName': 'TV', 'UISceneDelegateClassName': 'DmTVSceneDelegate'}]}},
    }
    # The data ZIP import (win/ios/DataHelp.m) runs as a continued-processing task on iOS 26 and later: it goes on in the background with a Live Activity. Its identifiers are
    # <bundle ID>.import.<n> (a signer that changes the bundle ID makes the request fail, and the import runs in the foreground instead)
    p['BGTaskSchedulerPermittedIdentifiers'] = [f'{bundle_id}.import.*']
    p['UIBackgroundModes'] = ['processing']
    if icons:
        p['CFBundleIcons'] = {'CFBundlePrimaryIcon': {'CFBundleIconFiles': ['AppIcon60x60'], 'CFBundleIconName': 'AppIcon'}}
        p['CFBundleIcons~ipad'] = {'CFBundlePrimaryIcon': {'CFBundleIconFiles': ['AppIcon60x60', 'AppIcon76x76', 'AppIcon83.5x83.5'], 'CFBundleIconName': 'AppIcon'}}
    return p


ICONS = [('AppIcon60x60@2x.png', 120), ('AppIcon60x60@3x.png', 180), ('AppIcon76x76@2x~ipad.png', 152), ('AppIcon83.5x83.5@2x~ipad.png', 167), ('AppIcon.png', 1024)]


def make_icons(src, app):
    try: from PIL import Image
    except ImportError: t('no app icon: Pillow is not installed (pip install pillow); the home-screen icon stays blank'); return False
    im = Image.open(src).convert('RGB')
    for name, px in ICONS: im.resize((px, px), Image.LANCZOS).save(app / name, 'PNG')
    t(f'app icon: {src}')
    return True


_LISTED = {}
def list_files(src):
    """[(path, path relative to src with '/', size, mtime_ns)] of a folder, by os.scandir (on Windows the sizes and times come with the listing, no stat per file: TotK's RomFS is 300,000 files).
    Listed once per build"""
    src = Path(src)
    if src in _LISTED: return _LISTED[src]
    out, stack = [], [(str(src), '')]
    while stack:
        d, rel = stack.pop()
        with os.scandir(d) as it:
            for e in it:
                r = rel + e.name
                if e.is_dir(follow_symlinks=False): stack.append((e.path, r + '/'))
                else: st = e.stat(follow_symlinks=False); out.append((e.path, r, st.st_size, st.st_mtime_ns))
    out.sort(key=lambda x: x[1]); _LISTED[src] = out
    return out


def split_data(data, parts, stamp, name, skip_suffix=()):
    """Fill the data folder of a split build: {path inside it: source folder, or a source file (romfs.img: the extraction's RomFS image)}. Files are hard-linked (no disk space) on several threads, and copied where links fail
    (another drive). A folder that a build with the same stamp and the same files filled is kept as it is; otherwise it is made again in <folder>.partial and swapped in,
    so it never mixes files from two builds. Returns (files, bytes)"""
    import concurrent.futures as cf
    todo = [(f, f'{rel}/{r}', n, m) for rel, src in parts.items() if not Path(src).is_file() for f, r, n, m in list_files(src) if not r.endswith(tuple(skip_suffix))]
    todo += [(str(src), rel, (st := Path(src).stat()).st_size, st.st_mtime_ns) for rel, src in parts.items() if Path(src).is_file()]
    count, size = len(todo), sum(n for _, _, n, _ in todo)
    # the folder's files are hard links of the sources: a source written again (a new RomFS image, a shader library rebuilt with the same size) is a new file, so its time is in the signature too
    files = hashlib.sha256(''.join(f'{r}\t{n}\t{m}\n' for _, r, n, m in sorted(todo, key=lambda x: x[1])).encode()).hexdigest()
    sig = stamp + f'files\t{count}\nbytes\t{size}\ndigest\t{files}\n'
    if (data / 'nxw_data.tsv').is_file() and (data / 'nxw_data.tsv').read_text(encoding='utf-8') == sig:
        t(f'split build: reusing the data folder {data} ({count:,} files, {size / 2**30:.2f} GB, the same build)')
        return count, size
    t(f'split build: game files and shader libraries go to {data} ({count:,} files, hard links on {min(32, (os.cpu_count() or 4) * 2)} threads)')
    tmp = data.with_name(data.name + '.partial')
    if tmp.exists(): shutil.rmtree(tmp)
    for d in sorted({str(Path(r).parent) for _, r, _, _ in todo}): (tmp / d).mkdir(parents=True, exist_ok=True)
    def one(item):
        f, r, _, _ = item; dst = tmp / r
        try: os.link(f, dst)
        except OSError: shutil.copy2(f, dst)
    with cf.ThreadPoolExecutor(min(32, (os.cpu_count() or 4) * 2)) as ex: list(ex.map(one, todo, chunksize=256))
    (tmp / 'nxw_data.tsv').write_text(sig, encoding='utf-8')
    (tmp / 'README.txt').write_text(
        f'{name}: game data for the split IPA\n\n'
        'Install the IPA, open it once, then copy this whole folder (or its contents) into the app\'s Documents:\n'
        '  - Windows: Apple Devices app (or iTunes) > your iPhone/iPad > Files > the app > drag this folder in\n'
        '  - iPhone/iPad: Files app > On My iPhone/iPad > the app (from a USB drive, a network share or iCloud Drive)\n'
        'Then fully close and reopen the app. Re-signing the IPA later does not touch these files.\n'
        'Copy the data folder again only after a new build of the same game (nxw_data.tsv names the build).\n', encoding='utf-8')
    if data.exists(): shutil.rmtree(data)
    os.replace(tmp, data)
    t(f'data folder: {count:,} files, {size / 2**30:.2f} GB')
    return count, size


# The UIKit stand-ins for the Swift sources (no Swift toolchain on Windows): the launcher (Launcher.swift, LauncherSettings.swift, LauncherRow.swift), the in-game menu
# (GameMenu.swift), the split build's data screen and its ZIP import
WIN_IOS_SOURCES = ('Launcher.m', 'GameMenu.m', 'DataHelp.m', 'nxw_unzip.c')


def chain_version():
    hdr = (DM / 'gfx/nvn/dmsh_chain.h').read_text(encoding='utf-8')
    return (re.search(r'^#define DMSH_CHAIN "(.*)"', hdr, re.M) or die('no DMSH_CHAIN in dmsh_chain.h')).group(1)


class Program:
    """One program's inputs (build_ipa.sh check_program / prog_set): a single-program game has one, index None; a game of several programs (PROGRAMS_TSV: Super Mario 3D
    All-Stars) one per row, program 0 being GAME / PATCHED / ROMFS / MSL_IOS / GFXAPI"""
    def __init__(self, n, game, patched, romfs, msl_ios, gfx, capture=False):
        import game as gm
        self.n, self.game, self.patched, self.capture = n, game, Path(patched), capture
        self.prof = gm.load(game); self.gd = self.prof.dir
        self.romfs = rfs.Path(romfs) if not isinstance(romfs, rfs.Path) else romfs
        self.image = rfs.is_image(self.romfs)
        self.marker = self.prof.get('romfs_marker')
        v = chain_version()
        self.gfx = gfx or ('nvn' if list((Path(msl_ios) / f'b-{v}').glob('*_b.metallib')) else 'vulkan' if (Path(msl_ios) / 'vk/vk_shaders.metallib').exists()
                           else 'gl' if (Path(msl_ios) / 'gl/gl_shaders.metallib').exists() else 'nvn')
        self.msldir = {'vulkan': 'vk', 'gl': 'gl'}.get(self.gfx, f'b-{v}')
        self.msl_ios = Path(msl_ios)
        self.tag = f'p{n}' if n is not None else ''
        self.extra = Path(str(self.romfs)).parent   # beside the RomFS: the offline HTML pages (html/) and the nn::jit image (jit/)

    def check(self, env):
        game, gd = self.game, self.gd
        if not (gd / 'game.tsv').exists(): die(f'no game profile {gd}/game.tsv')
        if not (self.patched / 'main.fixups.tsv').exists(): die(f'no rewritten main in {self.patched} (run dm/tools/patch_nso.py first)')
        self.mods = py(DM / 'games/game.py', 'modules', game, self.patched).split()   # main's build row, as the host picks them: a version may lack a module another has
        for m in self.mods:
            if not ((self.patched / f'{m}.patched.bin').exists() and (self.patched / f'{m}.fixups.tsv').exists()): die(f'no rewritten module {self.patched}/{m} (run dm/tools/patch_nso.py first)')
        if not (self.romfs / self.marker).exists(): die(f'no RomFS at {self.romfs} (missing {self.marker})')
        if self.capture:
            self.msl_ios = WORK_EMPTY_MSL; (self.msl_ios / self.msldir).mkdir(parents=True, exist_ok=True)
            return
        if self.gfx == 'vulkan':
            if not (self.msl_ios / 'vk/vk_shaders.metallib').exists(): die(f'no iOS Vulkan shader library {self.msl_ios}/vk')
        elif self.gfx == 'gl':
            if not (self.msl_ios / 'gl/gl_shaders.metallib').exists(): die(f'no iOS GL shader library {self.msl_ios}/gl')
        else:
            v = chain_version()
            if not list((self.msl_ios / self.msldir).glob('*_b.metallib')): die(f'no iOS shader libraries {self.msl_ios}/{self.msldir}')
            inputs = py(DM / 'gfx/tools/dmsh_chain.py', '--inputs', env=dict(env, DM_GAME=game))
            stamp = (self.msl_ios / self.msldir / 'inputs.tsv')
            lines = stamp.read_text(encoding='utf-8').splitlines() if stamp.exists() else []
            if f'game\t{game}' not in lines or f'inputs\t{inputs}' not in lines: die(f'the iOS shader libraries {self.msl_ios}/{self.msldir} are not a full build from this profile\'s current tables (inputs {inputs})')
            c1 = gd / 'c1_full.tsv'
            first = c1.read_text(encoding='utf-8').splitlines()[:1] if c1.exists() else []
            if not (first and first[0].startswith(f'# chain b-{v} inputs {inputs} ')): die(f'{c1} is missing or not made from these libraries (chain {v}, inputs {inputs})')

    def tables(self, td, vnacp, env):
        """build_ipa.sh program_tables: the rewriter's tables, the shader tables and the launcher's settings into td"""
        td.mkdir(parents=True, exist_ok=True)
        gd = self.gd
        for pat in ('*.fixups.tsv', '*.gates.tsv', '*.cuts.tsv', '*.obs.tsv'):
            for f in self.patched.glob(pat): shutil.copy2(f, td)
        if (self.patched / 'nro.tsv').exists(): shutil.copy2(self.patched / 'nro.tsv', td)   # the NRO modules the game loads with nn::ro (hle_ro.c), embedded by gen_embed.py
        for f in ('shader_map.tsv', 'pso_manifest.tsv') + (() if self.gfx in ('vulkan', 'gl') else ('c1_full.tsv',)):
            if self.capture and not (gd / f).exists(): continue   # a capture IPA has no shader build: the tables it would stamp may not exist yet
            shutil.copy2(gd / f, td)
        if self.gfx == 'nvn':
            if (gd / 'cb_extent.tsv').exists(): shutil.copy2(gd / 'cb_extent.tsv', td)
            else: t(f'no {gd}/cb_extent.tsv: the host copies whole uniform bindings')
            # the shader pairs, beside the shader map where the pipeline prebuild reads them (nvn_mtl.m pso_prebuild): without them the app makes no pulling bases (build_ipa.sh)
            for f in ('shader_pairs.tsv', 'pso_pairs.tsv'):
                if (gd / f).exists(): shutil.copy2(gd / f, td)
        t('launcher' + (f' (program {self.n})' if self.n is not None else '') + ': ' + py(DM / 'games/settings.py', self.game, self.patched, vnacp, td / 'launcher.json', env=dict(env, GFXAPI=self.gfx, GAME=self.game)))


WORK_EMPTY_MSL = None


def pso_gpus(env, prof):
    """build_ipa.sh's DM_PSO_GPUS default: the profile's pso_gpu (1-4 GPU architectures) for a game that sets pso_mtl4 on, else g18p; none for the others"""
    if 'DM_PSO_GPUS' in env: return env['DM_PSO_GPUS']
    if prof.get('pso_mtl4', 'off') != 'on': return 'none'
    pg = prof.get('pso_gpu', '').split()
    ok = 1 <= len(pg) <= 4 and all(w != 'none' and re.fullmatch(r'[A-Za-z0-9]+', w[len('applegpu_'):] if w.startswith('applegpu_') else w) for w in pg)
    if pg and not ok: t(f'profile {prof.dir}: pso_gpu {" ".join(pg)!r} is not 1-4 GPU architectures - taking g18p')
    return ','.join(pg) if pg and ok else 'g18p'


def git_commit():
    """DMCommit (build_ipa.sh): the checkout that built the app, +dirty with uncommitted changes to tracked files; None without git"""
    try:
        c = subprocess.run(['git', '-C', str(DM), 'rev-parse', '--short=12', 'HEAD'], capture_output=True, text=True)
        if c.returncode: return None
        d = subprocess.run(['git', '-C', str(DM), 'status', '--porcelain', '--untracked-files=no'], capture_output=True, text=True)
        return c.stdout.strip() + ('+dirty' if d.stdout.strip() else '')
    except OSError: return None


def main():
    global WORK_EMPTY_MSL
    if len(sys.argv) > 1 and sys.argv[1] == '--prepare-xcode': die('--prepare-xcode makes an Xcode project: it needs a Mac (this Windows build packs the IPA directly)')
    env = os.environ
    game = env.get('GAME') or die('GAME is not set')
    w = Path(env.get('W') or die('W is not set: W=<NSP folder>/<title ID>-work'))
    sys.path.insert(0, str(DM / 'games')); import game as gm
    prof = gm.load(game)
    gd = prof.dir
    gp = lambda k: prof.get(k)
    if not (gd / 'game.tsv').exists(): die(f'no game profile {gd}/game.tsv')
    pkg = gp('package')
    WORK_EMPTY_MSL = w / 'build/ios/empty_msl'
    capture = env.get('NXW_CAPTURE_IPA') == '1'   # a capture IPA: no shader libraries (the game runs only to compile its run-time shaders, which its env.txt has the host save)
    p0 = Program(None, game, env.get('PATCHED') or w / f'build/patched_{pkg}', rfs.Path(env.get('ROMFS') or rfs.source(w / f'data/{pkg}')),   # <extraction>/RomFS.img, else the RomFS folder (build_ipa.sh)
                 env.get('MSL_IOS') or w / 'build/ios/dmsh_b', env.get('GFXAPI'), capture)
    programs_tsv = env.get('PROGRAMS_TSV')
    progs = [p0]
    if programs_tsv:   # a game of several programs: index, profile, patched, RomFS, iOS shaders, graphics API (program 0's row is GAME's)
        if not Path(programs_tsv).is_file(): die(f'no PROGRAMS_TSV {programs_tsv}')
        progs = []
        for ln in Path(programs_tsv).read_text(encoding='utf-8').splitlines():
            if not ln.strip() or ln.startswith('#'): continue
            n, g, pt, rf, ms, gx = (ln.split('\t') + [''] * 6)[:6]
            progs.append(Program(int(n), g, pt, rfs.Path(rf), ms, gx or None, capture))
        if not progs or progs[0].n != 0 or progs[0].game != game: die(f'{programs_tsv}: the first row must be program 0, the game {game}')
        if env.get('NXW_SPLIT_DATA', '') not in ('', '0'): die('a game of several programs keeps its programs\' files in the app: build without --split-data')
        if env.get('NXW_MODS_ROMFS'): die('mods\' RomFS folders are not supported for a game of several programs')
    for p in progs:
        if p.n is not None: t(f'program {p.n}: {p.game} ({p.prof.get("name")}), {p.gfx}')
        p.check(env)
    p0 = progs[0]
    romfs, image, gfx, msl_ios, msldir, patched = p0.romfs, p0.image, p0.gfx, p0.msl_ios, p0.msldir, p0.patched
    aoc = Path(env['AOC']) if env.get('AOC') else (None if 'AOC' in env else w / 'data/aoc')
    out_ipa = Path(sys.argv[1]) if len(sys.argv) > 1 else w.parent / gp('ipa')
    nacp = w / 'data/v0/control.nacp'
    if not nacp.exists(): nacp = romfs.parent / 'control.nacp'
    vnacp = romfs.parent / 'control.nacp'
    if not vnacp.exists(): vnacp = w / 'data/v0/control.nacp'
    name = env.get('DM_DISPLAY_NAME') or py(DM / 'tools/nacp.py', nacp)
    r = subprocess.run([sys.executable, str(DM / 'tools/nacp.py'), '--version', str(vnacp)], capture_output=True, text=True)
    version = env.get('DM_APP_VERSION') or (r.stdout.strip() if r.returncode == 0 and r.stdout.strip() else '1.0')
    bundle_id = env.get('DM_BUNDLE_ID') or f'org.nxnative.{game.lower()}'
    prefix = env.get('NXW_BUNDLE_PREFIX')   # the Windows driver's default prefix (org.nxnativewindows), unless --bundle-id named an ID
    if prefix and bundle_id.startswith('org.nxnative.'): bundle_id = prefix.rstrip('.') + bundle_id[len('org.nxnative'):]
    show_fps = env.get('DM_SHOW_FPS', '0') in ('1', 'YES')
    lang = env.get('DM_LANG') or 'en-US'

    if env.get('NXW_MODS_ROMFS'):   # mods' RomFS folders (win/mods.py): over a RomFS image (the NSP script's extraction), a new image with them in it; over a folder, hard links
        import mods
        if image: romfs = p0.romfs = rfs.Path(mods.overlay_image(Path(str(romfs)), env['NXW_MODS_ROMFS'].split(os.pathsep), w / 'build/romfs_mods.img', log=t))
        else: romfs = p0.romfs = mods.overlay_romfs(romfs, env['NXW_MODS_ROMFS'].split(os.pathsep), w / 'build/romfs_mods', log=t)
    v = chain_version()
    if capture: t('capture IPA: no shader libraries; the game saves the shaders it compiles at run time into Documents')

    sdk = tc.ios_sdk() or die('no iPhoneOS SDK: set NXW_IOS_SDK (win/sdk/extract_xip.py extracts it from Xcode.xip)')
    clang = tc.llvm_tool('clang') or die('no clang: install LLVM for Windows (https://github.com/llvm/llvm-project/releases)')
    if not tc.llvm_tool('ld64.lld'): die('no ld64.lld in the LLVM folder')
    sdk_ver, sdk_build = tc.sdk_settings(sdk)
    t(f'app: {name} {version} ({bundle_id}), language {lang}{", frame-rate counter on" if show_fps else ""}; SDK {sdk.name} {sdk_ver} {sdk_build}')

    base = w / 'build/ios/win'
    gen, app = base / 'Gen', base / 'Payload/DmIOS.app'
    if gen.exists(): shutil.rmtree(gen)
    if app.exists(): shutil.rmtree(app)
    (gen / 'profile').mkdir(parents=True); app.mkdir(parents=True)
    t('generate Gen/ (profile header, host shaders, embedded modules, tables)')
    py(DM / 'games/game.py', 'header', game, gen / 'profile/game_profile.h')   # with programs, a table of the programs' profiles (game.py header_multi)
    msl_h = host_msl(base / 'msl-iphoneos')   # kept between builds: the generator reuses it while its inputs match
    es = gen / 'embed.S'
    flags, parts = [], []
    for p in progs:
        jit = p.extra / 'jit/jit.img'
        tagged = ['--tag', p.tag] if p.tag else []
        out = gen / (f'embed_{p.tag}.S' if p.tag else 'embed.S')
        flags += py(IOS / 'tools/gen_embed.py', *tagged, *(['--jit', jit] if jit.is_file() else []), p.patched, out, *p.mods).split()
        parts.append(out)
    if programs_tsv:
        es.write_text(''.join(q.read_text(encoding='utf-8') for q in parts), encoding='utf-8')
        for q in parts: q.unlink()
    es.write_text(re.sub(r'\.incbin "([^"]*)"', lambda m: '.incbin "' + m.group(1).replace('\\', '/') + '"', es.read_text(encoding='utf-8')), encoding='utf-8')   # assembler strings take \ as an escape

    dmres = app / 'dm'; dmres.mkdir()
    if programs_tsv:
        for p in progs:
            pv = p.extra / 'control.nacp'
            p.tables(dmres / p.tag, pv if pv.exists() else vnacp, env)
        (dmres / 'programs.txt').write_text(''.join(f'{p.n}\n' for p in progs), encoding='utf-8')
        lj = dmres / 'p0/launcher.json'
    else:
        p0.tables(dmres, vnacp, env); lj = dmres / 'launcher.json'
    # The packed language (DMLanguage) is the Game language row's default, which settings.py makes the game's first language when it lacks DM_LANG (build_ipa.sh)
    try: ld = next((x['default'] for x in json.loads(lj.read_text(encoding='utf-8'))['settings'] if x['env'] == 'DM_LANG'), '')
    except (OSError, ValueError, KeyError): ld = ''
    if ld and ld != lang: t(f'game language: the game has no {lang}; packing {ld}, its first'); lang = ld
    # The pipeline archive made offline (dm/gfx/tools/pso_offline.py, as build_ipa.sh): the base of every shader pair compiled by metal-tt (Metal Developer Tools for Windows has it)
    # for each GPU architecture in DM_PSO_GPUS (comma-separated; none = no archive). Default: the profile's pso_gpu, else g18p, for a game whose profile sets pso_mtl4 on, else none
    pso = None
    gpus = pso_gpus(env, prof)
    if gfx == 'nvn' and not capture and not programs_tsv and gpus and gpus != 'none' and (gd / 'shader_pairs.tsv').exists():
        pso = w / 'build/ios/pso/bundle'
        t(f'pipeline archive for {gpus} (metal-tt; minutes when its inputs changed)')
        r = subprocess.run([sys.executable, str(DM / 'gfx/tools/pso_offline.py'), '--game', game, '--msl', str(msl_ios / msldir), '--out', str(pso), '--work', str(w / 'build/ios/pso/work'),
                            '--gpu', gpus] + (['--os-min', env['DM_PSO_IOS_MIN']] if env.get('DM_PSO_IOS_MIN') else []))
        if r.returncode: die('pipeline archive (dm/gfx/tools/pso_offline.py; DM_PSO_GPUS=none builds the app without it)')
    elif gfx == 'nvn': t('no pipeline archive (' + (f'DM_PSO_GPUS={gpus}' if 'DM_PSO_GPUS' in env else 'the profile does not set pso_mtl4 on; DM_PSO_GPUS=g18p builds one')
                         + ('' if (gd / 'shader_pairs.tsv').exists() else ', no shader_pairs.tsv') + ')')
    if env.get('DM_ENV_FILE'): shutil.copy2(env['DM_ENV_FILE'], dmres / 'env.txt')
    (dmres / 'font').mkdir()
    font = tc.std_font() or die('no standard font: set STD_FONT to a TTF with broad Unicode coverage')
    shutil.copy2(font, dmres / 'font/standard.ttf'); t(f'standard font: {font}')
    py(DM / 'tools/make_ext_font.py', dmres / 'font/nintendo_ext.ttf', tc.letter_font() or die('no bold TTF for the button icons: set LETTER_FONT'))

    files, incs = host_sources(gen / 'profile', msl_h)
    files += [p.resolve() for p in sorted((IOS / 'Sources').glob('*.m'))] + [(WIN / f'ios/{n}').resolve() for n in WIN_IOS_SOURCES] + [es.resolve()]
    dav1d, dav1d_incs = dav1d_sources()
    fws = frameworks(sdk, files)
    rt = compat_rt_needed(clang)
    if rt:
        rt.parent.mkdir(parents=True, exist_ok=True)
        r = subprocess.run([str(clang), '-target', f'arm64-apple-ios{tc.IOS_DEPLOYMENT}', '-isysroot', str(sdk), '-Os', '-c', str(WIN / 'ios/compat_rt.c'), '-o', str(rt)], capture_output=True, text=True)
        if r.returncode: print(r.stderr, file=sys.stderr); die('compat_rt.c')
    objs = compile_all(clang, sdk, files, incs, base / 'obj', [])
    objs += compile_all(clang, sdk, dav1d, dav1d_incs, base / 'obj-dav1d', DAV1D_FLAGS)
    link(clang, sdk, objs, fws, flags, app / 'DmIOS')
    # The entitlements the app asks for, in an ad-hoc signature of its own (win/macho_sign.py): the player's signing tool keeps those its Apple ID allows. Increased Memory Limit
    # is free to enable on an App ID (SideInstaller does it), but SideStore installs only what the executable asks for: unsigned, it asked for nothing
    # On by default (NXW_ENTITLEMENTS=0 / --no-entitlements leaves the executable unsigned). Checked against rcodesign's own ad-hoc signature; SideStore with Increased Memory Limit
    # enabled for the App ID (SideInstaller) installs it On, and a signing tool that may not grant it drops it: the app opens either way
    if env.get('NXW_ENTITLEMENTS', '1') != '0':
      import macho_sign
      ents = {'com.apple.developer.kernel.increased-memory-limit': True}
      t(f'entitlements asked for: {", ".join(ents)} (' + str(macho_sign.sign(str(app / 'DmIOS'), bundle_id, ents)) + '-byte ad-hoc signature)')

    icon = Path(env.get('DM_ICON') or romfs.parent / 'icon.jpg')
    icons = icon.exists() and make_icons(icon, app)
    if not icon.exists(): t(f'no app icon ({icon} not found): the home-screen icon stays blank')
    with open(app / 'Info.plist', 'wb') as f:
        pl = info_plist(bundle_id, name, version, gp('app_category'), show_fps, lang, sdk_ver, sdk_build, icons)
        if env.get('DM_METAL_CAPTURE') == '1': pl['MetalCaptureEnabled'] = True; t('Metal frame capture: enabled (DM_METAL_CAPTURE=1)')   # the host's DM_GPU_CAPTURE switch
        commit = git_commit()   # DMCommit / DMChain: the checkout and the shader chain the host logs at start (main.c)
        if commit: pl['DMCommit'] = commit; t(f'source: {commit}')
        if msldir.startswith('b-'): pl['DMChain'] = msldir[2:]
        sp = env.get('NXW_SPLIT_DATA', '')
        if sp and sp != '0':   # a split build: the app's "game data needed" screen (win/ios/DataHelp.m) names the data folder and its size
            dname = Path(sp).name if sp not in ('1', 'YES') else out_ipa.stem + '-data'
            dsize = sum(n for d in (None if image else romfs, msl_ios / msldir, aoc if aoc and aoc.is_dir() else None) if d for _, _, n, _ in list_files(d))   # listed once, reused by split_data
            if image: dsize += Path(str(romfs)).stat().st_size
            pl['NXWDataFolder'] = dname; pl['NXWDataSize'] = f'{dsize / 2**30:.1f} GB' if dsize >= 2**30 else f'{dsize / 2**20:.0f} MB'
        plistlib.dump(pl, f, fmt=plistlib.FMT_BINARY)
    (app / 'PkgInfo').write_bytes(b'APPL????')

    has_aoc = bool(aoc and aoc.is_dir() and any(aoc.iterdir()))
    if has_aoc: t('add-on content: ' + ' '.join(sorted(p.name for p in aoc.iterdir())))
    split = env.get('NXW_SPLIT_DATA', '')
    P = 'Payload/DmIOS.app'
    maps = [f'{P}={app}']
    skips = [f'{P}/{x}' for x in ('_CodeSignature', 'embedded.mobileprovision', 'msl', 'aoc', 'romfs', 'romfs.img', 'romfs.id', 'html', 'jit', 'pso')]
    if pso: maps.append(f'{P}/pso={pso}')
    # The pulling vertex libraries (<key>_bp) serve the hybrid pipelines: packed when the profile compiles pso_mtl4 in (DM_GAME_PSO_MTL4), or IOS_PULL=1, and always with an archive (build_ipa.sh)
    m = re.search(r'^#define DM_GAME_PSO_MTL4 (\d)', (gen / 'profile/game_profile.h').read_text(encoding='utf-8'), re.M)
    pull = env.get('IOS_PULL') or (m.group(1) if m and not programs_tsv else '0')
    skip_bp = not pso and pull != '1'
    if programs_tsv:   # each program's shader libraries, RomFS, offline HTML pages and nn::jit image under its own folder (build_ipa.sh)
        if has_aoc: maps.append(f'{P}/aoc={aoc}')
        for p in progs:
            skips.append(f'{P}/{p.tag}')
            maps.append(f'{P}/{p.tag}/romfs.img={p.romfs}' if p.image else f'{P}/{p.tag}/romfs={p.romfs}')
            maps.append(f'{P}/msl/{p.tag}/{p.msldir}={p.msl_ios / p.msldir}')
            for d in ('html', 'jit'):
                if (p.extra / d).is_dir(): maps.append(f'{P}/{p.tag}/{d}={p.extra / d}'); t(f'program {p.n}: {d}/ from {p.extra / d}')
    elif split and split != '0':
        # Split build: the IPA holds only the app (small, quick to sign and install); the game files and shader libraries go to a data folder the player copies
        # into the app's Documents (dm/ios/Sources/main.m looks for <Documents>/romfs(.img) and <Documents>/<folder>/romfs(.img), and takes msl/ and aoc/ beside it).
        # The RomFS goes as the extraction has it: the romfs folder, or one image (RomFS.img, the NSP script's and the NUP / dump packers' extraction) as romfs.img
        data = Path(split) if split not in ('1', 'YES') else out_ipa.with_name(out_ipa.stem + '-data')
        split_data(data, {('romfs.img' if image else 'romfs'): Path(str(romfs)) if image else romfs, f'msl/{msldir}': msl_ios / msldir, **({'aoc': aoc} if has_aoc else {})},
                   f'game\t{game}\nbundle_id\t{bundle_id}\nversion\t{version}\nchain\t{v}\ngfx\t{gfx}\n', name, skip_suffix=('_bp.metallib',) if skip_bp else ())
        for d in ('html', 'jit'):   # small, and read from the app (hle_web.c, loader.c dm_jit_serve_dir): they stay in the IPA
            if (p0.extra / d).is_dir(): maps.append(f'{P}/{d}={p0.extra / d}')
    else:
        maps.append(f'{P}/msl/{msldir}={msl_ios / msldir}')
        if has_aoc: maps.append(f'{P}/aoc={aoc}')
        maps.append(f'{P}/romfs.img={romfs}' if image else f'{P}/romfs={romfs}')   # main.m romfs_locate opens <App>/romfs.img (build_ipa.sh)
        for d in ('html', 'jit'):   # beside the RomFS: offline HTML pages (hle_web.c) and the nn::jit image (loader.c dm_jit_serve_dir)
            if (p0.extra / d).is_dir(): maps.append(f'{P}/{d}={p0.extra / d}'); t(f'{d}/ from {p0.extra / d}')
    zs = sorted({z for p in progs for z in p.prof.get('zip_store').split(':') if z})   # every program's
    t('pack IPA (already-compressed game files stored, everything else deflated)')
    r = subprocess.run([sys.executable, str(IOS / 'tools/pack_ipa.py'), str(out_ipa), '--store', ':'.join(zs), '--exec', f'{P}/DmIOS',
                        *[x for s_ in skips for x in ('--skip', s_)], *(['--skip-suffix', '_bp.metallib'] if skip_bp else []), *maps])
    if r.returncode: die('pack_ipa')
    sz = out_ipa.stat().st_size; t(f'done: {out_ipa} ({sz / 2**30:.1f} GB)' if sz >= 2**30 else f'done: {out_ipa} ({sz / 2**20:.1f} MB)')


if __name__ == '__main__':
    main()
