#!/usr/bin/env bash
# dlss5-steam-launcher.sh — DLSS 5 Neural Rendering override manager for Steam
# games on Linux/Proton (NVIDIA RTX 50).
#
# Wraps the Retoque v0.3.3 deploy engine (an OptiScaler fork, GPL-3.0) and the
# NVIDIA-signed DLSS 5 NR model nvngx_dlssnr.dll 310.9.16, both pinned by
# SHA-256. Every change the engine makes is journaled to <game>/.retoque/
# receipt.txt and reversible with `restore`; the NR model itself is journaled
# to <game>/.dlss5-launcher/journal.txt. The game's own Streamline (sl.*) and
# NGX (nvngx_dlss/dlssd/dlssg) files are never modified.
#
# Usage: dlss5-steam-launcher.sh <command> [args]
#   list | doctor | setup | refresh | preset | status | restore | launch
# See README.md in this folder for the full manual.
set -euo pipefail

VERSION='1.0.0'
PROG=${0##*/}

# ------------------------------------------------------------------ pins ---
# OptiScaler.dll from the SHA-verified Retoque-v0.3.3.zip (Retoque 0.3.3)
PIN_OPTISCALER='2c8fccd7e9f2a5038f93262e449ddebe51d6ec9bec93aa2ce73d58bcdd2697dc'
# nvngx.dll_dlssnr.dll forwarder (Retoque 0.3.3)
PIN_FORWARDER='a3c9bee2078c2fe351e9eff17ba1b9e4cf55837e301d16c3c27cbb3317301936'
# nvngx_dlssnr.dll — NVIDIA-signed DLSS 5 NR model 310.9.16 (model A + model B)
PIN_MODEL='2bc19bc09a7b89dd44f73e2ac0108fcc586e2154bdd0830f242f4f040e28789f'
# Provenance of the cached component archives (verified at download time)
PIN_RETOQUE_ZIP='0570602a68f0cba3d3b886e89583c1f1cee86307b4619358af30b2ecb56c83b1'
PIN_WINELAND_TAR='dfec653a7f167ba412b74d2d52de274d467f1bf8b0dfbd07c52a12d6f08e49b8'

WINELAND_NAME='proton-wineland-11.0-20261119-x86_64_v3'
DRIVER_WINE_NVNGX_CANDIDATES=(
    /usr/lib/x86_64-linux-gnu/nvidia/wine/_nvngx.dll
    /usr/lib/nvidia/wine/_nvngx.dll
    /usr/lib64/nvidia/wine/_nvngx.dll
)
DEFAULT_COMPONENTS_DIR="$HOME/dev/workbench/tmp/dlss5-linux"
DEFAULT_STEAM_ROOTS=(
    "$HOME/snap/steam/common/.local/share/Steam"
    "$HOME/.local/share/Steam"
    "$HOME/.steam/steam"
)

# ------------------------------------------------------- per-game table ---
# exe dir is relative to the game install dir; '.' means the install root.
declare -A GAME_EXE_SUBDIR=( ['292030']='bin/x64_dx12' ['1371980']='.' )
declare -A GAME_EXE_NAME=( ['292030']='witcher3.exe' ['1371980']='NoRestForTheWicked.exe' )
declare -A GAME_LAUNCH_ARGS=( ['292030']='--launcher-skip' )
declare -A GAME_EXCLUDE_REASON=(
    ['553850']='EasyAntiCheat kernel anti-cheat is present: a proxy DLL can trigger a ban, and Helldivers 2 does not run under Proton in any case'
)
declare -A GAME_NOTE=(
    ['292030']='D3D12 Remastered build, native DLSS via Streamline; the NR pass runs on the upscaler route; the RED pre-launcher window still appears despite --launcher-skip — click Play, then enter the game world'
    ['1371980']='Unity IL2CPP with D3D12Core and native DLSS; not on the Retoque measured list (verify with launch --verify)'
)
TOOL_APPIDS=' 228980 1493710 4183110 1628350 1391110 '

# ----------------------------------------------------------------- utils ---
say()  { printf '%s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die()  { local rc=$1; shift; printf '[-] %s\n' "$*" >&2; exit "$rc"; }

sha_of() { sha256sum -- "$1" 2>/dev/null | awk '{print $1}'; }

pin_ok() { [[ -f $1 ]] && [[ $(sha_of "$1") == "$2" ]]; }

hr() { printf -- '----\n'; }

usage() {
    cat <<EOF
$PROG $VERSION — DLSS 5 Neural Rendering override for Steam games (Linux/Proton)

Usage: $PROG <command> [options] [args]

Commands:
  list                          Games in the Steam library, override state, exclusions
  doctor [appid]                Environment checks (GPU, driver, Wineland, pins)
  setup <appid> [options]       Install / update the DLSS 5 NR override in a game
  refresh <appid> [options]     Alias for setup — re-run after a driver upgrade to
                                refresh the deployed _nvngx.dll from the new driver
  preset A|B <appid>            NR model weights: A = September (Preset 1),
                                B = October, smaller and faster (Preset 2, default)
  status [appid]                Installed state per game (files, pins, ini, log)
  restore <appid>               Undo everything: engine receipt + NR model + ini edits
  launch <appid> [--verify [N]] Launch via Steam (steam -applaunch); --verify polls
                                OptiScaler.log for up to N seconds (default 240) and
                                reports whether the DLSS-NR model loaded

setup/refresh options:
  --exedir DIR         Game exe folder (skips auto-detection)
  --proxy NAME         Proxy DLL name (default dxgi.dll)
  --dry-run            Plan only, write nothing
  --no-nvngx           Do not copy the driver Wine _nvngx.dll
  --allow-online       Install into an excluded online game (at your own risk)
  --replace-foreign    Replace a foreign file at the proxy name (backed up first)
  --keep-reshade       Keep an existing ReShade as ReShade64.dll, load it via OptiScaler
  --allow-second-proxy Allow a second OptiScaler proxy name in the same folder

Environment:
  DLSS5_STEAM_ROOT        Force the Steam root (default: auto-detected)
  DLSS5_COMPONENTS_DIR    Components cache (default: $DEFAULT_COMPONENTS_DIR)
EOF
    exit "${1:-0}"
}

# ------------------------------------------------------------ components ---
components_dir() { printf '%s\n' "${DLSS5_COMPONENTS_DIR:-$DEFAULT_COMPONENTS_DIR}"; }
retoque_dir()     { printf '%s\n' "$(components_dir)/retoque"; }
model_file()      { printf '%s\n' "$(components_dir)/nvngx_dlssnr.dll"; }
engine_file()    { printf '%s\n' "$(retoque_dir)/deploy-to-game.sh"; }

# ----------------------------------------------------------- steam library --
steam_root() {
    local r
    [[ -n ${DLSS5_STEAM_ROOT:-} ]] && { printf '%s\n' "$DLSS5_STEAM_ROOT"; return 0; }
    for r in "${DEFAULT_STEAM_ROOTS[@]}"; do
        [[ -d $r/steamapps ]] && { printf '%s\n' "$r"; return 0; }
    done
    return 1
}

library_dirs() { # $1 = steam root -> library roots, one per line
    local root=$1 vdf=$root/steamapps/libraryfolders.vdf d
    local -a out=()
    if [[ -f $vdf ]]; then
        while IFS= read -r d; do
            [[ -n $d ]] && out+=("$d")
        done < <(sed -n 's/.*"path"[[:space:]]*"\([^"]*\)".*/\1/p' "$vdf")
    fi
    (( ${#out[@]} )) || out+=("$root")
    printf '%s\n' "${out[@]}"
}

acf_value() { # $1 = acf file, $2 = key -> first value
    sed -n "s/.*\"$2\"[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$1" | head -n1
}

find_manifest() { # $1 = appid -> path
    local appid=$1 root lib m
    root=$(steam_root) || return 1
    while IFS= read -r lib; do
        m="$lib/steamapps/appmanifest_$appid.acf"
        [[ -f $m ]] && { printf '%s\n' "$m"; return 0; }
    done < <(library_dirs "$root")
    return 1
}

require_game() { # $1 = appid; sets GAME_NAME, GAME_DIR, GAME_MANIFEST
    GAME_MANIFEST=$(find_manifest "$1") ||
        die 1 "appid $1 is not installed in any Steam library this launcher can see"
    GAME_NAME=$(acf_value "$GAME_MANIFEST" name)
    local installdir lib
    installdir=$(acf_value "$GAME_MANIFEST" installdir)
    lib=$(dirname "$(dirname "$GAME_MANIFEST")")
    GAME_DIR="$lib/steamapps/common/$installdir"
    [[ -d $GAME_DIR ]] || die 1 "install dir missing: $GAME_DIR"
    [[ -n $GAME_NAME ]] || GAME_NAME="appid $1"
}

compat_tool_for() { # $1 = appid -> compat tool id or empty
    local root cfg
    root=$(steam_root) || return 0
    cfg="$root/config/config.vdf"
    [[ -f $cfg ]] || return 0
    grep -A3 "^[[:space:]]*\"$1\"$" "$cfg" 2>/dev/null |
        grep -m1 '"compat_tool"' |
        sed 's/.*"compat_tool"[[:space:]]*"\([^"]*\)".*/\1/' || true
}

launch_options_for() { # $1 = appid -> stored Steam launch options or empty
    local root cfg out
    root=$(steam_root) || return 0
    while IFS= read -r cfg; do
        [[ -f $cfg ]] || continue
        # values embed escaped quotes, so capture greedily to the last quote
        out=$(grep -A6 "^[[:space:]]*\"$1\"$" "$cfg" 2>/dev/null |
            grep -m1 'LaunchOptions' |
            sed 's/.*"LaunchOptions"[[:space:]]*"\(.*\)"/\1/')
        [[ -n $out ]] && { printf '%s\n' "$out"; return 0; }
    done < <(find "$root/userdata" -maxdepth 3 -name localconfig.vdf 2>/dev/null)
    return 0
}

# ------------------------------------------------------------- exe dir ----
resolve_exedir() { # $1 = appid, $2 = game dir -> exe folder
    local appid=$1 gamedir=$2 sub
    if [[ -n ${GAME_EXE_SUBDIR[$appid]:-} ]]; then
        sub=${GAME_EXE_SUBDIR[$appid]}
        [[ -d $gamedir/$sub ]] ||
            die 1 "expected exe folder '$sub' not found under $gamedir (game updated?)"
        printf '%s\n' "$gamedir/$sub"
        return 0
    fi
    local f d best='' bestscore=-1 score depth
    declare -A cnt=()
    while IFS= read -r f; do
        [[ -n $f ]] || continue
        d=$(dirname "$f")
        cnt[$d]=$(( ${cnt[$d]:-0} + 1 ))
    done < <(find "$gamedir" -maxdepth 4 -type f -iname '*.exe' ! -iname '*crash*' ! -iname '*setup*' ! -iname '*anticheat*' ! -iname '*installer*' 2>/dev/null)
    for d in "${!cnt[@]}"; do
        depth=$(awk -F/ '{print NF}' <<< "${d#"$gamedir"}")
        score=$(( cnt[$d] * 10 - depth ))
        if (( score > bestscore )); then best=$d; bestscore=$score; fi
    done
    [[ -n $best ]] ||
        die 1 "no game executable found under $gamedir; pass --exedir explicitly"
    printf '%s\n' "$best"
}

# ------------------------------------------------------------------ ini ----
# Same semantics as the deploy engine: a key is replaced in place inside its
# section, later duplicates are dropped (the parser keeps the last one), and a
# missing key is inserted at the end of its section. CRLF-aware: a replaced
# line keeps its own line ending, injected lines use the file's style, so a
# Windows ini never becomes mixed-endings (a drifted hash would make the
# engine's uninstall treat the ini as user-edited and leave it behind).
ini_set() { # $1 file  $2 section  $3 key  $4 value
    local file=$1 section=$2 key=$3 value=$4 tmp
    [[ -f $file ]] || die 2 "ini_set: no such file: $file"
    tmp=$(mktemp) || die 2 'mktemp failed'
    awk -v sec="[$section]" -v key="$key" -v val="$value" '
        BEGIN { CR = sprintf("%c", 13); insec = 0; injected = 0; anysec = 0; style = "" }
        NR == 1 && index($0, CR) > 0 { style = CR }
        /^[[:space:]]*\[/ {
            if (insec && !injected) { print key "=" val style; injected = 1 }
            line = $0; gsub(/[[:space:]]/, "", line)
            insec = (tolower(line) == tolower(sec)) ? 1 : 0
            if (insec) anysec = 1
            print; next
        }
        insec && $0 ~ ("^[[:space:]]*" key "[[:space:]]*=") {
            if (!injected) { print key "=" val (index($0, CR) > 0 ? CR : ""); injected = 1 }
            next
        }
        { print }
        END {
            if (!injected) {
                if (!insec) print sec style
                print key "=" val style
            }
        }
    ' "$file" > "$tmp" || { rm -f "$tmp"; die 2 'ini_set: awk failed'; }
    chmod --reference="$file" "$tmp" 2>/dev/null || chmod 644 "$tmp"
    mv -f -T -- "$tmp" "$file"
}

ini_get() { # $1 file  $2 section  $3 key -> value, CR and trailing space stripped
    local v
    [[ -f $1 ]] || return 0
    v=$(awk -v sec="[$2]" -v key="$3" '
        BEGIN { insec = 0 }
        /^[[:space:]]*\[/ {
            line = $0; gsub(/[[:space:]]/, "", line)
            insec = (tolower(line) == tolower(sec)) ? 1 : 0
            next
        }
        insec && $0 ~ ("^[[:space:]]*" key "[[:space:]]*=") {
            sub(/^[^=]*[[:space:]]*=[[:space:]]*/, "")
            print; exit
        }
    ' "$1")
    v=${v%$'\r'}
    v="${v%"${v##*[![:space:]]}"}"   # trim trailing whitespace
    printf '%s\n' "$v"
}

ini_del() { # $1 file  $2 section  $3 key — remove the key line from the section
    local file=$1 section=$2 key=$3 tmp
    [[ -f $file ]] || return 0
    tmp=$(mktemp) || return 0
    awk -v sec="[$section]" -v key="$key" '
        BEGIN { insec = 0 }
        /^[[:space:]]*\[/ {
            line = $0; gsub(/[[:space:]]/, "", line)
            insec = (tolower(line) == tolower(sec)) ? 1 : 0
            print; next
        }
        insec && $0 ~ ("^[[:space:]]*" key "[[:space:]]*=") { next }
        { print }
    ' "$file" > "$tmp" && mv -f -T -- "$tmp" "$file" || rm -f -- "$tmp"
}

# ---------------------------------------------------------------- guards ---
GPU_NAME='' GPU_DRIVER=''
gpu_info() {
    GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -n1 || true)
    GPU_DRIVER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1 || true)
}

require_rtx50() {
    gpu_info
    [[ -n $GPU_NAME ]] ||
        die 1 'no NVIDIA GPU visible (nvidia-smi failed); this override needs an RTX 50 GPU'
    [[ $GPU_NAME == *"RTX 50"* ]] || die 1 \
        "GPU is $GPU_NAME: the NVIDIA-signed DLSS 5 NR model starts on RTX 50 (Blackwell) only; RTX 20/30/40 need the community model via DLSS AiO Swapper"
}

driver_notes() {
    gpu_info
    case $GPU_DRIVER in
        621.01*) warn 'driver 621.01 is known-bad for the lecram/RenoDX ReShade add-on route in The Witcher 3 (crash at game start); 615.71.09 works' ;;
        620.73*) warn 'driver 620.73.04 GPU-faults in DOOM Eternal about a minute in, with or without Retoque loaded' ;;
    esac
}

verify_components() {
    local rd mf
    rd=$(retoque_dir)
    mf=$(model_file)
    [[ -f $rd/OptiScaler.dll ]]        || die 1 "missing component: $rd/OptiScaler.dll"
    [[ -f $rd/nvngx.dll_dlssnr.dll ]]  || die 1 "missing component: $rd/nvngx.dll_dlssnr.dll"
    [[ -f $rd/OptiScaler.ini ]]       || die 1 "missing component: $rd/OptiScaler.ini"
    [[ -f $rd/deploy-to-game.sh ]]     || die 1 "missing component: $rd/deploy-to-game.sh"
    [[ -f $mf ]]                       || die 1 "missing component: $mf (DLSS 5 NR model)"
    pin_ok "$rd/OptiScaler.dll" "$PIN_OPTISCALER" ||
        die 1 "SHA-256 mismatch: $rd/OptiScaler.dll is not the pinned Retoque 0.3.3 build"
    pin_ok "$rd/nvngx.dll_dlssnr.dll" "$PIN_FORWARDER" ||
        die 1 "SHA-256 mismatch: $rd/nvngx.dll_dlssnr.dll is not the pinned Retoque 0.3.3 forwarder"
    pin_ok "$mf" "$PIN_MODEL" ||
        die 1 "SHA-256 mismatch: $mf is not the pinned NVIDIA nvngx_dlssnr.dll 310.9.16"
    say '[+] components verified: Retoque 0.3.3 (engine, forwarder) + NVIDIA NR model 310.9.16 — all SHA pins match'
}

driver_wine_nvngx() { # -> first existing driver wine _nvngx.dll path
    local p
    for p in "${DRIVER_WINE_NVNGX_CANDIDATES[@]}"; do
        [[ -f $p ]] && { printf '%s\n' "$p"; return 0; }
    done
    return 1
}

# ------------------------------------------------------------- journal ----
journal_add() { # $1 = exedir, $2 = line
    mkdir -p -- "$1/.dlss5-launcher"
    printf '%s\n' "$2" >> "$1/.dlss5-launcher/journal.txt"
}

# ------------------------------------------------------------ commands -----
cmd_list() {
    local root lib m appid name installdir dir tool cls
    root=$(steam_root) || die 1 'no Steam root found (set DLSS5_STEAM_ROOT?)'
    say "Steam root: $root"
    hr
    printf '%-10s %-28s %-8s %-22s %s\n' APPID GAME STATE 'COMPAT TOOL' 'EXE DIR'
    while IFS= read -r m; do
        appid=$(basename "$m" .acf); appid=${appid#appmanifest_}
        name=$(acf_value "$m" name)
        installdir=$(acf_value "$m" installdir)
        lib=$(dirname "$(dirname "$m")")
        dir="$lib/steamapps/common/$installdir"
        tool=$(compat_tool_for "$appid"); tool=${tool:-"-"}
        local cls=tool
        [[ $TOOL_APPIDS == *" $appid "* ]] || cls=game
        local exedir='-'
        if [[ $cls == game ]]; then
            exedir=$(resolve_exedir_quiet "$appid" "$dir")
            if [[ -n ${GAME_EXCLUDE_REASON[$appid]:-} ]]; then
                cls=excluded
            elif [[ $exedir != '-' && -f $exedir/.retoque/receipt.txt ]]; then
                cls=installed
            else
                cls=eligible
            fi
        fi
        printf '%-10s %-28s %-9s %-22s %s\n' \
            "$appid" "${name:0:28}" "$cls" "${tool:0:22}" "$exedir"
    done < <(find_root_manifests "$root")
    hr
    local a
    for a in "${!GAME_EXCLUDE_REASON[@]}"; do
        say "excluded  $a: ${GAME_EXCLUDE_REASON[$a]}"
    done
}

find_root_manifests() { # $1 = root -> all appmanifest paths across libraries
    local root=$1 lib
    while IFS= read -r lib; do
        find "$lib/steamapps" -maxdepth 1 -name 'appmanifest_*.acf' 2>/dev/null
    done < <(library_dirs "$root") | sort -u
}

resolve_exedir_quiet() { # $1 appid $2 dir -> exe dir or '-' (never dies)
    local out
    out=$(resolve_exedir "$1" "$2" 2>/dev/null) || { echo '-'; return; }
    printf '%s\n' "$out"
}

cmd_doctor() {
    local appid=${1:-} drv_nvngx='' rd
    gpu_info
    say "== $PROG $VERSION doctor =="
    if [[ -n $GPU_NAME ]]; then
        say "GPU      : $GPU_NAME (driver $GPU_DRIVER)"
        if [[ $GPU_NAME == *"RTX 50"* ]]; then
            say 'RTX 50   : yes — the NVIDIA-signed NR model can run'
        else
            warn 'GPU is not RTX 50: the pinned NR model will not run'
        fi
    else
        warn 'no NVIDIA GPU visible (nvidia-smi failed)'
    fi
    driver_notes
    if drv_nvngx=$(driver_wine_nvngx); then
        say "driver Wine NGX : $drv_nvngx ($(stat -c %s "$drv_nvngx") bytes)"
        say "                  nvngx.dll beside it: $(dirname "$drv_nvngx")/nvngx.dll"
    else
        warn 'driver Wine NGX DLLs not found (install the nvidia driver wine NGX component)'
    fi
    local root
    root=$(steam_root) || { warn 'no Steam root found'; root=''; }
    if [[ -n $root ]]; then
        local ct="$root/compatibilitytools.d/$WINELAND_NAME"
        if [[ -d $ct ]]; then
            say "Wineland : $ct"
        else
            warn "Wineland Proton not found under $root/compatibilitytools.d (DLSS 5 NR needs it)"
        fi
    fi
    rd=$(retoque_dir)
    if [[ -d $rd ]]; then
        if pin_ok "$rd/OptiScaler.dll" "$PIN_OPTISCALER"; then
            say "Retoque  : $rd — OptiScaler.dll pin OK"
        else
            warn "Retoque  : $rd — OptiScaler.dll pin MISMATCH"
        fi
        if pin_ok "$(model_file)" "$PIN_MODEL"; then
            say "NR model: $(model_file) — 310.9.16 pin OK"
        else
            warn "NR model: $(model_file) — pin MISMATCH (expected NVIDIA 310.9.16)"
        fi
        local zip tarx
        zip="$(components_dir)/Retoque-v0.3.3.zip"
        tarx="$(components_dir)/wineland.tar.xz"
        if [[ -f $zip ]]; then
            if pin_ok "$zip" "$PIN_RETOQUE_ZIP"; then
                say "archive  : Retoque-v0.3.3.zip pin OK"
            else
                warn 'archive  : Retoque-v0.3.3.zip pin mismatch'
            fi
        fi
        if [[ -f $tarx ]]; then
            if pin_ok "$tarx" "$PIN_WINELAND_TAR"; then
                say "archive  : wineland.tar.xz pin OK"
            else
                warn 'archive  : wineland.tar.xz pin mismatch'
            fi
        fi
    else
        warn "components dir not found: $(components_dir)"
    fi
    if pgrep -f '[s]teamwebhelper|[s]teamrt64/steam' >/dev/null 2>&1; then
        say 'Steam    : running (launches go through the running client)'
    else
        say 'Steam    : not running'
    fi
    if [[ -n $appid ]]; then
        hr
        status_one "$appid"
    fi
    return 0
}

# setup/refresh shared implementation ---------------------------------------
cmd_setup() {
    local appid=$1; shift
    local opt_exedir='' opt_proxy=dxgi.dll opt_dryrun=0 opt_nvngx=1
    local opt_allow_online=0 opt_replace_foreign=0 opt_keep_reshade=0 opt_allow_second=0
    while (( $# )); do
        case $1 in
            --exedir) opt_exedir=$2; shift 2 ;;
            --proxy) opt_proxy=$2; shift 2 ;;
            --dry-run|-n) opt_dryrun=1; shift ;;
            --no-nvngx) opt_nvngx=0; shift ;;
            --allow-online) opt_allow_online=1; shift ;;
            --replace-foreign) opt_replace_foreign=1; shift ;;
            --keep-reshade) opt_keep_reshade=1; shift ;;
            --allow-second-proxy) opt_allow_second=1; shift ;;
            *) die 1 "setup: unknown option: $1" ;;
        esac
    done
    require_game "$appid"
    if [[ -n ${GAME_EXCLUDE_REASON[$appid]:-} ]] && (( ! opt_allow_online )); then
        die 1 "refusing $appid ($GAME_NAME): ${GAME_EXCLUDE_REASON[$appid]} (override with --allow-online at your own risk)"
    fi
    require_rtx50
    driver_notes
    verify_components

    local exedir
    if [[ -n $opt_exedir ]]; then
        exedir=$opt_exedir
    else
        exedir=$(resolve_exedir "$appid" "$GAME_DIR")
    fi
    [[ -d $exedir ]] || die 1 "exe folder does not exist: $exedir"

    say "game     : $GAME_NAME (appid $appid)"
    say "exe dir  : $exedir"
    say "proxy    : $opt_proxy"
    [[ -n ${GAME_NOTE[$appid]:-} ]] && say "note     : ${GAME_NOTE[$appid]}"

    local -a eargs=(--source-dir "$(retoque_dir)" --enable-nr)
    (( opt_dryrun ))          && eargs+=(--dry-run)
    (( ! opt_nvngx ))         && eargs+=(--no-nvngx)
    (( opt_replace_foreign )) && eargs+=(--replace-foreign)
    (( opt_keep_reshade ))    && eargs+=(--keep-reshade)
    (( opt_allow_second ))    && eargs+=(--allow-second-proxy)
    eargs+=("$exedir" "$opt_proxy")

    local rc=0
    bash "$(engine_file)" "${eargs[@]}" || rc=$?
    (( rc == 0 )) || { warn "deploy engine exited $rc (see its output above)"; exit "$rc"; }

    if (( opt_dryrun )); then
        say '[=] dry run: nothing written (model and ini keys would follow)'
        return 0
    fi

    # NR model — the engine never ships or touches nvngx_dlssnr.dll
    local dst="$exedir/nvngx_dlssnr.dll" mf tmp
    mf=$(model_file)
    if [[ -f $dst ]] && [[ $(sha_of "$dst") == "$PIN_MODEL" ]]; then
        say '[=] nvngx_dlssnr.dll already present and matches the pinned 310.9.16 model'
    else
        [[ -f $dst ]] && warn 'replacing an nvngx_dlssnr.dll whose hash is not the pinned model'
        tmp=$(mktemp "$exedir/.dlss5-launcher.incoming.XXXXXX")
        cp -- "$mf" "$tmp"
        mv -f -T -- "$tmp" "$dst"
        [[ $(sha_of "$dst") == "$PIN_MODEL" ]] || die 1 'model copy failed its SHA check'
        say '[+] installed nvngx_dlssnr.dll — DLSS 5 NR model 310.9.16 (NVIDIA, SHA pinned)'
    fi
    journal_add "$exedir" "model	$PIN_MODEL	nvngx_dlssnr.dll"

    # ini keys (engine set Enabled=true via --enable-nr; verify, then preset)
    local ini="$exedir/OptiScaler.ini"
    [[ -f $ini ]] || die 1 "engine did not leave an OptiScaler.ini at $ini"
    local cur
    cur=$(ini_get "$ini" DlssNr Enabled)
    if [[ $cur != true ]]; then
        ini_set "$ini" DlssNr Enabled true
        journal_add "$exedir" "ini	DlssNr	Enabled	${cur:-unset}	true"
        say '[+] [DlssNr] Enabled=true'
    else
        say '[=] [DlssNr] Enabled already true'
    fi
    cur=$(ini_get "$ini" DlssNr Preset)
    if [[ -z $cur || $cur == auto ]]; then
        ini_set "$ini" DlssNr Preset 2
        journal_add "$exedir" "ini	DlssNr	Preset	${cur:-unset}	2"
        say '[+] [DlssNr] Preset=2 (model B, October — smaller and faster; default)'
    else
        say "[=] [DlssNr] Preset already $cur"
    fi

    hr
    say "receipt  : $exedir/.retoque/receipt.txt (engine journal; restore uses it)"
    say "journal  : $exedir/.dlss5-launcher/journal.txt (model + launcher ini keys)"

    local tool
    tool=$(compat_tool_for "$appid")
    if [[ $tool == "$WINELAND_NAME" ]]; then
        say "compat   : $tool (OK)"
    else
        warn "this game is not set to $WINELAND_NAME (currently: ${tool:-default}) — DLSS 5 NR needs the Wineland Proton"
        say '         Steam UI: right-click the game > Properties > Compatibility >'
        say "         Force the use of a specific tool > $WINELAND_NAME"
    fi
    say 'reminder : if the proxy does not load, set the game launch options to'
    say "           WINEDLLOVERRIDES=\"${opt_proxy%.*}=n,b\" %command%"
    say "undo     : $PROG restore $appid"
}

