#!/usr/bin/env bash
# Apply or undo macOS-like modifier behaviour for an Apple Magic Keyboard
# on Kubuntu (Plasma 6 / Wayland).
#
#   ./macos-keyboard.sh apply    # install keyd + enable mappings
#   ./macos-keyboard.sh revert   # remove mappings (keyboard back to stock)
#   ./macos-keyboard.sh status
#   ./macos-keyboard.sh reload   # after editing the keyd config
#
# Panic (if a bad mapping bricks input): hold Backspace+Escape+Enter.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_SRC="${SCRIPT_DIR}/macos-keyboard/keyd/macos-magic-keyboard.conf"
HID_SRC="${SCRIPT_DIR}/macos-keyboard/modprobe.d/hid-apple.conf"
APP_SRC="${SCRIPT_DIR}/macos-keyboard/keyd/app.conf"
UNIT_SRC="${SCRIPT_DIR}/macos-keyboard/systemd/macos-keyboard-app-mapper.service"
CONF_DST="/etc/keyd/macos-magic-keyboard.conf"
HID_DST="/etc/modprobe.d/macos-magic-keyboard-hid-apple.conf"
STATE_DIR="/var/lib/kubuntu-murat-setup"
STATE_FILE="${STATE_DIR}/macos-keyboard.state"
MARKER="# managed by kubuntu-murat-setup macos-keyboard.sh"
MAPPER_UNIT="macos-keyboard-app-mapper.service"

