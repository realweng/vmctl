#!/usr/bin/env bash
# vmctl.sh — control local VMware Workstation/Fusion VMs via vmrun.
# Works on Windows (Git Bash/MSYS), inside WSL (via Windows interop), Linux, and macOS (Fusion).
#
# On first use (or `vmctl.sh doctor`) the script locates vmrun and caches it in
# ~/.config/vmctl/paths, so later calls are instant. Discovery order:
#   1. $VMCTL_VMRUN / $VMWARE_VMRUN env var
#   2. cached path from ~/.config/vmctl/paths
#   3. vmrun on PATH
#   4. common install locations (all drives from Windows Git Bash / all /mnt/* from WSL)
#   5. Windows registry uninstall entries (locates vmware.exe, vmrun.exe sits next to it)
set -uo pipefail

die() { echo "vmctl: error: $*" >&2; exit 1; }
die_usage() { echo "vmctl: error: $*" >&2; exit 64; }
info() { echo "vmctl: $*"; }

# ---------- environment kind ----------
ENV_KIND=unknown
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) ENV_KIND=winbash ;;
  Linux*)
    if grep -qi microsoft /proc/version 2>/dev/null; then ENV_KIND=wsl; else ENV_KIND=linux; fi ;;
  Darwin*) ENV_KIND=macos ;;
esac

CONFIG_DIR="$HOME/.config/vmctl"
CACHE_FILE="$CONFIG_DIR/paths"

# ---------- locate vmrun ----------
VMRUN=""
VMRUN_SRC=""

save_cache() { mkdir -p "$CONFIG_DIR" 2>/dev/null && printf 'VMRUN=%s\n' "$1" > "$CACHE_FILE" && return 0; return 1; }
read_cache() {
  [ -f "$CACHE_FILE" ] || return 1
  local v
  v="$(sed -n 's/^VMRUN=//p' "$CACHE_FILE" | head -n 1)"
  [ -n "$v" ] && [ -f "$v" ] && printf '%s\n' "$v" || return 1
}

find_reg_exe() {
  case "$ENV_KIND" in
    winbash) command -v reg.exe 2>/dev/null || command -v reg 2>/dev/null ;;
    wsl)
      local d
      for d in c d e f; do
        [ -f "/mnt/$d/Windows/System32/reg.exe" ] && { printf '%s\n' "/mnt/$d/Windows/System32/reg.exe"; return 0; }
      done ;;
  esac
  return 1
}

# last-resort: find the VMware install dir from Windows uninstall registry entries
registry_find_vmrun() {
  [ "$ENV_KIND" = winbash ] || [ "$ENV_KIND" = wsl ] || return 1
  local reg out icon uq dir
  reg="$(find_reg_exe)" || return 1
  out="$(MSYS_NO_PATHCONV=1 "$reg" query 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' -s 2>/dev/null | tr -d '\0')"
  [ -n "$out" ] || out="$(MSYS_NO_PATHCONV=1 "$reg" query 'HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall' -s 2>/dev/null | tr -d '\0')"
  [ -n "$out" ] || return 1
  icon="$(printf '%s\n' "$out" | awk -F'REG_SZ' 'tolower($0) ~ /displayicon/ && tolower($2) ~ /vmware\.exe/ {gsub(/^[ \t\r]+|[ \t\r]+$/, "", $2); sub(/,[0-9]+$/, "", $2); print $2; exit}')"
  [ -n "$icon" ] || return 1
  uq="$(to_unix_path "$icon")"
  dir="$(dirname "$uq")"
  [ -f "$dir/vmrun.exe" ] || return 1
  to_win_path "$dir/vmrun.exe"
}

probe_vmrun() {
  local c d
  case "$ENV_KIND" in
    wsl)
      for c in /mnt/*/AppData/VMware/vmrun.exe \
               /mnt/*/Program*/VMware*/vmrun.exe \
               /mnt/*/Program*/VMware*/bin/vmrun.exe ; do
        [ -f "$c" ] && { printf '%s\n' "$c"; return 0; }
      done ;;
    winbash)
      # drive letters are not glob-enumerable in some MSYS roots, probe explicitly
      for d in c d e f g h i j k l m n o p q r s t u v w x y z; do
        for c in "/$d/AppData/VMware/vmrun.exe" \
                 "/$d/Program Files (x86)/VMware/VMware Workstation/vmrun.exe" \
                 "/$d/Program Files/VMware/VMware Workstation/vmrun.exe" ; do
          [ -f "$c" ] && { printf '%s\n' "$c"; return 0; }
        done
      done ;;
    macos)
      for c in "/Applications/VMware Fusion.app/Contents/Library/vmrun"; do
        [ -f "$c" ] && { printf '%s\n' "$c"; return 0; }
      done ;;
  esac
  return 1
}

