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

SKILL_REPO_HTTPS="https://github.com/realweng/vmctl"
SKILL_REPO_SSH="git@github.com:realweng/vmctl.git"

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

skill_root() { # directory containing scripts/ (i.e. the skill install dir)
  local d
  d="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" && printf '%s\n' "$d"
}

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

# ---------- guest operations (need VMware Tools + guest credentials) ----------
# Connectivity probe executed inside the guest (no root needed). Prints one
# status line per check and exits 0 iff at least one public IP answers ping.
GUEST_CHECK_SCRIPT='
ip -4 -o addr show scope global | sed "s/^/addr: /"
gw="$(ip route show default | awk "{print \$3; exit}")"
if [ -n "$gw" ]; then
  echo "gw: $gw"
  if ping -c1 -W2 "$gw" >/dev/null 2>&1; then echo "gateway: reachable"; else echo "gateway: UNREACHABLE"; fi
else
  echo "gw: none"
fi
i1=fail; i2=fail
ping -c1 -W3 223.5.5.5 >/dev/null 2>&1 && i1=ok
ping -c1 -W3 8.8.8.8  >/dev/null 2>&1 && i2=ok
if [ "$i1" = ok ] || [ "$i2" = ok ]; then echo "internet: reachable"; else echo "internet: UNREACHABLE"; fi
if getent hosts github.com >/dev/null 2>&1; then echo "dns: ok"; else echo "dns: FAILED"; fi
[ "$i1" = ok ] || [ "$i2" = ok ]
'

guest_auth_set() { # $1 = -u value, $2 = -p value ("" falls back to env)
  GU="${1:-${VMCTL_GUEST_USER:-}}"
  GP="${2:-${VMCTL_GUEST_PASS:-}}"
  [ -n "$GU" ] && [ -n "$GP" ] || die_usage "guest credentials required: -u <user> -p <pass> (or env VMCTL_GUEST_USER / VMCTL_GUEST_PASS)"
}

# Run a shell script (/bin/bash) in the guest; print its stdout+stderr on the
# host and return the guest exit code. vmrun does not stream guest output, so
# it is relayed through a guest temp file + copyFileFromGuestToHost.
guest_run() { # $1 = windows-style vmx, $2 = script text
  local vmx="$1" script="$2" gout hout full rc
  gout="//tmp/vmctl.$$.$RANDOM.out"   # '//' survives MSYS/WSL arg conversion; guests collapse it to /tmp
  hout="$(mktemp "${TMPDIR:-/tmp}/vmctl-guest.XXXXXX")" || die "mktemp failed"
  full="exec > $gout 2>&1"$'\n'"$script"$'\n''printf "__VMCTL_RC=%s\n" "$?"'
  MSYS_NO_PATHCONV=1 "$VMRUN" -T ws -gu "$GU" -gp "$GP" runScriptInGuest "$vmx" /bin/bash "$full" </dev/null \
    || { rm -f "$hout"; die "could not run script in guest (VMware Tools running? guest credentials correct?)"; }
  MSYS_NO_PATHCONV=1 "$VMRUN" -T ws -gu "$GU" -gp "$GP" copyFileFromGuestToHost "$vmx" "$gout" "$(to_win_path "$hout")" </dev/null \
    || { rm -f "$hout"; die "could not copy guest output back to host"; }
  MSYS_NO_PATHCONV=1 "$VMRUN" -T ws -gu "$GU" -gp "$GP" runScriptInGuest "$vmx" /bin/bash "rm -f '$gout'" </dev/null >/dev/null 2>&1 || true
  rc="$(sed -n 's/^__VMCTL_RC=//p' "$hout" | tail -n 1)"
  sed '/^__VMCTL_RC=/d' "$hout"
  rm -f "$hout"
  [ -n "$rc" ] || rc=0
  return "$rc"
}