usage() {
  cat <<'EOF'
Usage: macos-keyboard.sh <apply|revert|status|reload>

  apply    Install keyd from Ubuntu, install the Magic Keyboard map,
           set Apple Fn keys to macOS behaviour, and enable at boot.
  revert   Remove this map and Fn-key tweak. Leaves the keyd package
           installed unless you pass --purge.
  status   Show whether the map is active.
  reload   Re-copy the config from this repo and reload keyd.

  revert --purge   Also apt-remove keyd (only if this script installed it).

What you get (Apple Magic Keyboard):
  Cmd+C/V/X/A/S/Z/F/T/W     copy/paste/cut/select-all/save/undo/find/tab/close
  Cmd+arrows                start/end of line (up/down: start/end of document)
  Option+arrows             word jump
  Cmd+Backspace             delete to start of line
  Option+Backspace          delete previous word
  Cmd+Delete                delete to end of line (Fn+Backspace is Delete)
  Option+Delete             delete next word
  Cmd+Tab / Cmd+`           app switcher / windows of this app
  Cmd+Space                 KRunner (Spotlight analogue)
  Cmd+Q                     close window
  Cmd+T in Konsole          new tab (via keyd app mapper → Ctrl+Shift+T)
  physical Ctrl+C           still SIGINT in a terminal

Cmd+C/V use Ctrl+Insert / Shift+Insert so terminals do not get Ctrl+C.

If a mapping bricks the keyboard: hold Backspace + Escape + Enter.
EOF
}

die() { echo "error: $*" >&2; exit 1; }

need_root() {
  if [[ ${EUID} -ne 0 ]]; then
    exec sudo --preserve-env=SUDO_USER -- "$0" "$@"
  fi
}

keyd_bin() {
  if command -v keyd.rvaiya >/dev/null 2>&1; then
    command -v keyd.rvaiya
  elif command -v keyd >/dev/null 2>&1; then
    command -v keyd
  else
    return 1
  fi
}

load_state() {
  KEYD_INSTALLED_BY_US=0
  MAPPER_INSTALLED_BY_US=0
  HID_FNMODE_PREV=""
  HID_SWAP_OPT_PREV=""
  HID_SWAP_CTRL_PREV=""
  if [[ -f "${STATE_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${STATE_FILE}"
  fi
}

save_state() {
  mkdir -p "${STATE_DIR}"
  cat > "${STATE_FILE}" <<EOF
# ${MARKER}
KEYD_INSTALLED_BY_US=${KEYD_INSTALLED_BY_US}
MAPPER_INSTALLED_BY_US=${MAPPER_INSTALLED_BY_US}
HID_FNMODE_PREV=${HID_FNMODE_PREV}
HID_SWAP_OPT_PREV=${HID_SWAP_OPT_PREV}
HID_SWAP_CTRL_PREV=${HID_SWAP_CTRL_PREV}
EOF
}

read_sysfs() {
  local path="$1"
  if [[ -r "${path}" ]]; then
    cat "${path}"
  fi
}

write_sysfs() {
  local path="$1" value="$2"
  if [[ -n "${value}" && -w "${path}" ]]; then
    printf '%s\n' "${value}" > "${path}"
  fi
}

detect_apple_keyboards() {
  command -v lsusb >/dev/null 2>&1 || return 0
  lsusb | grep -i apple | grep -i keyboard | grep -ivE 'trackpad|mouse' \
    | sed -n 's/.*ID \([0-9a-fA-F]*:[0-9a-fA-F]*\).*/\1/p' \
    | tr '[:upper:]' '[:lower:]'
}

target_user() {
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    printf '%s\n' "${SUDO_USER}"
  else
    printf '%s\n' "${USER}"
  fi
}

target_home() {
  getent passwd "$(target_user)" | cut -d: -f6
}

target_uid() {
  id -u "$(target_user)"
}

user_systemctl() {
  local user uid
  user="$(target_user)"
  uid="$(target_uid)"
  if systemctl --machine="${user}@.host" --user "$@"; then
    return 0
  fi
  sudo -u "${user}" \
    XDG_RUNTIME_DIR="/run/user/${uid}" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" \
    systemctl --user "$@"
}

cleanup_broken_konsole_overlay() {
  local home dest
  home="$(target_home)"
  for dest in \
    "${home}/.local/share/kxmlgui5/konsole/konsoleui.rc" \
    "${home}/.local/share/kxmlgui6/konsole/konsoleui.rc"
  do
    if [[ -f "${dest}" ]] && grep -q 'kubuntu-murat-setup macos-keyboard' "${dest}" 2>/dev/null; then
      rm -f "${dest}"
      echo "Removed broken Konsole overlay ${dest}"
    fi
  done
}

install_app_mapper() {
  local user home uid
  user="$(target_user)"
  home="$(target_home)"
  uid="$(target_uid)"

  if ! dpkg -s keyd-application-mapper >/dev/null 2>&1; then
    echo "Installing keyd-application-mapper…"
    DEBIAN_FRONTEND=noninteractive apt-get install -y keyd-application-mapper python3-dbus python3-gi
    MAPPER_INSTALLED_BY_US=1
  fi

  usermod -aG keyd "${user}"
  echo "Added ${user} to group keyd (needed to talk to keyd)."

  mkdir -p "${home}/.config/keyd" "${home}/.config/systemd/user"
  install -m 0644 "${APP_SRC}" "${home}/.config/keyd/app.conf"
  install -m 0644 "${UNIT_SRC}" "${home}/.config/systemd/user/${MAPPER_UNIT}"
  chown -R "${user}:${user}" "${home}/.config/keyd" "${home}/.config/systemd/user/${MAPPER_UNIT}"

  user_systemctl daemon-reload
  user_systemctl enable "${MAPPER_UNIT}"
  user_systemctl restart "${MAPPER_UNIT}" || true

  if user_systemctl is-active --quiet "${MAPPER_UNIT}"; then
    echo "Terminal app mapper is running (Cmd+T in Konsole → new tab)."
  else
    echo "Warning: could not start ${MAPPER_UNIT}."
    echo "After this, log out and back in (or reboot), then:"
    echo "  systemctl --user enable --now ${MAPPER_UNIT}"
  fi
}

remove_app_mapper() {
  local home
  home="$(target_home)"
  user_systemctl disable --now "${MAPPER_UNIT}" 2>/dev/null || true
  rm -f "${home}/.config/systemd/user/${MAPPER_UNIT}"
  if [[ -f "${home}/.config/keyd/app.conf" ]] && grep -q 'keyd-application-mapper' "${home}/.config/keyd/app.conf" 2>/dev/null; then
    rm -f "${home}/.config/keyd/app.conf"
  fi
  if [[ "${MAPPER_INSTALLED_BY_US}" -eq 1 ]]; then
    apt-get remove -y keyd-application-mapper || true
  fi
}

cmd_apply() {
  need_root apply "$@"
  [[ -f "${CONF_SRC}" ]] || die "missing ${CONF_SRC}"
  [[ -f "${HID_SRC}" ]] || die "missing ${HID_SRC}"
  [[ -f "${APP_SRC}" ]] || die "missing ${APP_SRC}"
  [[ -f "${UNIT_SRC}" ]] || die "missing ${UNIT_SRC}"

  load_state
  cleanup_broken_konsole_overlay

  if ! dpkg -s keyd >/dev/null 2>&1; then
    echo "Installing keyd (Ubuntu universe)…"
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y keyd
    KEYD_INSTALLED_BY_US=1
  fi

  local bin
  bin="$(keyd_bin)" || die "keyd binary not found after install (expected keyd.rvaiya on Ubuntu)"

  mkdir -p /etc/keyd
  install -m 0644 "${CONF_SRC}" "${CONF_DST}"

  local extra_id
  extra_id="$(detect_apple_keyboards || true)"
  if [[ -n "${extra_id}" ]]; then
    while read -r id; do
      [[ -z "${id}" ]] && continue
      if ! grep -qE "^k:${id}$|^${id}$" "${CONF_DST}"; then
        echo "Adding detected Apple keyboard id ${id} to keyd config"
        printf '\n# detected at apply time\nk:%s\n%s\n' "${id}" "${id}" >> "${CONF_DST}"
      fi
    done <<< "${extra_id}"
  fi

  if [[ -r /sys/module/hid_apple/parameters/fnmode ]]; then
    HID_FNMODE_PREV="$(read_sysfs /sys/module/hid_apple/parameters/fnmode)"
    HID_SWAP_OPT_PREV="$(read_sysfs /sys/module/hid_apple/parameters/swap_opt_cmd)"
    HID_SWAP_CTRL_PREV="$(read_sysfs /sys/module/hid_apple/parameters/swap_ctrl_cmd)"
    write_sysfs /sys/module/hid_apple/parameters/fnmode 1
    write_sysfs /sys/module/hid_apple/parameters/swap_opt_cmd 0
    write_sysfs /sys/module/hid_apple/parameters/swap_ctrl_cmd 0
  fi
  install -m 0644 "${HID_SRC}" "${HID_DST}"

  systemctl enable keyd.service
  if systemctl is-active --quiet keyd.service; then
    "${bin}" reload
  else
    systemctl start keyd.service
  fi

  install_app_mapper
  save_state

  echo
  echo "Applied. Magic Keyboard Command/Option should now behave like macOS."
  echo "Konsole: Cmd+T new tab, Cmd+W close tab, Cmd+N new window."
  echo "Undo with: ${SCRIPT_DIR}/macos-keyboard.sh revert"
  echo "Panic combo if input breaks: Backspace+Escape+Enter"
}

cmd_revert() {
  local purge=0
  if [[ "${1:-}" == "--purge" ]]; then
    purge=1
  fi
  need_root revert "$@"
  load_state
  cleanup_broken_konsole_overlay
  remove_app_mapper

  if [[ -f "${CONF_DST}" ]]; then
    rm -f "${CONF_DST}"
    echo "Removed ${CONF_DST}"
  fi

  if [[ -f "${HID_DST}" ]]; then
    rm -f "${HID_DST}"
    echo "Removed ${HID_DST}"
  fi

  write_sysfs /sys/module/hid_apple/parameters/fnmode "${HID_FNMODE_PREV}"
  write_sysfs /sys/module/hid_apple/parameters/swap_opt_cmd "${HID_SWAP_OPT_PREV}"
  write_sysfs /sys/module/hid_apple/parameters/swap_ctrl_cmd "${HID_SWAP_CTRL_PREV}"

  local other_confs=0
  if [[ -d /etc/keyd ]]; then
    other_confs="$(find /etc/keyd -maxdepth 1 -type f -name '*.conf' | wc -l)"
  fi

  if command -v keyd.rvaiya >/dev/null 2>&1 || command -v keyd >/dev/null 2>&1; then
    local bin
    bin="$(keyd_bin || true)"
    if [[ "${other_confs}" -eq 0 ]]; then
      systemctl disable --now keyd.service 2>/dev/null || true
      echo "Stopped keyd (no remaining configs)."
    elif [[ -n "${bin}" ]]; then
      "${bin}" reload || systemctl restart keyd.service
      echo "Reloaded keyd; other configs were left in place."
    fi
  fi

  if [[ "${purge}" -eq 1 ]]; then
    if [[ "${KEYD_INSTALLED_BY_US}" -eq 1 ]]; then
      apt-get remove -y keyd
      echo "Removed the keyd package."
    else
      echo "Not purging keyd: it was already installed before apply."
    fi
  fi

  rm -f "${STATE_FILE}"
  echo "Reverted. Keyboard modifiers are back to stock Linux behaviour."
}

cmd_status() {
  echo "Session: ${XDG_SESSION_TYPE:-unknown}  Desktop: ${XDG_CURRENT_DESKTOP:-unknown}"
  echo "keyd package: $(dpkg -s keyd 2>/dev/null | awk -F': ' '/Version/{print $2; exit}' || echo 'not installed')"
  local bin=""
  bin="$(keyd_bin 2>/dev/null || true)"
  echo "keyd binary: ${bin:-not found}"
  if systemctl list-unit-files keyd.service >/dev/null 2>&1; then
    echo "keyd.service: $(systemctl is-enabled keyd.service 2>/dev/null || echo unknown) / $(systemctl is-active keyd.service 2>/dev/null || echo unknown)"
  fi
  if [[ -f "${CONF_DST}" ]]; then
    echo "map: ${CONF_DST} (present)"
  else
    echo "map: ${CONF_DST} (absent)"
  fi
  if [[ -f "${HID_DST}" ]]; then
    echo "hid_apple: ${HID_DST} (present)"
  else
    echo "hid_apple: ${HID_DST} (absent)"
  fi
  if [[ -r /sys/module/hid_apple/parameters/fnmode ]]; then
    echo "hid_apple fnmode=$(cat /sys/module/hid_apple/parameters/fnmode) swap_opt_cmd=$(cat /sys/module/hid_apple/parameters/swap_opt_cmd)"
  fi
  echo "USB Apple devices:"
  lsusb | grep -i apple || echo "  (none)"
  echo "app mapper unit: $(systemctl --user is-enabled "${MAPPER_UNIT}" 2>/dev/null || echo n/a) / $(systemctl --user is-active "${MAPPER_UNIT}" 2>/dev/null || echo n/a)"
  echo "app.conf: $([ -f "$(target_home)/.config/keyd/app.conf" ] && echo present || echo absent)"
  echo "in keyd group: $(id -nG | grep -qw keyd && echo yes || echo no)"
  if [[ -f "${STATE_FILE}" ]]; then
    echo "state: ${STATE_FILE}"
    cat "${STATE_FILE}"
  else
    echo "state: not applied by this script (or unreadable without root)"
  fi
}

cmd_reload() {
  need_root reload
  [[ -f "${CONF_SRC}" ]] || die "missing ${CONF_SRC}"
  [[ -f "${CONF_DST}" ]] || die "map is not applied; run: $0 apply"
  cleanup_broken_konsole_overlay
  install -m 0644 "${CONF_SRC}" "${CONF_DST}"
  local bin
  bin="$(keyd_bin)" || die "keyd binary not found"
  "${bin}" reload
  local home
  home="$(target_home)"
  if [[ -f "${APP_SRC}" ]]; then
    mkdir -p "${home}/.config/keyd"
    install -m 0644 "${APP_SRC}" "${home}/.config/keyd/app.conf"
    chown "$(target_user):$(target_user)" "${home}/.config/keyd/app.conf"
  fi
  user_systemctl restart "${MAPPER_UNIT}" 2>/dev/null || true
  echo "Reloaded ${CONF_DST}"
}

main() {
  local cmd="${1:-}"
  shift || true
  case "${cmd}" in
    apply) cmd_apply "$@" ;;
    revert|undo|remove) cmd_revert "$@" ;;
    status) cmd_status "$@" ;;
    reload) cmd_reload "$@" ;;
    -h|--help|help|"") usage ;;
    *) usage >&2; die "unknown command: ${cmd}" ;;
  esac
}

main "$@"
