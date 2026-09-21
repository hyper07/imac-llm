# Starts llama.cpp's OpenAI-compatible server on the Radeon Pro 580 (Vulkan).
# Open WebUI (Docker) talks to this via http://host.docker.internal:8080/v1
#
#   .\start-llama-server.ps1            -> fast mode, no reasoning (default)
#   .\start-llama-server.ps1 -Thinking  -> Qwen3 reasons first, shown in the UI

param(
    [switch]$Thinking
)

$ErrorActionPreference = "Stop"
$Root  = "C:\llama-vulkan"
$Model = Join-Path $Root "models\Qwen3-8B-Q4_K_M.gguf"

if (-not (Test-Path $Model)) {
    Write-Error "Model not found: $Model"
    exit 1
}

# Qwen3 reasons before every reply, which costs ~20 s even on trivial questions.
# This GGUF's chat template ignores the usual /think and /no_think prompt tokens,
# so the only working switch is this template kwarg, and it is server-wide.
# Set via env var rather than an inline --chat-template-kwargs argument, because
# PowerShell mangles the embedded quotes when passing JSON to a native exe.
if ($Thinking) {
    $env:LLAMA_ARG_CHAT_TEMPLATE_KWARGS = '{"enable_thinking":true}'
    # 'none' keeps <think> tags inline in message.content so Open WebUI renders them.
    $ReasoningFormat = 'none'
    Write-Host "Reasoning ENABLED - replies take ~20-30s and show a Thinking block." -ForegroundColor Yellow
} else {
    $env:LLAMA_ARG_CHAT_TEMPLATE_KWARGS = '{"enable_thinking":false}'
    # 'deepseek' routes the template's empty <think></think> prefill into the
    # unused reasoning_content field, keeping message.content clean.
    $ReasoningFormat = 'deepseek'
    Write-Host "Fast mode - reasoning off. Use -Thinking to enable it." -ForegroundColor Green
}

# --host 0.0.0.0 is required so the Docker container can reach the server.
# -ngl 99 offloads every layer to the GPU; the 8B Q4_K_M + 8k KV cache fits in 8 GB.
#
# --flash-attn off is REQUIRED on this GPU. llama.cpp defaults to 'auto' and turns
# Flash Attention on, but the Vulkan FA kernel is broken on Polaris (fp16: 0,
# matrix cores: none) and makes the model emit endless '?' characters. The same
# prompt on the CPU backend answers correctly, which is how this was isolated.
# Do not remove this flag.
#
# --reasoning-format is set above: 'none' in thinking mode so Open WebUI can
# render the <think> tags itself (it does not display the separate
# reasoning_content field while streaming), 'deepseek' in fast mode so the
# template's empty prefill does not leak into the visible answer.
#
# --cache-ram 0 is REQUIRED on this GPU. llama-server's RAM prompt cache
# (default 8192 MiB) saves a slot's KV state to host memory before reusing the
# slot with a different continuation - regenerate, an edited message, a chat
# switch, or Open WebUI's tag/follow-up task calls. That save is a GPU-to-host
# readback which runs at ~100 MB/s over this Vulkan path, so it stalls ~11.5 s
# before the first token, every time. Disabling it costs nothing here: in-slot
# prefix caching (cache_n) still works. The only loss is that switching back to
# a chat whose slot was evicted re-processes that prompt from scratch.
#
# --parallel 1: the default is 4 slots sharing one unified KV cache, and every
# decode step attends across ALL slots' cached tokens. Each distinct prompt
# (new chat, or an Open WebUI tag/follow-up task call) fills another slot and
# slows every later reply: measured 14.2 -> 13.0 -> 12.0 -> 10.8 tok/s across
# four conversations, persisting until restart. One slot holds 14.3 flat with
# the full 8192 context. Trade-offs: requests serialize, and only the latest
# conversation stays cached, so alternating between two chats re-processes
# each prompt (~113 tok/s). Splitting the KV with --no-kv-unified instead would
# cap each slot at 2048 tokens.
& (Join-Path $Root "llama-server.exe") `
    --model  $Model `
    --alias  "Qwen3-8B" `
    --host   0.0.0.0 `
    --port   8080 `
    --n-gpu-layers 99 `
    --ctx-size 8192 `
    --parallel 1 `
    --jinja `
    --flash-attn off `
    --reasoning-format $ReasoningFormat `
    --cache-ram 0 `
    --spec-type ngram-map-k `
    --api-key "local-llama"

# --spec-type ngram-map-k is free upside. It drafts tokens by looking for
# repeats of the current context, so drafting costs nothing - no second model.
# When the reply quotes or reformats the prompt (editing, RAG answers that cite
# sources, "rewrite this", code changes) it drafts ~49 tokens at a time and all
# are accepted: 15.15 -> 53.90 tok/s, a 3.6x speedup. On ordinary prose it finds
# no repeats and does nothing, measured at 15.36 vs 15.36 tok/s over three
# prompts with byte-identical output. Unlike a draft *model* (--spec-type
# draft-simple), which was 24-63% SLOWER here because the draft model's own
# forward passes cost more than they saved.
