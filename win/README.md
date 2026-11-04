# nxnative on Windows

This folder builds the same IPA as `scripts/build_ipa_from_nsp.py` on a Windows 10/11 PC, with no Mac or Xcode.
The pipeline itself is unchanged: the upstream script runs as-is. Only the steps that call macOS tools are replaced, at the subprocess boundary.

Status: **an IPA built this way runs on a device.** Balatro was built on Windows 11, sideloaded and played on an iPad (A16, iPadOS 27); Megabyte Punch is under test. The player-facing guide is the repository's [README.md](../README.md). See also [Open risks](#open-risks).

Verified on Windows 11 with LLVM 23.1.4, Metal Developer Tools for Windows 6.2 (`metal 32023.850`) and the iPhoneOS 27.1 SDK from `Xcode_27.1.xip`:

- **Shaders:** a test MSL shader compiles to `.metallib` for both `air64-apple-ios18.0` and macOS.
- **Compile:** `win/compile_check.py` compiles all 267 app sources: host, NVN-on-Metal 4, libvpx, dav1d, the iOS front end (with the touch controls editor), `Launcher.m` and `GameMenu.m`. Checked on Linux with clang 20 and the iPhoneOS 27.1 SDK (`NXW_MCPU=apple-a17` for an LLVM older than apple-a18).
- **Link:** `ld64.lld` links the app with no undefined symbols. The SDK's stubs list only `arm64e`, and `arm64` links against them. With a synthetic rewritten module, `gen_embed.py`'s sections and the `-segprot` W segment come out as on a Mac.
- **Unit tests:** `win/tests/test_win.py` passes.

## How each macOS step is replaced