# sets VMRUN / VMRUN_SRC; $1 = 1 to ignore the cache and re-detect
find_vmrun() {
  local force="${1:-0}" c
  if [ -n "${VMCTL_VMRUN:-}" ] || [ -n "${VMWARE_VMRUN:-}" ]; then
    c="${VMCTL_VMRUN:-${VMWARE_VMRUN}}"
    [ -f "$c" ] || die "VMCTL_VMRUN=$c does not exist"
    VMRUN="$c"; VMRUN_SRC="env"; return 0
  fi
  if [ "$force" -eq 0 ] && c="$(read_cache)"; then
    VMRUN="$c"; VMRUN_SRC="cache"; return 0
  fi
  if command -v vmrun >/dev/null 2>&1; then
    c="$(command -v vmrun)"; VMRUN="$c"; VMRUN_SRC="path"; save_cache "$c"; return 0
  fi
  if c="$(probe_vmrun)"; then
    VMRUN="$c"; VMRUN_SRC="probe"; save_cache "$c"; return 0
  fi
  if [ "$ENV_KIND" = winbash ] || [ "$ENV_KIND" = wsl ]; then
    if c="$(registry_find_vmrun)"; then
      VMRUN="$c"; VMRUN_SRC="registry"; save_cache "$c"; return 0
    fi
  fi
  return 1
}

# ---------- locate inventory ----------
find_inventory() {
  local c
  if [ -n "${VMCTL_INVENTORY:-}" ] || [ -n "${VMWARE_INVENTORY:-}" ]; then
    c="${VMCTL_INVENTORY:-${VMWARE_INVENTORY}}"
    [ -f "$c" ] || die "VMCTL_INVENTORY=$c does not exist"
    printf '%s\n' "$c"; return 0
  fi
  case "$ENV_KIND" in
    wsl)
      for c in "/mnt/c/Users/${USER:-}/AppData/Roaming/VMware/inventory.vmls" \
               /mnt/c/Users/*/AppData/Roaming/VMware/inventory.vmls ; do
        [ -f "$c" ] && { printf '%s\n' "$c"; return 0; }
      done ;;
    winbash|linux)
      for c in "$HOME/AppData/Roaming/VMware/inventory.vmls" \
               /c/Users/*/AppData/Roaming/VMware/inventory.vmls ; do
        [ -f "$c" ] && { printf '%s\n' "$c"; return 0; }
      done ;;
    macos)
      for c in "$HOME/Library/Preferences/VMware Fusion/inventory.vmls"; do
        [ -f "$c" ] && { printf '%s\n' "$c"; return 0; }
      done ;;
  esac
  return 1
}

# ---------- path helpers ----------
to_win_path() { # unix-style path -> windows-style
  local p="$1"
  case "$p" in
    *:\\*|\\\\*) printf '%s\n' "$p"; return ;;
  esac
  case "$ENV_KIND" in
    wsl)     wslpath -w "$p" 2>/dev/null || printf '%s\n' "$p" ;;
    winbash) cygpath -w "$p" 2>/dev/null || printf '%s\n' "$p" ;;
    *) printf '%s\n' "$p" ;;
  esac
}

to_unix_path() { # windows-style path -> unix-style (best effort)
  local p="$1"
  case "$p" in
    *:\\*|\\\\*) ;;
    *) printf '%s\n' "$p"; return ;;
  esac
  case "$ENV_KIND" in
    wsl)     wslpath -u "$p" 2>/dev/null || printf '%s\n' "$p" ;;
    winbash) cygpath -u "$p" 2>/dev/null || printf '%s\n' "$p" ;;
    *) printf '%s\n' "$p" ;;
  esac
}

canon() { printf '%s\n' "$1" | tr '[:upper:]\\' '[:lower:]/'; }

basename_of_vmx() { local p; p="${1##*[\\/]}"; printf '%s\n' "${p%.[vV][mM][xX]}"; }

# ---------- inventory / running state ----------
INVENTORY=""

load_env() {
  find_vmrun "${1:-0}" || die "vmrun not found (searched: env, cache, PATH, common locations, registry); set VMCTL_VMRUN to the full path of vmrun(.exe) or run 'vmctl.sh doctor'"
  INVENTORY="$(find_inventory)" || INVENTORY=""
}

