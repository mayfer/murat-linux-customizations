#!/usr/bin/env bash
# Apply or undo 3-finger swipe back/forward on Kubuntu (Plasma 6 / Wayland).
#
#   ./three-finger-nav.sh apply     # install InputActions + enable the map
#   ./three-finger-nav.sh revert    # remove the map and plugin
#   ./three-finger-nav.sh status
#   ./three-finger-nav.sh rebuild   # after a Plasma/KWin upgrade
#   ./three-finger-nav.sh reload    # after editing three-finger-nav/config.yaml

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_SRC="${SCRIPT_DIR}/three-finger-nav/config.yaml"
CONF_DST="${HOME}/.config/inputactions/config.yaml"
STATE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/kubuntu-murat-setup"
STATE_FILE="${STATE_DIR}/three-finger-nav.state"
INSTALLER_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/inputactions-installer"
INSTALLER_URL="https://raw.githubusercontent.com/taj-ny/InputActions/refs/heads/main/install.sh"
MARKER="# managed by kubuntu-murat-setup three-finger-nav.sh"
EFFECT="kwin_gestures"

PLUGIN_SO="/usr/lib/x86_64-linux-gnu/qt6/plugins/kwin/effects/plugins/kwin_gestures.so"
PLUGIN_KCM="/usr/lib/x86_64-linux-gnu/qt6/plugins/kwin/effects/configs/inputactions_kwin_kcm.so"
PLUGIN_BIN="/usr/bin/inputactions"

# Build-only packages. Do not list kwin-wayland / git here — we must not purge those.
DEPS=(
  cmake
  extra-cmake-modules
  g++
  gettext
  kwin-dev
  libcli11-dev
  libdrm-dev
  libevdev-dev
  libkf6configwidgets-dev
  libkf6kcmutils-dev
  libxkbcommon-dev
  libyaml-cpp-dev
  pkg-config
  qt6-declarative-dev
  qt6-tools-dev
)

usage() {
  cat <<'EOF'
Usage: three-finger-nav.sh <apply|revert|status|rebuild|reload>

  apply     Install InputActions (KWin plugin) and map:
              3-finger swipe left  → Back  (Alt+Left)
              3-finger swipe right → Forward (Alt+Right)
  revert    Disable the effect, remove our config and the plugin.
  status    Show whether the map is active.
  rebuild   Rebuild/reinstall the plugin (needed after a Plasma upgrade).
  reload    Re-copy config.yaml from this repo and reload InputActions.

  revert --purge   Also remove the InputActions build tree and the
                   -dev packages this script installed.

Plasma has no built-in remap for 3-finger swipe. This installs InputActions
to override it. After a Plasma/KWin update, run: ./three-finger-nav.sh rebuild
EOF
}

die() { echo "error: $*" >&2; exit 1; }

need_user() {
  [[ ${EUID} -ne 0 ]] || die "run this as your user, not root (needs your KWin session)"
}

