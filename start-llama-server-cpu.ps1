# CPU-only fallback: used while the Radeon Pro 580 driver is too old for the
# Vulkan backend (it does not expose storageBuffer16BitAccess).
# -t 4 matches the i7-7700K's 4 physical cores; more threads does not help here.

$ErrorActionPreference = "Stop"
$Root  = "C:\llama-vulkan"
$Model = Join-Path $Root "models\Qwen3-8B-Q4_K_M.gguf"

if (-not (Test-Path $Model)) {
    Write-Error "Model not found: $Model"
    exit 1
}

# Thinking off by default; type /think in a message to opt back in for that turn.
$env:LLAMA_ARG_CHAT_TEMPLATE_KWARGS = '{"enable_thinking":false}'

& (Join-Path $Root "llama-server.exe") `
    --model  $Model `
    --alias  "Qwen3-8B" `
    --host   0.0.0.0 `
    --port   8080 `
    --device none `
    --n-gpu-layers 0 `
    --threads 4 `
    --ctx-size 8192 `
    --parallel 1 `
    --jinja `
    --reasoning-format none `
    --api-key "local-llama"

# --parallel 1 mirrors the GPU launcher. With the default 4 unified slots every
# decode step attends across all slots' cached tokens, so each new conversation
# slows the rest (measured -24% by the fourth on the GPU). The mechanism is
# attention over more KV cells, not anything GPU-specific, so it applies here
# too; it has not been separately measured on the CPU backend.
