#!/usr/bin/env bash
# Set vim as the default editor and allow passwordless sudo on Kubuntu.
#
#   ./vim-sudo.sh apply     # install vim, set EDITOR, NOPASSWD sudo
#   ./vim-sudo.sh revert    # undo env/sudoers/alternatives (keeps vim)
#   ./vim-sudo.sh status

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="/var/lib/kubuntu-murat-setup"
STATE_FILE="${STATE_DIR}/vim-sudo.state"
MARKER="# managed by kubuntu-murat-setup vim-sudo.sh"
BLOCK_START="# >>> kubuntu-murat-setup vim-sudo >>>"
BLOCK_END="# <<< kubuntu-murat-setup vim-sudo <<<"
ENV_FILE="/etc/environment"
PLASMA_ENV_REL=".config/plasma-workspace/env/editor.sh"

usage() {
  cat <<'EOF'
Usage: vim-sudo.sh <apply|revert|status>

  apply    Install vim, make it the system/user default editor, and
           allow passwordless sudo for the invoking user.
  revert   Remove our editor env, sudoers drop-in, and alternatives
           pin. Leaves the vim package installed unless you pass --purge.
  status   Show editor + sudo configuration.

  revert --purge   Also apt-remove vim if this script installed it.

What you get:
  vim package (vim.basic) instead of vim-tiny
  /usr/bin/editor → vim.basic
  EDITOR / VISUAL / SUDO_EDITOR=vim  (bash, login, Plasma, /etc/environment)
  git core.editor=vim
  passwordless sudo for this user via /etc/sudoers.d/99-nopasswd-$USER
EOF
}

die() { echo "error: $*" >&2; exit 1; }

need_root() {
  if [[ ${EUID} -ne 0 ]]; then
    exec sudo --preserve-env=SUDO_USER -- "$0" "$@"
  fi
}

target_user() {
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    printf '%s\n' "${SUDO_USER}"
  elif [[ ${EUID} -eq 0 ]]; then
    die "run as your user (or via sudo from your user) so the sudoers rule is not for root"
  else
    printf '%s\n' "${USER}"
  fi
}

target_home() {
  getent passwd "$(target_user)" | cut -d: -f6
}

sudoers_path() {
  printf '/etc/sudoers.d/99-nopasswd-%s\n' "$(target_user)"
}

vim_basic() {
  if [[ -x /usr/bin/vim.basic ]]; then
    printf '%s\n' /usr/bin/vim.basic
  else
    return 1
  fi
}

pkg_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'
}