# prints lines: DisplayName<TAB>WindowsVmxPath
read_inventory() {
  [ -n "$INVENTORY" ] || return 0
  local data
  if command -v iconv >/dev/null 2>&1; then
    data="$(iconv -f GBK -t UTF-8 "$INVENTORY" 2>/dev/null || cat "$INVENTORY")"
  else
    data="$(cat "$INVENTORY")"
  fi
  printf '%s\n' "$data" | tr -d '\r' | awk '
    /^vmlist[0-9]+\.config = / {
      s = $0; sub(/^vmlist[0-9]+\.config = "/, "", s); sub(/"$/, "", s)
      if (s ~ /\.vmx$/) { k = $0; sub(/^vmlist/, "", k); sub(/\.config.*/, "", k); cfg[k] = s }
    }
    /^vmlist[0-9]+\.DisplayName = / {
      s = $0; sub(/^vmlist[0-9]+\.DisplayName = "/, "", s); sub(/"$/, "", s)
      k = $0; sub(/^vmlist/, "", k); sub(/\.DisplayName.*/, "", k); name[k] = s
    }
    END {
      for (k in cfg) {
        n = (k in name) ? name[k] : ""
        if (n == "") { n = cfg[k]; sub(/.*[\\\/]/, "", n); sub(/\.vmx$/, "", n) }
        print n "\t" cfg[k]
      }
    }'
}

# prints windows-style vmx paths of running VMs, one per line
# </dev/null: a Windows exe under WSL interop may consume the caller's stdin
# tr -d '\r': vmrun emits CRLF; WSL pipes do not strip it (Git Bash does)
running_vms() { "$VMRUN" list </dev/null 2>/dev/null | tr -d '\r' | tail -n +2 | sed '/^[[:space:]]*$/d'; }

is_running() { # $1 = windows-style vmx path
  local want r
  want="$(canon "$1")"
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    [ "$want" = "$(canon "$r")" ] && return 0
  done < <(running_vms)
  return 1
}

# ---------- name resolution ----------
RESOLVED_NAME=""
RESOLVED_PATH=""

resolve_vm() { # $1 = user query; sets RESOLVED_NAME / RESOLVED_PATH (windows path)
  local q="$1" uq name path key bn lname lbn exact_hit="" sub_hits=""
  [ -n "$q" ] || die "empty VM name"
  uq="$(to_unix_path "$q")"
  if [ -f "$uq" ]; then
    RESOLVED_PATH="$(to_win_path "$uq")"
    RESOLVED_NAME="$(basename_of_vmx "$RESOLVED_PATH")"
    return 0
  fi
  key="$(canon "$q")"
  while IFS=$'\t' read -r name path; do
    [ -n "$path" ] || continue
    bn="$(basename_of_vmx "$path")"
    lname="$(canon "$name")"; lbn="$(canon "$bn")"
    if [ "$key" = "$lname" ] || [ "$key" = "$lbn" ] || [ "$key" = "$(canon "$path")" ]; then
      exact_hit="$name"$'\t'"$path"; break
    fi
    if [[ "$lname" == *"$key"* || "$lbn" == *"$key"* ]]; then
      sub_hits+="$name"$'\t'"$path"$'\n'
    fi
  done < <(read_inventory | sort -u)
  if [ -n "$exact_hit" ]; then
    RESOLVED_NAME="${exact_hit%%$'\t'*}"; RESOLVED_PATH="${exact_hit#*$'\t'}"
    return 0
  fi
  local n
  n="$(printf '%s' "$sub_hits" | grep -c . || true)"
  if [ "${n:-0}" -eq 1 ]; then
    local line; line="$(printf '%s' "$sub_hits" | head -n 1)"
    RESOLVED_NAME="${line%%$'\t'*}"; RESOLVED_PATH="${line#*$'\t'}"
    return 0
  elif [ "${n:-0}" -gt 1 ]; then
    echo "vmctl: '$q' is ambiguous, candidates:" >&2
    printf '%s' "$sub_hits" | awk -F'\t' 'NF >= 2 {printf "  - %s (%s)\n", $1, $2}' >&2
    exit 2
  fi
  # fall back to running VMs not present in inventory
  local r
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    if [ "$key" = "$(canon "$r")" ] || [ "$key" = "$(canon "$(basename_of_vmx "$r")")" ]; then
      RESOLVED_NAME="$(basename_of_vmx "$r")"; RESOLVED_PATH="$r"; return 0
    fi
  done < <(running_vms)
  echo "vmctl: no VM matches '$q'" >&2
  if [ -n "$INVENTORY" ]; then
    echo "known VMs (from $INVENTORY):" >&2
    read_inventory | sort -u | awk -F'\t' 'NF >= 2 {printf "  - %s (%s)\n", $1, $2}' >&2
  else
    echo "no inventory.vmls found; set VMCTL_INVENTORY or pass a full .vmx path" >&2
  fi
  exit 1
}

