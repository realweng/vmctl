---
name: vmctl
description: Control local VMware Workstation VMs — power on/off, suspend, reset, guest IP, and snapshot create/revert/delete/list. Use when user wants to start/stop/power on/off/suspend a VMware VM (虚拟机), take, restore or delete snapshots, list local VMs, or check VM status. 支持开启、关闭、挂起、重启虚拟机与快照管理，Windows (Git Bash) 与 WSL 通用。
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
| `snapshot <vm> <name>` | Create snapshot |
| `snapshots <vm> [--tree]` | List snapshots (hierarchical with `--tree`) |
| `revert <vm> <name>` | Restore VM to snapshot |
| `delsnap <vm> <name> [--children]` | Delete snapshot (and its children) |

## VM name matching

`<vm>` matches case-insensitively by: display name / vmx basename (no extension) / full .vmx path — exact match first, then unique substring. Any path style works: WSL `/mnt/e/...`, Git Bash `/e/...`, Windows `E:\...`. Ambiguous names error with candidates (exit 2); no match lists all known VMs (exit 1).

## Notes

- `soft` stop/suspend/reset and `ip` require VMware Tools in the guest; use `hard` for guests without Tools.
- `stop`/`suspend` on an already-off VM are idempotent; `start` on a running VM is too.
- Snapshots and `revert` work on both running and powered-off VMs; `revert` restores the power state captured in the snapshot.
- Overrides: `VMCTL_VMRUN` (vmrun path), `VMCTL_INVENTORY` (inventory.vmls path). Legacy `VMWARE_VMRUN`/`VMWARE_INVENTORY` also honored.
- In WSL, calls go through Windows interop — identical effect to running on Windows, no extra setup.
- Exit codes: `0` ok · `1` not found / operation failed · `2` ambiguous VM name · `64` usage error.
