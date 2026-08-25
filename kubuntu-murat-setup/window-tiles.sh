#!/usr/bin/env bash
# Bind KWin quick-tile / center / maximize shortcuts on Kubuntu (Plasma 6).
#
#   ./window-tiles.sh apply
#   ./window-tiles.sh revert
#   ./window-tiles.sh status
#
# Ctrl+Alt+Left/Right/Up/Down  left / right / top / bottom half
# Ctrl+Alt+Enter               resize to 75% of the work area and center
# Ctrl+Alt+F                   maximize
#
# Existing Meta+arrow quick-tile and Meta+PgUp maximize bindings are kept.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/kubuntu-murat-setup"
STATE_FILE="${STATE_DIR}/window-tiles.state"
MARKER="# managed by kubuntu-murat-setup window-tiles.sh"
KWIN_SCRIPT_ID="muratcenter75"
KWIN_SCRIPT_SRC="${SCRIPT_DIR}/window-tiles/${KWIN_SCRIPT_ID}"
KWIN_SCRIPT_DST="${HOME}/.local/share/kwin/scripts/${KWIN_SCRIPT_ID}"

usage() {
  cat <<'EOF'
Usage: window-tiles.sh <apply|revert|status>

  apply    Bind:
              Ctrl+Alt+Left/Right/Up/Down → tile to that half of the screen
              Ctrl+Alt+Enter              → resize to 75% and center
              Ctrl+Alt+F                  → maximize
           Keeps the stock Meta+arrow tile shortcuts.
  revert   Restore the KWin shortcuts this script replaced, remove the
           75% center script.
  status   Show the current bindings.

These are KWin "Quick Tile" halves (same as Meta+arrows), not the Meta+T
custom tile editor. Center is a small KWin script: 75% of the work area,
then centered. KWin has no built-in "resize and center" action.

On the Magic Keyboard, keyd's Option+arrow word-jump must not swallow
Control+Option+arrows. window-tiles.sh does not touch keyd; that overlay
lives in macos-keyboard/keyd/macos-magic-keyboard.conf ([opt+control]).
EOF
}

die() { echo "error: $*" >&2; exit 1; }

need_user() {
  [[ ${EUID} -ne 0 ]] || die "run this as your user, not root (needs your Plasma session)"
}

need_session() {
  command -v kwriteconfig6 >/dev/null 2>&1 || die "kwriteconfig6 not found (install plasma-workspace?)"
  command -v kreadconfig6 >/dev/null 2>&1 || die "kreadconfig6 not found"
  [[ "${XDG_CURRENT_DESKTOP:-}" == *KDE* || "${XDG_SESSION_DESKTOP:-}" == *plasma* ]] \
    || echo "warning: desktop is ${XDG_CURRENT_DESKTOP:-unknown}; expected KDE/Plasma" >&2
}

qdbus_kwin() {
  qdbus6 org.kde.KWin "$@"
}

script_loaded() {
  [[ "$(qdbus_kwin /Scripting org.kde.kwin.Scripting.isScriptLoaded "${KWIN_SCRIPT_ID}" 2>/dev/null || true)" == "true" ]]
}

install_center_script() {
  [[ -f "${KWIN_SCRIPT_SRC}/contents/code/main.js" ]] || die "missing ${KWIN_SCRIPT_SRC}"
  mkdir -p "${KWIN_SCRIPT_DST}"
  cp -a "${KWIN_SCRIPT_SRC}/." "${KWIN_SCRIPT_DST}/"

  kwriteconfig6 --file kwinrc --group Plugins --key "${KWIN_SCRIPT_ID}Enabled" true

  qdbus_kwin /Scripting org.kde.kwin.Scripting.unloadScript "${KWIN_SCRIPT_ID}" >/dev/null 2>&1 || true
  qdbus_kwin /KWin reconfigure >/dev/null 2>&1 || true

  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if script_loaded; then
      return 0
    fi
    sleep 0.15
  done

  qdbus_kwin /Scripting org.kde.kwin.Scripting.loadScript \
    "${KWIN_SCRIPT_DST}/contents/code/main.js" "${KWIN_SCRIPT_ID}" >/dev/null
  qdbus_kwin /Scripting org.kde.kwin.Scripting.start >/dev/null 2>&1 || true

  script_loaded || die "KWin did not load ${KWIN_SCRIPT_ID}"
}

remove_center_script() {
  qdbus_kwin /Scripting org.kde.kwin.Scripting.unloadScript "${KWIN_SCRIPT_ID}" >/dev/null 2>&1 || true
  kwriteconfig6 --file kwinrc --group Plugins --key "${KWIN_SCRIPT_ID}Enabled" --delete 2>/dev/null || true
  rm -rf "${KWIN_SCRIPT_DST}"
  qdbus_kwin /KWin reconfigure >/dev/null 2>&1 || true
}