# ---------- commands ----------
cmd_doctor() {
  find_vmrun 1 || true
  INVENTORY="$(find_inventory)" || INVENTORY=""
  echo "env:       $ENV_KIND"
  echo "cache:     $CACHE_FILE"
  if [ -n "$VMRUN" ]; then
    echo "vmrun:     $VMRUN  (source: $VMRUN_SRC)"
    echo "running:   $(running_vms | grep -c . || true) VM(s)"
  else
    echo "vmrun:     NOT FOUND - set VMCTL_VMRUN=/full/path/to/vmrun(.exe)"
  fi
  if [ -n "$INVENTORY" ]; then
    echo "inventory: $INVENTORY ($(read_inventory | grep -c . || true) VMs)"
  else
    echo "inventory: not found (set VMCTL_INVENTORY to override; VMs can still be addressed by full .vmx path)"
  fi
  [ -n "$VMRUN" ] || exit 1
}

cmd_list() {
  load_env
  local inv canon_list name path r
  inv="$(read_inventory | sort -u)"
  canon_list="$(printf '%s\n' "$inv" | while IFS=$'\t' read -r _ p; do [ -n "$p" ] && canon "$p"; done)"
  printf '%-30s %-9s %s\n' "NAME" "STATE" "VMX"
  while IFS=$'\t' read -r name path; do
    [ -n "$path" ] || continue
    local state=off
    is_running "$path" && state=running
    printf '%-30s %-9s %s\n' "$name" "$state" "$path"
  done <<< "$inv"
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    printf '%s\n' "$canon_list" | grep -qxF -- "$(canon "$r")" || \
      printf '%-30s %-9s %s\n' "$(basename_of_vmx "$r")" "running" "$r"
  done < <(running_vms)
}

cmd_status() {
  load_env; resolve_vm "$1"
  if is_running "$RESOLVED_PATH"; then
    info "$RESOLVED_NAME is running ($RESOLVED_PATH)"
  else
    info "$RESOLVED_NAME is off ($RESOLVED_PATH)"
  fi
}

cmd_start() {
  local q="$1" gui="nogui"
  [ "${2:-}" = "--gui" ] && gui="gui"
  load_env; resolve_vm "$q"
  if is_running "$RESOLVED_PATH"; then
    info "$RESOLVED_NAME is already running ($RESOLVED_PATH)"; return 0
  fi
  info "starting $RESOLVED_NAME ($gui): $RESOLVED_PATH"
  "$VMRUN" start "$RESOLVED_PATH" "$gui" </dev/null || die "vmrun start failed (is the VM locked by another process?)"
  info "$RESOLVED_NAME started ($gui)"
}

cmd_power() { # $1=stop|suspend|reset, $2=vm, $3=mode
  local op="$1" q="$2" mode="${3:-soft}"
  case "$mode" in soft|hard) ;; *) die_usage "mode must be soft or hard, got '$mode'";; esac
  load_env; resolve_vm "$q"
  if ! is_running "$RESOLVED_PATH"; then
    if [ "$op" = "reset" ]; then die "$RESOLVED_NAME is not running; cannot reset"; fi
    info "$RESOLVED_NAME is not running; nothing to $op"; return 0
  fi
  "$VMRUN" "$op" "$RESOLVED_PATH" "$mode" </dev/null || die "vmrun $op failed"
  info "$RESOLVED_NAME: $op ($mode) done"
}

cmd_ip() {
  local q="$1" wait=""
  [ "${2:-}" = "--wait" ] && wait="-wait"
  load_env; resolve_vm "$q"
  is_running "$RESOLVED_PATH" || die "$RESOLVED_NAME is not running"
  "$VMRUN" getGuestIPAddress "$RESOLVED_PATH" $wait </dev/null | tr -d '\r' \
    || die "could not get guest IP (VMware Tools installed and guest fully booted?)"
}

cmd_snapshot() { # create
  load_env; resolve_vm "$1"
  "$VMRUN" snapshot "$RESOLVED_PATH" "$2" </dev/null || die "vmrun snapshot failed"
  info "$RESOLVED_NAME: snapshot '$2' created"
}

