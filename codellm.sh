# ── codellm: local coding LLM toolkit ──────────────────────────────────
# Qwen2.5-Coder via llama.cpp.  Sourced from ~/.zshrc.
# Primary interface:  codellm <subcommand>   (run `codellm help`)
# Short aliases also kept: askcode, llama, coderepo, codehelp.

export CODELLM_BIN="$HOME/repo/llama.cpp/build/bin"
export CODELLM_MODEL_14B="$HOME/models/qwen2.5-coder-14b-instruct-q4_k_m.gguf"  # quality
export CODELLM_MODEL_7B="$HOME/models/qwen2.5-coder-7b-instruct-q4_k_m.gguf"    # fast
export CODELLM_MODEL_AGENT="$HOME/models/Qwen3-Coder-30B-A3B-Instruct-UD-Q3_K_XL.gguf"  # agentic (tool-calling)
export CODELLM_MODEL_AGENT_BYTES="${CODELLM_MODEL_AGENT_BYTES:-13806312608}"             # full download size
export CODELLM_MODEL="${CODELLM_MODEL:-$CODELLM_MODEL_14B}"                      # default: quality
export CODELLM_PORT="${CODELLM_PORT:-8080}"
export CODELLM_CTX="${CODELLM_CTX:-40960}"   # context window; q8 KV keeps it in the M5 GPU budget
export CODELLM_URL="http://localhost:${CODELLM_PORT}"
export CODELLM_REPO="${CODELLM_REPO:-$HOME/repo/onprem-ai}"  # where `codellm sync` publishes this script

# ── internal helpers (prefixed _codellm_) ──────────────────────────────
_codellm_running() { curl -s "${CODELLM_URL}/health" >/dev/null 2>&1; }

# True only if the model file exists and is fully downloaded ($2 = expected bytes, optional).
_codellm_model_ready() {
  [ -f "$1" ] || return 1
  [ -z "$2" ] && return 0
  local sz; sz="$(stat -f%z "$1" 2>/dev/null || echo 0)"
  [ "$sz" -ge "$2" ]
}

_codellm_start() {
  if _codellm_running; then echo "codellm: already running at ${CODELLM_URL} (${CODELLM_MODEL##*/})"; return 0; fi
  echo "codellm: starting ${CODELLM_MODEL##*/}  (ctx ${CODELLM_CTX})${CODELLM_JINJA:+ +jinja} ..."
  # --jinja enables the model's tool-call parser (needed for the agentic model).
  local jinja=(); [ -n "${CODELLM_JINJA:-}" ] && jinja=(--jinja)
  # Flash attention + q8_0 KV cache keep a large context within the M5's ~18.6 GB GPU budget.
  nohup "$CODELLM_BIN/llama-server" \
    -m "$CODELLM_MODEL" \
    --port "$CODELLM_PORT" -c "$CODELLM_CTX" -ngl 99 \
    -fa on -ctk q8_0 -ctv q8_0 "${jinja[@]}" \
    > "$HOME/.config/codellm/server.log" 2>&1 &
  local pid=$!
  # Wait for health — but bail out if the server process dies (don't loop forever).
  while ! _codellm_running; do
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "codellm: server failed to start. Last log lines:" >&2
      tail -n 6 "$HOME/.config/codellm/server.log" >&2
      return 1
    fi
    sleep 1
  done
  echo "codellm: ready → ${CODELLM_URL}"
}

# Stop and WAIT until the server is truly gone (fixes restart race).
_codellm_stop() {
  if ! pgrep -f "llama-server.*--port ${CODELLM_PORT}" >/dev/null 2>&1; then
    echo "codellm: not running"; return 0
  fi
  pkill -f "llama-server.*--port ${CODELLM_PORT}" 2>/dev/null
  local n=0
  while pgrep -f "llama-server.*--port ${CODELLM_PORT}" >/dev/null 2>&1 && [ $n -lt 50 ]; do
    sleep 0.2; n=$((n + 1))
  done
  echo "codellm: stopped"
}

