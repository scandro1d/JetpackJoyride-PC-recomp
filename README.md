# Jetpack Joyride (PS3) on Windows - community build kit

Runs **your own copy** of *Jetpack Joyride Deluxe* (PSN `NPUB31615`) natively on Windows by statically recompiling
the PS3 game with [ps3recomp](https://github.com/sp00nznet/ps3recomp). This repository contains **only tooling and patches -
no game files, no recompiled game code, no game executable**. You build everything yourself from your own game.

> **Status: experimental test release.** It builds and runs from a clean install on the author's PC (Windows 11, RTX 5070)
> but has not been tried on other machines yet, so expect rough edges. Please open an issue with your `play.log` (and
> `builder.log` if the build failed) if something breaks.

## What you get
- Picture, sound and keyboard/controller input working
- **F1 settings window** (controller-friendly): master / music / effects volume, windowed or fullscreen, window size,
  internal **render resolution 720p-4K**, sharpening, keyboard and controller remapping
- Fullscreen keeps 16:9 (pillarboxed on ultrawide) and crops the game's own black border
- `builder.exe` that builds the game from your own files, and a `JetPackJoyride.exe` launcher

## Legal
You need to own the game and supply its files yourself. Don't share decrypted game files or the binaries you build from
them. This is for personal use. See [NOTICE.md](NOTICE.md).

## What you need
- 64-bit Windows 10/11, 16 GB RAM (more is better), ~15 GB free disk, a GPU with Direct3D 12
- **Visual Studio 2022 Build Tools** with: *Desktop development with C++*, *C++ Clang tools for Windows*,
  *C++ CMake tools for Windows*, and a Windows 10/11 SDK
- **Git for Windows** and **Python 3.10+** (tick "Add python.exe to PATH")
- From your own copy of the game: the **decrypted** `EBOOT.elf`, `jet.pak` and `sound.pak` (plain files - the original
  `jet.pak.edat` / `sound.pak.edat` and `EBOOT.BIN` are encrypted and will be rejected), plus the extracted game folder
  (contains `PARAM.SFO` and `USRDIR\movies\BS_ShirtSleeves_Final.avi`). This project does not include, and cannot
  create, the decrypted files: you must already have them from your own copy of the game.
- A PS3 firmware **`dev_flash`** folder (RPCS3 installs one)

## Install - the easy way (builder.exe)
1. Download the release zip and unzip it somewhere (keep the folders next to `builder.exe`).
2. Run **`builder.exe`** (it asks for administrator rights because it may install tools). Windows SmartScreen or your
   antivirus may warn about it because it is not code-signed; the source is in `builder\builder.c` (rebuild it with `builder\build_builder.ps1`).
3. Choose your **game folder** (the folder called `NPUB31615` that contains `PARAM.SFO` and `USRDIR`).
   The decrypted files and your PS3 `dev_flash` folder are found automatically when they sit next to it / RPCS3 is
   installed; otherwise pick them in the boxes.
4. Choose where to install (default `C:\JetpackJoyride`, a short path without spaces) and press **Build**.
   It installs anything missing (Git, Python, Visual Studio Build Tools), translates and compiles the game. Plan on one to
   a few hours the first time (mostly compiling), about 15 GB of disk space and 16 GB of RAM.
   Near the end (step 8, "Optimizing the sound engine") a game window opens and closes by itself for a minute or two; this
   is normal, don't close it. It creates a faster version of the game's sound code from your own files, which removes
   crackling coin sounds. If that step can't complete the build still finishes, just without the sound fix.
5. When it says *Done*, press **Play**, or run **`JetPackJoyride.exe`** in the install folder any time.

If a step fails, the message and `builder.log` (in the install folder) say why. Press Build again - finished work is reused.

## Install - manual (PowerShell)
Use a short path without spaces. From the repository folder:

```powershell
.\scripts\00_check_tools.ps1                       # checks the tools listed above
.\scripts\01_get_toolkit.ps1                       # fetches ps3recomp at a pinned commit and applies our patch
.\scripts\02_prepare_game.ps1 -Dump "D:\path\to\NPUB31615" -Decrypted "D:\path\to\decrypted"
.\scripts\03_lift.ps1                              # generates ~215 MB of C++ from your game (1-3 min)
.\scripts\04_build.ps1 -Jobs 4                     # compiles it (first build: tens of minutes to a few hours)
.\scripts\set_devflash.ps1 -Path "D:\path\to\dev_flash"
.\scripts\06_mixplug.ps1 -Jobs 4                   # sound fix: starts the game briefly, recompiles the sound code
.\scripts\05_build_launcher.ps1                    # builds JetPackJoyride.exe
```
(`.\scripts\build_all.ps1 -Dump ...` does all of this in one go; it is what builder.exe runs.)

## Controls
| | Keyboard | Controller (Xbox / XInput) |
|---|---|---|
| Settings window | **F1** (again to close) | **L3 + R3** (click both sticks); D-pad / left stick to move, A select, B close |
| Fullscreen | **F11** | Mode dropdown in the settings window |
| Leave fullscreen | **Esc** (never quits the game) | - |
| Game | arrows, Z, X, A, S, Enter, Tab (remappable) | remappable |

Changing *Render res* needs a restart; a **Restart game** button appears in the settings window. Settings are saved
in `settings.ini`.

**Controllers must be in XInput (Xbox) mode.** Many pads (for example 8BitDo) start in another mode; `.\scripts\padcheck.ps1`
tells you whether Windows sees yours as XInput.

## Known issues
- The music/effects split is approximate: music is the stereo music stream, "effects" is everything else.
- The SPU audio mixer leaks a little stack per loop; a large stack limit makes it last roughly 40+ minutes of continuous play.
- Intro movie, online features (PSN, Facebook, leaderboards) don't work.
- At render scales other than 1080p some post effects aren't scaled yet; tell us if you see artifacts.

## Testing a fresh install (maintainers)
Copy the repository to a new folder and run the Install steps there; don't reuse a folder that already has `ps3recomp\`.

## License
The tooling, scripts and patch in this repository are [MIT licensed](LICENSE). The game itself is not covered and is not
included.

## Credits
[ps3recomp](https://github.com/sp00nznet/ps3recomp) by sp00nznet. Game by Halfbrick Studios.

