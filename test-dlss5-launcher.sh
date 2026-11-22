#!/usr/bin/env bash
# test-dlss5-launcher.sh — validation harness for dlss5-steam-launcher.sh.
#
# Runs without touching real games: syntax + shellcheck, unit tests of the
# ini/vdf/pin helpers against the real pinned components, and an end-to-end
# pass on a fake game tree built from the REAL components (engine deploy,
# model install, idempotency, presets, status, refusals, byte-exact restore).
# The GPU/driver guards run against the real machine (it has the RTX 5090).
#
# Usage: bash test-dlss5-launcher.sh    (exit 0 = all checks passed)
set -uo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
LAUNCHER="$HERE/dlss5-steam-launcher.sh"
COMPONENTS=${DLSS5_COMPONENTS_DIR:-"$HOME/dev/workbench/tmp/dlss5-linux"}
WORK=$(mktemp -d /tmp/dlss5-test.XXXXXX)
PASS=0 FAIL=0 STEP=0

say()  { printf '%s\n' "$*"; }
ok()   { PASS=$((PASS + 1)); printf 'ok   %s\n' "$*"; }
bad()  { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$*"; }

check() { # check <description> <command...> — passes when the command succeeds
    local desc=$1; shift
    STEP=$((STEP + 1))
    if "$@" >"$WORK/last.out" 2>&1; then ok "$desc"; else
        bad "$desc"; sed -n '1,12p' "$WORK/last.out" | sed 's/^/       /'
    fi
}
check_fails() { # check_fails <description> <expected-exit> <command...>
    local desc=$1 want=$2 rc=0; shift 2
    STEP=$((STEP + 1))
    "$@" >"$WORK/last.out" 2>&1; rc=$?
    if (( rc == want )); then ok "$desc"; else
        bad "$desc (exit $rc, wanted $want)"; sed -n '1,8p' "$WORK/last.out" | sed 's/^/       /'
    fi
}
grep_out() { # grep_out <description> <pattern>
    STEP=$((STEP + 1))
    if grep -aq "$2" "$WORK/last.out"; then ok "$1"; else bad "$1 (pattern not found: $2)"; fi
}

cleanup() { rm -rf -- "$WORK"; }
trap cleanup EXIT

# ------------------------------------------------------------------ 0. shape
[[ -f $LAUNCHER ]] || { say "launcher not found: $LAUNCHER"; exit 1; }
[[ -d $COMPONENTS/retoque ]] || { say "components not found: $COMPONENTS (set DLSS5_COMPONENTS_DIR)"; exit 1; }
[[ -f $COMPONENTS/nvngx_dlssnr.dll ]] || { say "NR model missing in $COMPONENTS"; exit 1; }

say "== dlss5-steam-launcher test harness =="
say "   launcher : $LAUNCHER"
say "   components: $COMPONENTS"
say "   workdir  : $WORK"

# 0.1 syntax
check 'bash -n parses the launcher' bash -n "$LAUNCHER"

# 0.2 shellcheck (advisory)
if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck -S warning "$LAUNCHER" >"$WORK/last.out" 2>&1; then
        ok 'shellcheck clean (warnings+)'
    else
        bad 'shellcheck findings (advisory)'; sed -n '1,8p' "$WORK/last.out" | sed 's/^/       /'
    fi
else
    say '---  shellcheck not installed — skipped (advisory)'
fi

# 0.3 usage exits 0 with --help
check '--help exits 0' bash "$LAUNCHER" --help
grep_out 'usage lists the commands' 'setup <appid>'

# ------------------------------------------------- 1. unit tests of helpers
# Source the launcher with its main dispatch stripped so functions can be
# tested directly without executing a command.
sed '/^# ------------------------------------------------------------------ main ---/,$d' "$LAUNCHER" > "$WORK/lib.sh"
# shellcheck source=/dev/null
source "$WORK/lib.sh"
set +e   # the sourced lib sets errexit; the harness collects failures itself

# 1.1 ini_set replaces in place, drops later duplicates, leaves other sections
cat > "$WORK/t.ini" <<'EOF'
[Menu]
ShortcutKey=0x24

[DlssNr]
Enabled=auto
; a comment
Preset=auto
Enabled=false

[Other]
Enabled=never
EOF
ini_set "$WORK/t.ini" DlssNr Enabled true
ini_set "$WORK/t.ini" DlssNr Preset 2
n=$(awk 'f&&/^\[/{exit} /^\[DlssNr\]/{f=1} f&&/^Enabled=/' "$WORK/t.ini" | wc -l)
v=$(ini_get "$WORK/t.ini" DlssNr Enabled)
p=$(ini_get "$WORK/t.ini" DlssNr Preset)
o=$(ini_get "$WORK/t.ini" Other Enabled)
(( n == 1 )) && [[ $v == true && $p == 2 && $o == never ]] \
    && ok 'ini_set: single key, right section, other sections intact' \
    || bad 'ini_set: dup-drop/section isolation failed'
# missing key inside an existing section is appended to that section
ini_set "$WORK/t.ini" DlssNr NewKey 7
[[ $(ini_get "$WORK/t.ini" DlssNr NewKey) == 7 ]] \
    && ok 'ini_set: appends a missing key to the section' \
    || bad 'ini_set: append failed'
# section that does not exist yet is created
ini_set "$WORK/t.ini" BrandNew Key value
[[ $(ini_get "$WORK/t.ini" BrandNew Key) == value ]] \
    && ok 'ini_set: creates a missing section at EOF' \
    || bad 'ini_set: section creation failed'
# a comment line is never mistaken for the key
grep -aq '^; a comment' "$WORK/t.ini" && ok 'ini_set: comments preserved' || bad 'ini_set: comment lost'

# 1.2 acf_value parses a manifest
cat > "$WORK/appmanifest_1.acf" <<'EOF'
"AppState"
{
	"appid"		"999000"
	"name"		"Fake Game"
	"installdir"		"FakeGame"
	"StateFlags"		"4"
}
EOF
[[ $(acf_value "$WORK/appmanifest_1.acf" name) == 'Fake Game' \
    && $(acf_value "$WORK/appmanifest_1.acf" installdir) == FakeGame ]] \
    && ok 'acf_value: name and installdir parsed' || bad 'acf_value: parse failed'

# 1.3 compat_tool_for finds the mapping in a config.vdf
mkdir -p "$WORK/fakesteam/config"
cat > "$WORK/fakesteam/config/config.vdf" <<'EOF'
"InstallConfigStore"
{
	"Software"
	{
		"Valve"
		{
			"Steam"
			{
				"CompatToolMapping"
				{
					"292030"
					{
						"name"		"proton-wineland-11.0-20261119-x86_64_v3"
						"compat_tool"		"proton-wineland-11.0-20261119-x86_64_v3"
					}
					"553850"
					{
						"ShaderCacheSize"		"42"
					}
				}
			}
		}
	}
}
EOF
[[ $(DLSS5_STEAM_ROOT=$WORK/fakesteam compat_tool_for 292030) == proton-wineland-11.0-20261119-x86_64_v3 ]] \
    && ok 'compat_tool_for: mapping found' || bad 'compat_tool_for: mapping not found'
[[ -z $(DLSS5_STEAM_ROOT=$WORK/fakesteam compat_tool_for 553850) ]] \
    && ok 'compat_tool_for: no false positive on a non-mapping block' || bad 'compat_tool_for: false positive'

# 1.4 pin checks against the real components (positive) and a corrupted copy (negative)
mkdir -p "$WORK/bad/retoque"
cp "$COMPONENTS/retoque/OptiScaler.dll" "$WORK/bad/retoque/OptiScaler.dll"
cp "$COMPONENTS/retoque/nvngx.dll_dlssnr.dll" "$WORK/bad/retoque/nvngx.dll_dlssnr.dll"
cp "$COMPONENTS/retoque/OptiScaler.ini" "$WORK/bad/retoque/OptiScaler.ini"
cp "$COMPONENTS/retoque/deploy-to-game.sh" "$WORK/bad/retoque/deploy-to-game.sh"
cp "$COMPONENTS/nvngx_dlssnr.dll" "$WORK/bad/nvngx_dlssnr.dll"
check 'verify_components accepts the real pinned cache' \
    env DLSS5_COMPONENTS_DIR=$COMPONENTS bash -c "source '$WORK/lib.sh'; verify_components"
printf 'X' | dd of="$WORK/bad/retoque/OptiScaler.dll" bs=1 seek=100 conv=notrunc status=none
check_fails 'verify_components rejects a corrupted component' 1 \
    env DLSS5_COMPONENTS_DIR=$WORK/bad bash -c "source '$WORK/lib.sh'; verify_components"

# 1.5 resolve_exedir heuristic on an unknown game layout
mkdir -p "$WORK/fakegame/bin" "$WORK/fakegame/tools"
cp "$COMPONENTS/retoque/nvngx.dll_dlssnr.dll" "$WORK/fakegame/bin/FakeGame.exe"   # any PE x64 file
cp "$COMPONENTS/retoque/nvngx.dll_dlssnr.dll" "$WORK/fakegame/bin/Second.exe"
cp "$COMPONENTS/retoque/nvngx.dll_dlssnr.dll" "$WORK/fakegame/tools/CrashHandler.exe"
he=$(GAME_EXE_SUBDIR=() resolve_exedir 999000 "$WORK/fakegame")
[[ $he == "$WORK/fakegame/bin" ]] \
    && ok 'resolve_exedir: picks the exe folder, skips crash handlers' \
    || bad "resolve_exedir: got '$he'"

# ------------------------------------------------------ 2. e2e on fake tree
# Fake Steam root with one unknown game (heuristic exe dir) and a fake
# Helldivers 2 (excluded appid with real EAC marker dirs).
FS=$WORK/fakesteam
LIB=$FS
mkdir -p "$FS/steamapps/common/FakeGame/bin" "$FS/steamapps/common/Helldivers 2/bin" \
         "$FS/steamapps/common/Helldivers 2/EasyAntiCheat"
cat > "$FS/steamapps/libraryfolders.vdf" <<EOF
"libraryfolders"
{
	"0"
	{
		"path"		"$FS"
	}
}
EOF
cat > "$FS/steamapps/appmanifest_999000.acf" <<EOF
"AppState"
{
	"appid"		"999000"
	"name"		"Fake Game"
	"installdir"		"FakeGame"
	"StateFlags"		"4"
}
EOF
cat > "$FS/steamapps/appmanifest_553850.acf" <<EOF
"AppState"
{
	"appid"		"553850"
	"name"		"HELLDIVERS 2"
	"installdir"		"Helldivers 2"
	"StateFlags"		"4"
}
EOF
cp "$COMPONENTS/retoque/nvngx.dll_dlssnr.dll" "$FS/steamapps/common/FakeGame/bin/FakeGame.exe"
cp "$COMPONENTS/retoque/nvngx.dll_dlssnr.dll" "$FS/steamapps/common/Helldivers 2/bin/helldivers2.exe"
EXE=$FS/steamapps/common/FakeGame/bin

# Fake Epic Games Launcher v2 data dir (library cache with one assessed game
# and one unassessed purchase) + a fake install root holding Death Stranding.
EPICD=$WORK/fake-eglv2
EROOT=$WORK/epicroot
EACCT=$EPICD/cache/prod/account/8b7d5b55211f4a4a88cb56fd19d96527
mkdir -p "$EACCT" "$EROOT/DeathStranding"
cat > "$EACCT/library-cache.json" <<'EOF'
{"items":[{"appId":{"appName":"Boga"}},{"appId":{"appName":"UnassessedNewGame77"}}]}
EOF
cp "$COMPONENTS/retoque/nvngx.dll_dlssnr.dll" "$EROOT/DeathStranding/DeathStranding.exe"
EEXE=$EROOT/DeathStranding

run() { # run <args...> — invoke the launcher against the fake roots
    DLSS5_STEAM_ROOT=$FS DLSS5_EGLV2_DIR=$EPICD DLSS5_EPIC_ROOTS=$EROOT \
    DLSS5_COMPONENTS_DIR=$COMPONENTS bash "$LAUNCHER" "$@"
}

# 2.1 list and doctor
check 'list: exits 0' run list
grep_out 'list: fake game shown eligible' 'Fake Game'
check 'doctor: exits 0 with no appid' run doctor
grep_out 'doctor: reports the GPU' 'GPU'

# 2.2 excluded appid is refused
check_fails 'setup refuses the excluded anti-cheat game' 1 run setup 553850
grep_out 'refusal names the anti-cheat reason' 'EasyAntiCheat'

# 2.3 unknown appid is refused
check_fails 'setup refuses an appid that is not installed' 1 run setup 1

# 2.4 dry run writes nothing
check 'setup --dry-run exits 0' run setup 999000 --dry-run
[[ ! -e $EXE/dxgi.dll ]] && ok 'dry run wrote no proxy' || bad 'dry run wrote files'

# 2.5 real install
check 'setup 999000 installs the override' run setup 999000
grep_out 'install output mentions the model' 'nvngx_dlssnr.dll'
[[ $(sha_of "$EXE/dxgi.dll") == "$PIN_OPTISCALER" ]] \
    && ok 'dxgi.dll is the pinned Retoque proxy' || bad 'dxgi.dll hash mismatch'
[[ $(sha_of "$EXE/OptiScaler.dll") == "$PIN_OPTISCALER" ]] \
    && ok 'OptiScaler.dll beside the proxy is pinned' || bad 'OptiScaler.dll hash mismatch'
[[ $(sha_of "$EXE/nvngx.dll_dlssnr.dll") == "$PIN_FORWARDER" ]] \
    && ok 'forwarder installed and pinned' || bad 'forwarder hash mismatch'
[[ $(sha_of "$EXE/nvngx_dlssnr.dll") == "$PIN_MODEL" ]] \
    && ok 'NR model 310.9.16 installed and pinned' || bad 'model hash mismatch'
grep -aq 'OptiScaler working as' "$EXE/dxgi.dll" \
    && ok 'proxy carries the OptiScaler marker' || bad 'proxy marker missing'
[[ -f $EXE/OptiScaler.ini ]] && ok 'OptiScaler.ini installed' || bad 'OptiScaler.ini missing'
[[ $(ini_get "$EXE/OptiScaler.ini" DlssNr Enabled) == true ]] \
    && ok '[DlssNr] Enabled=true' || bad 'Enabled not true'
[[ $(ini_get "$EXE/OptiScaler.ini" DlssNr Preset) == 2 ]] \
    && ok '[DlssNr] Preset=2 (model B) by default' || bad 'Preset not 2'
[[ -f $EXE/OptiScaler/D3D12_OptiScaler/D3D12Core.dll ]] \
    && ok 'support tree (OptiScaler/) installed' || bad 'support tree missing'
if [[ -f /usr/lib/x86_64-linux-gnu/nvidia/wine/_nvngx.dll ]]; then
    [[ $(sha_of "$EXE/_nvngx.dll") == $(sha_of /usr/lib/x86_64-linux-gnu/nvidia/wine/_nvngx.dll) ]] \
        && ok 'driver Wine _nvngx.dll copied fresh from the current driver' \
        || bad '_nvngx.dll does not match the current driver'
fi
[[ $(awk -F'\t' '$1=="status"{print $2}' "$EXE/.retoque/receipt.txt" | tail -n1) == complete ]] \
    && ok 'engine receipt is complete' || bad 'receipt not complete'
grep -aq '^model' "$EXE/.dlss5-launcher/journal.txt" \
    && ok 'launcher journal records the model' || bad 'launcher journal missing'

# 2.6 idempotency
before=$(sha_of "$EXE/dxgi.dll")
check 're-running setup is idempotent' run setup 999000
[[ $(sha_of "$EXE/dxgi.dll") == "$before" ]] && ok 'proxy unchanged by re-run' || bad 'proxy changed on re-run'
[[ $(awk -F'\t' '$1=="status"{print $2}' "$EXE/.retoque/receipt.txt" | tail -n1) == complete ]] \
    && ok 'receipt still complete after re-run' || bad 'receipt broken by re-run'

# 2.7 presets
check 'preset A applies Preset=1' run preset A 999000
[[ $(ini_get "$EXE/OptiScaler.ini" DlssNr Preset) == 1 ]] \
    && ok 'preset A wrote 1' || bad 'preset A failed'
check 'preset B applies Preset=2' run preset B 999000
[[ $(ini_get "$EXE/OptiScaler.ini" DlssNr Preset) == 2 ]] \
    && ok 'preset B wrote 2' || bad 'preset B failed'
check_fails 'preset C is rejected' 1 run preset C 999000

# 2.8 status
check 'status 999000 exits 0' run status 999000
grep_out 'status shows the pinned model' '310.9.16 (pinned)'
grep_out 'status shows the proxy' 'dxgi.dll'

# 2.9 running-game refusal (a process maps a file in the exe dir)
python3 - "$EXE/FakeGame.exe" >"$WORK/last.out" 2>&1 <<'EOF' &
import mmap, sys, time
f = open(sys.argv[1], 'rb')
m = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
print('mapping held', flush=True)
time.sleep(120)
EOF
MAPPER=$!
sleep 2
check_fails 'setup refuses while a process maps the game dir' 3 run setup 999000
kill "$MAPPER" 2>/dev/null; wait "$MAPPER" 2>/dev/null

# 2.10 foreign proxy refusal + --replace-foreign + byte-exact restore
check 'restore 999000 removes the override' run restore 999000
[[ ! -e $EXE/dxgi.dll && ! -e $EXE/nvngx_dlssnr.dll && ! -e $EXE/OptiScaler.ini ]] \
    && ok 'restore removed proxy, model and ini' || bad 'restore left files behind'
printf 'this is a foreign dxgi.dll\n' > "$EXE/dxgi.dll"
foreign_sha=$(sha_of "$EXE/dxgi.dll")
check_fails 'setup refuses a foreign file at the proxy name' 4 run setup 999000
[[ $(sha_of "$EXE/dxgi.dll") == "$foreign_sha" ]] \
    && ok 'refusal left the foreign file untouched' || bad 'refusal modified the foreign file'
check 'setup --replace-foreign backs up and installs' run setup 999000 --replace-foreign
[[ $(sha_of "$EXE/dxgi.dll") == "$PIN_OPTISCALER" ]] \
    && ok 'proxy installed over the foreign file' || bad 'proxy not installed'
check 'restore returns the foreign file byte-exact' run restore 999000
[[ $(sha_of "$EXE/dxgi.dll") == "$foreign_sha" ]] \
    && ok 'foreign dxgi.dll restored byte-exact' || bad 'foreign file not restored byte-exact'
rm -f -- "$EXE/dxgi.dll"   # clear the restored foreign file for the next scenario

# 2.11 preserved user ini is edited in place and restored byte-exact
printf '[DlssNr]\nEnabled=false\nCustomKey=keepme\n' > "$EXE/OptiScaler.ini"
user_sha=$(sha_of "$EXE/OptiScaler.ini")
check 'setup preserves an existing user ini' run setup 999000
[[ $(ini_get "$EXE/OptiScaler.ini" DlssNr Enabled) == true \
    && $(ini_get "$EXE/OptiScaler.ini" DlssNr CustomKey) == keepme ]] \
    && ok 'user ini edited in place, custom keys intact' || bad 'user ini handling broken'
check 'restore returns the user ini byte-exact' run restore 999000
[[ $(sha_of "$EXE/OptiScaler.ini") == "$user_sha" ]] \
    && ok 'user ini restored byte-exact' || bad 'user ini not restored'

# 2.12 final state clean
[[ ! -e $EXE/dxgi.dll && ! -e $EXE/OptiScaler.dll && ! -e $EXE/nvngx.dll_dlssnr.dll \
    && ! -e $EXE/nvngx_dlssnr.dll && ! -e $EXE/.dlss5-launcher ]] \
    && ok 'no override residue after restore' || bad 'residue left after restore'

# ------------------------------------------------ 3. epic library (helpers)
# 3.0 unit checks of the epic helpers against the fixtures above
is_epic epic:Boga && ! is_epic 292030 \
    && ok 'is_epic: epic: prefix detected' || bad 'is_epic failed'
[[ $(epic_app epic:Boga) == Boga ]] \
    && ok 'epic_app: appName extracted' || bad 'epic_app failed'
[[ $(DLSS5_EPIC_ROOTS='/a:/b' epic_roots | tr '\n' ' ') == '/a /b ' ]] \
    && ok 'epic_roots: colon-separated override parsed' || bad 'epic_roots override failed'
[[ $(DLSS5_EPIC_ROOTS=$EROOT epic_gamedir_for epic:Boga) == "$EEXE" ]] \
    && ok 'epic_gamedir_for: installed game dir found' || bad 'epic_gamedir_for failed'
DLSS5_EPIC_ROOTS=$EROOT epic_gamedir_for epic:Larkspur >/dev/null 2>&1
[[ $? -eq 1 ]] \
    && ok 'epic_gamedir_for: absent install dir returns 1' || bad 'epic_gamedir_for rc wrong'
[[ $(DLSS5_EGLV2_DIR=$EPICD epic_cache_appnames | sort | tr '\n' ' ') == 'Boga UnassessedNewGame77 ' ]] \
    && ok 'epic_cache_appnames: cache appNames listed' || bad 'epic_cache_appnames failed'
epic_list_keys | grep -qx 'epic:Boga' \
    && ok 'epic_list_keys: table keys sorted by title' || bad 'epic_list_keys failed'
[[ $(epic_list_keys | wc -l) -eq 166 ]] \
    && ok 'epic_list_keys: all 166 owned items listed' || bad 'epic_list_keys count wrong'
[[ -z $(DLSS5_STEAM_ROOT=$FS compat_tool_for epic:Boga) ]] \
    && ok 'compat_tool_for: epic keys skip the Steam config' || bad 'compat_tool_for leaked into epic'

# ------------------------------------------------ 4. e2e on the epic tree
# 4.1 list covers both stores
check 'list (steam+epic fixtures): exits 0' run list
grep_out 'list: fake steam game shown eligible' 'Fake Game'
grep_out 'list: epic section shows Death Stranding' 'Death Stranding'
grep_out 'list: epic counts line' '85 eligible, 35 excluded, 46 not games'
grep_out 'list: epic excluded summary present' 'excluded  epic:Dodo:'
check 'list --tsv: exits 0' run list --tsv
if awk -F'\t' '$1=="epic" && $2=="epic:Boga" && $3=="Death Stranding" && $4=="eligible" && NF==5' \
        "$WORK/last.out" | grep -q .; then
    ok 'list --tsv: epic row shape source/id/title/state/exedir'
else
    bad 'list --tsv: epic row shape wrong'
fi
if awk -F'\t' '$1=="steam" && $2=="999000" && NF==5' "$WORK/last.out" | grep -q .; then
    ok 'list --tsv: steam row shape intact'
else
    bad 'list --tsv: steam row shape wrong'
fi
grep_out 'list: warns about the unassessed epic purchase' 'UnassessedNewGame77'

# 4.2 doctor reports the epic section
check 'doctor: exits 0 with the epic fixtures' run doctor
grep_out 'doctor: reports the EGL v2 data dir' 'Epic EGLv2'
grep_out 'doctor: reports the epic root' 'Epic root'

# 4.3 full install on an epic game (same engine path as Steam)
check 'setup epic:Boga installs the override' run setup epic:Boga
grep_out 'setup epic: compat notes the EGL Proton runtime' 'Epic Games Launcher runs this game under its own Proton'
[[ $(sha_of "$EEXE/dxgi.dll") == "$PIN_OPTISCALER" ]] \
    && ok 'epic: dxgi.dll is the pinned Retoque proxy' || bad 'epic: dxgi.dll hash mismatch'
[[ $(sha_of "$EEXE/nvngx_dlssnr.dll") == "$PIN_MODEL" ]] \
    && ok 'epic: NR model 310.9.16 installed and pinned' || bad 'epic: model hash mismatch'
[[ $(ini_get "$EEXE/OptiScaler.ini" DlssNr Enabled) == true \
    && $(ini_get "$EEXE/OptiScaler.ini" DlssNr Preset) == 2 ]] \
    && ok 'epic: ini keys set (Enabled=true, Preset=2)' || bad 'epic: ini keys wrong'
[[ $(awk -F'\t' '$1=="status"{print $2}' "$EEXE/.retoque/receipt.txt" | tail -n1) == complete ]] \
    && ok 'epic: engine receipt is complete' || bad 'epic: receipt not complete'

# 4.4 status and presets on an epic key
check 'status epic:Boga exits 0' run status epic:Boga
grep_out 'status epic: shows the pinned model' '310.9.16 (pinned)'
grep_out 'status epic: compat line names EGL v2' 'EGLv2'
check 'status (no args) lists installed epic games' run status
grep_out 'status (no args): Death Stranding present' 'Death Stranding'
check 'preset A applies on an epic key' run preset A epic:Boga
[[ $(ini_get "$EEXE/OptiScaler.ini" DlssNr Preset) == 1 ]] \
    && ok 'preset A wrote 1 on the epic key' || bad 'preset A failed on epic'
check 'preset B applies on an epic key' run preset B epic:Boga
[[ $(ini_get "$EEXE/OptiScaler.ini" DlssNr Preset) == 2 ]] \
    && ok 'preset B wrote 2 on the epic key' || bad 'preset B failed on epic'

# 4.5 refusals for epic keys (exit code + message)
check_fails 'setup refuses an owned-but-not-installed epic game' 1 run setup epic:Larkspur
grep_out 'refusal: install it with the Epic Games Launcher' 'install it with the Epic Games Launcher'
check_fails 'setup refuses an excluded anti-cheat epic game' 1 run setup epic:Peppermint
grep_out 'refusal: names the anti-cheat reason' 'EasyAntiCheat'
check_fails 'setup refuses an excluded renderer epic game' 1 run setup epic:Dodo
grep_out 'refusal: names the renderer reason' 'D3D9'
check_fails 'setup refuses a non-game epic item' 1 run setup epic:TM_2020.1
check_fails 'setup refuses an unknown epic key' 1 run setup epic:NoSuchKey
check_fails 'launch refuses an excluded epic game' 1 run launch epic:Dodo

# 4.6 restore on an epic key
check 'restore epic:Boga removes the override' run restore epic:Boga
[[ ! -e $EEXE/dxgi.dll && ! -e $EEXE/nvngx_dlssnr.dll && ! -e $EEXE/OptiScaler.ini \
    && ! -e $EEXE/.dlss5-launcher ]] \
    && ok 'epic: no override residue after restore' || bad 'epic: residue left after restore'

# 4.7 launch hands the EGL URL scheme to the Epic launcher binary
mkdir -p "$WORK/bin"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" > "%s/urlargs.txt"\n' "$WORK" > "$WORK/bin/EpicGamesLauncher"
chmod +x "$WORK/bin/EpicGamesLauncher"
check 'launch epic:Boga exits 0 through the shim' \
    env PATH="$WORK/bin:$PATH" DLSS5_STEAM_ROOT=$FS DLSS5_EGLV2_DIR=$EPICD \
        DLSS5_EPIC_ROOTS=$EROOT bash "$LAUNCHER" launch epic:Boga
sleep 1
[[ $(cat "$WORK/urlargs.txt" 2>/dev/null) == 'com.epicgames.launcher://apps/Boga?action=launch&silent=true' ]] \
    && ok 'launch: EGL URL action=launch&silent=true handed to the binary' \
    || bad 'launch: wrong or missing URL handed to the Epic binary'

# ------------------------------------------------------------------ summary
say ''
say "==== $PASS passed, $FAIL failed ($STEP checks) ===="
if (( FAIL )); then
    exit 1
fi
exit 0