_codellm_use() {
  case "$1" in
    # fast/quality reset to the safe default context (40960) — big ctx + 14B overflows GPU memory.
    fast|7b)     export CODELLM_MODEL="$CODELLM_MODEL_7B";    export CODELLM_CTX=40960; export CODELLM_JINJA=""; echo "codellm: → 7B (fast), ctx 40960" ;;
    quality|14b) export CODELLM_MODEL="$CODELLM_MODEL_14B";   export CODELLM_CTX=40960; export CODELLM_JINJA=""; echo "codellm: → 14B (quality), ctx 40960" ;;
    # long = 7B + large context for summarizing big docs / many files (fits in memory on the 7B).
    long|docs)   export CODELLM_MODEL="$CODELLM_MODEL_7B";    export CODELLM_CTX=65536; export CODELLM_JINJA=""; echo "codellm: → 7B + 65536 ctx (large docs)" ;;
    # agent = Qwen3-Coder-30B (MoE) with tool-call parsing on — for the agentic CLI.
    agent)
      if ! _codellm_model_ready "$CODELLM_MODEL_AGENT" "$CODELLM_MODEL_AGENT_BYTES"; then
        local have; have="$(stat -f%z "$CODELLM_MODEL_AGENT" 2>/dev/null || echo 0)"
        echo "codellm: agent model still downloading ($((have/1000000))/$((CODELLM_MODEL_AGENT_BYTES/1000000)) MB) — try again when complete." >&2
        return 1   # leave the current server untouched
      fi
      export CODELLM_MODEL="$CODELLM_MODEL_AGENT"; export CODELLM_CTX=65536; export CODELLM_JINJA=1;  echo "codellm: → Qwen3-Coder-30B agent (tools/jinja on), ctx 65536" ;;
    *) echo "usage: codellm use fast|quality|long|agent   (current: ${CODELLM_MODEL##*/}, ctx ${CODELLM_CTX})"; return 1 ;;
  esac
  _codellm_stop; _codellm_start
}

# Interactive terminal chat (loads the model directly, no server needed).
_codellm_chat() {
  "$CODELLM_BIN/llama-cli" -m "$CODELLM_MODEL" -ngl 99 -c "$CODELLM_CTX" -fa on -cnv \
    -p "You are an expert coding assistant. Be concise and prefer code."
}

# aider against the local server, in the current repo. Auto-detects the loaded model.
_codellm_repo() {
  if ! _codellm_running; then echo "codellm: server not running. Run:  codellm start" >&2; return 1; fi
  local id; id="$(curl -s "${CODELLM_URL}/v1/models" | jq -r '.data[0].id')"
  echo "codellm: aider → ${id} @ ${CODELLM_URL}"
  OPENAI_API_BASE="${CODELLM_URL}/v1" OPENAI_API_KEY="dummy" \
    aider --model "openai/${id}" --no-show-model-warnings "$@"
}

# One-shot query to the running server (streams; also reads piped stdin).
_codellm_ask() {
  if ! _codellm_running; then echo "codellm: server not running. Run:  codellm start" >&2; return 1; fi
  local prompt="$*" piped="" user
  if [ ! -t 0 ]; then piped="$(cat)"; fi
  user="$prompt"; [ -n "$piped" ] && user="${prompt}"$'\n\n'"${piped}"
  jq -n --arg sys "You are an expert coding assistant. Reply concisely; prefer code with minimal prose." \
        --arg user "$user" \
    '{messages:[{role:"system",content:$sys},{role:"user",content:$user}],temperature:0.2,stream:true}' \
  | curl -s -N "${CODELLM_URL}/v1/chat/completions" -H "Content-Type: application/json" -d @- \
  | while IFS= read -r line; do
      line="${line#data: }"
      [ "$line" = "[DONE]" ] && { printf '\n'; break; }
      case "$line" in
        \{*) printf '%s' "$line" | jq -j '.choices[0].delta.content // empty' 2>/dev/null ;;
      esac
    done
}

# Agentic coding CLI (qwen-code) against the local Qwen3-Coder model — explores + edits.
# Auto-switches the server to the agent model if it isn't already loaded.
_codellm_agent() {
  if ! command -v qwen >/dev/null 2>&1; then echo "codellm: 'qwen' (qwen-code) not installed" >&2; return 1; fi
  local running_id; running_id="$(curl -s "${CODELLM_URL}/v1/models" 2>/dev/null | jq -r '.data[0].id' 2>/dev/null)"
  case "$running_id" in
    *Qwen3-Coder*) : ;;  # agent model already loaded
    *) echo "codellm: loading the Qwen3-Coder agent model first ..."; _codellm_use agent || return 1 ;;
  esac
  local id; id="$(curl -s "${CODELLM_URL}/v1/models" | jq -r '.data[0].id')"
  echo "codellm: qwen-code agent → ${id} @ ${CODELLM_URL}  (explores + edits; offline)"
  OPENAI_API_KEY="dummy" \
  OPENAI_BASE_URL="${CODELLM_URL}/v1" \
  OPENAI_MODEL="$id" \
    qwen "$@"
}

# Launch Claude Code against the LOCAL server — SCOPED to this one invocation.
# Env vars are set inline on the `claude` process only, so your normal `claude`
# (and any running session) is never affected.  NOTE: agentic tools are unreliable
# on local models — plain chat works best; use `codellm repo` (aider) for real edits.
_codellm_code() {
  if ! _codellm_running; then echo "codellm: server not running. Run:  codellm start" >&2; return 1; fi
  if ! command -v claude >/dev/null 2>&1; then echo "codellm: 'claude' CLI not found on PATH" >&2; return 1; fi
  local id; id="$(curl -s "${CODELLM_URL}/v1/models" | jq -r '.data[0].id')"
  echo "codellm: Claude Code → ${id} @ ${CODELLM_URL}  (scoped; your real 'claude' is untouched)"
  echo "         heads-up: file-editing tools are unreliable on local models; prefer 'codellm repo' for edits."
  ANTHROPIC_BASE_URL="$CODELLM_URL" \
  ANTHROPIC_AUTH_TOKEN="dummy" \
  ANTHROPIC_API_KEY="dummy" \
  ANTHROPIC_MODEL="$id" \
  ANTHROPIC_SMALL_FAST_MODEL="$id" \
  ANTHROPIC_DEFAULT_HAIKU_MODEL="$id" \
  ANTHROPIC_DEFAULT_SONNET_MODEL="$id" \
  ANTHROPIC_DEFAULT_OPUS_MODEL="$id" \
    claude "$@"
}