python_shortcuts() {
  python3 - "$@" <<'PY'
import sys, subprocess

try:
    from PyQt6.QtGui import QKeySequence
except ImportError:
    sys.exit("error: PyQt6 is required to encode KWin shortcuts")

try:
    from gi.repository import Gio, GLib
except ImportError:
    sys.exit("error: python3-gi is required to talk to kglobalaccel")

# current, default, friendly — current may contain literal \t between shortcuts
# Unbind first so Ctrl+Alt+F / Enter are free for maximize and the center script.
ACTIONS = [
    (
        "Window Move Center",
        "",
        "",
        "Move Window to the Center",
    ),
    (
        "Window Fullscreen",
        "",
        "",
        "Make Window Fullscreen",
    ),
    (
        "Window Quick Tile Left",
        r"Ctrl+Alt+Left\tMeta+Left",
        "Meta+Left",
        "Quick Tile Window to the Left",
    ),
    (
        "Window Quick Tile Right",
        r"Ctrl+Alt+Right\tMeta+Right",
        "Meta+Right",
        "Quick Tile Window to the Right",
    ),
    (
        "Window Quick Tile Top",
        r"Ctrl+Alt+Up\tMeta+Up",
        "Meta+Up",
        "Quick Tile Window to the Top",
    ),
    (
        "Window Quick Tile Bottom",
        r"Ctrl+Alt+Down\tMeta+Down",
        "Meta+Down",
        "Quick Tile Window to the Bottom",
    ),
    (
        "Window Maximize",
        r"Ctrl+Alt+F\tMeta+PgUp",
        "Meta+PgUp",
        "Maximize Window",
    ),
]

KEYS = [a[0] for a in ACTIONS]


def kread(key: str) -> str:
    r = subprocess.run(
        ["kreadconfig6", "--file", "kglobalshortcutsrc", "--group", "kwin", "--key", key],
        check=True,
        capture_output=True,
        text=True,
    )
    return r.stdout.rstrip("\n")


def kwrite(key: str, value: str) -> None:
    cmd = [
        "kwriteconfig6",
        "--file",
        "kglobalshortcutsrc",
        "--group",
        "kwin",
        "--key",
        key,
        "--notify",
        value,
    ]
    subprocess.run(cmd, check=True)


def kdelete(key: str) -> None:
    subprocess.run(
        [
            "kwriteconfig6",
            "--file",
            "kglobalshortcutsrc",
            "--group",
            "kwin",
            "--key",
            key,
            "--delete",
            "--notify",
        ],
        check=False,
    )


def sequences_from_current(current: str) -> list[list[int]]:
    parts = current.split("\\t") if "\\t" in current else current.split("\t")
    out: list[list[int]] = []
    for part in parts:
        part = part.strip()
        if not part:
            continue
        seq = QKeySequence(part)
        if seq.count() == 0:
            sys.exit(f"error: could not parse shortcut {part!r}")
        codes = [seq[i].toCombined() if i < seq.count() else 0 for i in range(4)]
        out.append(codes)
    if not out:
        out = [[0, 0, 0, 0]]
    return out


def set_live(action: str, current: str, friendly: str) -> None:
    keys_py = [(codes,) for codes in sequences_from_current(current)]
    bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    params = GLib.Variant(
        "(asa(ai)u)",
        (
            ["kwin", action, "KWin", friendly],
            keys_py,
            4,  # NoAutoloading — apply now, do not reread kdeglobals
        ),
    )
    bus.call_sync(
        "org.kde.kglobalaccel",
        "/kglobalaccel",
        "org.kde.KGlobalAccel",
        "setShortcutKeys",
        params,
        GLib.VariantType("(a(ai))"),
        Gio.DBusCallFlags.NONE,
        5000,
        None,
    )


def live_strings(action: str, friendly: str) -> str:
    bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    reply = bus.call_sync(
        "org.kde.kglobalaccel",
        "/kglobalaccel",
        "org.kde.KGlobalAccel",
        "shortcutKeys",
        GLib.Variant("(as)", (["kwin", action, "KWin", friendly],)),
        GLib.VariantType("(a(ai))"),
        Gio.DBusCallFlags.NONE,
        5000,
        None,
    )
    seqs = reply.unpack()[0]
    names = []
    for seq in seqs:
        ints = seq[0] if seq and isinstance(seq[0], (list, tuple)) else seq
        codes = [c for c in ints if c]
        if not codes:
            continue
        names.append(QKeySequence(codes[0]).toString())
    return ", ".join(names) if names else "(none)"


def cmd_dump_prev() -> None:
    for key in KEYS:
        print(f"{key}\t{kread(key)}")


def cmd_apply() -> None:
    for action, current, default, friendly in ACTIONS:
        kwrite(action, f"{current},{default},{friendly}")
        set_live(action, current, friendly)


def cmd_restore() -> None:
    for line in sys.stdin:
        line = line.rstrip("\n")
        if not line or line.startswith("#") or "\t" not in line:
            continue
        action, value = line.split("\t", 1)
        kwrite(action, value)
        current, _sep, rest = value.partition(",")
        default, _sep, friendly = rest.partition(",")
        set_live(action, current, friendly)


def cmd_delete_script_shortcuts() -> None:
    for action, friendly in (
        ("muratCenter75", "Resize window to 75% and center"),
        ("muratCenter75Keypad", "Resize window to 75% and center (keypad Enter)"),
    ):
        try:
            set_live(action, "", friendly)
        except Exception:
            pass
        kdelete(action)


def cmd_status() -> None:
    for action, current, default, friendly in ACTIONS:
        file_val = kread(action).replace("\t", r"\t")
        live = live_strings(action, friendly)
        print(f"{action}")
        print(f"  file: {file_val}")
        print(f"  live: {live}")
    for action, friendly in (
        ("muratCenter75", "Resize window to 75% and center"),
        ("muratCenter75Keypad", "Resize window to 75% and center (keypad Enter)"),
    ):
        file_val = kread(action).replace("\t", r"\t")
        try:
            live = live_strings(action, friendly)
        except Exception:
            live = "(unavailable)"
        print(f"{action}")
        print(f"  file: {file_val or '(none)'}")
        print(f"  live: {live}")


cmd = sys.argv[1]
{
    "dump-prev": cmd_dump_prev,
    "apply": cmd_apply,
    "restore": cmd_restore,
    "delete-script-shortcuts": cmd_delete_script_shortcuts,
    "status": cmd_status,
}[cmd]()
PY
}

