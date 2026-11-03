# dsh-test-window

[![dsh-plugin](https://img.shields.io/badge/GitHub%20topic-dsh--plugin-3b82f6)](https://github.com/topics/dsh-plugin) [![awesome-dsh-plugins](https://img.shields.io/badge/awesome--dsh--plugins-PR%20open-6b7280)](https://github.com/cccakeee/awesome-dsh-plugins)


> 给 DeepSeek Harness 的「测试窗口落哪块屏」插件：在设置里选显示器，Agent 拉起的游戏/编辑器/预览窗口就会开在那块屏上，不再盖住 DSH 窗口。

[English](#english) · [安装](#安装) · [快速上手](#快速上手) · [Agent 工具](#agent-工具open_test_window) · [配置](#配置)

---

## 它解决什么

多屏工作时，Agent 用命令拉起的窗口（Godot 游戏、编辑器、`npm run dev` 的浏览器页、预览服……）会按程序自己的习惯出现在随机位置——最常见的是**正好压在 DSH 窗口上**，把对话挡住。

本插件把「测试窗口开在哪」变成一个设置项，并且同时覆盖两条路径：

1. **设置页手动拉起**（`/launch`）
2. **Agent 调用 `open_test_window` 工具**

一次选择，两边都生效。

## 功能

- 🖥️ **显示器选择**：设置页列出真实物理屏幕（DPI 感知、物理像素、含坐标/工作区/是否主屏），点选即存
- 🪟 **自动摆放并保持**：等到进程窗口出现后移动/最大化到目标屏，并在 `settleMs`（默认 6 秒）内持续校正——引擎常会回写自己保存的窗口几何
- 🔁 **失败自动降级**：程序顽固拒绝最大化时，退化为「铺满目标屏工作区」的普通窗口，而不是留下一个越界窗口
- 🎯 **精确判定**：最大化窗口天然比屏幕大 8 像素（边框），判定逻辑对最大化态放宽，不会把正确结果误判成越界
- 🧰 **Agent 工具**：`open_test_window(command, cwd?, displayIndex?, titleContains?, maximize?, topMost?, foreground?, timeoutMs?, settleMs?)`
- 🚪 **如实回报**：窗口被程序关掉会明确返回 `window-closed`，不会假装成功
- 🌐 仅本机：所有 HTTP 路由只接受回环地址

## 环境要求

- **Windows 10/11**（依赖 PowerShell + Win32 窗口 API；macOS/Linux 不支持）
- PowerShell 5.1+（系统自带）
- DeepSeek Harness **>= 0.2.1-rc.2**
- Node.js `^22.19.0 || >=24.0.0`

## 安装

```bash
cd "/d/Program Files/DeepSeek Harness/resources/runtime/cli/bin"
./dsh.cmd plugin --profile desktop add "git+https://github.com/Aily-DSH/dsh-test-window.git"
```

或本地开发：

```bash
dsh plugin --profile desktop add "file:/D:/path/to/dsh-test-window"
```

**装完重启一次 DeepSeek Harness 客户端**（宿主半与注入清单都只在启动时计算）。重启后打开 **设置 → 测试窗口**。

## 快速上手

1. 设置 → 测试窗口，从列表里选一块屏（例如 `2 · 1920×1080 @ 640,-1080`）
2. 勾选「最大化」「置顶」「切到前台」等选项，保存
3. 在「立即启动命令」里填一个命令点启动，例如 `godot --path D:/GC/MyGame`，看窗口是否落在目标屏
4. 之后让 Agent 拉窗口时，它会自动带上这个设置

## Agent 工具：`open_test_window`

给 Agent 用的入口，参数：

| 参数 | 类型 | 说明 |
| --- | --- | --- |
| `command` | string **(必填)** | 打开窗口的程序或 shell 命令，如 `godot --path D:/GC/MyGame`、`npm run dev` |
| `cwd` | string | 工作目录 |
| `displayIndex` | number | 覆盖设置里的显示器（1 起，与设置页一致） |
| `titleContains` | string | 窗口标题子串；命令把窗口交给别的进程时（浏览器）用它命中 |
| `maximize` | boolean | 覆盖「最大化」 |
| `topMost` | boolean | 覆盖「置顶」 |
| `foreground` | boolean | 覆盖「切前台」 |
| `timeoutMs` | number | 等窗口出现的最长毫秒数 |
| `settleMs` | number | 窗口出现后继续校正矩形的时长（慢引擎可调大） |

返回结构含 `window`（`ok / pid / title / x / y / width / height / zoomed / inside / attempts / maximizeFellBack`）与 `display`，并在工具输出里渲染成一句中文说明。

## 配置

配置文件：`~/.dsh/dsh-test-window/config.json`

| 字段 | 默认 | 说明 |
| --- | --- | --- |
| `displayIndex` | `0` | 目标显示器序号（1 起；0 表示未选择） |
| `device` | `""` | 设备名，如 `\\.\DISPLAY2` |
| `maximize` | `true` | 摆放后是否最大化 |
| `topMost` | `false` | 是否置顶 |
| `foreground` | `true` | 是否切到前台 |
| `timeoutMs` | `20000` | 等窗口出现的超时 |
| `settleMs` | `6000` | 窗口出现后持续校正的时长 |
| `lastCommand`/`lastCwd` | `""` | 上次启动的命令，方便复跑 |

路由（仅回环）：

| 路由 | 用途 |
| --- | --- |
| `GET /api/dsh-test-window/state` | 配置、显示器列表、运行中窗口 |
| `POST /api/dsh-test-window/config` | 增量更新配置 |
| `POST /api/dsh-test-window/launch` | 立即启动并摆放一个命令 |
| `POST /api/dsh-test-window/stop` | 停掉本插件拉起的窗口 |

## 工作原理

```
launch(command)
  └─ spawn 子进程（独立控制台，PID 写入 pidFile）
       └─ watch-window.ps1 -Pid <pid> -X/-Y/-W/-H <目标矩形> -Maximize ...
            Phase 1  等窗口出现（-TimeoutMs），先隐藏状态下摆位，再显示，最后最大化
            Phase 2  每 50ms 校验矩形，漂移就重启摆位；最大化最多重试 6 次
            Phase 3  最终校验；窗口已关闭 → reason=window-closed
  └─ 读取结果 JSON，交给设置页或 open_test_window 返回
```

要点：

- 最大化窗口的矩形允许比显示器大 16 像素（`$maximizedOverhang`），否则会把「正确最大化」误判为越界
- 隐藏状态下先 `SetWindowPos` 再 `SW_MAXIMIZE` 会被 Windows 按旧显示器钳制，因此顺序是「显示 → 最大化」
- 引擎（如 Godot 编辑器）会在启动后几百毫秒回写几何，所以需要 settle 阶段持续校正

## 已知限制

- 只支持 Windows
- 用 `titleContains` 时若进程快速换名，可能错过窗口（放宽 `timeoutMs` 或换个更稳的标题片段）
- 全屏（`fullscreen`）模式的程序不受摆位控制
- 需要桌面会话（无人值守/服务会话下窗口 API 不可用）

## 卸载

```bash
dsh plugin --profile desktop remove dsh-test-window
```

删除配置目录 `~/.dsh/dsh-test-window/`（可选）。

## 目录结构

```
lib/index.js              宿主半：配置、路由、启动与等待、工具注册
lib/client.js             客户端半：设置页（显示器列表、选项、立即启动）
lib/scripts/displays.ps1  枚举物理显示器
lib/scripts/watch-window.ps1  等待并摆放窗口（三阶段校正）
cordis.patch.yml          插入插件行
```

## 赞赏

如果这个插件帮你省了钱，欢迎扫码请作者喝一杯 ☕（纯属自愿，不影响使用和更新）

<p align="center">
  <img src="assets/reward-qr.png" alt="赞赏码" width="260">
</p>

## 生态与收录

- **GitHub topic**：[dsh-plugin](https://github.com/topics/dsh-plugin)——DSH 社区约定的插件标记，本仓库已加上
  `dsh` / `dsh-plugin` / `deepseek-harness` / `plugin` 等 topics。
- **社区目录**：已向 [cccakeee/awesome-dsh-plugins](https://github.com/cccakeee/awesome-dsh-plugins) 提交收录 PR；
  收录后可在 [deepseekharnessplugins.com](https://deepseekharnessplugins.com) 与
  [awesome-dsh-plugin.com](https://awesome-dsh-plugin.com) 搜到。
- **客户端插件市场**：DSH 的「设置 → 插件市场」只读**配置里的索引 URL**（不搜 npm）。索引格式 1 的示例见
  [Aily-DSH/dsh-plugin-index](https://github.com/Aily-DSH/dsh-plugin-index)，把它的 jsDelivr 地址加进
  `dsh.profile.indexes` 即可在客户端内直接看到 dsh-test-window。
- **查不到时**：npm / GitHub 搜索有索引延迟，新包一般 1–3 天；先用
  `dsh plugin --profile desktop add git+https://github.com/Aily-DSH/dsh-test-window.git` 直接装。

## English

**dsh-test-window** picks the monitor that Agent-launched test windows open on. Choose a display once in Settings → 测试窗口 and every window started through the settings page or the `open_test_window` agent tool is moved, maximized and kept there — so a game or editor never pops up on top of the chat. Windows-only; uses two PowerShell helpers for DPI-aware monitor enumeration and a three-phase window-placement loop that survives apps restoring their own geometry.

```bash
dsh plugin --profile desktop add "git+https://github.com/Aily-DSH/dsh-test-window.git"
# restart the client once
```

**Sponsor:** if this plugin saved you money, you can buy the author a coffee — scan `assets/reward-qr.png`.

## License

[MIT](./LICENSE)
