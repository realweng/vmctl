---
name: vmctl
description: Control local VMware Workstation VMs — power on/off, suspend, reset, guest IP, snapshots, run bash commands inside the guest (exec), and guest network connectivity diagnosis & repair (netcheck, --fix-dhcp). Use when the user wants to start/stop/power a VMware VM (虚拟机), manage snapshots, check VM status, execute a command in the guest OS, or troubleshoot guest network / internet problems (虚拟机网络不通、无法联网、网络诊断). Windows (Git Bash) 与 WSL 通用：开机、关机、挂起、重启、快照、客户机命令执行与网络诊断修复。
---

# vmctl — VMware VM control

Controls local VMware Workstation VMs via `vmrun`. On first use (or via `doctor`) it auto-locates vmrun (env var → cache → PATH → common install paths → Windows registry) and caches the result, handles WSL ↔ Windows path translation, GBK inventory decoding, and CRLF output. Works identically from Windows (Git Bash) and WSL.

## Quick start

Script lives at `scripts/vmctl.sh` in this skill dir (both Windows Git Bash and WSL: `~/.agents/skills/vmctl/scripts/vmctl.sh`):

```bash
bash ~/.agents/skills/vmctl/scripts/vmctl.sh doctor                  # verify setup, (re)detect & cache vmrun path
bash ~/.agents/skills/vmctl/scripts/vmctl.sh list                    # all VMs + running state
bash ~/.agents/skills/vmctl/scripts/vmctl.sh start UbuntuServer1     # power on headless (nogui)
bash ~/.agents/skills/vmctl/scripts/vmctl.sh stop UbuntuServer1      # soft shutdown
```

## Commands

| Command | Description |
|---|---|
| `doctor` | Show detected env/vmrun/inventory; force re-detection and refresh cache |
| `list` | List all inventory VMs with running/off state |
| `status <vm>` | Show power state of one VM |
| `start <vm> [--gui]` | Power on; `nogui` (default) runs headless, `--gui` opens the VMware window |
| `stop <vm> [soft\|hard]` | Shutdown; `soft` (default) = graceful in-guest, `hard` = power off |
| `suspend <vm> [soft\|hard]` | Suspend to memory |
| `reset <vm> [soft\|hard]` | Reboot the VM (must be running) |
| `ip <vm> [--wait]` | Guest IP (needs VMware Tools; `--wait` blocks until available) |
| `exec <vm> [-u user] [-p pass] -- <cmd...>` | Run a bash command inside the guest (Linux guests, needs VMware Tools) and print its output; exit code = guest exit code |
| `netcheck <vm> [-u user] [-p pass] [--fix-dhcp]` | Diagnose guest connectivity: VMnet subnet vs guest IP match, DHCP/NAT services, gateway/internet/DNS from inside the guest; `--fix-dhcp` switches static NICs to DHCP and re-checks |
| `snapshot <vm> <name>` | Create snapshot |
| `snapshots <vm> [--tree]` | List snapshots (hierarchical with `--tree`) |
| `revert <vm> <name>` | Restore VM to snapshot |
| `delsnap <vm> <name> [--children]` | Delete snapshot (and its children) |
| `upgrade [--force]` | Update this skill from GitHub; `--force` discards local changes |

## VM name matching

`<vm>` matches case-insensitively by: display name / vmx basename (no extension) / full .vmx path — exact match first, then unique substring. Any path style works: WSL `/mnt/e/...`, Git Bash `/e/...`, Windows `E:\...`. Ambiguous names error with candidates (exit 2); no match lists all known VMs (exit 1).

## Notes

- `soft` stop/suspend/reset, `ip`, `exec` and `netcheck` need VMware Tools in the guest; use `hard` for guests without Tools.
- `exec`/`netcheck` need guest credentials: `-u <user> -p <pass>` flags, or `VMCTL_GUEST_USER`/`VMCTL_GUEST_PASS` env vars. Guest commands run via `/bin/bash` (Linux guests). `netcheck` exits `1` when the guest has no internet.
- Classic "VM has no network" cause that `netcheck` catches: the guest holds a static IP from an old NAT/host-only subnet (e.g. after a VMware upgrade reset the VMnet subnets) — `--fix-dhcp` switches it back to DHCP in one step.
- `stop`/`suspend` on an already-off VM are idempotent; `start` on a running VM is too.
- Snapshots and `revert` work on both running and powered-off VMs; `revert` restores the power state captured in the snapshot.
- Overrides: `VMCTL_VMRUN` (vmrun path), `VMCTL_INVENTORY` (inventory.vmls path). Legacy `VMWARE_VMRUN`/`VMWARE_INVENTORY` also honored.
- In WSL, calls go through Windows interop — identical effect to running on Windows, no extra setup.
- Exit codes: `0` ok · `1` not found / operation failed / netcheck found no internet · `2` ambiguous VM name · `64` usage error.
