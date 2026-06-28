# Local Coding LLM — Setup & Running Guide (Apple Silicon)

A purpose-built, **fully local / offline coding assistant** running on `llama.cpp` (Apple Metal GPU).
No training required — these are pre-trained coding-specialist models. Three tiers:

- **Qwen2.5-Coder 7B / 14B** — chat, one-shot Q&A, and repo-aware editing (`aider`).
- **Qwen3-Coder-30B-A3B** (MoE) — an **agentic** model with real tool-calling, driven by the
  `qwen-code` CLI to explore a codebase and do the heavy lifting (Claude-Code-like, local).

Front-ends: `codellm ask` (CLI Q&A), `codellm chat` (chat), `codellm repo` (aider editing),
`codellm agent` (agentic explore+edit), plus the built-in web UI.

---

## Requirements

### Hardware (what this guide was built and tested on)

| | Spec | Notes |
|---|---|---|
| Machine | Apple **M5**, **24 GB** unified memory | Any Apple-Silicon Mac works; RAM drives model size |
| GPU budget | ~18.6 GB usable for Metal | `recommendedMaxWorkingSetSize`; caps model+KV cache |
| Disk | ~30 GB free | Models: 7B 4.4 GB + 14B 8.4 GB + 30B 13 GB |
| OS | macOS 26.x (Tahoe) | Darwin 25.x |

Rule of thumb: **16 GB** → 7B (+ maybe 14B); **24 GB** → up to the 30B-A3B agent at Q3; **32 GB+** → roomier contexts / higher quants.

### Software (versions installed here)

| Tool | Version | Install | Used for |
|---|---|---|---|
| **llama.cpp** | source build | `cmake` (see Step 1) | the inference server (`llama-server`) |
| **Homebrew** | — | preinstalled | package manager for the below |
| **aider** | 0.86.2 | `brew install aider` | repo-aware editing (`codellm repo`) |
| **Node.js / npm** | 26.4.0 / 11.17.0 | `brew install node` | runs qwen-code |
| **qwen-code** | 0.19.2 | `npm i -g @qwen-code/qwen-code` | agentic CLI (`codellm agent`) |
| **huggingface_hub (`hf`)** | 1.21.0 | `pipx install "huggingface_hub[cli,hf_transfer]"` | reliable model downloads |
| **pipx** | 1.15.0 | `brew install pipx` | isolated Python CLIs |
| **python@3.12** | 3.12.13 | `brew install python@3.12` | pin for pipx (avoids 3.14 wheel breaks) |
| **aria2** | 1.37.0 | `brew install aria2` | multi-connection downloads (optional) |
| **jq** | 1.7.1 | preinstalled (or `brew install jq`) | JSON parsing in the helper |
| **curl** | system | preinstalled | downloads / API calls |
| **claude** (Claude Code) | optional | — | `codellm code` experiment (see caveats) |

