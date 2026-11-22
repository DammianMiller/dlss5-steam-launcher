#!/usr/bin/env python3
"""DLSS 5 tray icon + control panel for dlss5-steam-launcher.

A thin GTK3 GUI over the validated dlss5-steam-launcher.sh CLI:
  - a top-bar status icon (AyatanaAppIndicator / Ubuntu AppIndicators)
    with a dropdown menu: launch, launch+verify, preset A/B per game,
    refresh, doctor, status, control panel, quit
  - a control panel window: per-game state, preset radios, and the
    Status / Launch / Verify / Refresh / Restore actions, plus a live
    output pane showing everything the launcher prints

The GUI never implements install logic itself; every action shells out
to dlss5-steam-launcher.sh and streams its output.

Usage:
  dlss5-tray.py            start the tray icon (menu opens the panel)
  dlss5-tray.py --panel    start with the control panel window open
  dlss5-tray.py --self-test  construct everything, print OK, exit 0
"""

import os
import re
import signal
import subprocess
import sys
import threading

import gi

gi.require_version("Gtk", "3.0")
try:
    gi.require_version("AyatanaAppIndicator3", "0.1")
    from gi.repository import AyatanaAppIndicator3 as AppIndicator
    HAVE_INDICATOR = True
except Exception:  # pragma: no cover - GNOME without appindicator
    AppIndicator = None
    HAVE_INDICATOR = False

from gi.repository import GLib, Gtk

# ------------------------------------------------------------- games -----
# The game list is loaded from the launcher's machine-readable output
# (`list --tsv`: source, id, title, state, exedir) so the tray follows the
# launcher's whole library — Steam and Epic — without hardcoded ids here.
# Only games the launcher can act on (installed or eligible) are shown; the
# fallback list below is used when the launcher cannot be read.
FALLBACK_GAMES = [
    # (appid, display name)
    ("292030", "The Witcher 3: Wild Hunt — Remastered"),
    ("1371980", "No Rest for the Wicked"),
]
GAMES = FALLBACK_GAMES


