#!/usr/bin/env bash
# Build/apply or completely undo compositor-owned Magic Trackpad scrolling.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSET_DIR="${SCRIPT_DIR}/magic-trackpad-scroll"
SOURCE_DIR="${ASSET_DIR}/plugin"
CONFIG_SRC="${ASSET_DIR}/magic-trackpad-scrollrc"
MARKER="# managed by kubuntu-murat-setup magic-trackpad-scroll.sh"

EFFECT="murat_magic_trackpad_scroll"
MULTIARCH="$(dpkg-architecture -qDEB_HOST_MULTIARCH)"
PLUGIN_DST="/usr/lib/${MULTIARCH}/qt6/plugins/kwin/effects/plugins/${EFFECT}.so"
CONFIG_DST="${XDG_CONFIG_HOME:-$HOME/.config}/magic-trackpad-scrollrc"
STATE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/kubuntu-murat-setup"
STATE_FILE="${STATE_DIR}/magic-trackpad-scroll.state"
CONFIG_BACKUP="${STATE_DIR}/magic-trackpad-scrollrc.original"
BUILD_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/kubuntu-murat-setup/magic-trackpad-scroll-build"
BUILD_SO="${BUILD_DIR}/${EFFECT}.so"

MAGIC_VENDOR_DEC=1452
MAGIC_PRODUCT_DEC=613

DEPS=(
  cmake
  extra-cmake-modules
  g++
  kwin-dev
  libkf6config-dev
  ninja-build
  qt6-base-dev
)

usage() {
  cat <<'EOF'
Usage: magic-trackpad-scroll.sh <apply|revert|status|reload|rebuild|logs>

  apply     Build, install, and safely enable the KWin scroll plugin.
  revert    Disable/remove it and restore the exact previous configuration.
  status    Show plugin, KWin, device, configuration, and ABI state.
  reload    Re-copy magic-trackpad-scrollrc and safely reload the effect.
  rebuild   Rebuild/reinstall after source or KWin changes, then safely reload.
  logs      Show this boot's plugin diagnostics and release velocities.

  revert --purge   Also remove the build cache and packages installed by us.

The plugin transforms events inside KWin. It does not read /dev/input, create a
virtual device, run a background service, or change libinput. A failed first
load leaves the persistent KWin setting disabled so KWin can restart safely.
EOF
}

die() { echo "error: $*" >&2; exit 1; }

need_user() {
  [[ ${EUID} -ne 0 ]] || die "run this as your desktop user, not root"
}

