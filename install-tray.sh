#!/usr/bin/env bash
# Install the DLSS 5 tray icon + control panel for the current user.
#   install-tray.sh              install the application menu entry
#   install-tray.sh --autostart  also start it at login
#   install-tray.sh --run        install and start it right now
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
tray="$here/dlss5-tray.py"
icon="$here/icons/dlss5-nr.svg"
apps_dir="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
autostart_dir="${XDG_CONFIG_HOME:-$HOME/.config}/autostart"

[[ -f $tray ]] || { echo "dlss5-tray.py not found next to this script" >&2; exit 1; }
[[ -f $icon ]] || { echo "icons/dlss5-nr.svg not found next to this script" >&2; exit 1; }
chmod +x "$tray"

mkdir -p "$apps_dir"
cat > "$apps_dir/dlss5-tray.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=DLSS 5 Tray
GenericName=DLSS 5 override controls
Comment=Status bar icon and control panel for the DLSS 5 launcher (Witcher 3, No Rest for the Wicked)
Exec=python3 $tray --panel
Icon=$icon
Terminal=false
Categories=Utility;Game;
Keywords=DLSS;NVIDIA;NR;neural rendering;
StartupNotify=false
X-GNOME-UsesNotifications=false
EOF

if [[ ${1:-} == "--autostart" ]]; then
    mkdir -p "$autostart_dir"
    cp "$apps_dir/dlss5-tray.desktop" "$autostart_dir/dlss5-tray.desktop"
    echo "[+] autostart entry: $autostart_dir/dlss5-tray.desktop"
fi

update-desktop-database "$apps_dir" 2>/dev/null || true
echo "[+] installed: $apps_dir/dlss5-tray.desktop"
echo "    start from the Activities overview ('DLSS 5 Tray') or:"
echo "    python3 $tray"

if [[ ${1:-} == "--run" ]]; then
    nohup python3 "$tray" --panel >> "${XDG_CACHE_HOME:-$HOME/.cache}/dlss5-tray.log" 2>&1 &
    disown || true
    echo "[+] started in the background (log: ~/.cache/dlss5-tray.log)"
fi
