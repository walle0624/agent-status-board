#!/usr/bin/env bash
# configure-llm.sh — interactive setup for the optional "needs input" AI classifier.
#
# Writes ~/.agent-status-board/classify.json. Safe to re-run anytime to change
# the provider, endpoint, key, or model. The key is stored locally (chmod 600)
# and only ever sent to the endpoint you choose.
set -euo pipefail

BASE="$HOME/.agent-status-board"
CFG="$BASE/classify.json"
mkdir -p "$BASE"

if [ ! -t 0 ]; then
  echo "configure-llm: 需在终端交互运行。也可手写 $CFG："
  echo '  {"provider":"openai","base_url":"https://host/v1","api_key":"sk-...","model":"..."}'
  exit 0
fi

if [ -f "$CFG" ]; then
  printf '已存在配置 %s，是否重新配置? [y/N] ' "$CFG"
  read -r ans || ans=""
  case "$ans" in y|Y|yes|YES) ;; *) echo "保留现有配置。"; exit 0 ;; esac
fi

cat <<'MENU'

『需要处理』AI 分类器 —— 每个回合结束后，用一个小模型读对话尾部，判断会话是否
在等你操作，并给出一句话摘要（不需要任何 Claude / Anthropic Key）。

选择推理后端（OpenAI 兼容接口，几乎所有厂商都支持）：
  1) 阿里百炼 DashScope   (OpenAI 兼容, 需 API Key)
  2) OpenAI               (需 API Key)
  3) DeepSeek             (需 API Key)
  4) 自定义 OpenAI 兼容端点 (自填 Base URL, 需 API Key —— 也可填本地 Ollama/vLLM)
  5) 本地 bl CLI          (阿里百炼命令行, 无需 Key; 仅本机已装 bl 时可用)
  6) 跳过                 (暂不启用; 之后重跑本脚本即可)
MENU
printf '请选择 [1-6]: '
read -r choice || choice=""

provider=""; base_url=""; def_model=""; model=""; api_key=""
case "$choice" in
  1) provider=openai; base_url="https://dashscope.aliyuncs.com/compatible-mode/v1"; def_model="qwen-plus" ;;
  2) provider=openai; base_url="https://api.openai.com/v1"; def_model="gpt-4o-mini" ;;
  3) provider=openai; base_url="https://api.deepseek.com/v1"; def_model="deepseek-chat" ;;
  4) provider=openai
     printf 'Base URL (形如 https://host/v1): '
     read -r base_url || base_url="" ;;
  5) provider=bl ;;
  *) echo "已跳过，未启用 AI 分类器。"; exit 0 ;;
esac

if [ "$provider" = "bl" ]; then
  printf '模型名 [默认 qwen3.7-max]: '
  read -r model || model=""
  model="${model:-qwen3.7-max}"
else
  if [ -z "$base_url" ]; then echo "未填 Base URL，已跳过。"; exit 0; fi
  printf 'API Key (输入时不回显): '
  read -rs api_key || api_key=""
  echo
  if [ -z "$api_key" ]; then echo "未输入 Key，已跳过。"; exit 0; fi
  if [ -n "$def_model" ]; then
    printf '模型名 [默认 %s]: ' "$def_model"
  else
    printf '模型名: '
  fi
  read -r model || model=""
  model="${model:-$def_model}"
  if [ -z "$model" ]; then echo "未输入模型名，已跳过。"; exit 0; fi
fi

# Write JSON via python so values are escaped correctly; key passed via env (not
# argv) so it never shows up in the process list.
ASB_P="$provider" ASB_B="$base_url" ASB_K="$api_key" ASB_M="$model" \
python3 - "$CFG" <<'PY'
import json, os, sys
cfg = {"provider": os.environ.get("ASB_P", "")}
for env, key in (("ASB_B", "base_url"), ("ASB_K", "api_key"), ("ASB_M", "model")):
    v = os.environ.get(env, "")
    if v:
        cfg[key] = v
path = sys.argv[1]
with open(path, "w") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
os.chmod(path, 0o600)
print("已写入", path)
PY

echo "完成。随时重跑本脚本可修改：$0"