cmd_preset() {
    local which=$1 appid=$2 ini key val
    case $which in
        A|a) key=1; val='A (September model, the original)' ;;
        B|b) key=2; val='B (October model, smaller and faster)' ;;
        *) die 1 "preset: expected A or B, got '$which'" ;;
    esac
    require_game "$appid"
    local exedir
    exedir=$(resolve_exedir "$appid" "$GAME_DIR")
    ini="$exedir/OptiScaler.ini"
    [[ -f $ini ]] || die 1 "no OptiScaler.ini at $ini — run setup first"
    local cur
    cur=$(ini_get "$ini" DlssNr Preset)
    ini_set "$ini" DlssNr Preset "$key"
    journal_add "$exedir" "ini	DlssNr	Preset	${cur:-unset}	$key"
    say "[+] $GAME_NAME: [DlssNr] Preset=$key — model $val"
    say '    applies at the next game start'
}

status_one() {
    local appid=$1 exedir dir proxy receipt model_hash ini enabled preset tool
    require_game "$appid"
    dir=$GAME_DIR
    exedir=$(resolve_exedir_quiet "$appid" "$dir")
    tool=$(compat_tool_for "$appid"); tool=${tool:-"(default)"}
    say "$GAME_NAME (appid $appid)"
    say "  exe dir   : $exedir"
    say "  compat    : $tool"
    if [[ -n ${GAME_EXCLUDE_REASON[$appid]:-} ]]; then
        say "  state     : EXCLUDED — ${GAME_EXCLUDE_REASON[$appid]}"
        return 0
    fi
    [[ $exedir == '-' ]] && { say '  state     : no exe dir resolved'; return 0; }
    proxy=missing
    [[ -f $exedir/dxgi.dll ]] && proxy=dxgi.dll
    local p
    for p in winmm.dll version.dll d3d12.dll dbghelp.dll winhttp.dll wininet.dll; do
        [[ -f $exedir/$p ]] && { proxy=$p; break; }
    done
    receipt='none'
    if [[ -f $exedir/.retoque/receipt.txt ]]; then
        receipt=$(awk -F'\t' '$1=="status"{print $2}' "$exedir/.retoque/receipt.txt" | tail -n1)
        receipt="${receipt:-present} ($(stat -c '%y' "$exedir/.retoque/receipt.txt" | cut -d. -f1))"
    fi
    model_hash=$(sha_of "$exedir/nvngx_dlssnr.dll" 2>/dev/null || true)
    if [[ -z $model_hash ]]; then
        model_hash='missing'
    elif [[ $model_hash == "$PIN_MODEL" ]]; then
        model_hash='310.9.16 (pinned) OK'
    else
        model_hash="present, hash $model_hash (NOT the pinned model)"
    fi
    ini="$exedir/OptiScaler.ini"
    enabled=$(ini_get "$ini" DlssNr Enabled 2>/dev/null || true); enabled=${enabled:-unset}
    preset=$(ini_get "$ini" DlssNr Preset 2>/dev/null || true)
    case $preset in
        1) preset='1 = model A (September)' ;;
        2) preset='2 = model B (October, default)' ;;
        ''|auto) preset='auto (falls back to model B)' ;;
    esac
    local nvngx_state='n/a'
    local drv
    if drv=$(driver_wine_nvngx); then
        if [[ -f $exedir/_nvngx.dll ]]; then
            if [[ $(sha_of "$exedir/_nvngx.dll") == $(sha_of "$drv") ]]; then
                nvngx_state='fresh (matches current driver)'
            else
                nvngx_state="STALE — run: $PROG refresh $appid after this driver upgrade"
            fi
        fi
    fi
    say "  proxy     : $proxy"
    say "  receipt   : $receipt"
    say "  NR model  : $model_hash"
    say "  _nvngx.dll: $nvngx_state"
    say "  ini       : [DlssNr] Enabled=$enabled, Preset=$preset"
    local log="$exedir/OptiScaler.log"
    if [[ -f $log ]]; then
        say "  last log  : $(stat -c '%y' "$log" | cut -d. -f1)"
        local run model_fail
        run=$(grep -a -m1 'DLSS-NR running' "$log" 2>/dev/null || true)
        model_fail=$(grep -a -c 'kernels cannot be loaded' "$log" 2>/dev/null || true)
        if [[ -n $run ]]; then
            say "             : $run"
        fi
        if (( ${model_fail:-0} > 0 )); then
            say "             : WARNING — 'kernels cannot be loaded' seen $model_fail time(s) in the last log (model did not load)"
        fi
    else
        say '  last log  : none yet (game has not run with the override)'
    fi
}