ensure_state() {
  mkdir -p "${STATE_DIR}"
  if [[ ! -f "${STATE_FILE}" ]]; then
    echo "${MARKER}" > "${STATE_FILE}"
  fi
  local line key
  while IFS= read -r line; do
    key="${line%%$'\t'*}"
    [[ -n "${key}" ]] || continue
    if ! grep -q "^${key}"$'\t' "${STATE_FILE}"; then
      printf '%s\n' "${line}" >> "${STATE_FILE}"
    fi
  done < <(python_shortcuts dump-prev)
}

cmd_apply() {
  need_user
  need_session
  ensure_state
  python_shortcuts apply
  install_center_script
  echo "Bound:"
  echo "  Ctrl+Alt+Left/Right/Up/Down  tile to that half"
  echo "  Ctrl+Alt+Enter               75% size, centered"
  echo "  Ctrl+Alt+F                   maximize"
  echo "Undo with: ${SCRIPT_DIR}/window-tiles.sh revert"
}

cmd_revert() {
  need_user
  need_session
  python_shortcuts delete-script-shortcuts
  remove_center_script
  if [[ ! -f "${STATE_FILE}" ]]; then
    echo "No saved shortcuts; restoring KWin defaults for these actions."
    python_shortcuts restore <<'EOF'
Window Quick Tile Left	Meta+Left,Meta+Left,Quick Tile Window to the Left
Window Quick Tile Right	Meta+Right,Meta+Right,Quick Tile Window to the Right
Window Quick Tile Top	Meta+Up,Meta+Up,Quick Tile Window to the Top
Window Quick Tile Bottom	Meta+Down,Meta+Down,Quick Tile Window to the Bottom
Window Maximize	Meta+PgUp,Meta+PgUp,Maximize Window
Window Move Center	,,Move Window to the Center
Window Fullscreen	,,Make Window Fullscreen
EOF
  else
    python_shortcuts restore < "${STATE_FILE}"
    rm -f "${STATE_FILE}"
  fi
  echo "Restored previous KWin tile / center / maximize shortcuts."
}

cmd_status() {
  need_user
  need_session
  echo "Session: ${XDG_SESSION_TYPE:-unknown}  Desktop: ${XDG_CURRENT_DESKTOP:-unknown}"
  if [[ -f "${STATE_FILE}" ]]; then
    echo "state: ${STATE_FILE} (applied)"
  else
    echo "state: not applied by this script"
  fi
  echo "center script: $(script_loaded && echo loaded || echo not loaded)  (${KWIN_SCRIPT_DST})"
  python_shortcuts status
}

main() {
  local cmd="${1:-}"
  shift || true
  case "${cmd}" in
    apply) cmd_apply "$@" ;;
    revert|undo|remove) cmd_revert "$@" ;;
    status) cmd_status "$@" ;;
    -h|--help|help|"") usage ;;
    *) usage >&2; die "unknown command: ${cmd}" ;;
  esac
}

main "$@"
