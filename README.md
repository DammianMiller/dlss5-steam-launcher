# DLSS 5 Steam Launcher (Linux / Proton)

Runs Steam and Epic Games Launcher games under Proton with NVIDIA's **DLSS 5
Neural Rendering** model active, and installs the override safely into each
game: SHA-256-pinned components, a journaled backup of everything that
changes, and one-command restore. Built for this machine's RTX 5090 + driver
615.71.09 + Wineland Proton setup, and validated against the real components.

DLSS 5 (September 2026) is not a DLSS 4-style DLL swap: NVIDIA ships a new
runtime, `nvngx_dlssnr.dll`, and offers no override switch in the NVIDIA App.
On Linux/Proton the working route is the **Retoque** project (an OptiScaler
fork, Linux-first), which loads as a proxy DLL beside the game executable:

1. **`dxgi.dll`** — Retoque 0.3.3 (OptiScaler fork) proxy; forwards everything
   to the real DXGI except the upscaler calls and presents it is interested in.
   The game's own Streamline `sl.*` plugins are never touched.
2. **`nvngx.dll_dlssnr.dll`** — the forwarder; the model only answers callers
   whose module path contains `nvngx.dll`.
3. **`nvngx_dlssnr.dll`** — NVIDIA's signed DLSS 5 NR model **310.9.16**, which
   this launcher supplies and pins (the same pin as the companion Windows
   Witcher 3 launcher). The model carries two
   weight sets: `[DlssNr] Preset=1` is the September model (A), `Preset=2` the
   smaller, faster October model (B, the default).
4. **`_nvngx.dll`** — copied from the installed NVIDIA driver's Wine NGX
   component (`/usr/lib/x86_64-linux-gnu/nvidia/wine/`), refreshed whenever
   `setup`/`refresh` runs after a driver upgrade.

The Neural Rendering pass runs after the game's upscaler on D3D12 (HookMethod
1), through the D3D11-to-D3D12 bridge for D3D11 games, or at present time for
games without an upscaler. Games with DLSS, FSR 2/3 or XeSS all qualify.

## Requirements

- An **NVIDIA RTX 50 (Blackwell)** GPU — the NVIDIA-signed model starts on
  RTX 50 only. RTX 20/30/40 need the community-modified model instead.
- NVIDIA driver **615.71.09** (installed here). Avoid 621.01 (crashes the
  lecram/RenoDX route in The Witcher 3) and 620.73.04 (GPU fault in DOOM
  Eternal). `doctor` reports known-bad versions.
- The **Wineland Proton** (`proton-wineland-11.0-20261119-x86_64_v3`) in
  `<steamroot>/compatibilitytools.d/` (installed here), selected per game in
  Steam: Properties → Compatibility → Force a specific tool. The DLSS 5 NR
  model needs NGX support that stock Proton does not carry.
- Steam (snap install on this machine) with the game installed.
- For Epic games: the native **Epic Games Launcher v2** (`EpicGamesLauncher`,
  data dir `~/.local/share/com.epicgames.eglv2/`). Epic games run under the
  launcher's own Proton runtime — no Steam compat-tool mapping is involved.
  The game must be installed by the Epic launcher first; owned-but-not-installed
  games are listed as `owned` and `setup` asks you to install them first.
- Components cache at `~/dev/workbench/tmp/dlss5-linux` on the reference
  machine (Retoque 0.3.3 zip extracted, plus the model; `doctor` prints the
  expected paths for your setup). Every component is hash-pinned; a mismatch
  aborts.

## Quick start

```bash
git clone https://github.com/DammianMiller/dlss5-steam-launcher.git
cd dlss5-steam-launcher

./dlss5-steam-launcher.sh list                 # library overview (Steam + Epic)
./dlss5-steam-launcher.sh doctor               # GPU, driver, Wineland, EGL v2, pins
./dlss5-steam-launcher.sh setup 292030         # The Witcher 3 (Remastered, Steam)
./dlss5-steam-launcher.sh setup epic:Boga     # Death Stranding (Epic)
./dlss5-steam-launcher.sh launch 292030 --verify   # play + confirm the model loads
```

In game: press **F7** to toggle Neural Rendering on and off
(`[DlssNr] ToggleKey=0x76`), **Home** for the menu panel. With DLSS enabled in
the game's video settings, the NR pass runs on the upscaled frame.

## Commands