def load_games():
    """(id, title) for every installed/eligible game, from `list --tsv`."""
    global GAMES
    try:
        proc = subprocess.run(
            ["bash", launcher_path(), "list", "--tsv"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            timeout=120, text=True, errors="replace")
        rows = []
        for line in proc.stdout.splitlines():
            f = line.split("\t")
            if len(f) >= 4 and f[0] in ("steam", "epic") \
                    and f[3] in ("installed", "eligible"):
                rows.append((f[1], f[2]))
        if rows:
            GAMES = rows
    except Exception:
        pass  # launcher unreadable — keep the fallback list
    return GAMES

PRESETS = {"A": "1", "B": "2"}          # letter -> ini Preset value
PRESET_FROM_INI = {"1": "A", "2": "B"}   # ini Preset value -> letter


def script_dir():
    return os.path.dirname(os.path.realpath(__file__))


def launcher_path():
    env = os.environ.get("DLSS5_LAUNCHER")
    if env and os.path.isfile(env):
        return env
    cand = os.path.join(script_dir(), "dlss5-steam-launcher.sh")
    if os.path.isfile(cand):
        return cand
    sys.exit("dlss5-steam-launcher.sh not found next to dlss5-tray.py "
             "(or set DLSS5_LAUNCHER)")


def icon_path():
    cand = os.path.join(script_dir(), "icons", "dlss5-nr.svg")
    return cand if os.path.isfile(cand) else "video-display"


# ------------------------------------------------------------- runner ----
class Runner:
    """Runs launcher commands in a thread, streams text to a callback."""

    def __init__(self, on_output):
        self.on_output = on_output
        self.busy = False

    def run(self, args, done=None, capture=None):
        if self.busy:
            self.on_output("[!] a command is already running — wait for it\n")
            return
        self.busy = True
        self.on_output("$ dlss5-steam-launcher.sh %s\n" % " ".join(args))

        def worker():
            try:
                proc = subprocess.run(
                    ["bash", launcher_path()] + args,
                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                    timeout=900, text=True, errors="replace")
                out = proc.stdout
                rc = proc.returncode
            except subprocess.TimeoutExpired:
                out, rc = "[!] command timed out after 900 s\n", 1
            except Exception as exc:  # pragma: no cover
                out, rc = "[!] %s\n" % exc, 1

            def deliver():
                self.busy = False
                self.on_output(out)
                if rc != 0:
                    self.on_output("[!] exit status %d\n" % rc)
                if capture:
                    capture(out)
                if done:
                    done()
                return False
            GLib.idle_add(deliver)

        threading.Thread(target=worker, daemon=True).start()


# ----------------------------------------------------------- state -------
def parse_status(appid, text):
    """Pull the panel-relevant facts out of `status <appid>` output."""
    st = {"installed": "receipt   : complete" in text,
          "preset": None, "compat": None, "verdict": []}
    m = re.search(r"Preset=(\d)", text)
    if m:
        st["preset"] = PRESET_FROM_INI.get(m.group(1))
    m = re.search(r"compat\s*:\s*(\S+)", text)
    if m:
        st["compat"] = m.group(1)
    for line in text.splitlines():
        s = line.strip()
        if s.startswith(":") or "verdict" in s.lower() or \
                "kernels cannot be loaded" in s:
            if s and s not in st["verdict"]:
                st["verdict"].append(s[:120])
    return st


# ------------------------------------------------------------- panel -----
class Panel(Gtk.Window):
    def __init__(self, runner, on_status_refresh):
        super().__init__(title="DLSS 5 Control Panel")
        self.runner = runner
        self.on_status_refresh = on_status_refresh
        self.set_default_size(720, 560)
        self.preset_radios = {}   # appid -> {"A": rb, "B": rb}
        self.state_labels = {}    # appid -> Gtk.Label

        hb = Gtk.HeaderBar()
        hb.set_show_close_button(True)
        hb.props.title = "DLSS 5 Control Panel"
        hb.props.subtitle = "Retoque 0.3.3 · NR model 310.9.16 · %s" % \
            os.path.basename(launcher_path())
        hb.show_all()
        self.set_titlebar(hb)

        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        box.set_border_width(10)

        for appid, name in GAMES:
            box.pack_start(self._game_frame(appid, name), False, False, 0)

        # ---- output pane ----
        frame = Gtk.Frame(label=" Launcher output ")
        frame.set_shadow_type(Gtk.ShadowType.IN)
        sw = Gtk.ScrolledWindow()
        sw.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)
        sw.set_size_request(-1, 220)
        self.buffer = Gtk.TextBuffer()
        view = Gtk.TextView(buffer=self.buffer)
        view.set_editable(False)
        view.set_cursor_visible(False)
        view.set_monospace(True)
        view.set_wrap_mode(Gtk.WrapMode.WORD_CHAR)
        tag = self.buffer.create_tag("dim",
                                     foreground="rgba(120,120,120,1)",
                                     scale=0.9)
        sw.add(view)
        frame.add(sw)
        box.pack_start(frame, True, True, 0)

        self.add(box)
        self.connect("delete-event", self._hide)

    def _game_frame(self, appid, name):
        frame = Gtk.Frame(label=" %s  (appid %s) " % (name, appid))
        grid = Gtk.Grid(row_spacing=8, column_spacing=12,
                        margin=10, border_width=4)

        self.state_labels[appid] = Gtk.Label(halign=Gtk.Align.START)
        self.state_labels[appid].set_markup(
            "<small>state unknown — press Status</small>")
        grid.attach(self.state_labels[appid], 0, 0, 4, 1)

        # preset radios: A (September) / B (October, default)
        rb_a = Gtk.RadioButton.new_with_label_from_widget(None,
                                                           "Model A (Sept)")
        rb_b = Gtk.RadioButton.new_with_label_from_widget(rb_a,
                                                           "Model B (Oct, default)")
        rb_a.connect("toggled", self._preset_toggled, appid, "A")
        rb_b.connect("toggled", self._preset_toggled, appid, "B")
        self.preset_radios[appid] = {"A": rb_a, "B": rb_b}
        grid.attach(rb_a, 0, 1, 1, 1)
        grid.attach(rb_b, 1, 1, 1, 1)

        btns = Gtk.Box(spacing=8)
        for label, cb in (("Status", self._status), ("Launch", self._launch),
                           ("Verify", self._verify), ("Refresh", self._refresh)):
            b = Gtk.Button.new_with_label(label)
            b.connect("clicked", cb, appid)
            btns.pack_start(b, False, False, 0)
        rb = Gtk.Button.new_with_label("Restore…")
        rb.get_style_context().add_class("destructive-action")
        rb.connect("clicked", self._restore, appid)
        btns.pack_end(rb, False, False, 0)
        grid.attach(btns, 0, 2, 4, 1)

        frame.add(grid)
        return frame

    # ---- panel actions ----
    def _preset_toggled(self, widget, appid, letter):
        if not widget.get_active():
            return
        current = getattr(self, "_shown_preset", {}).get(appid)
        if current == letter:
            return  # just reflecting status, not a user change
        self.runner.run(["preset", letter, appid],
                       done=lambda: self.on_status_refresh(appid))

    def _status(self, _b, appid):
        self.on_status_refresh(appid, verbose=True)

    def _launch(self, _b, appid):
        self.runner.run(["launch", appid])

    def _verify(self, _b, appid):
        self.runner.run(["launch", appid, "--verify"])

    def _refresh(self, _b, appid):
        self.runner.run(["refresh", appid],
                        done=lambda: self.on_status_refresh(appid))

    def _restore(self, _b, appid):
        name = dict(GAMES)[appid]
        dlg = Gtk.MessageDialog(
            transient_for=self, flags=0,
            message_type=Gtk.MessageType.QUESTION,
            buttons=Gtk.ButtonsType.OK_CANCEL,
            text="Remove the DLSS 5 override for %s?" % name)
        dlg.format_secondary_text(
            "restore removes the proxy, forwarder, NR model and ini edits, "
            "and puts back every original file. Steam 'verify integrity' "
            "is never needed.")
        resp = dlg.run()
        dlg.destroy()
        if resp == Gtk.ResponseType.OK:
            self.runner.run(["restore", appid],
                            done=lambda: self.on_status_refresh(appid))

    # ---- state display ----
    def set_state(self, appid, st):
        shown = getattr(self, "_shown_preset", {})
        shown[appid] = st.get("preset")
        self._shown_preset = shown
        if st.get("installed"):
            state = "<b>installed</b>"
        else:
            state = "<b>not installed</b>"
        compat = st.get("compat")
        if compat and compat != "-":
            state += " · compat: %s" % GLib.markup_escape_text(compat)
        if st.get("preset"):
            state += " · model %s" % st["preset"]
        self.state_labels[appid].set_markup(state)
        radios = self.preset_radios.get(appid, {})
        for letter, rb in radios.items():
            rb.set_active(st.get("preset") == letter)
        for line in st.get("verdict", []):
            self.state_labels[appid].set_tooltip_text(line)

    def _hide(self, *_a):
        self.hide()
        return True  # keep the process alive; tray reopens the panel

    def append(self, text):
        end = self.buffer.get_end_iter()
        self.buffer.insert(end, text)
        # keep the pane bounded
        if self.buffer.get_line_count() > 2000:
            start = self.buffer.get_iter_at_line(
                self.buffer.get_line_count() - 2000)
            self.buffer.delete(self.buffer.get_start_iter(), start)


