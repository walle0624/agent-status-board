# AI-SETUP — 给 AI 助手的安装/配置说明（请直接执行）

> **你（AI 助手）正在帮用户安装这个 macOS 桌面组件。** 这个文件是写给你执行的，不是给人读的。
> 请**按顺序执行下面的命令**。遇到标了 **【需要问用户】** 的地方，停下来向用户要信息（API key、是否有 Claude 订阅等）或提示用户去浏览器授权。所有命令默认在**本解压目录的根目录**下运行。

它是什么：macOS 14+ 的桌面悬浮组件 + 菜单栏指示灯，实时显示用户的 **Codex** 和 **Claude Code（CC）** 会话状态（正在执行 / 需要处理 / 今日完成）和 **用量**（5 小时 / 每周 + 重置时间）。

---

## 执行总览（checklist）

1. 检查前提（macOS + Swift 工具链）
2. 编译 App 并开启自启
3. 安装事件 hooks（让组件能实时拿到会话状态）
4. **配置 LLM 分类器**（用户现在用「百炼」；可切换任意 OpenAI 兼容厂商）— 需要用户的 API key
5. **配置 CC 登录认证**（用量面板需要）— 需要用户在浏览器授权
6. 验证

---

## 1. 前提检查

```bash
sw_vers -productVersion          # 需要 macOS 14 或更高
swift --version                  # 需要 Swift 工具链
```
若 `swift` 不存在：执行 `xcode-select --install`，让用户在弹窗里点“安装”，装完再继续。

---

## 2. 编译 App + 开机自启

```bash
./script/build_and_run.sh package          # 编译 release 到 dist/AgentStatusBoard.app
bash script/agent-hooks/autostart.sh on    # 安装到 ~/Applications + 写 LaunchAgent + 立即启动
```
> 从源码本地编译，不会触发 Gatekeeper 拦截。完成后桌面右上角应出现深色玻璃组件、菜单栏出现一颗 LED 药丸。

---

## 3. 安装事件 hooks

```bash
bash script/agent-hooks/install.sh
```
这会（自动备份后）改两个配置、并把运行脚本装到 `~/.agent-status-board/bin/`：
- `~/.claude/settings.json` —— Claude Code 的生命周期 hooks
- `~/.codex/config.toml` —— Codex 的官方 hooks

**【需要问用户】Codex 必须信任 hooks**：让用户在 Codex 里执行一次 `/hooks` 并信任；或启动 Codex 时加 `--dangerously-bypass-hook-trust`。否则 Codex 状态不会更新。

> 提示：在交互式终端里 `install.sh` 末尾会自动调起第 4 步的 LLM 配置向导；非交互运行则会跳过，你按第 4 步手动配。

---

## 4. 配置「需要处理」AI 分类器（**切换 LLM 在这里**）

**作用**：每个会话回合结束后，用一个小模型读对话尾部，判断该会话是否在「等用户操作」，并写一句话摘要。**支持任意 OpenAI 兼容接口**。配置文件：`~/.agent-status-board/classify.json`。

**【需要问用户】**向用户确认用哪个 LLM 提供商，并向用户索取 **API key**。用户目前用的是**阿里百炼（DashScope）**。

你可以**直接写配置文件**（推荐，省去交互）：

```bash
mkdir -p ~/.agent-status-board
# —— 阿里百炼 DashScope（OpenAI 兼容，用户当前用的就是它）——
cat > ~/.agent-status-board/classify.json <<EOF
{"provider":"openai","base_url":"https://dashscope.aliyuncs.com/compatible-mode/v1","api_key":"<把用户的 DASHSCOPE_API_KEY 填这里>","model":"qwen-plus"}
EOF
chmod 600 ~/.agent-status-board/classify.json
```

换别的厂商只改 `base_url` / `model`（`api_key` 换成对应厂商的）：

| 厂商 | base_url | model 示例 |
|---|---|---|
| 阿里百炼 DashScope | `https://dashscope.aliyuncs.com/compatible-mode/v1` | `qwen-plus`（或 `qwen-max`） |
| OpenAI | `https://api.openai.com/v1` | `gpt-4o-mini` |
| DeepSeek | `https://api.deepseek.com/v1` | `deepseek-chat` |
| 本地 Ollama | `http://localhost:11434/v1` | `qwen2.5`（本地无需 key，可留空字符串） |