cmd_snapshots() { # list
  local q="$1" tree=""
  [ "${2:-}" = "--tree" ] && tree="showTree"
  load_env; resolve_vm "$q"
  "$VMRUN" listSnapshots "$RESOLVED_PATH" $tree </dev/null 2>/dev/null | tr -d '\r'
}

cmd_revert() {
  load_env; resolve_vm "$1"
  "$VMRUN" revertToSnapshot "$RESOLVED_PATH" "$2" </dev/null || die "vmrun revertToSnapshot failed (does the snapshot exist?)"
  info "$RESOLVED_NAME: reverted to snapshot '$2'"
}

cmd_delsnap() {
  local q="$1" snap="$2" kids=""
  [ "${3:-}" = "--children" ] && kids="andDeleteChildren"
  load_env; resolve_vm "$q"
  "$VMRUN" deleteSnapshot "$RESOLVED_PATH" "$snap" $kids </dev/null || die "vmrun deleteSnapshot failed"
  info "$RESOLVED_NAME: snapshot '$snap' deleted${kids:+ (with children)}"
}

usage() {
  cat <<'EOF'
vmctl — control local VMware VMs via vmrun (Windows / WSL / Linux / macOS)

usage: vmctl.sh doctor
       vmctl.sh list
       vmctl.sh status    <vm>
       vmctl.sh start     <vm> [--gui]
       vmctl.sh stop      <vm> [soft|hard]
       vmctl.sh suspend   <vm> [soft|hard]
       vmctl.sh reset     <vm> [soft|hard]
       vmctl.sh ip        <vm> [--wait]
       vmctl.sh snapshot  <vm> <snap-name>              create snapshot
       vmctl.sh snapshots <vm> [--tree]                 list snapshots
       vmctl.sh revert    <vm> <snap-name>              restore snapshot
       vmctl.sh delsnap   <vm> <snap-name> [--children] delete snapshot

<vm>: VM display name, vmx file basename, or full .vmx path
      (WSL /mnt/e/..., Git Bash /e/..., or Windows E:\... style all work)

env:  VMCTL_VMRUN      override vmrun path
      VMCTL_INVENTORY  override inventory.vmls path
EOF
}

main() {
  local cmd="${1:-list}"
  [ $# -gt 0 ] && shift
  case "$cmd" in
    doctor)
      [ $# -eq 0 ] || die_usage "doctor takes no arguments"
      cmd_doctor ;;
    list)
      [ $# -eq 0 ] || die_usage "list takes no arguments"
      cmd_list ;;
    status)
      [ $# -eq 1 ] || die_usage "usage: vmctl.sh status <vm>"
      cmd_status "$1" ;;
    start)
      case $# in 1|2) ;; *) die_usage "usage: vmctl.sh start <vm> [--gui]";; esac
      [ $# -eq 2 ] && [ "$2" != "--gui" ] && die_usage "start: unknown option '$2' (only --gui)"
      cmd_start "$@" ;;
    stop|suspend|reset)
      case $# in 1|2) ;; *) die_usage "usage: vmctl.sh $cmd <vm> [soft|hard]";; esac
      cmd_power "$cmd" "$@" ;;
    ip)
      case $# in 1|2) ;; *) die_usage "usage: vmctl.sh ip <vm> [--wait]";; esac
      [ $# -eq 2 ] && [ "$2" != "--wait" ] && die_usage "ip: unknown option '$2' (only --wait)"
      cmd_ip "$@" ;;
    snapshot)
      case $# in 2) ;; *) die_usage "usage: vmctl.sh snapshot <vm> <snap-name>";; esac
      case "$2" in -*) die_usage "invalid snapshot name '$2'";; esac
      cmd_snapshot "$@" ;;
    snapshots)
      case $# in 1|2) ;; *) die_usage "usage: vmctl.sh snapshots <vm> [--tree]";; esac
      [ $# -eq 2 ] && [ "$2" != "--tree" ] && die_usage "snapshots: unknown option '$2' (only --tree)"
      cmd_snapshots "$@" ;;
    revert)
      case $# in 2) ;; *) die_usage "usage: vmctl.sh revert <vm> <snap-name>";; esac
      case "$2" in -*) die_usage "invalid snapshot name '$2'";; esac
      cmd_revert "$@" ;;
    delsnap)
      case $# in 2|3) ;; *) die_usage "usage: vmctl.sh delsnap <vm> <snap-name> [--children]";; esac
      [ $# -eq 3 ] && [ "$3" != "--children" ] && die_usage "delsnap: unknown option '$3' (only --children)"
      cmd_delsnap "$@" ;;
    help|-h|--help) usage ;;
    *) usage >&2; exit 64 ;;
  esac
}

main "$@"