# -------------------------------------------------------------- app ------
class App:
    def __init__(self):
        self.panel = None
        self.indicator = None
        self.status_cache = {}

    def output(self, text):
        if self.panel:
            self.panel.append(text)
        else:
            sys.stdout.write(text)
            sys.stdout.flush()

    def refresh_status(self, appid, verbose=False):
        def capture(text):
            self.last_status = text

        def done():
            st = parse_status(appid, self.last_status)
            self.status_cache[appid] = st
            if self.panel:
                self.panel.set_state(appid, st)
            if verbose:
                self.output(self.last_status)

        self.last_status = ""
        self.runner.run(["status", appid], done=done, capture=capture)

    def build(self):
        self.runner = Runner(self.output)
        load_games()   # panel and menus read GAMES — fill it first

        # ---- panel ----
        self.panel = Panel(self.runner, self.refresh_status)

        # ---- tray menu ----
        menu = Gtk.Menu()

        def item(label, cb=None, submenu=None):
            mi = Gtk.MenuItem.new_with_label(label)
            if submenu:
                mi.set_submenu(submenu)
            elif cb:
                mi.connect("activate", cb)
            menu.append(mi)

        item("Open Control Panel", lambda *_: self.show_panel())

        menu.append(Gtk.SeparatorMenuItem())

        for appid, name in GAMES:
            short = name.split(":")[0]
            sub = Gtk.Menu()
            for label, args in (
                    ("Launch", ["launch", appid]),
                    ("Launch + verify model", ["launch", appid, "--verify"]),
                    ("Refresh override", ["refresh", appid])):
                mi = Gtk.MenuItem.new_with_label(label)
                mi.connect("activate",
                           lambda _m, a=args: self.runner.run(a))
                sub.append(mi)

            psub = Gtk.Menu()
            first = Gtk.RadioMenuItem.new_with_label(None, "Model A (Sept)")
            second = Gtk.RadioMenuItem.new_with_label_from_widget(
                first, "Model B (Oct, default)")
            first.connect("activate", lambda _m, a=appid: self.set_preset(a, "A"))
            second.connect("activate", lambda _m, a=appid: self.set_preset(a, "B"))
            self.tray_preset_radios = getattr(self, "tray_preset_radios", {})
            self.tray_preset_radios[appid] = {"A": first, "B": second}
            psub.append(first)
            psub.append(second)
            ptitle = Gtk.MenuItem.new_with_label("Preset")
            ptitle.set_submenu(psub)
            sub.append(Gtk.SeparatorMenuItem())
            sub.append(ptitle)

            item("▶  %s" % short, submenu=sub)

        menu.append(Gtk.SeparatorMenuItem())

        for appid, name in GAMES:
            short = name.split(":")[0]
            item("Status — %s" % short,
                 lambda _m, a=appid: self.refresh_status(a, verbose=True))
        item("Doctor (GPU, driver, pins)",
             lambda *_: self.runner.run(["doctor"]))
        item("List library",
             lambda *_: self.runner.run(["list"]))

        menu.append(Gtk.SeparatorMenuItem())
        item("Quit", lambda *_: Gtk.main_quit())
        menu.show_all()

        # ---- indicator ----
        if HAVE_INDICATOR:
            self.indicator = AppIndicator.Indicator.new(
                "dlss5-tray", icon_path(),
                AppIndicator.IndicatorCategory.APPLICATION_STATUS)
            self.indicator.set_status(AppIndicator.IndicatorStatus.ACTIVE)
            self.indicator.set_title("DLSS 5")
            self.indicator.set_menu(menu)
        else:
            self.output("[i] no AppIndicator support — control panel only; "
                        "the tray icon needs ubuntu-appindicators\n")

        # initial state load (silent)
        for appid, _ in GAMES:
            self.refresh_status(appid)

    def show_panel(self):
        self.panel.show_all()
        self.panel.present()

    def set_preset(self, appid, letter):
        self.runner.run(["preset", letter, appid],
                        done=lambda: self.refresh_status(appid))


def main():
    signal.signal(signal.SIGINT, signal.SIG_DFL)  # Ctrl-C quits cleanly
    args = set(sys.argv[1:])
    if "--help" in args:
        print(__doc__)
        return 0
    app = App()
    app.build()
    if "--self-test" in args:
        print("SELF-TEST OK: menu, panel, indicator constructed; "
              "launcher=%s indicator=%s" % (launcher_path(),
                                            bool(app.indicator)))
        return 0
    if "--panel" in args:
        app.show_panel()
    Gtk.main()
    return 0


if __name__ == "__main__":
    sys.exit(main())