| Upstream step (Mac) | Windows replacement | Where |
|---|---|---|
| `xcrun -sdk iphoneos/macosx metal`, `metallib` | Apple's **Metal Developer Tools for Windows** (`metal.exe`, `metallib.exe`). `-mios-version-min=X` becomes `-target air64-apple-iosX`. | `win/xcrun.py` |
| `xcodegen` + `xcodebuild` (C, ObjC, asm, Swift) | **LLVM clang** (`-target arm64-apple-ios26.0 -isysroot iPhoneOS.sdk`), one compile per file, linked by **ld64.lld** | `win/build_app.py` |
| `Launcher.swift`, `LauncherSettings.swift`, `LauncherRow.swift` (SwiftUI) | `win/ios/Launcher.m`: a UIKit port with the same `dm_show_launcher` contract (sub-settings, launch-fixed values, cloud saves, programs' `DM_APP_DM`), so no Swift toolchain is needed | `win/ios/Launcher.m`, `win/ios/Launcher.h` |
| `GameMenu.swift` | `win/ios/GameMenu.m`: the in-game menu (`dm_game_menu`), with the same rows and **Edit touch controls…** | `win/ios/GameMenu.m` |
| `make` (`gen/msl-iphoneos/host_msl_gen.h`, `gen/dav1d`) | `host_msl.py` through `win/xcrun.py` (Metal Developer Tools for Windows), dav1d compiled with its Makefile flags | `win/build_app.py` |
| Darwin compiler-rt (`@available`) | `win/ios/compat_rt.c` (`__isPlatformVersionAtLeast` through `_availability_version_check`), used only when LLVM has no `libclang_rt.ios.a` | `win/ios/compat_rt.c` |
| `actool` asset catalog | loose PNG icons named in `CFBundleIcons`, scaled by Pillow | `win/build_app.py` |
| `sips`, `plutil` | Pillow, `plistlib` | `win/build_app.py` |
| `make -n -B dmhost` (source list) | the `dm/host/Makefile` source rules, reproduced. The build stops if the Makefile's `SRC=` / `GFX=` lines change. | `build_app.host_sources()` |
| `dmsh_xlate` apphost (Mach-O) | `dotnet dmsh_xlate.dll`: the same locked DLLs, so the chain fingerprints still match `dmsh_chain.lock` | `win/pyshim/sitecustomize.py` |
| `which`, `python3`, `ctypes.CDLL(None)` (clonefile) | `shutil.which`, the current Python, an empty library (falls back to plain copies) | `win/pyshim/sitecustomize.py` |
| Unix modes in the IPA (the executable's x bit) | `pack_ipa.py --exec`: on Windows, folders are packed as 755, the executable as 755, other files as 644 | `dm/ios/tools/pack_ipa.py` |
| iPhoneOS SDK from Xcode | `win/sdk/extract_xip.py` streams `Xcode_26.xip` (xar, then pbzx, then cpio) and writes only `iPhoneOS.sdk` | `win/sdk/extract_xip.py` |

These steps already run on Windows as they are: `nx_extract` (.NET, LibHac), the NSO rewriter (`patch_nso.py`), shader translation (`dmsh_xlate`), spirv-cross, reflection and tables (`dmsh_build.py`, `c1_guard.py`, `cb_extent.py`), and `pack_ipa.py`.

### LÖVE games without the Mac host

Upstream gets Balatro's shaders by booting it in the Mac host with `DM_GL_CAPTURE`. `win/love_shaders.py` makes them offline instead:

1. It reads LÖVE's `wrap_GraphicsShader.lua`, which love-nx embeds in `main` as text.
2. It takes the GLSL blocks out of that file.
3. It assembles the same sources `love.graphics._shaderCodeToGLSL` would: the default shaders, plus one shader per `resources/shaders/*.fs`.

The four default shaders match the hashes in the profile's `gl_capture.tsv` byte for byte. On v0, the 31 game stages differ from the table only because v0's `.fs` files differ from 1.1.3's.

### Steps upstream runs in the Mac host

Some games make shaders or code only at run time, and to get them upstream boots the game's own arm64 code in the Mac host. On Windows the same code runs on the device or in an emulated ARM64 machine instead:

- **Run-time shader captures** (GLSLC: Fire Emblem: Three Houses, Portal; Vulkan: Super Mario Galaxy; GL of a non-LÖVE game): the first build packs a capture IPA (`<game>-capture.ipa`) and stops with the steps. After one run on the device, the folder it wrote in Documents, copied next to the game files, finishes the build.
- **The NRO capture** (Mario Tennis Fever, a Switch 2 game whose `main` is a boot stub that decodes the game's code at run time): the same way. The capture IPA boots the rewritten stub with `DM_NRO_CAPTURE=nro_capture` and closes itself within seconds of **Play**, once `dm/host/hle_ro.c` has written the decoded NRO. Copy the app's `nro_capture` folder next to the game files and build again: the NRR's SHA-256 checks the image, and the rewrite takes it as upstream's capture does (`win/build_ipa_windows.py capture_nro`).
- **Oodle, LZ5 and Unreal decoding** (Pokémon Legends: Z-A, PlatinumGames PKZ games, DRAGON QUEST XI S, OCTOPATH TRAVELER 0, …): the game's own decoder runs in an emulated ARM64 machine (`win/oodle_emu.py`).
- **The heap check and the address region check** of a provisional profile: estimated from the files (`heap_estimate`) and skipped (`region_skip`); both only report.

Still Mac-only: the nn::jit capture (`uses_jit`, no game in the table needs it yet) and Mac apps.

The detection rules are in `dm/games/profile_guess.py`. Most games need none of these steps, for example Mario Wonder, Odyssey, Mario Kart 8 Deluxe, Zelda BotW/TotK and Mario Kart World.

## Prerequisites

Run `python win/doctor.py`. It lists what is missing and where to get it:

1. **Python 3.10+**, then: `python -m pip install lz4 capstone fonttools pillow zbic "backports.zstd; python_version < '3.14'"`
2. **.NET SDK 10** (x64)
3. **LLVM for Windows** 20 or later (`LLVM-*-win64.exe`; it includes `clang.exe` and `ld64.lld.exe`)
4. **Metal Developer Tools for Windows**, from developer.apple.com/download (free Apple ID)
5. **iPhoneOS 26 SDK**: download `Xcode_26.x.xip` from developer.apple.com/download (free Apple ID), then run `python win/sdk/extract_xip.py Xcode_26.x.xip`. Copying `iPhoneOS.sdk` from a Mac also works.
6. **spirv-cross** and **zstd**, Windows builds (the Vulkan SDK has spirv-cross and glslangValidator; zstd has releases on GitHub)
7. Optional: `STD_FONT`, a TTF with broad Unicode coverage for the shared-font stand-in. The default is Windows' Arial.

If a tool is not found automatically, set its path in `win/toolchain.json` (copy `win/toolchain.example.json`) or with `NXW_<KEY>` environment variables.

Licences: Apple's Xcode and SDK agreement covers how its SDK and tools may be used. Read it before you use them on non-Apple hardware.

## Build

```
python win/build_ipa_windows.py D:\Games\MarioWonder -k D:\keys\prod.keys
```

The options are the upstream script's (`-h`). Only `--platform ios` exists here. The IPA is unsigned, as upstream: sign it with your sideloading tool (Sideloadly on Windows, AltStore, …), with the Increased Memory Limit capability where the tool offers it.

### Notes on the tools

- **Metal Developer Tools for Windows 5.x and 6.x** ship one toolchain in `bin/` for every target, and the `-target` triple picks the OS. 4.x had separate `ios/` and `macos/` folders. `win/toolchain.py` finds either layout.
- **Xcode 27's `.xip`** is a sorted, deduplicated cpio (Metadata `xbs_sortcpio`). Only one entry of each hard-linked inode carries the bytes; the others hold a `NULLcanary` placeholder of the same size. `extract_xip.py` reads the archive twice: the first pass finds the entry that carries each inode's bytes, the second writes them to every SDK path. The extractor also resolves symlinks that point through other symlinks (`Headers → Versions/Current/Headers`).
- **Line endings:** the checkout must keep LF (see `.gitattributes`). The shader chain hashes source bytes, so a CRLF checkout breaks `dmsh_xlate --source-sha`.

## Open risks

These risks remain until a real game is built and played. Check each one in this order:

1. **Shader libraries on the device:** they come from the Windows compiler (`32023.850`; upstream locks Xcode's `32023.921`). They must load and render on iOS 26+ (`newLibraryWithURL`). `own_compilers.py` accepts the different compiler.
2. **The real game modules:** sections hundreds of MB large, linked by `ld64.lld`, then signed by the sideloading tool.
3. **Icons without an asset catalog** on iOS 26.
4. **The launcher port** (`Launcher.m`, `GameMenu.m`) must behave like `Launcher.swift` and `GameMenu.swift`.

The `rea` MCP (github.com/morluto/rea) is optional. It helps compare a Windows-built Mach-O with a Mac-built one (load commands, sections, symbols) when a step above fails.