Games are addressed by Steam appid (e.g. `292030`) or, for Epic games, as
`epic:<appName>` (e.g. `epic:Boga` is Death Stranding); `list` prints every id.

| Command | What it does |
| --- | --- |
| `list [--tsv]` | Every app in the Steam and Epic libraries: game/tool, override state, compat tool (Steam), exe dir; excluded games and why. `--tsv` prints one line per game — `source<TAB>id<TAB>title<TAB>state<TAB>exedir` with states `eligible, installed, excluded, owned, tool` — for the tray app and scripts. |
| `doctor [appid]` | GPU + driver checks (RTX 50, known-bad versions), driver Wine NGX DLLs, Wineland Proton presence, the Epic Games Launcher v2 (data dir, binary, URL handler, install roots), all component SHA pins, archive provenance pins, Steam state; `doctor 292030` appends that game's status. |
| `setup <appid>` | Install or update the override: verify pins, run the Retoque deploy engine (`--enable-nr`), install the pinned NR model beside the exe, ensure `[DlssNr] Enabled=true` and `Preset=2`, check the game's compat tool. Idempotent — re-running updates in place. |
| `refresh <appid>` | Alias for setup. Run it after a **driver upgrade** to refresh the deployed `_nvngx.dll` from the new driver. |
| `preset A\|B <appid>` | Model weights: A = September (`Preset=1`), B = October, smaller and faster (`Preset=2`, default). Applies at the next game start. |
| `status [appid]` | Per game: proxy, engine receipt, model hash, `_nvngx.dll` freshness vs the current driver, ini keys, compat tool, and the DLSS-NR verdict lines from the last `OptiScaler.log`. Without an appid, every Steam game and every installed Epic game. |
| `restore <appid>` | Undo everything: the engine replays its receipt (restores originals, removes its files), the pinned model is removed, launcher ini keys and journal are cleared. |
| `launch <appid> [--verify [secs]]` | Steam: `steam -applaunch <appid>`; per-game arguments (e.g. W3's `--launcher-skip`) are appended only when the game's stored Steam launch options do not already contain them. Epic: hands `com.epicgames.launcher://apps/<appName>?action=launch&silent=true` to the `EpicGamesLauncher` binary (or `xdg-open`). With `--verify`, waits for the game process, then watches `OptiScaler.log` for up to 240 s (default) and reports whether the DLSS-NR model loaded. |

Setup options: `--exedir DIR` (skip exe-dir detection), `--proxy NAME`
(default `dxgi.dll`), `--dry-run`, `--no-nvngx`, `--allow-online`,
`--replace-foreign`, `--keep-reshade`, `--allow-second-proxy` — the last three
map to the deploy engine's own conflict handling.

## What gets installed, and how it is safe

Everything lands in the game's executable folder:

- `dxgi.dll` (the proxy) + `OptiScaler.dll` (renamed copy), `nvngx.dll_dlssnr.dll`,
  `OptiScaler.ini` (only if the game has none; an existing ini is edited in
  place, never duplicated), `OptiScaler/` (FSR/XeSS/D3D12 support files),
  `_nvngx.dll` (from the driver), `nvngx_dlssnr.dll` (the model).
- The deploy engine journals every write, rename and backup to
  `<game>/.retoque/receipt.txt` with backups under `.retoque/backup/<stamp>/`;
  `restore` replays it backwards. The launcher journals its own additions
  (the model, ini keys) to `<game>/.dlss5-launcher/journal.txt`.
- The engine refuses to run while the game is running (it reads `/proc/*/maps`),
  refuses a foreign file at the proxy name unless `--replace-foreign` is given
  (the original is kept in the backup), refuses a second OptiScaler proxy in
  the same folder, refuses 32-bit-only folders, and prints anti-cheat evidence
  it recognizes.
- The game's own `sl.*` Streamline files and its `nvngx_dlss/dlssd/dlssg`
  NGX DLLs are never modified. The pinned model is only ever replaced by the
  same pinned bytes.

## Games on this machine

| AppID | Game | State |
| --- | --- | --- |
| 292030 | The Witcher 3: Wild Hunt — Remastered | Installed (install fully verified; the in-game model-load verdict awaits the first play session). DX12 build (`bin/x64_dx12`), native DLSS via Streamline; mapped to Wineland Proton. Note: the RED pre-launcher window still opens despite `--launcher-skip` — click **Play** in it; the game process idles until you do. |
| 1371980 | No Rest for the Wicked | Supported (Unity, exe at install root, D3D12Core + native DLSS). Online co-op without anti-cheat — acceptable to some players, removed with `restore` if not. Set it to Wineland Proton before the first launch. |
| 553850 | HELDIVERS 2 | **Excluded, hard.** EasyAntiCheat: a proxy DLL can trip anti-cheat and ban the account; HD2 does not run under Proton anyway. |

**Epic library (166 owned items, none installed yet):** every item this
account owns on the Epic Games Launcher is assessed in the launcher's table —
**85 eligible** (D3D11/D3D12, no kernel anti-cheat; the best NR targets
include Death Stranding `epic:Boga`, Guardians of the Galaxy, Ghostwire
Tokyo, Witchfire, both Tomb Raider sequels, MechWarrior 5, Sifu, Mortal
Shell), **35 excluded** (7 kernel anti-cheat: ARK, Chivalry 2, Destiny 2,
Genshin Impact, GTA V and GTA V Enhanced, Midnight Ghost Hunt; 28
D3D9/OpenGL/2D-only renderers), and **46 skip** (DLC, soundtracks, beta
branches, tools). `list` prints the whole table with per-game notes and
exclusion reasons; the table is cross-checked against the launcher's library
cache so a new, unassessed purchase is flagged.

## Epic Games Launcher (EGL v2) specifics

- **Addressing**: `epic:<appName>` — Epic's launch id, the same id the
  `com.epicgames.launcher://apps/<appName>` URL scheme uses (some are
  codenames: `epic:Boga` = Death Stranding, `epic:Larkspur` = Far Cry Primal).
- **Install roots**: the Epic launcher's `defaultInstallDir` (read from its
  `app-settings.json`; `~/Games` here), then `~/Games`. Override with
  `DLSS5_EPIC_ROOTS` (colon-separated). The data dir override is
  `DLSS5_EGLV2_DIR`.