cmd_exec() { # vmctl exec <vm> [-u user] [-p pass] -- <shell command...>
  local vm="" gu="" gp="" c
  local cmd=()
  while [ $# -gt 0 ]; do
    c="$1"
    case "$c" in
      -u|--user) [ $# -ge 2 ] || die_usage "missing value after $c"; gu="$2"; shift 2 ;;
      -p|--pass) [ $# -ge 2 ] || die_usage "missing value after $c"; gp="$2"; shift 2 ;;
      --)        shift; cmd=("$@"); break ;;
      -*)        die_usage "exec: unknown option '$c'" ;;
      *) [ -z "$vm" ] || die_usage "usage: vmctl.sh exec <vm> [-u user] [-p pass] -- <shell command...>"; vm="$c"; shift ;;
    esac
  done
  [ -n "$vm" ] || die_usage "usage: vmctl.sh exec <vm> [-u user] [-p pass] -- <shell command...>"
  [ ${#cmd[@]} -gt 0 ] || die_usage "exec: nothing to run (put the command after '--')"
  guest_auth_set "$gu" "$gp"
  load_env; resolve_vm "$vm"
  is_running "$RESOLVED_PATH" || die "$RESOLVED_NAME is not running"
  guest_run "$RESOLVED_PATH" "${cmd[*]}"
}

# vmnet subnet for a VMnet number: "a.b.c.d/n" from VMware's config (Windows:
# vmnetdhcp.conf segments; macOS Fusion: networking preferences). "" if unknown.
vmnet_subnet() {
  local n="$1" f line sub
  case "$ENV_KIND" in
    winbash|linux) f="/c/ProgramData/VMware/vmnetdhcp.conf" ;;
    wsl)           f="/mnt/c/ProgramData/VMware/vmnetdhcp.conf" ;;
    macos)
      f="/Library/Preferences/VMware Fusion/networking"
      [ -f "$f" ] || return 0
      printf '%s\n' "$(sed -n 's/^VNET_'"$n"'_HOSTONLY_SUBNET=//p' "$f" | head -n 1)/24"
      return 0 ;;
    *) return 0 ;;
  esac
  [ -f "$f" ] || return 0
  line="$(awk -v n="$n" 'tolower($0) ~ ("# virtual ethernet segment " n "$") {seen=1; next}
                          seen && /subnet / {print; exit}' "$f" 2>/dev/null)"
  sub="$(printf '%s' "$line" | sed -n 's/^subnet \([0-9.]*\) netmask \([0-9.]*\) {/\1|\2/p')"
  [ -n "$sub" ] || return 0
  local addr="${sub%%|*}" mask="${sub#*|}" bits=0 o
  for o in ${mask//./ }; do
    case "$o" in
      255) bits=$((bits+8));; 254) bits=$((bits+7));; 252) bits=$((bits+6));;
      248) bits=$((bits+5));; 240) bits=$((bits+4));; 224) bits=$((bits+3));;
      192) bits=$((bits+2));; 128) bits=$((bits+1));; 0) ;;
    esac
  done
  printf '%s/%s\n' "$addr" "$bits"
}

in_subnet() { # $1 = ip, $2 = a.b.c.d[/n] (default /24; octet-aligned subnets only)
  local ip="$1" spec="$2" net bits i
  case "$spec" in */*) net="${spec%%/*}"; bits="${spec#*/}";; *) net="$spec"; bits=24;; esac
  local n_oct=$((bits/8)); [ "$n_oct" -gt 4 ] && n_oct=4
  local -a ia na
  IFS=. read -r ia[0] ia[1] ia[2] ia[3] <<< "$ip"
  IFS=. read -r na[0] na[1] na[2] na[3] <<< "$net"
  for ((i=0; i<n_oct; i++)); do
    [ "${ia[i]:-x}" = "${na[i]:-y}" ] || return 1
  done
  return 0
}

