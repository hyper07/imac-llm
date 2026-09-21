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
    --api-key "local-llama"

# The first request after a model load is sometimes corrupt on this GPU: it
# comes back as repeated junk ("softsoftsoft...", "*[ * * *", "?????") instead
# of an answer. Measured across 3 fresh boots, the first request failed twice
# and every later request was fine. A throwaway request absorbs it - across 4
# boots with a warm-up, 0 of 12 real requests were corrupt. This job waits for
# the API and burns that first request before you ever see it.
Start-Job -ScriptBlock {
    for ($i = 0; $i -lt 60; $i++) {
        Start-Sleep -Seconds 3
        try {
            $b = @{ model = 'Qwen3-8B'; messages = @(@{ role = 'user'; content = 'hi' })
                    max_tokens = 8; stream = $false } | ConvertTo-Json -Depth 5
            Invoke-RestMethod 'http://127.0.0.1:8080/v1/chat/completions' -Method Post `
                -ContentType 'application/json' -Headers @{Authorization = 'Bearer local-llama'} `
                -Body $b -TimeoutSec 120 | Out-Null
            break
        } catch { }
    }
} | Out-Null

# DO NOT add --spec-type ngram-map-k. It looked like free speed - 3.6x on
# prompts whose reply reuses the input, and no measurable cost on prose - but
# it CORRUPTS OUTPUT on this GPU. A Python-function prompt returned an unbroken
# run of '?' on 6 of 6 runs with it enabled and 0 of 6 without, at 95/95 draft
# acceptance, so the drafted garbage is being "verified" as correct. Same
# failure signature as Vulkan flash attention above, which suggests the batched
# verification path is not merely slow on Polaris but wrong.
#
# It was briefly enabled here on the strength of echo and prose benchmarks; no
# code prompt had been checked. Any speculation setting on this GPU needs its
# OUTPUT validated across prompt types, not just its tok/s.
