# Claude Live Title

为 Claude Code 自动生成有意义的标题，随对话推进动态更新。

[![License](https://img.shields.io/github/license/macworld/claude-live-title)](LICENSE)
[![Stars](https://img.shields.io/github/stars/macworld/claude-live-title)](https://github.com/macworld/claude-live-title/stargazers)

[English](README.md) | 中文

## 为什么需要它？

Claude Code 默认用随机 slug（如 `elegant-chasing-eich`）作为会话名。根据第一条消息起标题能好一些，但会话会往前走：你从修登录 Bug 开始，最后可能在重构认证中间件。

claude-live-title 让标题始终对应会话**当前**在做的事。如果你在 tmux 或多个终端里同时开着几个会话，看一眼状态栏就知道哪个是哪个、上次做到哪。搭配 [Claude HUD](#配合-claude-hud-使用) 可以直接在状态栏显示标题。

## 特性

- **跟着当前任务走** — 你换了一个任务，标题也跟着换
- **稳定** — 还在做同一件事时标题不动；回一句"好""继续""ok"不会让标题被改写
- **只看你说的话** — 后台任务通知、子 agent 的回报、skill 说明、压缩摘要都不算
- **出错不乱写** — 账号用量到达上限或 API 出错时什么都不写，插件暂停一会儿再试
- **尊重你起的名字** — 用 `/rename` 或 `--name` 命名过的会话，插件不再改动
- **多语言** — 默认用你说话的语言，也可以指定
- **轻量** — 每次更新一次小的 Haiku 调用（约 1.5K token，$0.0001），全部在后台运行
- **跨平台** — 支持 Linux 和 macOS

## 工作原理

插件用三个 hook：

1. **UserPromptSubmit（异步）** — 你发送消息时，在 Claude 回复的同时生成新标题。每 `throttleInterval` 秒最多一次，被跳过的消息由 Stop hook 补上。
2. **Stop（异步）** — 每次回复结束后运行。会话还没有标题时起一个；补上被节流跳过的消息；长时间自主运行时每 15 分钟刷新一次；如果 Claude Code 把旧标题写回了 transcript，就恢复成最新的。
3. **UserPromptSubmit（同步）** — `/resume`、`/compact` 或改名之后，Claude Code 会自己保留一份标题，并不断写回 transcript。这个 hook 通过官方的 `sessionTitle` 字段把最新标题交给 Claude Code，让两边保持一致。它不调用模型，大约 20 ms 完成。

模型（默认 Haiku）看到的是一份简短的会话摘要：

- **`CURRENT_TITLE`** — 当前显示的标题。只要工作没换方向就原样保留，标题不会来回变。
- **`FIRST`** — 你的第一条消息，用来理解后面简短的跟进。
- **`EARLIER`** — 最新一条之前的几条近期消息（最多 `contextMessages.tail` 条）。
- **`LATEST`** — 你的最新一条消息，最重要的信号。
- **`CLAUDE`** — Claude 最新回复的摘录，作为辅助信息。

过长的消息只保留开头和结尾。Claude 的回复会先清洗：去掉代码块、行内代码、堆栈帧和 shell 提示符行（规则在 `hooks/lib/sanitize-line-rules.tsv`），剩下的文字太少就整段不用。

模型调用通过 `claude -p` 进行，不带工具、不保存会话。如果返回的标题超过 `maxLength`，会再调用一次让它缩短。结果作为 `custom-title` 记录写入 transcript。

```mermaid
flowchart LR
    A[你发送消息] --> B{是你输入的？<br/>不只是"好"？<br/>没被节流？}
    B -->|否| D[之后由 Stop hook 补上]
    B -->|是| E["CURRENT_TITLE + FIRST +<br/>EARLIER + LATEST + CLAUDE"]
    E --> F[Haiku 生成标题]
    F --> G[追加 custom-title<br/>到 transcript]
    G --> H[HUD 在状态栏<br/>显示标题]
```

## 安装

有两种安装方式，任选其一，然后重启 Claude Code。

### 从 Anthropic 官方目录安装（推荐）

已收录在 [`claude-plugins-community`](https://github.com/anthropics/claude-plugins-community)。官方目录每周批量同步一次，所以那边的版本可能比本仓库晚几天。

```
/plugin marketplace add anthropics/claude-plugins-community
/plugin install claude-live-title@claude-plugins-community
```

### 从本仓库直接安装（永远最新）

```
/plugin marketplace add macworld/claude-live-title
/plugin install claude-live-title@claude-live-title
```

### 然后重启 Claude Code

Hook 只在启动时注册，必须完整重启才能生效 —— `/reload-plugins` 只能重载 command 和 skill，不能重载 hook。插件开箱即用，无需任何配置。

<details>
<summary><strong>Linux 上安装报 <code>EXDEV: cross-device link not permitted</code>？</strong></summary>

很多 Linux 发行版的 `/tmp` 是独立的 tmpfs，会导致插件安装失败。启动 Claude Code 前把 TMPDIR 指到 home 目录下：

```bash
mkdir -p ~/.cache/tmp && TMPDIR=~/.cache/tmp claude
```

然后在该会话中执行上面的安装命令。

</details>

## 配置

配置完全可选，所有设置都有合理的默认值。

使用斜杠命令交互式配置：

```
/claude-live-title:config
```

或直接编辑配置文件。它在插件的数据目录里，目录名取决于你从哪个 marketplace 安装，例如：

```
~/.claude/plugins/data/claude-live-title-claude-live-title/config.json
```

```jsonc
{
  // 标题生成模型（默认："haiku"）
  "model": "haiku",

  // 标题语言（默认："auto"，即你说话的语言）
  // 可设为 "zh"、"en"、"ja"、"ko" 等指定语言
  "language": "auto",

  // 标题最大显示列宽（默认：30）
  // CJK 字符算 2 列，拉丁字符算 1 列
  "maxLength": 30,

  // 模型能看到你的多少条消息
  "contextMessages": {
    "head": 1,  // 最早的几条（默认：1）
    "tail": 5   // 最近的几条（默认：5）
  },

  // 你连续发消息时，两次更新之间的最小秒数（默认：60）
  "throttleInterval": 60,

  // 随会话推进更新标题（默认：true）
  // 设为 false：第一次回复后起一个标题，之后不再改
  "liveUpdate": true,

  // 在插件数据目录写调试日志（默认：false）
  "debug": false
}
```

### 语言设置

默认情况下（`"auto"`），标题使用你自己消息的语言，即使代码和 Claude 的回复是英文。

如果你用英文和 Claude 交流，但希望标题用中文，可以明确设置：

```json
{
  "language": "zh"
}
```

## 配合 Claude HUD 使用

[claude-live-title](https://github.com/macworld/claude-live-title) 可与 [Claude HUD](https://github.com/jarrodwatts/claude-hud) 无缝配合。生成的标题会自动显示在 HUD 状态栏中。

### 设置步骤

1. 安装两个插件：

   ```
   /plugin marketplace add macworld/claude-live-title
   /plugin install claude-live-title
   /plugin marketplace add jarrodwatts/claude-hud
   /plugin install claude-hud
   ```

2. 在 HUD 中启用会话名称显示（默认关闭）：

   ```
   /claude-hud:configure
   ```

   将 `showSessionName` 设为 `true`。或手动编辑配置：

   ```json
   // ~/.claude/plugins/claude-hud/config.json
   {
     "display": {
       "showSessionName": true
     }
   }
   ```

3. 开始新对话 — 发送第一条消息后，标题就会出现在状态栏中，并随对话演进实时更新。

### 集成原理

claude-live-title 将 `custom-title` 记录写入会话 transcript 文件。Claude HUD 读取这些记录并在状态栏显示最新标题，替代默认的随机 slug。标题会随对话推进实时更新。

## 系统要求

- Claude Code 2.1.x 或更高版本
- `jq`（JSON 处理器）— 大多数系统已预装，或通过包管理器安装
- Linux 或 macOS（Windows 用户需要 Git Bash 或 WSL）

## 常见问题

**标题没有出现？**
1. 确认插件已安装并启用：在已启用插件列表中查找 `claude-live-title`
2. 安装或更新后重启 Claude Code，hook 只在启动时加载
3. 在配置中设置 `"debug": true`，然后查看 `~/.claude/plugins/data/claude-live-title-*/debug.log`

**某个会话不再更新了？**
- 如果你给它改过名（`/rename`、`--name`），插件会刻意保留你的名字。
- 遇到用量上限后插件会暂停 10 分钟（其他错误暂停 2 分钟），避免反复撞上限。

**标题语言不对？**
在配置中明确设置 `language`。

**更新太频繁或太少？**
调整配置中的 `throttleInterval`（秒）。

**遇到了离谱标题？欢迎帮我们改进。**
开启 `"debug": true` 后，每次生成标题都会在调试日志里记下模型真正看到的输入。运行 `bin/promote-fixture.sh <slug>` 可以把最近一条固化成 `tests/fixtures/transcripts/` 下的回归 fixture，附在 issue 或 PR 里提交即可。

## 开发

```bash
git clone https://github.com/macworld/claude-live-title
cd claude-live-title

# 从源码目录加载插件进行开发
claude --plugin-dir .
```

本地开发时，`--plugin-dir` 直接从工作目录加载插件，无需安装或缓存。修改 hook 需要重启会话；修改 command/skill 可用 `/reload-plugins` 热重载。

运行测试：

```bash
for t in tests/test-*.sh; do bash "$t"; done

# 再用真实模型检查 fixture（花费不到一美分）
RUN_LIVE=1 bash tests/test-fixtures.sh
```

## 更多

- [更新日志](CHANGELOG.md) —— 版本记录和发布说明
- [隐私政策](PRIVACY.md) —— 本地运行范围，以及什么数据不会离开你的机器

## 许可证

MIT