- **Compat**: Epic games run under the EGL v2's own managed Proton runtime —
  there is no Steam compat-tool mapping to check, so `setup`/`status` report
  that instead of the Wineland line. The deploy engine, pins, model and
  `restore` behave exactly as for Steam games.
- **Launching**: `launch epic:<app>` hands
  `com.epicgames.launcher://apps/<appName>?action=launch&silent=true` to the
  `EpicGamesLauncher` binary (falling back to `xdg-open`); `--verify` works
  the same way via `OptiScaler.log`.
- **Owned but not installed**: listed as `owned`; `setup`/`status`/`launch`
  refuse with the exact message to install the game with the Epic launcher
  first (excluded games instead report their exclusion reason).
- **New purchases**: `list` warns about any item in the EGL library cache that
  the table does not assess yet.

## Launch options

Usually none: a native `dxgi.dll` beside the game executable loads before
Wine's builtin. If a game/prefix refuses it, set the game's Steam launch
options to `WINEDLLOVERRIDES="dxgi=n,b" %command%`. The deploy output reminds
you of this line. (Env vars set on `steam -applaunch` do not reach the game
when the Steam client is already running, which is why launch options are the
reliable path.) For an Epic game, set `WINEDLLOVERRIDES="dxgi=n,b"` in the
game environment instead — there are no Steam launch options on that path.

## Verifying the model is active

- `launch 292030 --verify` prints a verdict from the fresh `OptiScaler.log`:
  - `[PASS] DLSS-NR is running` — the pass is dispatching on frames.
  - `[PASS] DLSS-NR model messages present` — the model loaded.
  - `[FAIL] the model kernels still cannot be loaded` — driver/`_nvngx.dll`
    mismatch: run `doctor`, then `refresh <appid>`, confirm the Wineland
    Proton mapping, and relaunch.
  - `[TIMEOUT]` — no verdict lines yet: if the game has a pre-launcher window
    (Witcher 3 does), confirm it with **Play**; the pass only dispatches during
    gameplay, so enter the game world, then check `status <appid>`.
- `status 292030` shows the same evidence from the last log, plus `_nvngx.dll`
  freshness (a stale copy after a driver upgrade says so, with the exact
  `refresh` command to run).