A free **Hugging Face account + access token** is effectively required — anonymous downloads are
throttled hard. `hf auth login --token hf_xxx` once. See [Downloading models](#downloading-models-important).

---

## Install from this repo

This repo ships the toolkit script (`codellm.sh`). To set it up on a fresh machine:

```bash
# 1. Install dependencies (see Requirements table above)
brew install aider node pipx aria2 jq python@3.12
npm install -g @qwen-code/qwen-code
pipx install "huggingface_hub[cli,hf_transfer]"

# 2. Build llama.cpp (see "Step 1 — Build llama.cpp" below), then drop the toolkit in place:
mkdir -p ~/.config/codellm
cp codellm.sh ~/.config/codellm/codellm.sh
cp sandbox-macos-podman.sb ~/.config/codellm/   # podman-aware agent sandbox profile
echo 'source ~/.config/codellm/codellm.sh' >> ~/.zshrc
source ~/.zshrc

# 3. Authenticate to HF and download a model (see "Downloading models"):
hf auth login --token hf_xxxxxxxx
HF_HUB_DISABLE_XET=1 hf download Qwen/Qwen2.5-Coder-14B-Instruct-GGUF \
  qwen2.5-coder-14b-instruct-q4_k_m.gguf --local-dir ~/models

# 4. Go:
codellm start && codellm ask "hello"
```

Edit the model paths/sizes at the top of `codellm.sh` if yours differ.

---

## Everyday use (start here)

Everything is already installed and wired into your shell. In any new terminal:

```bash
codellm start             # start the local model server (idempotent)
codellm ask "question"    # quick one-shot question (also accepts piped input)
codellm chat              # interactive terminal chat

cd ~/repo/myproject       # to work ON a real codebase:
codellm use quality       # switch to the stronger 14B model
codellm repo              # aider — repo-aware editing + git commits

codellm status            # what's running (model + context)
# browser chat UI:  http://localhost:8080
codellm stop              # shut the server down when done
```

That's the whole daily loop. The rest of this doc explains each piece, the install steps that
got you here, and troubleshooting.

### Full command reference

Primary interface is the `codellm <subcommand>` dispatcher (`codellm help` lists them):

| Command | What it does |
|---|---|
| `codellm start` / `stop` / `restart` | Server lifecycle (`stop` waits until the process is truly gone) |
| `codellm status` | Show running model + context window |
| `codellm use fast` / `quality` | Switch model: 7B (fast) ⇄ 14B (quality), ctx 40960, + restart |
| `codellm use long` | 7B + 65536 ctx — for summarizing big docs / many files |
| `codellm use agent` | Qwen3-Coder-30B (MoE) + tool-calling, ctx 65536 |
| `codellm ask "..."` | One-shot query; streams; reads piped stdin |
| `codellm chat` | Interactive terminal chat |
| `codellm repo [files]` | Launch **aider** in the current repo against the local server |
| `codellm agent [args]` | **qwen-code** — agentic explore + edit (Qwen3-Coder); the Claude-Code-like one |
| `codellm code [args]` | Claude Code CLI against the **local** model (scoped) — see caveat below |
| `codellm guide` | Open this guide |
| `codellm help` | List all subcommands |

Short aliases still work: `askcode "..."`, `llama` (bare = chat), `coderepo`, `codehelp`.

Helpers live in `~/.config/codellm/codellm.sh` (auto-sourced from `~/.zshrc`).
Models live in `~/models/`. Server logs: `~/.config/codellm/server.log`.

### Context window & memory

**Default is 14B at 40960 tokens** (with flash attention + a q8_0 KV cache — the quantization is
what keeps a context this large inside the M5's ~18.6 GB GPU budget). That's the everyday setup.

When you need a **bigger window** (summarizing large docs, many files at once), the 14B can't go
much past ~49K without overflowing GPU memory — so switch to the 7B, which fits a far larger
context in the same memory:

```bash
codellm use long     # 7B + 65536 ctx (one command)
codellm use quality  # back to the default 14B / 40960 when done
```

`fast`/`quality` always snap context back to the safe 40960, so you can't accidentally end up with
the memory-busting 14B-plus-huge-context combo. For a custom size: `export CODELLM_CTX=N && codellm restart`.

---

## Why no training?

Training/fine-tuning a coding model from scratch needs huge datasets + many GPUs + weeks of
compute. You don't need it. **Qwen2.5-Coder** is already trained on billions of lines of code.
Download it and run. Customize later with system prompts → RAG → (only if needed) LoRA.

---

## Hardware → model choice (24 GB unified memory)

| Model | Quant | RAM | Notes |
|-------|-------|-----|-------|
| **Qwen2.5-Coder-14B-Instruct** ⭐ | Q4_K_M | ~9 GB | Recommended sweet spot |
| Qwen2.5-Coder-7B-Instruct | Q4_K_M | ~4.5 GB | Faster / lighter |
| Qwen2.5-Coder-32B-Instruct | Q3_K_M | ~15 GB | Highest quality, slower |

---

## Step 1 — Build llama.cpp (already done on this machine)

```bash
cd ~/repo/llama.cpp
cmake -B build
cmake --build build --config Release -j
# Binaries land in build/bin/  (llama-cli, llama-server)
```

## Step 2 — Get the model

> ⚠️ **Gotcha:** `llama-server -hf <repo>:Q4_K_M` failed on this build with
> `HEAD failed, status: 404 / no remote preset found, skipping`.
> The `-hf` auto-resolver probes a manifest endpoint that 404s for the official Qwen GGUF repo.
> **Workaround used:** download the GGUF file directly, then load with `-m`.

```bash
mkdir -p ~/models && cd ~/models
curl -L -C - \
  "https://huggingface.co/Qwen/Qwen2.5-Coder-14B-Instruct-GGUF/resolve/main/qwen2.5-coder-14b-instruct-q4_k_m.gguf?download=true" \
  -o qwen2.5-coder-14b-instruct-q4_k_m.gguf
```
- `-C -` resumes if interrupted — just re-run the same command.
- File size ≈ **8.99 GB**.

## Step 3 — Run the server

```bash
~/repo/llama.cpp/build/bin/llama-server \
  -m ~/models/qwen2.5-coder-14b-instruct-q4_k_m.gguf \
  --port 8080 \
  -c 16384 \
  -ngl 99
```

Flag reference (these are what the `codellm` helper uses):
- `-ngl 99` — offload all layers to the M5 GPU (Metal). Key for speed.
- `-c 40960` — context window. Big enough for several files + reply.
- `-fa on` — flash attention (faster, less memory).
- `-ctk q8_0 -ctv q8_0` — quantize the KV cache → ~halves its size, so a large context fits in GPU memory.
- `--port 8080` — HTTP port.

Open **http://localhost:8080** for the built-in chat UI.

### Or use the terminal instead of the server

```bash
~/repo/llama.cpp/build/bin/llama-cli \
  -m ~/models/qwen2.5-coder-14b-instruct-q4_k_m.gguf \
  -ngl 99 -c 16384 -cnv
```

## Step 4 — Use the API (OpenAI-compatible)

```bash
curl http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "messages": [
      {"role": "system", "content": "You are an expert coding assistant. Reply with code only unless asked to explain."},
      {"role": "user", "content": "Write a Python function to debounce a callback."}
    ],
    "temperature": 0.2
  }'
```

## CLI toolkit (zsh)

Helpers live in `~/.config/codellm/codellm.sh` and are auto-sourced from `~/.zshrc`.
Open a new terminal (or run `source ~/.zshrc`) to load them.

| Command | What it does |
|---|---|
| `codellm` | Start the server in the background (idempotent; waits until ready) |
| `codellm-stop` | Stop the server |
| `codechat` / `llama` | Interactive terminal chat (loads the model directly, no server) |
| `askcode "..."` | One-shot query to the running server, streams the answer |

### Switching models (fast ⇄ quality)

Two models are installed; switch the active one and restart the server with one command:

| Command | Model | Use when |
|---|---|---|
| `codellm-use fast` | Qwen2.5-Coder-**7B** (4.4 GB) | Quick edits, autocomplete, snappy answers |
| `codellm-use quality` | Qwen2.5-Coder-**14B** (8.4 GB) | Harder problems, multi-file reasoning |

Default on a fresh shell is **14B**. To make a session start on 7B without restarting:
`export CODELLM_MODEL=$CODELLM_MODEL_7B` before `codellm`.

`askcode` also reads piped stdin, so you can feed it code:

```bash
askcode "write a bash loop that retries a command 3 times"
cat main.py | askcode "find the bug"
askcode "explain this regex" < pattern.txt
git diff | askcode "review this change"
```

Override the port for a session: `export CODELLM_PORT=9090` before `codellm`.

## Repo-aware editing with aider

`aider` is installed and wired to the local server through the `coderepo` helper. It indexes your
repo, pulls relevant files into context, and **edits files + makes git commits** for you.

> ⚠️ **Install gotcha (for reinstalls):** install aider with **`brew install aider`**, not pipx.
> The Homebrew formula bundles its own Python 3.12. Installing via `pipx`/`pip` on this machine
> grabs Python 3.14, and aider's pinned `numpy==1.24.3` has no wheel for 3.14 → build failure.

```bash
cd ~/repo/myproject
codellm-use quality     # use 14B — better for actual edits
coderepo                # launches aider against the local server (auto-detects the model)
```

Inside aider:
- Type a request, e.g. `add input validation to login() in auth.py`.
- `/add path/to/file.py` — put a file in context. `/drop` to remove.
- `/diff` — see pending changes. `/undo` — revert aider's last commit.
- `/help` — all commands. `Ctrl-C` / `/exit` — quit.

`coderepo` passes extra flags through, e.g. `coderepo --no-auto-commits` to stop it
auto-committing, or `coderepo file1.py file2.py` to start with files in context.

> Note: the 7B/14B are solid but small — aider works best with strong models, so expect the
> occasional malformed edit. `codellm-use quality` (14B) helps; `/undo` is your safety net.

## Agentic coding — explore + heavy lifting (`codellm agent`)

This is the Claude-Code-like, fully-local agent: it **explores the codebase with tools and edits
files autonomously**. Two ingredients:

1. **Qwen3-Coder-30B-A3B** — an MoE model (only ~3B active params, so it's fast and fits 24 GB)
   that is *tuned for agentic tool-calling*.
2. **qwen-code** — the agentic CLI (a Gemini-CLI fork built for Qwen-Coder), pointed at the local server.

> **Why not the 7B/14B?** Agentic work needs the model to emit *structured* tool calls. The
> Qwen2.5-Coder 7B/14B emit them as plain text (`<tools>{...}</tools>`), which CLIs can't act on —
> so they stall. Qwen3-Coder **+ `--jinja`** produces real `tool_calls` (verified: `finish_reason:
> "tool_calls"`). That's the whole unlock.

### Use it

```bash
cd ~/repo/onprem-pbx
codellm agent            # auto-loads the Qwen3-Coder model (jinja/tools on), launches qwen-code
# then: "explore the codebase and summarize the architecture and key components"
```

- `codellm agent` auto-switches the server to the agent model if it isn't already loaded.
- Interactive mode asks before running tools. For non-interactive/headless, add `-y` (YOLO —
  auto-runs tools): `codellm agent -y -p "find and fix the failing test"`.
- Context is **65536** for this preset — qwen-code's own system prompt + tool definitions are ~44K
  tokens, so a big window is mandatory (40960 overflows before you even start).

### Honest expectations

- ✅ Tool-calling **works** — it really explores and edits.
- 🐢 **Slow.** A 30B at Q3 on the M5 takes real time per agentic step (each step reprocesses a large
  prompt). Great for "go figure this out" tasks you can walk away from; not snappy like the 14B chat.
- 🎯 Q3 quant + 30B is *good*, not Claude-Opus-level. For the hardest reasoning, real Claude Code still wins.

### Sandbox & Podman builds

`codellm agent` runs **sandboxed by default** (macOS Seatbelt). The sandbox confines writes to the
project directory (host dirs like `/opt/homebrew` are protected) while leaving network open so the
local model server stays reachable. Disable per session with `CODELLM_SANDBOX=0 codellm agent`.

Because the global `QWEN.md` tells the agent to **build inside Podman**, the helper auto-installs a
**podman-aware Seatbelt profile** so containerized builds work inside the sandbox:

- Canonical profile: `~/.config/codellm/sandbox-macos-podman.sb` (base `permissive-open` + write
  access to `~/.local/share/containers`, `~/.config/containers`, `~/.ssh`).
- On launch, `codellm agent` copies it to `./.qwen/sandbox-macos-podman.sb` in the current repo and
  sets `SEATBELT_PROFILE=podman` (Seatbelt profiles are resolved per-project).
- The generated `./.qwen/sandbox-macos-podman.sb` is auto-added to the repo's `.git/info/exclude`,
  so it won't clutter `git status` (local-only — your shared `.gitignore` is untouched).

This is why Podman (which talks to its VM over SSH/loopback and writes to `~/.local/share/containers`)
keeps working even with the sandbox on.

## Downloading models (important)

Hugging Face **throttles anonymous downloads hard** (we saw 160 KB/s and stalls). Also, HF's newer
**Xet** transfer protocol stalled on this network. The reliable recipe:

```bash
# 1. One-time: free token from https://huggingface.co/settings/tokens (Read scope)
hf auth login --token hf_xxxxxxxxxxxxxxxxxxxxx

# 2. Download with Xet DISABLED (classic LFS endpoint) — fast & reliable here:
HF_HUB_DISABLE_XET=1 hf download <repo> <file.gguf> --local-dir ~/models
```

Example (the agent model):
```bash
HF_HUB_DISABLE_XET=1 hf download \
  unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF \
  Qwen3-Coder-30B-A3B-Instruct-UD-Q3_K_XL.gguf --local-dir ~/models
```

Lessons learned (so you don't repeat them):
- **Authenticate first** — the single biggest speedup.
- **`HF_HUB_DISABLE_XET=1`** if a download stalls at 0 B/s with an "active" process.
- Plain `curl`/`aria2c` against HF Xet URLs fail (`errorCode=22`) — each signed URL is byte-range-locked.

## Claude Code against the local model (`codellm code`)

llama.cpp's server natively exposes the **Anthropic Messages API** (`/v1/messages`), so the Claude
Code CLI can be pointed at the local model. `codellm code` does this **scoped to that one
invocation** — the `ANTHROPIC_*` env vars are set inline on the `claude` process only.

```bash
codellm code            # opens Claude Code talking to your local model
codellm code -p "..."   # headless one-shot
```

> ⚠️ **Two big caveats — use this only for experimentation:**
> 1. **Tools (Read/Edit/Bash) are unreliable.** The local model emits tool calls as plain text
>    (`<tools>{...}</tools>`) instead of structured `tool_use` blocks, so Claude Code often can't
>    actually act on files. For real local editing use **`codellm repo`** (aider) instead.
> 2. **It's slow.** Claude Code sends a large system prompt + tool definitions; the 14B takes a
>    long time to process all of it before the first reply.
>
> 🚫 **Never put `ANTHROPIC_BASE_URL` in `~/.zshrc`** — that redirects your *real* Claude Code
> (every session) to the local model and breaks it. `codellm code` avoids this by scoping the env
> vars to a single process; verify with `env | grep -i anthropic` → should be empty in your shell.

**Bottom line:** for local agentic coding, prefer `codellm repo` (aider). Keep your real `claude`
on the Anthropic API for serious work.

## Step 5 — Editor integration (optional)

**VS Code (Continue.dev):** set the provider to "OpenAI-compatible", base URL
`http://localhost:8080/v1`, model name `qwen2.5-coder`, any dummy API key.

---

## Tuning tips for coding

- **Lower temperature** (`0.1–0.3`) → more deterministic, correct code.
- **System prompt** is your cheapest customization — encode your stack/conventions there.
- For "know my repo" use **RAG** (feed relevant files as context), not fine-tuning.
- Bigger context (`-c 32768`) helps with multi-file tasks; watch RAM.

## Starting the server

You don't need a manual alias — `codellm` is already a shell function (in
`~/.config/codellm/codellm.sh`). Just run `codellm` in any terminal; it launches the server in
the background and waits until it's ready. It won't start a second copy if one is already running.

To auto-start on login, you *could* add `codellm` to the end of `~/.zshrc`, but it's better to
start it on demand so it's not always holding ~9 GB of RAM.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `HEAD failed, status: 404` with `-hf` | Use the direct `curl` download + `-m` (Step 2/3). |
| Server hangs at startup, no port open | Kill it (`pkill -f llama-server`) and confirm the `.gguf` is fully downloaded. |
| Out of memory / very slow | Use the 7B model, or a smaller quant (Q3_K_M). |
| Port in use | Change `--port`, or `export CODELLM_PORT=9090` before `codellm`. |
| Verify download is complete | `ls -lh ~/models/*.gguf` (14B ≈ 8.4 GB, 7B ≈ 4.4 GB). |
| `aider` install fails on numpy build | Use `brew install aider` (bundles Python 3.12), not pipx/pip (grabs 3.14). |
| `coderepo: server not running` | Run `codellm start` first. |
| aider: `request (N tokens) exceeds the available context size` | Raise context: `export CODELLM_CTX=49152 && codellm restart`. Or in aider `/drop` files / `/clear`. |
| Server won't restart ("already running") | Use `codellm restart` (its `stop` waits for the process to die before starting). |
| Commands not found in a new shell | `source ~/.zshrc`, or check that it sources `~/.config/codellm/codellm.sh`. |
| aider makes a bad edit | `/undo` inside aider reverts its last commit; use `codellm use quality` for better edits. |
| Download stuck at 0 B/s / 160 KB/s | Authenticate (`hf auth login --token …`) and use `HF_HUB_DISABLE_XET=1 hf download …`. |
| `curl`/`aria2c` HF download fails (`errorCode=22`) | HF Xet byte-range-locks URLs; use the `hf` CLI with `HF_HUB_DISABLE_XET=1`. |
| `codellm agent`: `request exceeds context size` | qwen-code needs a big window; the `agent` preset uses ctx 65536 — make sure you're on it (`codellm use agent`). |
| `codellm agent` says "still downloading" | The Qwen3-Coder model isn't fully downloaded yet; it leaves your current server running. |
| qwen-code: tool needs approval in headless | Add `-y` (YOLO): `codellm agent -y -p "…"`. |
| Podman build fails under the agent sandbox | The `podman` Seatbelt profile is auto-installed; if writes are still blocked, run `CODELLM_SANDBOX=0 codellm agent`, or add the needed path to `~/.config/codellm/sandbox-macos-podman.sb`. |
| `brew install` / `rm` refused by the agent | Intended — blocked in `~/.qwen/settings.json` (`permissions.deny`). Manage with `/permissions`. |

---

## License

[MIT](LICENSE) © 2026 naushada
