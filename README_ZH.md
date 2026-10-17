# Live Title

为 Claude Code 自动生成有意义的标题，随对话推进动态更新。原名 `claude-live-title`。

[![Release](https://img.shields.io/github/v/release/macworld/claude-live-title)](https://github.com/macworld/claude-live-title/releases)
[![License](https://img.shields.io/github/license/macworld/claude-live-title)](LICENSE)
[![Stars](https://img.shields.io/github/stars/macworld/claude-live-title)](https://github.com/macworld/claude-live-title/stargazers)

[English](README.md) | 中文

![演示：Live Title 根据第一条消息给 Claude Code 会话起标题，任务变了标题跟着变，在多个标签页和 /resume 里都能一眼认出每个会话](assets/demo-zh.gif)

## 为什么需要它？

Claude Code 会根据你的第一条消息给会话起标题，之后就不再改。但会话会往前走：你从排查一个分页 Bug 开始，最后可能在改造所有列表接口。Live Title 让每个会话的标题始终对应它**当前**在做的事。

| 你说的话 | Claude Code 的标题 | Live Title |
|---|---|---|
| 用户反馈订单列表翻到第二页，会看到和第一页重复的订单，帮我查一下 | 订单列表分页重复订单 | 订单列表翻页重复问题排查 |
| 干脆把所有列表接口都改成游标分页吧 | 订单列表分页重复订单 | 所有列表接口改用游标分页 |
| 好，开始吧 | 订单列表分页重复订单 | 所有列表接口改用游标分页 |

- **有了任务才起标题。** 描述一个 Bug，会话就以它命名；只说一句"你好"或发条测试消息，会话先不命名，等有了任务再起。
- **任务变了，标题跟着变。** 工作换了方向，标题随之更新；回一句"好，开始吧"，标题保持不动。
- **随时找回。** 在多个标签页、tmux 或分屏里同时开着几个会话，看一眼标签页或状态栏就知道哪个是哪个；在 `/resume` 里，以前的会话按标题列出。
- **想要固定格式也可以。** 可选的命名规则，比如标题以工单号开头，对所有会话生效或按项目单独设置。

表格和演示里的标题都是 Claude Code 和插件针对这些消息实际生成的。演示里的状态栏是开启了 `showSessionName` 的 [Claude HUD](#配合-claude-hud-使用)。

## 特性

- **跟着当前任务走** — 你换了一个任务，标题也跟着换
- **稳定** — 还在做同一件事时标题不动；回一句"好""继续""ok"不会让标题被改写
- **等有了任务再起名** — 打招呼或测试消息不会生成标题，你提出要做的事之后才命名
- **自定义命名格式** — 用一句话写下规则，比如工单号开头、类型前缀，可全局设置也可按项目设置（见[命名格式](#命名格式)）
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
3. **UserPromptSubmit（同步）** — Claude Code 自己保留一份标题：终端标签页和状态栏显示的是这一份，它也会被写回 transcript。这个 hook 通过官方的 `sessionTitle` 字段把最新标题交给 Claude Code，让两边保持一致。它不调用模型，大约 20 ms 完成。

模型（默认 Haiku）看到的是一份简短的会话摘要：

- **`CURRENT_TITLE`** — 当前显示的标题。只要工作没换方向就原样保留，标题不会来回变。
- **`FIRST`** — 你的第一条消息，用来理解后面简短的跟进。
- **`EARLIER`** — 最新一条之前的几条近期消息（最多 `contextMessages.tail` 条）。
- **`LATEST`** — 你的最新一条消息，最重要的信号。
- **`CLAUDE`** — Claude 最新回复的摘录，作为辅助信息。

过长的消息只保留开头和结尾。Claude 的回复会先清洗：去掉代码块、行内代码、堆栈帧和 shell 提示符行（规则在 `hooks/lib/sanitize-line-rules.tsv`），剩下的文字太少就整段不用。

模型只把对话当作要起标题的材料，从不当作指令，所以你贴进会话的提示词不会左右标题。如果你的消息里还没有任务（打招呼、测试消息、闲聊），模型回答 `SKIP`，什么都不写。

模型调用通过 `claude -p` 进行，不带工具、不保存会话。如果返回的标题超过 `maxLength`，最多再调用两次让它缩短。结果作为 `custom-title` 记录写入 transcript。

```mermaid
flowchart LR
    A[你发送消息] --> B{是你输入的？<br/>不只是"好"？<br/>没被节流？}
    B -->|否| D[之后由 Stop hook 补上]
    B -->|是| E["CURRENT_TITLE + FIRST +<br/>EARLIER + LATEST + CLAUDE"]
    E --> F[Haiku 生成标题]
    F --> G[追加 custom-title<br/>到 transcript]
    G --> H[显示在 /resume、<br/>标签页和状态栏]
```

## 安装

有两种安装方式，任选其一，然后重启 Claude Code。

### 从 Anthropic 官方目录安装（推荐）

已收录在 [`claude-plugins-community`](https://github.com/anthropics/claude-plugins-community)，用的还是旧名 `claude-live-title`。每个新版本都要先过 Anthropic 的审核，所以那边的版本可能比本仓库旧。

```
/plugin marketplace add anthropics/claude-plugins-community
/plugin install claude-live-title@claude-community
```

### 从本仓库直接安装（永远最新）

```
/plugin marketplace add macworld/claude-live-title
/plugin install live-title@claude-live-title
```

### 然后重启 Claude Code

Hook 只在启动时注册，必须完整重启才能生效 —— `/reload-plugins` 只能重载 command 和 skill，不能重载 hook。插件开箱即用，无需任何配置。

### 从 claude-live-title 升级

插件在 2.0 从 `claude-live-title` 改名为 `live-title`。用 `--keep-data` 卸载旧插件，安装新插件，然后重启。配置和各会话的标题都会自动带过来。

```bash
claude plugin uninstall claude-live-title@claude-live-title --keep-data
claude plugin marketplace update claude-live-title
claude plugin install live-title@claude-live-title
```

如果当初是从官方社区目录安装的，不用重装：那边的条目还是旧名。

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
/live-title:config
```

或直接编辑配置文件。它在插件的数据目录里，目录名取决于你从哪个 marketplace 安装，例如：

```
~/.claude/plugins/data/live-title-claude-live-title/config.json
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

  // 你的命名规则，用自然语言写（默认：无）
  // 项目里的 .claude/live-title.md 会在该项目中取代这一项
  "style": "",

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

### 命名格式

默认的标题是一个简短的短语。想要固定格式，就在 `style` 里描述它：

```json
{
  "style": "标题格式：「模块：做什么」，比如「订单：导出按钮无响应」。"
}
```

规则用中文或英文写都可以。比如这一条：

```json
{
  "style": "Start the title with the ticket ID in square brackets, like [PROJ-123], when the user mentions one."
}
```

`PROJ-1423: the login form accepts an empty password, fix it` 得到的标题是 `[PROJ-1423] Fix empty password`。

只想给某个项目设规则，就写在项目根目录的 `.claude/live-title.md` 里。它会在这个项目的会话中取代 `style`，提交到仓库后整个团队用同一种格式。另一条好用的规则：

- `Begin the title with one of feat:, fix:, docs:, refactor:, chore: and then a short lowercase summary.`

规则最长 1000 个字符，`maxLength` 照样生效。

## 标题显示在哪里

- **`/resume`** 按标题列出以前的会话。
- **终端标签页。** Claude Code 会把会话标题设为终端标题（在 tmux 里是 pane 标题），不用额外设置。
- **你的状态栏。** Claude Code 会把标题作为 `session_name` 传给状态栏命令。最简单的显示方式，写在 `~/.claude/settings.json` 里：

  ```json
  {
    "statusLine": {
      "type": "command",
      "command": "jq -r '.session_name // empty'"
    }
  }
  ```

- **[Claude HUD](#配合-claude-hud-使用)**，需开启 `showSessionName`。

标签页和 `session_name` 要等你发下一条消息时才换上新标题，因为 Claude Code 只在这个时机接受插件给的标题。插件的第一个标题到来之前，它们显示 Claude Code 自己起的标题。

## 配合 Claude HUD 使用

[Live Title](https://github.com/macworld/claude-live-title) 可与 [Claude HUD](https://github.com/jarrodwatts/claude-hud) 配合使用：会话标题会显示在 HUD 状态栏中。

### 设置步骤

1. 安装两个插件：

   ```
   /plugin marketplace add macworld/claude-live-title
   /plugin install live-title@claude-live-title
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

3. 开始新对话。状态栏会显示会话标题，并随工作推进更新。

### 集成原理

Live Title 把 `custom-title` 记录写入会话 transcript，并把最新标题交给 Claude Code。新版 HUD 显示的是 Claude Code 传给状态栏的 `session_name`，它在你发下一条消息时换上新标题；旧版 HUD 直接从 transcript 读取 `custom-title` 记录。

## 系统要求

- Claude Code 2.1.x 或更高版本
- `jq`（JSON 处理器）— 大多数系统已预装，或通过包管理器安装
- Linux 或 macOS（Windows 用户需要 Git Bash 或 WSL）

## 常见问题

**Claude Code 不是已经会给会话起名了吗？**
它根据第一条消息起标题，之后整个会话都用这一个。Live Title 会在工作换方向时给会话改名，还可以按你设定的格式起名。

**为什么标签页上的新标题晚一条消息才出现？**
Claude Code 只在你发送消息时接受插件给的标题。标题是在 Claude 回复期间生成的，所以标签页和状态栏要等你发下一条消息时才换上。`/resume` 读取 transcript，能立刻看到。

## 故障排查

**会话没有标题？**
打招呼或测试消息不会生成标题，你提出要做的事之后，会话才会命名。

**标题没有出现？**
1. 确认插件已安装并启用：在已启用插件列表中查找 `live-title`
2. 安装或更新后重启 Claude Code，hook 只在启动时加载
3. 在配置中设置 `"debug": true`，然后查看 `~/.claude/plugins/data/live-title-*/debug.log`

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

# 每个 fixture 跑 4 次，抓出偶尔才出错的标题
RUN_LIVE=1 SAMPLES=4 bash tests/test-fixtures.sh
```

## 更多

- [更新日志](CHANGELOG.md) —— 版本记录和发布说明
- [隐私政策](PRIVACY.md) —— 本地运行范围，以及什么数据不会离开你的机器

## 许可证

MIT