win_service_state() { # $1 = service name -> running|stopped|unknown
  local scq
  case "$ENV_KIND" in
    winbash) scq="$(command -v sc.exe 2>/dev/null || command -v sc 2>/dev/null)" ;;
    wsl)     scq=/mnt/c/Windows/System32/sc.exe ;;
    *) return 2 ;;
  esac
  [ -n "$scq" ] || { echo unknown; return 0; }
  if "$scq" query "$1" </dev/null 2>/dev/null | grep -q RUNNING; then echo running; else echo stopped; fi
}

cmd_netcheck() { # vmctl netcheck <vm> [-u user] [-p pass] [--fix-dhcp]
  local vm="" gu="" gp="" fix=0 c
  while [ $# -gt 0 ]; do
    c="$1"
    case "$c" in
      -u|--user)  [ $# -ge 2 ] || die_usage "missing value after $c"; gu="$2"; shift 2 ;;
      -p|--pass)  [ $# -ge 2 ] || die_usage "missing value after $c"; gp="$2"; shift 2 ;;
      --fix-dhcp) fix=1; shift ;;
      -*) die_usage "netcheck: unknown option '$c'" ;;
      *) [ -z "$vm" ] || die_usage "usage: vmctl.sh netcheck <vm> [-u user] [-p pass] [--fix-dhcp]"; vm="$c"; shift ;;
    esac
  done
  [ -n "$vm" ] || die_usage "usage: vmctl.sh netcheck <vm> [-u user] [-p pass] [--fix-dhcp]"
  load_env; resolve_vm "$vm"
  is_running "$RESOLVED_PATH" || die "$RESOLVED_NAME is not running"

  # ---- host side: adapter type, vmnet subnet, guest IP, NAT/DHCP services ----
  local vmx_u conn vnet vmnet subnet ipaddr
  vmx_u="$(to_unix_path "$RESOLVED_PATH")"
  conn="$(tr -d '\r' < "$vmx_u" | sed -n 's/^[[:space:]]*ethernet0\.connectionType[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/Ip' | head -n 1)"
  vnet="$(tr -d '\r' < "$vmx_u" | sed -n 's/^[[:space:]]*ethernet0\.vnet[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/Ip' | head -n 1)"
  vmnet="$vnet"
  case "$(printf '%s' "$conn" | tr '[:upper:]' '[:lower:]')" in
    nat)      [ -n "$vmnet" ] || vmnet=8 ;;
    hostonly) [ -n "$vmnet" ] || vmnet=1 ;;
    bridged)  [ -n "$vmnet" ] || vmnet=0 ;;
    "")       conn=bridged;  [ -n "$vmnet" ] || vmnet=0 ;;
  esac
  ipaddr="$("$VMRUN" getGuestIPAddress "$RESOLVED_PATH" </dev/null 2>/dev/null | tr -d '\r' | grep -E '^[0-9]+(\.[0-9]+){3}$')"
  info "$RESOLVED_NAME: network check (host side)"
  info "  adapter : ethernet0 ${conn}${vmnet:+ (VMnet$vmnet)}"
  info "  guest IP: ${ipaddr:-unknown (needs VMware Tools)}"
  subnet="$(vmnet_subnet "$vmnet")"
  case "$vmnet" in
    0) info "  network : bridged — guest shares the physical LAN, no virtual subnet" ;;
    *)
      if [ -n "$subnet" ]; then
        info "  VMnet$vmnet subnet: $subnet"
        if [ -n "$ipaddr" ]; then
          if in_subnet "$ipaddr" "$subnet"; then
            info "  guest IP is inside the VMnet$vmnet subnet: OK"
          else
            info "  MISMATCH: guest IP is OUTSIDE the VMnet$vmnet subnet ($subnet)"
            info "  → most likely cause: static IP in the guest from an old subnet. Run:"
            info "    vmctl.sh netcheck $vm -u <user> -p <pass> --fix-dhcp"
          fi
        fi
      else
        info "  VMnet$vmnet subnet: unknown (config file not found)"
      fi
      if [ "$ENV_KIND" = winbash ] || [ "$ENV_KIND" = wsl ]; then
        info "  services: VMware DHCP $(win_service_state VMnetDHCP), VMware NAT $(win_service_state 'VMware NAT Service')"
      fi ;;
  esac

  # ---- guest side: needs credentials ----
  GU="$gu"; GP="$gp"
  if [ -z "$GU" ] || [ -z "$GP" ]; then
    GU="${VMCTL_GUEST_USER:-}"; GP="${VMCTL_GUEST_PASS:-}"
  fi
  if [ -z "$GU" ] || [ -z "$GP" ]; then
    [ "$fix" -eq 1 ] && die "--fix-dhcp needs guest credentials: -u <user> -p <pass> (or env VMCTL_GUEST_USER/VMCTL_GUEST_PASS)"
    info "  tip: add -u <user> -p <pass> (or env VMCTL_GUEST_USER/VMCTL_GUEST_PASS) to also probe inside the guest"
    return 0
  fi

  local script="" rc
  if [ "$fix" -eq 1 ]; then
    info "  --fix-dhcp: switching static ethernet connections to DHCP..."
    # password interpolated for non-interactive sudo; only valid if $GP is shell-safe
    script="if [ \"\$(id -u)\" != 0 ]; then printf '%s\n' '$GP' | sudo -S -p '' -v 2>/dev/null; fi