_codellm_status() {
  if _codellm_running; then
    local id; id="$(curl -s "${CODELLM_URL}/v1/models" | jq -r '.data[0].id')"
    echo "codellm: RUNNING  model=${id}  ctx=${CODELLM_CTX}  url=${CODELLM_URL}"
  else
    echo "codellm: stopped  (selected model: ${CODELLM_MODEL##*/}, ctx ${CODELLM_CTX})"
  fi
}

# Publish this script to the onprem-ai repo: copy → commit → push.
# Optional commit message: codellm sync "my message"
_codellm_sync() {
  local repo="$CODELLM_REPO" self="$HOME/.config/codellm/codellm.sh"
  [ -d "$repo/.git" ] || { echo "codellm: repo not found at $repo (set CODELLM_REPO)" >&2; return 1; }
  cp "$self" "$repo/codellm.sh"
  ( cd "$repo" || return 1
    git add codellm.sh
    if git diff --cached --quiet; then
      echo "codellm: codellm.sh already up to date — nothing to push"
    else
      git commit -q -m "${*:-update codellm.sh}" && git push -q && echo "codellm: synced & pushed → $repo"
    fi )
}

_codellm_guide() {
  local guide="$HOME/models/LOCAL-CODING-LLM-GUIDE.md"
  [ -f "$guide" ] || { echo "codellm: guide not found at $guide" >&2; return 1; }
  if command -v glow >/dev/null 2>&1; then glow -p "$guide"
  elif command -v bat  >/dev/null 2>&1; then bat --style=plain --paging=always -l md "$guide"
  else ${PAGER:-less} "$guide"; fi
}

_codellm_help() {
  cat <<'EOF'
codellm — local coding LLM toolkit

  codellm start              start the model server (idempotent)
  codellm stop               stop the server (waits until gone)
  codellm restart            stop then start
  codellm status             show running model / context
  codellm use fast|quality   switch 7B ⇄ 14B (default ctx 40960) and restart
  codellm use long           7B + 65536 ctx — for big docs / many files
  codellm use agent          Qwen3-Coder-30B (MoE) with tool-calling on
  codellm chat               interactive terminal chat
  codellm ask "question"     one-shot query (also reads piped stdin)
  codellm repo [files...]    aider — repo-aware editing in the current dir
  codellm agent [args...]    qwen-code — agentic explore + edit (Qwen3-Coder); the Claude-Code-like one
  codellm code [args...]     Claude Code CLI against the LOCAL model (scoped; chat-only, tools flaky)
  codellm guide              open the full guide
  codellm sync ["msg"]       publish codellm.sh to the onprem-ai repo (commit + push)
  codellm help               this help

Short aliases: askcode "...", llama, coderepo, codehelp
EOF
}

# ── dispatcher ─────────────────────────────────────────────────────────
codellm() {
  local cmd="${1:-help}"; [ $# -gt 0 ] && shift
  case "$cmd" in
    start|up)        _codellm_start ;;
    stop|down)       _codellm_stop ;;
    restart)         _codellm_stop; _codellm_start ;;
    status|ps)       _codellm_status ;;
    use)             _codellm_use "$@" ;;
    chat)            _codellm_chat ;;
    ask)             _codellm_ask "$@" ;;
    repo)            _codellm_repo "$@" ;;
    agent)           _codellm_agent "$@" ;;
    code)            _codellm_code "$@" ;;
    guide|doc)       _codellm_guide ;;
    sync)            _codellm_sync "$@" ;;
    help|-h|--help)  _codellm_help ;;
    *) echo "codellm: unknown command '$cmd'" >&2; _codellm_help; return 1 ;;
  esac
}

# ── backward-compatible short aliases ──────────────────────────────────
codellm-stop() { _codellm_stop; }
codellm-use()  { _codellm_use "$@"; }
codechat()     { _codellm_chat; }
coderepo()     { _codellm_repo "$@"; }
askcode()      { _codellm_ask "$@"; }
codehelp()     { _codellm_guide; }
# `llama` bare → chat; with args → the Homebrew llama tool.
llama() { if [ $# -eq 0 ]; then _codellm_chat; else command llama "$@"; fi }
# ───────────────────────────────────────────────────────────────────────