cmd_status() {
    local appid=${1:-}
    if [[ -n $appid ]]; then
        status_one "$appid"
        return 0
    fi
    local root m a
    root=$(steam_root) || die 1 'no Steam root found'
    while IFS= read -r m; do
        a=$(basename "$m" .acf); a=${a#appmanifest_}
        [[ $TOOL_APPIDS == *" $a "* ]] && continue
        status_one "$a"
        hr
    done < <(find_root_manifests "$root")
}

cmd_restore() {
    local appid=$1 exedir rc
    require_game "$appid"
    exedir=$(resolve_exedir "$appid" "$GAME_DIR")
    [[ -d $exedir ]] || die 1 "no exe dir: $exedir"

    # Revert this launcher's ini edits first (reverse journal order): the
    # engine's uninstall only removes/restores files whose hash still matches
    # what it recorded, so the ini must look exactly as the engine left it.
    local journal="$exedir/.dlss5-launcher/journal.txt" ini="$exedir/OptiScaler.ini"
    if [[ -f $journal && -f $ini ]]; then
        local kind section key old new cur
        while IFS=$'\t' read -r kind section key old new; do
            [[ $kind == ini ]] || continue
            cur=$(ini_get "$ini" "$section" "$key")
            [[ $cur == "$new" ]] || continue   # changed since; leave it alone
            if [[ -z $old || $old == unset ]]; then
                ini_del "$ini" "$section" "$key"
            else
                ini_set "$ini" "$section" "$key" "$old"
            fi
        done < <(tac "$journal")
    fi

    local -a eargs=(--uninstall "$exedir")
    rc=0
    bash "$(engine_file)" "${eargs[@]}" || rc=$?
    # the engine receipt never covers the NR model — remove it only if it is ours
    local dst="$exedir/nvngx_dlssnr.dll"
    if [[ -f $dst ]]; then
        if [[ $(sha_of "$dst") == "$PIN_MODEL" ]]; then
            rm -f -- "$dst"
            say '[+] removed nvngx_dlssnr.dll (pinned model installed by this launcher)'
        else
            warn "leaving $dst: its hash is not the pinned model (not ours to remove)"
        fi
    fi
    rm -rf -- "$exedir/.dlss5-launcher" 2>/dev/null || true
    (( rc == 0 )) || exit "$rc"
    say "[+] $GAME_NAME: override fully removed (engine receipt + model + launcher journal)"
}

cmd_launch() {
    local appid=$1; shift
    local opt_verify=0 opt_timeout=240
    while (( $# )); do
        case $1 in
            --verify) opt_verify=1; [[ ${2:-} =~ ^[0-9]+$ ]] && { opt_timeout=$2; shift; } ;;
            --timeout) opt_timeout=$2; shift 2 ;;
            *) die 1 "launch: unknown option: $1" ;;
        esac
        shift || true
    done
    command -v steam >/dev/null 2>&1 || die 1 'steam command not found in PATH'
    require_game "$appid"
    local exedir log
    exedir=$(resolve_exedir_quiet "$appid" "$GAME_DIR")
    log="$exedir/OptiScaler.log"
    if [[ -n ${GAME_EXCLUDE_REASON[$appid]:-} ]]; then
        die 1 "refusing to launch-with-override for excluded game $appid: ${GAME_EXCLUDE_REASON[$appid]}"
    fi
    if [[ $exedir != '-' ]] && [[ ! -f $exedir/.retoque/receipt.txt ]]; then
        warn "no override installed for $GAME_NAME — launching the game as-is"
    fi
    local -a args=()
    local stored a
    stored=$(launch_options_for "$appid")
    for a in ${GAME_LAUNCH_ARGS[$appid]:-}; do
        [[ $stored == *"$a"* ]] || args+=("$a")
    done
    if (( ${#args[@]} )); then
        say "[+] launching $GAME_NAME via Steam (appid $appid) with ${args[*]}"
    elif [[ -n $stored ]]; then
        say "[+] launching $GAME_NAME via Steam (appid $appid) (stored launch options: $stored)"
    else
        say "[+] launching $GAME_NAME via Steam (appid $appid)"
    fi
    local started=$(date +%s)
    nohup steam -applaunch "$appid" ${args[@]+"${args[@]}"} >/dev/null 2>&1 &
    if (( ! opt_verify )); then
        say '[+] Steam launch requested; F7 toggles Neural Rendering in game (ToggleKey=0x76)'
        return 0
    fi
    # ---- verification: wait for the game process, then judge the fresh log ----
    local exe=${GAME_EXE_NAME[$appid]:-} i proc_up=0
    say "[.] verifying: waiting for the game process (timeout ${opt_timeout}s)"
    for ((i = 0; i < opt_timeout; i += 3)); do
        if [[ -n $exe ]] && pgrep -f "$exe" >/dev/null 2>&1; then proc_up=1; break; fi
        sleep 3
    done
    if (( proc_up )); then
        say "[+] game process is up ($exe)"
    elif [[ -n $exe ]]; then
        warn 'game process not detected — continuing to watch the log anyway'
    fi
    local deadline=$(( $(date +%s) + opt_timeout )) verdict=timeout
    local -a evidence=()
    while (( $(date +%s) < deadline )); do
        if [[ -f $log ]] && [[ $(stat -c %Y "$log" 2>/dev/null || echo 0) -ge $started ]]; then
            if grep -aq 'kernels cannot be loaded' "$log" 2>/dev/null; then
                verdict=model-not-loaded; break
            fi
            if grep -aq 'DLSS-NR running' "$log" 2>/dev/null; then
                verdict=running; break
            fi
            if grep -aq 'DLSS-NR model' "$log" 2>/dev/null; then
                verdict=model-loaded; break
            fi
        fi
        sleep 3
    done
    hr
    case $verdict in
        running)
            say '[PASS] DLSS-NR is running'
            mapfile -t evidence < <(grep -a 'DLSS-NR running' "$log" | tail -n2)
            ;;
        model-loaded)
            say '[PASS] DLSS-NR model messages present'
            mapfile -t evidence < <(grep -a 'DLSS-NR model' "$log" | tail -n3)
            ;;
        model-not-loaded)
            say '[FAIL] the model kernels still cannot be loaded — driver or _nvngx.dll mismatch'
            mapfile -t evidence < <(grep -a 'kernels cannot be loaded\|NOT AVAILABLE' "$log" | tail -n4)
            say '       hints: run doctor; run refresh '"$appid"' (updates the deployed _nvngx.dll);'
            say '       confirm the game is set to the Wineland Proton'
            ;;
        timeout)
            say '[TIMEOUT] no DLSS-NR verdict lines in OptiScaler.log yet'
            say '          the pass only dispatches during gameplay (enter the game world),'
            say '          then check: status '"$appid"' or grep "DLSS-NR" '"$log"
            ;;
    esac
    local line
    for line in "${evidence[@]:-}"; do
        if [[ -n $line ]]; then
            say "  $line"
        fi
    done
    [[ $verdict == running || $verdict == model-loaded ]]
}

# ------------------------------------------------------------------ main ---
[[ $# -ge 1 ]] || usage 1
cmd=$1; shift
case $cmd in
    list)    cmd_list "$@" ;;
    doctor)  cmd_doctor "$@" ;;
    setup)   [[ $# -ge 1 ]] || die 1 'setup: missing appid'; cmd_setup "$@" ;;
    refresh) [[ $# -ge 1 ]] || die 1 'refresh: missing appid'; cmd_setup "$@" ;;
    preset)  [[ $# -ge 2 ]] || die 1 'preset: expected A|B and an appid'; cmd_preset "$@" ;;
    status)  cmd_status "$@" ;;
    restore) [[ $# -ge 1 ]] || die 1 'restore: missing appid'; cmd_restore "$@" ;;
    launch)  [[ $# -ge 1 ]] || die 1 'launch: missing appid'; cmd_launch "$@" ;;
    -h|--help|help) usage 0 ;;
    --version) say "$PROG $VERSION"; exit 0 ;;
    *) usage 1 ;;
esac