as_root() {
  if [[ ${EUID} -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
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

load_state() {
  STATE_VERSION=2
  STATE_CAPTURED=0
  CONFIG_EXISTED=0
  ORIGINAL_EFFECT_KEY_PRESENT=0
  ORIGINAL_EFFECT_VALUE=""
  PLUGIN_INSTALLED_BY_US=0
  PLUGIN_SHA256=""
  BUILT_KWIN_VERSION=""
  DEPS_INSTALLED_BY_US=()

  if [[ -f "${STATE_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${STATE_FILE}"
    [[ "${STATE_VERSION:-}" == 2 ]] || die "legacy state found; run the old script's revert first"
  fi
}

save_state() {
  mkdir -p "${STATE_DIR}"
  {
    echo "${MARKER}"
    printf 'STATE_VERSION=%q\n' "${STATE_VERSION}"
    printf 'STATE_CAPTURED=%q\n' "${STATE_CAPTURED}"
    printf 'CONFIG_EXISTED=%q\n' "${CONFIG_EXISTED}"
    printf 'ORIGINAL_EFFECT_KEY_PRESENT=%q\n' "${ORIGINAL_EFFECT_KEY_PRESENT}"
    printf 'ORIGINAL_EFFECT_VALUE=%q\n' "${ORIGINAL_EFFECT_VALUE}"
    printf 'PLUGIN_INSTALLED_BY_US=%q\n' "${PLUGIN_INSTALLED_BY_US}"
    printf 'PLUGIN_SHA256=%q\n' "${PLUGIN_SHA256}"
    printf 'BUILT_KWIN_VERSION=%q\n' "${BUILT_KWIN_VERSION}"
    printf 'DEPS_INSTALLED_BY_US=('
    if ((${#DEPS_INSTALLED_BY_US[@]})); then
      printf '%q ' "${DEPS_INSTALLED_BY_US[@]}"
    fi
    echo ')'
  } > "${STATE_FILE}"
}

capture_state() {
  [[ "${STATE_CAPTURED}" == 0 ]] || return 0

  if [[ -e "${PLUGIN_DST}" ]]; then
    die "refusing to overwrite unmanaged ${PLUGIN_DST}"
  fi

  if [[ -e "${CONFIG_DST}" ]]; then
    CONFIG_EXISTED=1
    cp -a "${CONFIG_DST}" "${CONFIG_BACKUP}"
  fi

  local original
  original="$(kreadconfig6 --file kwinrc --group Plugins --key "${EFFECT}Enabled" --default __MISSING__)"
  if [[ "${original}" != __MISSING__ ]]; then
    ORIGINAL_EFFECT_KEY_PRESENT=1
    ORIGINAL_EFFECT_VALUE="${original}"
  fi

  STATE_CAPTURED=1
  save_state
}

pkg_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'
}

install_deps() {
  local missing=() package
  for package in "${DEPS[@]}"; do
    pkg_installed "${package}" || missing+=("${package}")
  done
  ((${#missing[@]} == 0)) && return 0

  echo "Installing build packages: ${missing[*]}"
  as_root apt-get install -y "${missing[@]}"
  DEPS_INSTALLED_BY_US+=("${missing[@]}")
  save_state
}

build_plugin() {
  echo "Building the KWin ${EFFECT} plugin…"
  cmake --fresh -S "${SOURCE_DIR}" -B "${BUILD_DIR}" -G Ninja \
    -DBUILD_TESTING=ON -DCMAKE_BUILD_TYPE=RelWithDebInfo
  cmake --build "${BUILD_DIR}" --parallel
  ctest --test-dir "${BUILD_DIR}" --output-on-failure
  [[ -s "${BUILD_SO}" ]] || die "build succeeded but ${BUILD_SO} is missing"
  BUILT_KWIN_VERSION="$(dpkg-query -W -f='${Version}' kwin-dev)"
  save_state
}

managed_config() {
  [[ -f "${CONFIG_DST}" ]] && grep -qxF "${MARKER}" "${CONFIG_DST}"
}

install_config() {
  if [[ -e "${CONFIG_DST}" ]] && ! managed_config && [[ "${CONFIG_EXISTED}" == 0 ]]; then
    die "refusing to overwrite unmanaged ${CONFIG_DST}"
  fi
  install -Dm600 "${CONFIG_SRC}" "${CONFIG_DST}"
}

plugin_matches_state() {
  [[ -f "${PLUGIN_DST}" && -n "${PLUGIN_SHA256}" ]] || return 1
  [[ "$(sha256sum "${PLUGIN_DST}" | awk '{print $1}')" == "${PLUGIN_SHA256}" ]]
}

install_plugin() {
  if [[ -e "${PLUGIN_DST}" ]] && ! plugin_matches_state; then
    die "refusing to overwrite changed or unmanaged ${PLUGIN_DST}"
  fi
  as_root install -Dm755 "${BUILD_SO}" "${PLUGIN_DST}"
  PLUGIN_INSTALLED_BY_US=1
  PLUGIN_SHA256="$(sha256sum "${BUILD_SO}" | awk '{print $1}')"
  save_state
}

effect_loaded() {
  local q
  q="$(qdbus_bin)"
  [[ "$("${q}" org.kde.KWin /Effects org.kde.kwin.Effects.isEffectLoaded "${EFFECT}" 2>/dev/null || true)" == true ]]
}

disable_persistent_effect() {
  kwriteconfig6 --file kwinrc --group Plugins --key "${EFFECT}Enabled" false
}

enable_persistent_effect() {
  kwriteconfig6 --file kwinrc --group Plugins --key "${EFFECT}Enabled" true
}

unload_effect() {
  local q
  q="$(qdbus_bin)"
  "${q}" org.kde.KWin /Effects org.kde.kwin.Effects.unloadEffect "${EFFECT}" >/dev/null 2>&1 || true
}

safe_load_effect() {
  local q result=""
  q="$(qdbus_bin)"

  # This ordering prevents a bad binary from becoming a KWin restart loop.
  disable_persistent_effect
  unload_effect
  result="$("${q}" org.kde.KWin /Effects org.kde.kwin.Effects.loadEffect "${EFFECT}" 2>/dev/null || true)"

  for _ in {1..10}; do
    effect_loaded && break
    sleep 0.2
  done

  if ! effect_loaded; then
    echo "KWin load result: ${result:-no response}" >&2
    die "KWin did not load ${EFFECT}; persistent loading remains safely disabled"
  fi
  enable_persistent_effect
}

restore_effect_key() {
  if [[ "${ORIGINAL_EFFECT_KEY_PRESENT}" == 1 ]]; then
    kwriteconfig6 --file kwinrc --group Plugins --key "${EFFECT}Enabled" "${ORIGINAL_EFFECT_VALUE}"
  else
    kwriteconfig6 --file kwinrc --group Plugins --key "${EFFECT}Enabled" --delete
  fi
}

restore_config() {
  if [[ "${CONFIG_EXISTED}" == 1 && -f "${CONFIG_BACKUP}" ]]; then
    cp -a "${CONFIG_BACKUP}" "${CONFIG_DST}"
  elif managed_config; then
    rm -f -- "${CONFIG_DST}"
  elif [[ -e "${CONFIG_DST}" ]]; then
    echo "Leaving ${CONFIG_DST}; it is no longer managed by this script"
  fi
}

remove_plugin() {
  if plugin_matches_state; then
    as_root rm -f -- "${PLUGIN_DST}"
  elif [[ -e "${PLUGIN_DST}" ]]; then
    echo "Leaving changed ${PLUGIN_DST}; refusing to remove it" >&2
    return 1
  fi
  PLUGIN_INSTALLED_BY_US=0
  PLUGIN_SHA256=""
}

magic_kwin_paths() {
  local path vendor product touchpad
  while IFS= read -r path; do
    [[ "${path}" == /org/kde/KWin/InputDevice/event* ]] || continue
    vendor="$(busctl --user get-property org.kde.KWin "${path}" org.kde.KWin.InputDevice vendor 2>/dev/null | awk '{print $2}')"
    product="$(busctl --user get-property org.kde.KWin "${path}" org.kde.KWin.InputDevice product 2>/dev/null | awk '{print $2}')"
    touchpad="$(busctl --user get-property org.kde.KWin "${path}" org.kde.KWin.InputDevice touchpad 2>/dev/null | awk '{print $2}')"
    if [[ "${vendor}" == "${MAGIC_VENDOR_DEC}" && "${product}" == "${MAGIC_PRODUCT_DEC}" && "${touchpad}" == true ]]; then
      echo "${path}"
    fi
  done < <("$(qdbus_bin)" org.kde.KWin 2>/dev/null || true)
}

apply_setup() {
  trap 'disable_persistent_effect 2>/dev/null || true; echo "Apply failed; the effect was left disabled. Run: ./magic-trackpad-scroll.sh revert" >&2' ERR
  load_state
  capture_state
  install_deps
  build_plugin
  install_config
  install_plugin
  safe_load_effect
  trap - ERR
  echo
  status_setup
}

reload_setup() {
  load_state
  plugin_matches_state || die "managed plugin is not installed; run: $0 apply"
  install_config
  safe_load_effect
  echo "Reloaded ${CONFIG_DST} and ${EFFECT}."
}

rebuild_setup() {
  load_state
  [[ "${STATE_CAPTURED}" == 1 ]] || capture_state
  install_deps
  disable_persistent_effect
  unload_effect
  build_plugin
  install_plugin
  install_config
  safe_load_effect
  echo "Rebuilt for KWin ${BUILT_KWIN_VERSION}."
}

revert_setup() {
  local purge="${1:-}"
  load_state

  disable_persistent_effect
  unload_effect
  remove_plugin
  restore_config
  restore_effect_key

  if [[ "${purge}" == --purge ]]; then
    case "${BUILD_DIR}" in
      "${XDG_CACHE_HOME:-$HOME/.cache}/kubuntu-murat-setup/magic-trackpad-scroll-build")
        rm -rf -- "${BUILD_DIR}"
        ;;
      *) die "refusing to remove unexpected build path: ${BUILD_DIR}" ;;
    esac
    if ((${#DEPS_INSTALLED_BY_US[@]})); then
      echo "Removing build packages installed by this script: ${DEPS_INSTALLED_BY_US[*]}"
      as_root apt-get purge -y "${DEPS_INSTALLED_BY_US[@]}"
    fi
    rm -f -- "${STATE_FILE}" "${CONFIG_BACKUP}"
  else
    save_state
  fi

  echo "Magic Trackpad scrolling restored to its exact previous KWin configuration."
}

status_setup() {
  load_state
  local current_kwin path count=0
  current_kwin="$(dpkg-query -W -f='${Version}' kwin-dev 2>/dev/null || echo missing)"

  echo "plugin file:     $([[ -f "${PLUGIN_DST}" ]] && echo installed || echo missing)"
  echo "plugin checksum: $(plugin_matches_state && echo managed || echo absent-or-changed)"
  echo "KWin effect:     $(effect_loaded && echo loaded || echo not-loaded)"
  echo "startup enabled: $(kreadconfig6 --file kwinrc --group Plugins --key "${EFFECT}Enabled" --default false)"
  echo "configuration:   $(managed_config && echo managed || echo missing-or-unmanaged)"
  echo "built KWin:      ${BUILT_KWIN_VERSION:-not-built}"
  echo "current KWin:    ${current_kwin}"

  while IFS= read -r path; do
    ((++count))
    echo "trackpad:        $(basename "${path}") (1452:613)"
    echo "KWin factor:     $(busctl --user get-property org.kde.KWin "${path}" org.kde.KWin.InputDevice scrollFactor | awk '{print $2}') (unchanged by plugin)"
  done < <(magic_kwin_paths)
  ((count > 0)) || echo "trackpad:        not visible to KWin"

  if plugin_matches_state && effect_loaded && managed_config && [[ "${current_kwin}" == "${BUILT_KWIN_VERSION}" ]]; then
    echo "status:          active"
  else
    echo "status:          inactive or incomplete"
    return 1
  fi
}

logs_setup() {
  journalctl --user -b --no-pager -g 'kwin.effect.murat_magic_trackpad_scroll' || true
}

main() {
  need_user
  case "${1:-}" in
    apply) apply_setup ;;
    revert)
      [[ -z "${2:-}" || "${2:-}" == --purge ]] || die "unknown option: ${2}"
      revert_setup "${2:-}"
      ;;
    status) status_setup ;;
    reload) reload_setup ;;
    rebuild) rebuild_setup ;;
    logs) logs_setup ;;
    -h|--help|help|"") usage ;;
    *) usage >&2; exit 2 ;;
  esac
}

main "$@"
