# vmctl

**English** | [简体中文](README.zh-CN.md)

**A cross-platform agent skill for controlling local VMware Workstation virtual machines.**

`vmctl` wraps VMware's `vmrun` CLI so that AI coding agents (Kimi Code, Claude Code, Codex, or any agent that loads `.agents/skills` skills) can power VMs on/off, manage snapshots, and query state — from **Windows (Git Bash)** or **WSL**, with zero manual configuration.

```
vmctl start UbuntuServer1          # power on, headless
vmctl stop "Windows Server 2019"   # graceful shutdown
vmctl snapshot UbuntuServer1 pre-upgrade
vmctl revert UbuntuServer1 pre-upgrade
```

## Why

- Agents frequently need to boot/stop VMs for testing, but `vmrun` paths differ per machine, its output is Windows-flavored (CRLF, GBK), and WSL adds path-translation and interop quirks.
- `vmctl` handles all of that once, so every agent on the machine gets a reliable VM toolbox.

Features:

- **Power ops** — `start` (headless or `--gui`), `stop` (`soft`/`hard`), `suspend`, `reset`, `status`, guest `ip`
- **Snapshots** — create / list (`--tree`) / revert / delete (`--children`)
- **Smart VM discovery** — reads VMware's `inventory.vmls`, matches by display name, vmx basename, or full path (any path style)
- **Robust vmrun detection** — env var → cache (`~/.config/vmctl/paths`) → `PATH` → common install locations on every drive → Windows registry; cached after first success
- **Windows + WSL + Linux + macOS (Fusion)** — automatic path/encoding/line-ending translation
- Idempotent power ops, clear exit codes (`0` ok · `1` not found/failed · `2` ambiguous name · `64` usage)

## Install

The repo *is* the skill — clone it into your agent skills directory.

**Windows (Git Bash):**

```bash
git clone https://github.com/realweng/vmctl ~/.agents/skills/vmctl
bash ~/.agents/skills/vmctl/scripts/vmctl.sh doctor
```

**WSL:**

```bash
git clone https://github.com/realweng/vmctl ~/.agents/skills/vmctl
bash ~/.agents/skills/vmctl/scripts/vmctl.sh doctor
```

**Linux / macOS (VMware Fusion):** same as above; on Linux install `vmrun` (from VMware Workstation for Linux) anywhere on `PATH`.

`doctor` verifies the setup and caches the detected `vmrun` path. That's it — restart your agent session and the `vmctl` skill appears.

> Requirements: bash, `iconv` (usually preinstalled); VMware Workstation on Windows (interop enabled in WSL — the default) or VMware Fusion on macOS.

**Update:** `bash ~/.agents/skills/vmctl/scripts/vmctl.sh upgrade [--force]` — fast-forwards the git clone (or re-downloads if installed by copy); `--force` discards local changes.

## Usage

```
vmctl.sh doctor                              # show env / vmrun / inventory, refresh cache
vmctl.sh list                                # all VMs + state
vmctl.sh status <vm>
vmctl.sh start <vm> [--gui]                  # default: headless (nogui)
vmctl.sh stop <vm> [soft|hard]               # default: soft (graceful, needs VMware Tools)
vmctl.sh suspend <vm> [soft|hard]
vmctl.sh reset <vm> [soft|hard]
vmctl.sh ip <vm> [--wait]
vmctl.sh snapshot <vm> <name>                # create snapshot
vmctl.sh snapshots <vm> [--tree]             # list snapshots
vmctl.sh revert <vm> <name>                  # restore snapshot
vmctl.sh delsnap <vm> <name> [--children]    # delete snapshot
vmctl.sh upgrade [--force]                   # update this skill from GitHub
```

`<vm>` matches case-insensitively by display name, vmx basename, or full `.vmx` path (exact match first, then unique substring; e.g. `server2` → `UbuntuServer2`). Ambiguity is reported with candidates.

### Environment variables (optional)

| Variable | Purpose |
|---|---|
| `VMCTL_VMRUN` | Full path to `vmrun`/`vmrun.exe` when auto-detection can't find it |
| `VMCTL_INVENTORY` | Full path to `inventory.vmls` when the default location isn't found |

## How it works

- **vmrun discovery** — `VMCTL_VMRUN` → cached path → `command -v vmrun` → common install paths (every drive letter on Windows, `/mnt/*/` in WSL, Fusion bundle on macOS) → Windows uninstall registry (`DisplayIcon` of "VMware Workstation"). Result cached in `~/.config/vmctl/paths`.
- **VM inventory** — parses `%APPDATA%\VMware\inventory.vmls` (GBK-decoded, CRLF-stripped); running VMs come from `vmrun list`.
- **WSL support** — calls the Windows `vmrun.exe` through interop; translates paths both ways (`wslpath`/`cygpath`), strips CRLF from output, and guards stdin against interop quirks.

## Troubleshooting

- **`vmrun not found`** — run `vmctl.sh doctor`; if it still fails, set `VMCTL_VMRUN=/path/to/vmrun(.exe)`.
- **`soft` stop fails / no guest IP** — guest lacks VMware Tools; use `hard`, install `open-vm-tools` (Linux) or VMware Tools (Windows).
- **WSL: interop disabled** — ensure `/etc/wsl.conf` doesn't disable it (`[interop] enabled=true`, the default), then `wsl --shutdown` and retry.

## License

[MIT](LICENSE)