或者跑交互向导（菜单式，隐藏输入 key）：
```bash
bash ~/.agent-status-board/bin/configure-llm.sh
```

还有一种**本地百炼 CLI** 路子（用户已 `bl` 登录时，无需 key）：`{"provider":"bl","model":"qwen3.7-max"}`。

> **安全**：`api_key` 是机密。从用户那里拿到后写进文件即可，**不要打印到输出里**。文件权限设 600。
> 环境变量也可覆盖：`ASB_LLM_BASE_URL` / `ASB_LLM_API_KEY` / `ASB_LLM_MODEL` / `ASB_LLM_PROVIDER`。

---

## 5. 配置 CC（Claude Code）登录认证 —— 用量面板需要

**作用**：显示 Claude Code 的「5 小时 / 每周」用量 + 重置时间。数据来自实时调用 `/v1/messages` 读其响应头（极小开销），需要一个 **Claude 长期 token**。

**【需要问用户】**需要用户有 Claude 订阅（Pro/Max），并会在弹出的浏览器里点授权。然后执行：

```bash
bash ~/.agent-status-board/bin/cc-token-setup.sh
```
- 它会跑 `claude setup-token`（在宽 PTY 里跑，避免 token 被 80 列终端换行截断），把长期 token 存到 `~/.agent-status-board/cc-token.json`（权限 600）。
- 脚本会自动找 `claude` CLI；找不到就用 Claude 桌面端内置的 CLI。若两者都没有，提示用户安装 Claude Code（桌面端或 `npm i -g @anthropic-ai/claude-code`）。
- token 长期有效。**若以后 CC 用量长期不更新**，重跑此脚本刷新即可。

> **Codex 用量无需任何配置**：自动调 Codex 自己的实时用量端点（`chatgpt.com/backend-api/wham/usage`，认证读 `~/.codex/auth.json` 的登录态；失败才回退本地 rollout 快照），开箱即用。

---

## 6. 验证

- 桌面右上角有深色玻璃组件（可拖动改位置；左上角 📌 可切换“置顶/普通”）。
- 让用户在 Codex 或 CC 里随便跑点东西 → 组件应在几秒内更新“正在执行 / 今日完成”。
- 「用量」区几秒后显示 CC 与 Codex 的 5 小时/每周百分比 + 重置倒计时（CC 那条需要第 5 步的 token）。

---

## 卸载

```bash
bash script/agent-hooks/autostart.sh off
bash script/agent-hooks/uninstall.sh        # 还原 CC/Codex 配置，移除 bin 脚本
```

---

## 配置文件速查（都在 `~/.agent-status-board/`）

| 文件 | 作用 | 谁来填 |
|---|---|---|
| `classify.json` | LLM 分类器（provider/base_url/api_key/model） | 第 4 步，你写 |
| `cc-token.json` | CC 用量的长期 token `{"token":"sk-ant-oat…"}` | 第 5 步脚本写 |
| `classify-model` | （可选）只改 bl 路径的模型名 | 可选 |
| `names.json` | （可选）`{路径:显示名}` 覆盖会话显示名 | 可选 |
| `sessions/*.json`、`activity.jsonl` | 运行时状态（hooks 写，**勿手改**） | 自动 |

## 架构（供你理解，不必照做）

- 生命周期 hooks 把每个会话状态写成 `~/.agent-status-board/sessions/<source>-<id>.json`，Swift 端每 3s 读取并渲染。
- 用量：**Codex** 实时 GET `https://chatgpt.com/backend-api/wham/usage`（认证用 `~/.codex/auth.json` 的 token，免费非推理；失败回退本地 rollout 快照的 `token_count → rate_limits`）；**CC** 用 token ping `/v1/messages`，读 `anthropic-ratelimit-unified-5h/7d-utilization|reset` 响应头。
- 已删除的 CC 会话 / 已归档的 Codex 会话会自动从面板隐藏（按底层 transcript / rollout 是否还在判断；恢复后自动重新显示）。
- 更多技术细节见同目录 `README.md`。