load_state() {
  VIM_INSTALLED_BY_US=0
  EDITOR_ALT_PREV=""
  EDITOR_ALT_STATUS=""
  GIT_EDITOR_PREV=""
  GIT_EDITOR_HAD=0
  SELECTED_EDITOR_PREV=""
  SELECTED_EDITOR_HAD=0
  if [[ -f "${STATE_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${STATE_FILE}"
  fi
}

save_state() {
  mkdir -p "${STATE_DIR}"
  cat > "${STATE_FILE}" <<EOF
${MARKER}
VIM_INSTALLED_BY_US=${VIM_INSTALLED_BY_US}
EDITOR_ALT_PREV=$(printf '%q' "${EDITOR_ALT_PREV}")
EDITOR_ALT_STATUS=$(printf '%q' "${EDITOR_ALT_STATUS}")
GIT_EDITOR_PREV=$(printf '%q' "${GIT_EDITOR_PREV}")
GIT_EDITOR_HAD=${GIT_EDITOR_HAD}
SELECTED_EDITOR_PREV=$(printf '%q' "${SELECTED_EDITOR_PREV}")
SELECTED_EDITOR_HAD=${SELECTED_EDITOR_HAD}
EOF
}

own_user_file() {
  local file="$1" user
  user="$(target_user)"
  [[ -e "${file}" ]] || return 0
  chown "${user}:${user}" "${file}"
}

alt_query() {
  local name="$1" field="$2"
  update-alternatives --query "${name}" 2>/dev/null \
    | awk -v f="${field}" -F': ' '$1 == f {print $2; exit}'
}

snapshot_editor_alt() {
  # Keep the first snapshot we ever recorded. If vim is already the
  # editor (this machine was configured before the script existed),
  # revert back to auto so Ubuntu's default (nano) returns.
  if [[ -n "${EDITOR_ALT_STATUS}" ]]; then
    return 0
  fi
  local value status bin
  value="$(alt_query editor Value || true)"
  status="$(alt_query editor Status || true)"
  bin="$(vim_basic || true)"
  if [[ -n "${bin}" && "${value}" == "${bin}" ]]; then
    EDITOR_ALT_PREV=""
    EDITOR_ALT_STATUS="auto"
  else
    EDITOR_ALT_PREV="${value}"
    EDITOR_ALT_STATUS="${status}"
  fi
}

ensure_vim() {
  if pkg_installed vim; then
    return 0
  fi
  echo "Installing vim…"
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y vim
  VIM_INSTALLED_BY_US=1
}

ensure_alternatives() {
  local bin
  bin="$(vim_basic)" || die "vim.basic missing after vim install"
  snapshot_editor_alt
  update-alternatives --set editor "${bin}"
  if update-alternatives --query vi >/dev/null 2>&1; then
    update-alternatives --set vi "${bin}" || true
  fi
}

revert_alternatives() {
  if [[ "${EDITOR_ALT_STATUS}" == "auto" ]]; then
    update-alternatives --auto editor || true
  elif [[ -n "${EDITOR_ALT_PREV}" && -e "${EDITOR_ALT_PREV}" ]]; then
    update-alternatives --set editor "${EDITOR_ALT_PREV}" || true
  else
    update-alternatives --auto editor || true
  fi
}

strip_managed_and_bare_exports() {
  awk -v start="${BLOCK_START}" -v end="${BLOCK_END}" '
    $0 == start {skip=1; next}
    $0 == end {skip=0; next}
    skip {next}
    $0 == "export EDITOR=vim" {next}
    $0 == "export VISUAL=vim" {next}
    $0 == "export SUDO_EDITOR=vim" {next}
    {print}
  '
}

trim_trailing_blanks() {
  # drop trailing empty lines so we can append a clean block
  awk '
    { lines[NR] = $0 }
    END {
      end = NR
      while (end > 0 && lines[end] ~ /^[[:space:]]*$/) end--
      for (i = 1; i <= end; i++) print lines[i]
    }
  '
}

upsert_shell_block() {
  local file="$1"
  [[ -f "${file}" ]] || return 0
  local tmp
  tmp="$(mktemp)"
  {
    strip_managed_and_bare_exports < "${file}" | trim_trailing_blanks
    printf '\n%s\nexport EDITOR=vim\nexport VISUAL=vim\nexport SUDO_EDITOR=vim\n%s\n' \
      "${BLOCK_START}" "${BLOCK_END}"
  } > "${tmp}"
  cat "${tmp}" > "${file}"
  rm -f "${tmp}"
  own_user_file "${file}"
}

remove_shell_block() {
  local file="$1"
  [[ -f "${file}" ]] || return 0
  local tmp
  tmp="$(mktemp)"
  strip_managed_and_bare_exports < "${file}" | trim_trailing_blanks > "${tmp}"
  printf '\n' >> "${tmp}"
  cat "${tmp}" > "${file}"
  rm -f "${tmp}"
  own_user_file "${file}"
}

ensure_shell_env() {
  local home
  home="$(target_home)"
  upsert_shell_block "${home}/.bashrc"
  upsert_shell_block "${home}/.profile"
}

revert_shell_env() {
  local home
  home="$(target_home)"
  remove_shell_block "${home}/.bashrc"
  remove_shell_block "${home}/.profile"
}

ensure_plasma_env() {
  local dest
  dest="$(target_home)/${PLASMA_ENV_REL}"
  mkdir -p "$(dirname "${dest}")"
  cat > "${dest}" <<EOF
#!/bin/sh
${MARKER}
export EDITOR=vim
export VISUAL=vim
export SUDO_EDITOR=vim
EOF
  chmod 755 "${dest}"
  own_user_file "${dest}"
  own_user_file "$(dirname "${dest}")"
}

revert_plasma_env() {
  local dest
  dest="$(target_home)/${PLASMA_ENV_REL}"
  if [[ -f "${dest}" ]] && grep -qF "${MARKER}" "${dest}"; then
    rm -f "${dest}"
  elif [[ -f "${dest}" ]] && grep -q 'export EDITOR=vim' "${dest}"; then
    rm -f "${dest}"
  fi
}

ensure_selected_editor() {
  local dest bin
  dest="$(target_home)/.selected_editor"
  bin="$(vim_basic)" || return 0
  if [[ -f "${dest}" && "${SELECTED_EDITOR_HAD}" -eq 0 && -z "${SELECTED_EDITOR_PREV}" ]]; then
    local prev
    prev="$(awk -F= '/^SELECTED_EDITOR=/{print $2}' "${dest}" | tr -d '"' || true)"
    if [[ -n "${prev}" && "${prev}" != "${bin}" ]]; then
      SELECTED_EDITOR_HAD=1
      SELECTED_EDITOR_PREV="${prev}"
    fi
  fi
  cat > "${dest}" <<EOF
${MARKER}
SELECTED_EDITOR="${bin}"
EOF
  own_user_file "${dest}"
}

revert_selected_editor() {
  local dest
  dest="$(target_home)/.selected_editor"
  [[ -f "${dest}" ]] || return 0
  if ! grep -qF "${MARKER}" "${dest}" && ! grep -q 'Generated by Grok' "${dest}"; then
    echo "Leaving ${dest} (not managed by this script)"
    return 0
  fi
  if [[ "${SELECTED_EDITOR_HAD}" -eq 1 && -n "${SELECTED_EDITOR_PREV}" ]]; then
    cat > "${dest}" <<EOF
SELECTED_EDITOR="${SELECTED_EDITOR_PREV}"
EOF
    own_user_file "${dest}"
  else
    rm -f "${dest}"
  fi
}

gitconfig_path() {
  printf '%s/.gitconfig\n' "$(target_home)"
}

ensure_git_editor() {
  local cfg
  cfg="$(gitconfig_path)"
  if [[ -f "${cfg}" && "${GIT_EDITOR_HAD}" -eq 0 && -z "${GIT_EDITOR_PREV}" ]]; then
    local current=""
    current="$(git config --file "${cfg}" --get core.editor 2>/dev/null || true)"
    if [[ -n "${current}" && "${current}" != "vim" ]]; then
      GIT_EDITOR_HAD=1
      GIT_EDITOR_PREV="${current}"
    fi
  fi
  git config --file "${cfg}" core.editor vim
  own_user_file "${cfg}"
}

revert_git_editor() {
  local cfg
  cfg="$(gitconfig_path)"
  [[ -f "${cfg}" ]] || return 0
  local current=""
  current="$(git config --file "${cfg}" --get core.editor 2>/dev/null || true)"
  [[ "${current}" == "vim" ]] || return 0
  if [[ "${GIT_EDITOR_HAD}" -eq 1 && -n "${GIT_EDITOR_PREV}" ]]; then
    git config --file "${cfg}" core.editor "${GIT_EDITOR_PREV}"
  else
    git config --file "${cfg}" --unset core.editor || true
  fi
}

ensure_etc_environment() {
  local tmp
  tmp="$(mktemp)"
  if [[ -f "${ENV_FILE}" ]]; then
    awk -v marker="${MARKER}" '
      $0 == marker {inblock=1; next}
      inblock {
        if ($0 ~ /^(EDITOR|VISUAL|SUDO_EDITOR)=/ || $0 ~ /^[[:space:]]*$/) next
        inblock=0
      }
      $0 ~ /^(EDITOR|VISUAL|SUDO_EDITOR)=vim$/ {next}
      {print}
    ' "${ENV_FILE}" | trim_trailing_blanks > "${tmp}"
  else
    : > "${tmp}"
  fi
  printf '\n%s\nEDITOR=vim\nVISUAL=vim\nSUDO_EDITOR=vim\n' "${MARKER}" >> "${tmp}"
  cat "${tmp}" > "${ENV_FILE}"
  rm -f "${tmp}"
}

revert_etc_environment() {
  [[ -f "${ENV_FILE}" ]] || return 0
  local tmp
  tmp="$(mktemp)"
  awk -v marker="${MARKER}" '
    $0 == marker {inblock=1; next}
    inblock {
      if ($0 ~ /^(EDITOR|VISUAL|SUDO_EDITOR)=/ || $0 ~ /^[[:space:]]*$/) next
      inblock=0
    }
    $0 ~ /^(EDITOR|VISUAL|SUDO_EDITOR)=vim$/ {next}
    {print}
  ' "${ENV_FILE}" | trim_trailing_blanks > "${tmp}"
  printf '\n' >> "${tmp}"
  cat "${tmp}" > "${ENV_FILE}"
  rm -f "${tmp}"
}

ensure_sudoers() {
  local user dest stage
  user="$(target_user)"
  dest="$(sudoers_path)"
  stage="${dest}.tmp"
  cat > "${stage}" <<EOF
${MARKER}
${user} ALL=(ALL:ALL) NOPASSWD:ALL
EOF
  chmod 440 "${stage}"
  visudo -c -f "${stage}" >/dev/null
  mv "${stage}" "${dest}"
  chmod 440 "${dest}"
  visudo -c >/dev/null
}

revert_sudoers() {
  local dest
  dest="$(sudoers_path)"
  if [[ -f "${dest}" ]] && grep -qF "${MARKER}" "${dest}"; then
    rm -f "${dest}"
    visudo -c >/dev/null
  elif [[ -f "${dest}" ]]; then
    echo "Leaving ${dest} (not managed by this script)"
  fi
}

cmd_apply() {
  need_root apply "$@"
  load_state
  ensure_vim
  ensure_alternatives
  ensure_shell_env
  ensure_plasma_env
  ensure_selected_editor
  ensure_git_editor
  ensure_etc_environment
  ensure_sudoers
  save_state
  echo
  echo "Applied. vim is the default editor; $(target_user) has passwordless sudo."
  echo "New terminals pick up EDITOR immediately. Plasma GUI apps need a re-login."
  echo "Undo with: ${SCRIPT_DIR}/vim-sudo.sh revert"
}

cmd_revert() {
  local purge=0
  if [[ "${1:-}" == "--purge" ]]; then
    purge=1
  elif [[ -n "${1:-}" ]]; then
    die "unknown option: $1"
  fi
  need_root revert "$@"
  load_state
  revert_sudoers
  revert_etc_environment
  revert_shell_env
  revert_plasma_env
  revert_selected_editor
  revert_git_editor
  revert_alternatives
  if [[ "${purge}" -eq 1 ]]; then
    if [[ "${VIM_INSTALLED_BY_US}" -eq 1 ]]; then
      apt-get remove -y vim vim-runtime || true
      echo "Removed the vim package."
    else
      echo "Not purging vim: it was already installed before apply."
    fi
  fi
  rm -f "${STATE_FILE}"
  echo "Reverted. Editor env and passwordless sudo drop-in removed."
}

cmd_status() {
  local user home dest
  if [[ ${EUID} -eq 0 ]]; then
    user="$(target_user)"
  else
    user="${USER}"
  fi
  home="$(getent passwd "${user}" | cut -d: -f6)"
  dest="/etc/sudoers.d/99-nopasswd-${user}"

  echo "user:          ${user}"
  echo "vim package:   $(pkg_installed vim && dpkg-query -W -f='${Version}' vim || echo 'not installed')"
  echo "vim.basic:     $(command -v vim.basic 2>/dev/null || echo missing)"
  echo "editor alt:    $(readlink -f /usr/bin/editor 2>/dev/null || echo missing) ($(alt_query editor Status || echo unknown))"
  echo "EDITOR:        ${EDITOR:-unset}"
  echo "VISUAL:        ${VISUAL:-unset}"
  echo "SUDO_EDITOR:   ${SUDO_EDITOR:-unset}"
  if [[ -f "${home}/.bashrc" ]] && grep -qF "${BLOCK_START}" "${home}/.bashrc"; then
    echo "bashrc block:  present"
  else
    echo "bashrc block:  absent"
  fi
  if [[ -f "${home}/${PLASMA_ENV_REL}" ]]; then
    echo "plasma env:    ${home}/${PLASMA_ENV_REL}"
  else
    echo "plasma env:    absent"
  fi
  echo "git editor:    $(git config --file "${home}/.gitconfig" --get core.editor 2>/dev/null || echo unset)"
  if [[ -f "${ENV_FILE}" ]] && grep -q '^EDITOR=vim$' "${ENV_FILE}"; then
    echo "/etc/environment EDITOR=vim: yes"
  else
    echo "/etc/environment EDITOR=vim: no"
  fi
  if [[ -f "${dest}" ]]; then
    echo "sudoers:       ${dest} (present)"
  else
    echo "sudoers:       ${dest} (absent)"
  fi
  if sudo -n true 2>/dev/null; then
    echo "sudo -n:       ok (passwordless)"
  else
    echo "sudo -n:       failed (password required or not permitted)"
  fi
  if [[ -f "${STATE_FILE}" ]]; then
    echo "state:         ${STATE_FILE}"
  else
    echo "state:         not applied by this script (or unreadable without root)"
  fi
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