nmcli -t -f NAME,TYPE con show 2>/dev/null | while IFS=: read -r n t; do
  [ \"\$t\" = 802-3-ethernet ] || continue
  m=\$(nmcli -g ipv4.method con show \"\$n\" 2>/dev/null)
  if [ -n \"\$m\" ] && [ \"\$m\" != auto ]; then
    sudo nmcli con mod \"\$n\" ipv4.method auto ipv4.addresses '' ipv4.gateway '' ipv4.dns '' \
      && sudo nmcli con up \"\$n\" >/dev/null 2>&1 && echo \"fixed: \$n switched to DHCP\"
  fi
done
sleep 3"
  fi
  info "  --- inside guest ---"
  rc=0
  guest_run "$RESOLVED_PATH" "$script$GUEST_CHECK_SCRIPT" || rc=$?
  if [ "$rc" -eq 0 ]; then
    info "  → $RESOLVED_NAME has internet: OK"
    return 0
  fi
  info "  → $RESOLVED_NAME has NO internet (see lines above; a MISMATCH above means wrong subnet/static IP)"
  return 1
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

# ---------- self-upgrade ----------
repo_fetch() { # $1 = git dir; fetch main from upstream (https first, ssh fallback)
  git -C "$1" fetch -q "$SKILL_REPO_HTTPS" main 2>/dev/null && return 0
  info "https fetch failed, trying ssh..."
  git -C "$1" fetch -q "$SKILL_REPO_SSH" main && return 0
  return 1
}

repo_clone() { # $1 = dest dir; shallow clone from upstream (https first, ssh fallback)
  git clone -q --depth 1 "$SKILL_REPO_HTTPS" "$1" 2>/dev/null && return 0
  info "https clone failed, trying ssh..."
  git clone -q --depth 1 "$SKILL_REPO_SSH" "$1" && return 0
  return 1
}

cmd_upgrade() {
  local force=0
  [ "${1:-}" = "--force" ] && force=1
  local dir tmp old new
  dir="$(skill_root)"
  info "skill dir: $dir"
  if [ -d "$dir/.git" ] && command -v git >/dev/null 2>&1; then
    if [ -n "$(git -C "$dir" status --porcelain --untracked-files=no 2>/dev/null)" ] && [ "$force" -ne 1 ]; then
      die "skill dir has local changes; run 'vmctl.sh upgrade --force' to overwrite them"
    fi
    old="$(git -C "$dir" log -1 --format='%h (%cs)' 2>/dev/null || echo unknown)"
    repo_fetch "$dir" || die "fetch from $SKILL_REPO_HTTPS failed (network?)"
    if [ "$(git -C "$dir" rev-parse HEAD)" = "$(git -C "$dir" rev-parse FETCH_HEAD)" ]; then
      info "already up to date ($old)"; return 0
    fi
    if [ "$force" -eq 1 ]; then
      git -C "$dir" reset --hard -q FETCH_HEAD || die "git reset failed"
    else
      git -C "$dir" merge --ff-only -q FETCH_HEAD || die "cannot fast-forward (history diverged); run 'vmctl.sh upgrade --force'"
    fi
    new="$(git -C "$dir" log -1 --format='%h (%cs)')"
    info "upgraded: $old -> $new"
  else
    # not a git checkout: overlay a fresh copy (includes .git, so future upgrades are git-based)
    command -v git >/dev/null 2>&1 || command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 \
      || die "upgrade needs git or curl/wget"
    tmp="$(mktemp -d)" || die "mktemp failed"
    if command -v git >/dev/null 2>&1; then
      repo_clone "$tmp/vmctl" || { rm -rf "$tmp"; die "clone from $SKILL_REPO_HTTPS failed (network?)"; }
    else
      mkdir -p "$tmp/vmctl" || { rm -rf "$tmp"; die "mkdir failed"; }
      ( cd "$tmp/vmctl" \
        && { curl -fsSL "$SKILL_REPO_HTTPS/archive/refs/heads/main.tar.gz" -o src.tgz \
             || wget -qO src.tgz "$SKILL_REPO_HTTPS/archive/refs/heads/main.tar.gz"; } \
        && tar -xzf src.tgz --strip-components=1 ) || { rm -rf "$tmp"; die "download/extract failed"; }
    fi
    cp -a "$tmp/vmctl/." "$dir/" || { rm -rf "$tmp"; die "copying into skill dir failed"; }
    rm -rf "$tmp"
    new="$(git -C "$dir" log -1 --format='%h (%cs)' 2>/dev/null || echo latest)"
    info "upgraded to $new (install is now a git checkout; future upgrades use git)"
  fi
  info "restart your agent session to reload the skill"
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
       vmctl.sh exec      <vm> [-u user] [-p pass] -- <shell command...>
                                                          run a bash command inside the guest (Linux guests, needs VMware Tools)
       vmctl.sh netcheck  <vm> [-u user] [-p pass] [--fix-dhcp]
                                                          diagnose guest connectivity; --fix-dhcp switches static NICs to DHCP
       vmctl.sh snapshot  <vm> <snap-name>              create snapshot
       vmctl.sh snapshots <vm> [--tree]                 list snapshots
       vmctl.sh revert    <vm> <snap-name>              restore snapshot
       vmctl.sh delsnap   <vm> <snap-name> [--children] delete snapshot
       vmctl.sh upgrade   [--force]                     update this skill from GitHub

<vm>: VM display name, vmx file basename, or full .vmx path
      (WSL /mnt/e/..., Git Bash /e/..., or Windows E:\... style all work)

env:  VMCTL_VMRUN      override vmrun path
      VMCTL_INVENTORY  override inventory.vmls path
      VMCTL_GUEST_USER / VMCTL_GUEST_PASS   default guest credentials for exec/netcheck
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
    exec)
      [ $# -ge 1 ] || die_usage "usage: vmctl.sh exec <vm> [-u user] [-p pass] -- <shell command...>"
      cmd_exec "$@" ;;
    netcheck)
      [ $# -ge 1 ] || die_usage "usage: vmctl.sh netcheck <vm> [-u user] [-p pass] [--fix-dhcp]"
      cmd_netcheck "$@" ;;
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
    upgrade)
      case $# in 0|1) ;; *) die_usage "usage: vmctl.sh upgrade [--force]";; esac
      [ $# -eq 1 ] && [ "$1" != "--force" ] && die_usage "upgrade: unknown option '$1' (only --force)"
      cmd_upgrade "${1:-}" ;;
    help|-h|--help) usage ;;
    *) usage >&2; exit 64 ;;
  esac
}

main "$@"