as_root() {
  if [[ ${EUID} -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

load_state() {
  DEPS_INSTALLED_BY_US=()
  PLUGIN_INSTALLED_BY_US=0
  if [[ -f "${STATE_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${STATE_FILE}"
  fi
}

save_state() {
  mkdir -p "${STATE_DIR}"
  {
    echo "# ${MARKER}"
    echo "PLUGIN_INSTALLED_BY_US=${PLUGIN_INSTALLED_BY_US}"
    if ((${#DEPS_INSTALLED_BY_US[@]})); then
      printf 'DEPS_INSTALLED_BY_US=(%s)\n' "${DEPS_INSTALLED_BY_US[*]}"
    else
      echo 'DEPS_INSTALLED_BY_US=()'
    fi
  } > "${STATE_FILE}"
}

qdbus_bin() {
  if command -v qdbus6 >/dev/null 2>&1; then
    command -v qdbus6
  elif command -v qdbus >/dev/null 2>&1; then
    command -v qdbus
  else
    die "qdbus6 not found"
  fi
}

effect_loaded() {
  local q
  q="$(qdbus_bin)"
  [[ "$("${q}" org.kde.KWin /Effects org.kde.kwin.Effects.isEffectLoaded "${EFFECT}" 2>/dev/null || true)" == "true" ]]
}

load_effect() {
  local q
  q="$(qdbus_bin)"
  "${q}" org.kde.KWin /Effects org.kde.kwin.Effects.loadEffect "${EFFECT}" >/dev/null
  effect_loaded || die "KWin did not load ${EFFECT}. Log out and back in, then run: $0 status"
}

unload_effect() {
  local q
  q="$(qdbus_bin)"
  "${q}" org.kde.KWin /Effects org.kde.kwin.Effects.unloadEffect "${EFFECT}" >/dev/null 2>&1 || true
}

enable_kwinrc() {
  kwriteconfig6 --file kwinrc --group Plugins --key kwin_gesturesEnabled true
}

disable_kwinrc() {
  kwriteconfig6 --file kwinrc --group Plugins --key kwin_gesturesEnabled --delete
}

plugin_installed() {
  [[ -f "${PLUGIN_SO}" && -x "${PLUGIN_BIN}" ]]
}

pkg_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'
}

install_deps() {
  local missing=() p
  for p in "${DEPS[@]}"; do
    pkg_installed "${p}" || missing+=("${p}")
  done
  ((${#missing[@]})) || return 0
  echo "Installing build packages: ${missing[*]}"
  as_root apt-get install -y "${missing[@]}"
  DEPS_INSTALLED_BY_US+=("${missing[@]}")
}

install_plugin() {
  local installer="${INSTALLER_DIR}/inputactions-installer.sh"
  mkdir -p "${INSTALLER_DIR}"
  echo "Building InputActions (this takes a minute)…"
  curl -fsSL -o "${installer}" "${INSTALLER_URL}"
  chmod +x "${installer}"
  bash "${installer}" --ctl --kwin --latest
  plugin_installed || die "plugin install finished but ${PLUGIN_SO} is missing"
  PLUGIN_INSTALLED_BY_US=1
}

install_config() {
  mkdir -p "$(dirname "${CONF_DST}")"
  if [[ -f "${CONF_DST}" ]] && ! grep -qxF "${MARKER}" "${CONF_DST}"; then
    local bak="${CONF_DST}.bak.$(date +%Y%m%d%H%M%S)"
    echo "Existing config is not ours; backing up to ${bak}"
    cp -a "${CONF_DST}" "${bak}"
  fi
  cp "${CONF_SRC}" "${CONF_DST}"
  if command -v inputactions >/dev/null 2>&1; then
    inputactions config reload >/dev/null || true
  fi
}

remove_config() {
  if [[ -f "${CONF_DST}" ]] && grep -qxF "${MARKER}" "${CONF_DST}"; then
    rm -f "${CONF_DST}"
    rmdir "${HOME}/.config/inputactions" 2>/dev/null || true
  elif [[ -f "${CONF_DST}" ]]; then
    echo "Leaving ${CONF_DST} (not managed by this script)"
  fi
}

remove_plugin() {
  as_root rm -f "${PLUGIN_BIN}" "${PLUGIN_SO}" "${PLUGIN_KCM}"
}

cmd_apply() {
  need_user
  [[ -f "${CONF_SRC}" ]] || die "missing ${CONF_SRC}"
  load_state
  install_deps
  if ! plugin_installed; then
    install_plugin
  fi
  save_state
  install_config
  enable_kwinrc
  load_effect
  echo "3-finger swipe left = Back, right = Forward."
}

cmd_rebuild() {
  need_user
  load_state
  install_deps
  unload_effect
  install_plugin
  save_state
  install_config
  enable_kwinrc
  load_effect
  echo "Plugin rebuilt."
}

cmd_reload() {
  need_user
  [[ -f "${CONF_SRC}" ]] || die "missing ${CONF_SRC}"
  plugin_installed || die "plugin not installed; run: $0 apply"
  install_config
  echo "Config reloaded."
}

cmd_revert() {
  need_user
  local purge=0
  if [[ "${1:-}" == "--purge" ]]; then
    purge=1
  elif [[ -n "${1:-}" ]]; then
    die "unknown option: $1"
  fi
  load_state
  unload_effect
  disable_kwinrc
  remove_config
  if plugin_installed; then
    remove_plugin
  fi
  if ((purge)); then
    rm -rf "${INSTALLER_DIR}"
    if ((${#DEPS_INSTALLED_BY_US[@]})); then
      echo "Removing packages this script installed: ${DEPS_INSTALLED_BY_US[*]}"
      as_root apt-get remove -y "${DEPS_INSTALLED_BY_US[@]}"
      as_root apt-get autoremove -y
    fi
    rm -f "${STATE_FILE}"
  else
    PLUGIN_INSTALLED_BY_US=0
    save_state
  fi
  echo "3-finger back/forward removed. Plasma 3-finger swipe is stock again."
}

cmd_status() {
  need_user
  load_state
  echo "plugin files:  $(plugin_installed && echo installed || echo missing)"
  echo "kwin effect:   $(effect_loaded && echo loaded || echo not loaded)"
  echo "kwinrc:        $(kreadconfig6 --file kwinrc --group Plugins --key kwin_gesturesEnabled || true)"
  if [[ -f "${CONF_DST}" ]]; then
    if grep -qxF "${MARKER}" "${CONF_DST}"; then
      echo "config:        ${CONF_DST} (ours)"
    else
      echo "config:        ${CONF_DST} (not managed by this script)"
    fi
  else
    echo "config:        missing"
  fi
}

case "${1:-}" in
  apply) cmd_apply ;;
  revert) cmd_revert "${2:-}" ;;
  status) cmd_status ;;
  rebuild) cmd_rebuild ;;
  reload) cmd_reload ;;
  -h|--help|help|"") usage ;;
  *) usage >&2; exit 1 ;;
esac
