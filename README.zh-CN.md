# vmctl

**跨平台的本机 VMware Workstation 虚拟机控制 Agent Skill。**

`vmctl` 封装了 VMware 的 `vmrun` 命令行，让 AI 编程助手（Kimi Code、Claude Code、Codex 等任何加载 `.agents/skills` 技能的 agent）可以直接开关虚拟机、管理快照、查询状态 —— 在 **Windows (Git Bash)** 或 **WSL** 下均可使用，无需手动配置。

```
vmctl start UbuntuServer1          # 无界面开机
vmctl stop "Windows Server 2019"   # 优雅关机
vmctl snapshot UbuntuServer1 pre-upgrade
vmctl revert UbuntuServer1 pre-upgrade
```

## 为什么需要它

- agent 经常需要开机/关机虚拟机做测试，但 `vmrun` 的安装路径因人而异，输出还带 Windows 特性（CRLF、GBK 编码），WSL 下更有路径转换和 interop 的坑。
- `vmctl` 把这些一次性处理好，机器上所有 agent 都能获得可靠的虚拟机操作能力。

功能：

- **电源操作** —— `start`（后台或 `--gui`）、`stop`（`soft`/`hard`）、`suspend`、`reset`、`status`、客户机 `ip`
- **快照管理** —— 创建 / 列表（`--tree`）/ 恢复 / 删除（`--children`）
- **智能虚拟机发现** —— 读取 VMware 的 `inventory.vmls`，按显示名、vmx 文件名或完整路径匹配（任意路径风格）
- **健壮的 vmrun 探测** —— 环境变量 → 缓存（`~/.config/vmctl/paths`）→ `PATH` → 各盘符常见安装位置 → Windows 注册表；首次成功后缓存
- **Windows + WSL + Linux + macOS (Fusion)** —— 自动转换路径 / 编码 / 行尾
- 电源操作幂等，退出码清晰（`0` 成功 · `1` 未找到/失败 · `2` 名称歧义 · `64` 用法错误）

## 安装

本仓库本身就是 skill，克隆到你的 agent 技能目录即可。

**Windows (Git Bash)：**

```bash
git clone https://github.com/realweng/vmctl ~/.agents/skills/vmctl
bash ~/.agents/skills/vmctl/scripts/vmctl.sh doctor
```

**WSL：**

```bash
git clone https://github.com/realweng/vmctl ~/.agents/skills/vmctl
bash ~/.agents/skills/vmctl/scripts/vmctl.sh doctor
```

**Linux / macOS (VMware Fusion)：** 同上；Linux 需将 `vmrun`（来自 Linux 版 VMware Workstation）加入 `PATH`。

`doctor` 会验证环境并缓存探测到的 `vmrun` 路径。重启 agent 会话后即可看到 `vmctl` 技能。

> 依赖：bash、`iconv`（一般都自带）；Windows 上装 VMware Workstation（WSL 需启用 interop，默认开启），macOS 装 VMware Fusion。

## 使用

```
vmctl.sh doctor                              # 显示环境 / vmrun / 清单，刷新缓存
vmctl.sh list                                # 列出所有虚拟机及状态
vmctl.sh status <vm>
vmctl.sh start <vm> [--gui]                  # 默认后台无界面 (nogui)
vmctl.sh stop <vm> [soft|hard]               # 默认 soft（优雅关机，需 VMware Tools）
vmctl.sh suspend <vm> [soft|hard]
vmctl.sh reset <vm> [soft|hard]
vmctl.sh ip <vm> [--wait]
vmctl.sh snapshot <vm> <name>                # 创建快照
vmctl.sh snapshots <vm> [--tree]             # 列出快照
vmctl.sh revert <vm> <name>                  # 恢复快照
vmctl.sh delsnap <vm> <name> [--children]    # 删除快照
```

`<vm>` 按显示名、vmx 文件名或完整 `.vmx` 路径不区分大小写匹配（先精确，再唯一子串；如 `server2` → `UbuntuServer2`）。匹配多台时会报错并列出候选。

### 环境变量（可选）

| 变量 | 用途 |
|---|---|
| `VMCTL_VMRUN` | 自动探测失败时，手动指定 `vmrun`/`vmrun.exe` 完整路径 |
| `VMCTL_INVENTORY` | 默认位置找不到 `inventory.vmls` 时手动指定 |

## 工作原理

- **vmrun 探测** —— `VMCTL_VMRUN` → 缓存 → `command -v vmrun` → 常见安装路径（Windows 所有盘符、WSL 的 `/mnt/*/`、macOS 的 Fusion bundle）→ Windows 卸载注册表（"VMware Workstation" 的 `DisplayIcon`）。结果缓存到 `~/.config/vmctl/paths`。
- **虚拟机清单** —— 解析 `%APPDATA%\VMware\inventory.vmls`（GBK 解码、去 CRLF）；运行中的虚拟机来自 `vmrun list`。
- **WSL 支持** —— 通过 interop 调用 Windows 的 `vmrun.exe`；双向转换路径（`wslpath`/`cygpath`）、去除输出中的 CRLF、并防护 interop 吞 stdin 的问题。

## 故障排查

- **`vmrun not found`** —— 运行 `vmctl.sh doctor`；仍失败则设置 `VMCTL_VMRUN=/path/to/vmrun(.exe)`。
- **`soft` 关机失败 / 拿不到 IP** —— 客户机未装 VMware Tools；用 `hard`，或在客户机内安装 `open-vm-tools`（Linux）/ VMware Tools（Windows）。
- **WSL：interop 被禁用** —— 检查 `/etc/wsl.conf` 未禁用（`[interop] enabled=true` 为默认），然后 `wsl --shutdown` 后重试。

## 许可证

[MIT](LICENSE)