Background: on the pre-615.71.09 driver (Nov 21 run) the model never loaded —
`OptiScaler.log` repeated "the model's kernels cannot be loaded without the
extensions listed as NOT AVAILABLE" (`VK_NVX_binary_import`,
`VK_KHR_buffer_device_address`). Driver 615.71.09 + a refreshed `_nvngx.dll`
is what makes the model load; that is the state this launcher installs and
verifies.

## Tray icon and control panel

`dlss5-tray.py` is a GNOME status-bar icon plus a control panel window over
this launcher — every button runs the CLI above, nothing is reimplemented.

```bash
./install-tray.sh --run        # install the menu entry and start it now
./install-tray.sh --autostart  # also start it at every login
python3 dlss5-tray.py           # or run it directly
```

- **Status bar icon** (top bar, "NR" badge): dropdown with per-game
  Launch / Launch + verify model / Refresh override, a Preset submenu
  (model A or B) per game, Status, Doctor, List library, and Quit.
- **Control panel**: one card per game showing install state, compat tool,
  and current model, preset A/B radios, and Status / Launch / Verify /
  Refresh / Restore… buttons (Restore asks first). The bottom pane shows
  everything the launcher prints, live.
- The game list is not hardcoded: the tray reads `list --tsv` at startup and
  shows every game the launcher can act on (installed or eligible), Steam or
  Epic, in launcher order — so installing an Epic game makes it appear in the
  tray on the next start.
- Requires Ubuntu's AppIndicators extension (default on; the icon is
  skipped with a note if absent) and `python3-gi` +
  `gir1.2-ayatanaappindicator3-0.1` (all stock on Ubuntu).
- Background log when started detached: `~/.cache/dlss5-tray.log`.

## Uninstall

```bash
./dlss5-steam-launcher.sh restore 292030
```

Removes every file the engine receipt covers (restoring anything it replaced),
the pinned model, and the launcher journal. Steam "verify integrity" is not
needed for the override (the game's own files were never touched), but it also
never conflicts with it.

## Provenance and pins

| Component | Version | SHA-256 |
| --- | --- | --- |
| `OptiScaler.dll` (Retoque) | 0.3.3 | `2c8fccd7e9f2a5038f93262e449ddebe51d6ec9bec93aa2ce73d58bcdd2697dc` |
| `nvngx.dll_dlssnr.dll` (forwarder) | 0.3.3 | `a3c9bee2078c2fe351e9eff17ba1b9e4cf55837e301d16c3c27cbb3317301936` |
| `nvngx_dlssnr.dll` (NR model, NVIDIA-signed) | 310.9.16 | `2bc19bc09a7b89dd44f73e2ac0108fcc586e2154bdd0830f242f4f040e28789f` |
| `Retoque-v0.3.3.zip` (cache provenance) | 0.3.3 | `0570602a68f0cba3d3b886e89583c1f1cee86307b4619358af30b2ecb56c83b1` |
| `wineland.tar.xz` (cache provenance) | 11.0-20261119 v3 | `dfec653a7f167ba412b74d2d52de274d467f1bf8b0dfbd07c52a12d6f08e49b8` |

Retoque is GPL-3.0 (github.com/gabrielmaialva33/retoque), a fork of
OptiScaler (cdozdil) with Dagherbou's DLSS-NR module; its `Licenses/` folder
ships with the components. The NR model is NVIDIA's, redistributed here only
as a hash pin. The Wineland Proton build is a compatibility tool with
protonfixes (its Witcher 3 fix sets the `HideWineExports` registry key the
game's Streamline init needs). This launcher adds no binary of its own.

## Files

- `dlss5-steam-launcher.sh` — the launcher (Steam + Epic).
- `dlss5-tray.py` — the tray icon / control panel (see above).
- `test-dlss5-launcher.sh` — validation harness (see below).
- `README.md` — this manual.

## Validation

`test-dlss5-launcher.sh` checks the launcher without touching real games:
syntax and shellcheck, unit tests of the ini/vdf/pin and epic helpers against
the real pinned components, and end-to-end runs against fake game trees
using the **real** components — a fake Steam library and a fake Epic Games
Launcher v2 data dir + install root (library cache, install folder, URL
launch shim) — covering install, idempotent re-run, preset switching, status,
the anti-cheat exclusion, the running-game and foreign-file refusals, the
epic owned/excluded/skip/unknown refusals, and byte-exact restore round-trips
(including a preserved user `OptiScaler.ini`).

```bash
bash test-dlss5-launcher.sh   # exit 0 = all checks passed
```
