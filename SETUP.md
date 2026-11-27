# Jetpack Joyride Deluxe (NPUB31615) → Windows: setup guide

This takes the decrypted PS3 game and builds a native Windows executable with
[ps3recomp](https://github.com/sp00nznet/ps3recomp) (static recompilation).
Personal use only; don't redistribute the game files or the built exe.

**Honest status.** Everything up to and including the code generation has been
run and checked on the real game. The Windows build and first boot have **not**
been run by anyone yet, so expect to iterate. Section 9 says what to send back.

| Stage | Status |
|---|---|
| Decrypt EBOOT + .edat with your RAP | done (files provided) |
| Unpack .pak archives | done (`jj_unpak.py`) |
| Analyse ELF (25,582 functions, 261 imports, all named) | done, verified |
| PPU lift → 28,705 functions, 22 C++ files (~3.2 M lines) | done, ~1 min |
| Lifted C++ syntax-checked with clang 18 | 22/22 files, 0 errors |
| SPU lift of MultiStream mixer | done with our patch (`complete=True`) |
| Windows compile and link | **not yet tried** |
| First boot, graphics, audio, input | **not yet tried** |

---

## 1. Install the tools (one time, ~10 GB)

You need a 64-bit Windows 10/11 PC with **16 GB RAM or more** (8 GB can work with
`-Jobs 1` but will be slow) and about **15 GB free disk**.

1. **Visual Studio 2022 Build Tools** (free):
   https://visualstudio.microsoft.com/downloads/ → scroll to *All Downloads* →
   *Tools for Visual Studio* → **Build Tools for Visual Studio 2022**.
   In the installer tick the workload **Desktop development with C++**, then in
   the right-hand *Installation details* panel also tick:
   - **C++ Clang tools for Windows** (gives `clang-cl`, required)
   - **C++ CMake tools for Windows** (gives `cmake` and `ninja`)
   - **Windows 11 SDK** (any 10.0.19041 or newer SDK is fine)
2. **Git for Windows**: https://git-scm.com/download/win (defaults are fine)
3. **Python 3.12**: https://www.python.org/downloads/windows/ — on the first
   installer page tick **"Add python.exe to PATH"**. (3.10 or newer works.)

Optional but useful:
- **RPCS3** (reference emulator, to compare behaviour): https://rpcs3.net/download
- If you'd rather not use the Visual Studio copies, standalone CMake
  (https://cmake.org/download/), Ninja
  (https://github.com/ninja-build/ninja/releases) and LLVM
  (https://github.com/llvm/llvm-project/releases, get `LLVM-*-win64.exe`)
  also work; just make sure they're on PATH.

Close and reopen PowerShell after installing.

## 2. Get this folder onto your PC

Unzip `jetpack_port.zip` somewhere with **no spaces in the path and short**,
e.g. `C:\jj\`. You should have `C:\jj\jetpack_port\00_check_tools.ps1` etc.

Also download from this chat (they are large, so they are separate):
`decrypted\EBOOT.elf`, `decrypted\jet.pak`, `decrypted\sound.pak`. Put them in
`C:\jj\jetpack_port\decrypted\`.

You also need your **original extracted game folder** (the one containing
`PARAM.SFO` and `USRDIR\movies\BS_ShirtSleeves_Final.avi`), e.g. `C:\jj\NPUB31615\`.

## 3. Run the scripts, in order

Open **PowerShell** in `C:\jj\jetpack_port` (Shift+right-click in the folder →
*Open PowerShell window here*). The first time, allow scripts for this session:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
```

```powershell
.\00_check_tools.ps1      # lists anything missing, with download links
.\01_get_toolkit.ps1      # clones ps3recomp at the tested commit, applies our patch
.\02_prepare_game.ps1 -Dump C:\jj\NPUB31615
.\03_lift.ps1             # ~1-3 min; makes ~215 MB of C++ in .\recompiled (expected)
.\04_build.ps1 -Jobs 4    # the long one: tens of minutes to a few hours
.\05_run.ps1              # writes run.log
```

Notes:
- `-Jobs` = parallel compiles. Each can use 2-4 GB RAM. 16 GB → 4, 32 GB → 8,
  and if you see "out of memory" or the PC freezes, lower it.
- Step 3 should end with: `28705 functions lifted`, `10518 unique call targets`
  and `1/1 candidates registered; complete=True`. If the numbers differ, stop and
  send me the output.
- Step 4 is safe to interrupt and re-run; Ninja resumes where it stopped.
- If the game window opens but is black, or it exits immediately, that's the
  expected "first boot" state. Go to section 9.

## 4. What the scripts do

| Script | What it does |
|---|---|
| `env.ps1` | Loads the Visual Studio build environment (used by the rest) |
| `00_check_tools.ps1` | Verifies git, Python, cmake, ninja, clang-cl, SDK, RAM, disk |
| `01_get_toolkit.ps1` | `git clone` ps3recomp, checks out `de4f090…`, applies `patches/0001-spu-code-end.patch`, `pip install`s its requirements, copies the template project files (CMakeLists, main.cpp, stubs.cpp) |
| `02_prepare_game.ps1` | Builds the virtual PS3 disk under `vfs\` and `game\EBOOT.ELF` |
| `03_lift.ps1` | Loader → PPU lifter → SPU lifter |
| `04_build.ps1` | CMake + Ninja with `clang-cl`, Release |
| `05_run.ps1` | Sets `PS3_VFS_ROOT`, `PS3_HDD0_ROOT`, `PS3_HDD1_ROOT` and starts the game |

Why the `.edat` names: the game opens `jet.pak.edat` and `sound.pak.edat`. Those
files are encrypted to your RAP, which the runtime can't use. The script puts the
**already-decrypted** bytes in under the same names; the runtime only tries to
decrypt files that start with the `NPD` marker, so plain files pass straight
through.

Why the patch: the MultiStream mixer (a 69 KB program the game runs on the PS3's
SPU coprocessor) is a stripped image with strings stored after the code. The
stock tool refuses it, because it can't decode the strings as instructions. The
patch adds `--code-end` so the lifter stops at the real end of code (`0xDE10`;
verified: the highest branch target is `0xDD68`).

## 5. Firmware files you may need

The game asks for `/dev_flash/sys/external/flashATRAC.pic` and `flashMP3.pic`.
These are Sony firmware files and are **not** in the game. They are probably
what the music/sound-effect mixer uses to decode ATRAC audio. If `run.log` shows
`flashATRAC.pic` failing to open, you need a PS3 firmware's `dev_flash`:

1. Install RPCS3 (https://rpcs3.net/download) and follow its Quickstart
   (https://rpcs3.net/quickstart) to install the official firmware
   (Sony's download page: https://www.playstation.com/en-us/support/hardware/ps3/system-software/).
2. Its `dev_flash` folder is then at `<RPCS3 folder>\dev_flash`.
3. Run: `.\05_run.ps1 -DevFlash C:\path\to\rpcs3\dev_flash`

If nothing asks for them, ignore this section.

## 6. Folder layout after the steps

```
jetpack_port\
  decrypted\            EBOOT.elf, jet.pak, sound.pak   (you downloaded)
  ps3recomp\            the toolkit (cloned)
  game\EBOOT.ELF        decrypted executable
  vfs\hdd0\game\NPUB31615\USRDIR\   jet.pak.edat, sound.pak.edat, movies\
  analysis\             function table, imports (JSON)
  recompiled\           lifted PPU C++   (generated, ~215 MB)
  spu\                  lifted SPU C     (generated)
  build\                compiler output; JetpackJoyride.exe lands here
```

## 7. Things that are expected and are NOT errors

- ~3.2 million lines of generated C++. Compile warnings are switched off for them.
- Many "unimplemented NID" lines in `run.log`: the ~30 imports the toolkit doesn't
  cover yet (store, photo, parts of the video player). Most can stay stubbed.
- A first build taking hours.

## 8. The work that remains after it boots (so you know what's coming)

1. **Graphics.** The game talks to the GPU through raw `cellGcm` commands and
   Sony-compiled shaders. The toolkit has a Direct3D 12 backend; whether it
   renders this game correctly is unknown until we see it run.
2. **Audio.** The toolkit decodes ATRAC3plus natively, but this game mixes audio
   on the SPU via MultiStream (`.msf` files in `sound.pak`). If the lifted SPU
   mixer doesn't produce sound, the fallback is to replace it with a host mixer.
3. **Intro video.** The game plays `BS_ShirtSleeves_Final.avi` through `cellSail`,
   which is only partly implemented. Plan: skip it or play it with a host decoder.
4. **Online/store/trophies.** ~100 `sceNp*` calls to answer as "offline".

## 9. If something fails, send me these (not the whole folder)

| Failed at | Send |
|---|---|
| `00`–`02` | the text of the red error |
| `03_lift` | the console output |
| `04_build` | `configure.log` and the **first** `error:` in `build.log` |
| `05_run` | `run.log` (first ~200 lines, plus the last 50) |

Typical, easy-to-fix problems:
- *"running scripts is disabled"* → `Set-ExecutionPolicy -Scope Process Bypass`
- *`clang-cl` not found* → in the VS Installer, add **C++ Clang tools for Windows**
- *"fatal error: out of memory" / freezing* → `.\04_build.ps1 -Jobs 2`
- *`python` opens the Microsoft Store* → install Python from python.org and tick "Add to PATH"
- *Path too long errors* → move the folder closer to `C:\`
