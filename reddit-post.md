# Reddit post draft

Condensed from [README.md](README.md), aimed at r/LocalLLaMA. All numbers
measured on the machine below. Full method and negative results in the README.

Note: this is the top 2017 config (i7-7700K + Radeon Pro 580 8 GB), and the
64 GB is an aftermarket upgrade, not stock.

---

**Title:** A $250 27" 5K iMac (2017) is still a great machine — and it runs small local models fine. Numbers + five config traps

---

The 27" 5K iMac (2017) is worth $250 on its own merits — 5K display, 64 GB of upgradeable RAM, a complete machine. I picked mine up on Facebook Marketplace and then spent a day finding out how well it runs local models. Short answer: small ones run well, and there are some traps.

Posting the numbers because I couldn't find any.

**Specs:** i7-7700K, Radeon Pro 580 8 GB, 64 GB DDR4, 1 TB NVMe, Windows 11 via Boot Camp. Inference through llama.cpp Vulkan — no ROCm on Polaris.

Scripts and full write-up: **https://github.com/hyper07/imac-llm**

---

## Speed

Qwen3-8B Q4_K_M, same 961-token prompt through each server's API, greedy:

| Engine | Prompt | Generation |
|---|---|---|
| llama.cpp | 113 | 14.3 |
| llama.cpp, flash attn on | 45 | 16–17 *(corrupts — trap 2)* |
| **Ollama native** | **111** | **16.7** |
| Ollama, flash attn off | 114 | 14.4 |

With flash attention off the two engines match. Ollama's lead is entirely its FA kernel, which works here where llama.cpp's doesn't.

Across models and backends:

| Model | GPU | CPU | Ollama CPU | Docker/WSL | Ollama Docker |
|---|---|---|---|---|---|
| Qwen3-8B | 16.5 | 5.2 | 4.5 | 5.3 | 3.4 |
| Qwen3-4B | 20.5 | 9.5 | 7.5 | 9.7 | 5.1 |

GPU is 3.2x CPU. Docker costs Ollama a third of its CPU speed.

**You can't use the GPU from Docker on Windows.** You can pass `--device /dev/dxg` and mount `/usr/lib/wsl`, but that channel is D3D12, not Vulkan. Mesa's Dozen driver isn't packaged, and RADV needs `/dev/dri`, which doesn't exist under WSL. The only Vulkan device is `llvmpipe` — a CPU rasterizer. It fails silently: `-ngl 99` still prints `backend = Vulkan` and gives you 5.3 tok/s. Works fine on real Linux.

**15 tok/s is faster than reading speed.** Fine as a daily chat box.

---

## What $250 buys

This is a good computer at $250 whether or not you ever run a model on it:

- **27" 5K display.** 5120x2880, 218 PPI, P3. Still an excellent panel.
- **64 GB RAM, user-upgradeable.** Hatch above the power port, four SO-DIMM slots, five minutes.
- **A complete machine.** i7, 1 TB NVMe, keyboard, trackpad. Nothing to build.

Local inference is an option on top, not the reason to buy.

**Small models are the sweet spot.** 8 GB of VRAM is the real constraint — the 8B at Q4 with 8k context uses 5.6 GB, and the 5K desktop takes another 1.6 GB. Nothing bigger fits. But 4B runs at 20.5 tok/s and the 8B at 15, which is faster than you read. If you want a 13B+ rig, this isn't it. If you want to try local models without buying hardware for it, it's plenty.

---

## Five config traps

**1. `--cache-ram 0`.** llama-server's RAM prompt cache saves KV state to host memory before reusing a slot — on regenerate, an edited message, a chat switch, or any front-end background call. Over Vulkan that readback runs at ~100 MB/s, so 1.2 GB of KV stalls **11.5 seconds before the first token**. The server's own timers show nothing wrong. Found it in the gap between `get_availabl` and `launch_slot_` in the log. Disabling it drops the stall to 0.15 ms. In-slot prefix caching still works.

**2. `--flash-attn off`.** `auto` turns FA on, and the Vulkan FA kernel is wrong on Polaris. Two failure modes: endless `?`, and fluent text unrelated to the prompt. A repeated-sentence prompt came back as *"peggy the cat is a cat who loves to play with balls"* — that one reads like a real answer.

Non-deterministic and worse on long prompts:

| Prompt | Pass | Fail |
|---|---|---|
| Short chats | 10 | 0 |
| 961-token, caching off | 2 | **2** |

A few clean chats prove nothing. FA is ~20% faster at generation but drops prompt processing from 113 to 45 tok/s, so it loses anyway. Tested b11026, b11063 and b11065 — all corrupt. Ollama's fork was clean on 13/13, so a working Vulkan FA path exists; upstream doesn't have it.

**3. Your first message may be junk.** Independent of any other setting. With plain flags, the first request after a model load returned repeated garbage (`softsoftsoft...`, `giú ****`, `*[ * * *`) on **2 of 3** fresh boots. Every later request was clean. One boot lost the GPU entirely with `ErrorDeviceLost`. Fix: fire a throwaway request at startup — 0 of 12 real requests corrupt across 4 boots. If your first message looks broken, just send it again.

**4. `--parallel 1` if you're the only user.** Default is 4 slots on a shared KV cache, and every decode step attends across all of them:

| Config | 1 | 2 | 3 | 4 |
|---|---|---|---|---|
| 4 slots (default) | 14.2 | 13.0 | 12.0 | **10.8** |
| `--parallel 1` | 14.3 | 14.4 | 14.3 | 14.3 |

−24% by the fourth conversation, and it stays slow until restart. Every new chat takes a slot. This also wrecks benchmarks — send different prompts to a multi-slot server and you're measuring slot fill.

**5. Check your front-end's background calls.** Open WebUI generates chat tags and follow-up suggestions after every message, each re-sending the whole conversation. Three prompt passes instead of one. Free to turn off.

---

## What didn't work

| Tried | Result |
|---|---|
| Draft-model speculation (0.6B, 4 configs) | 24–63% **slower** |
| `ngram-map-k` | 3.6x faster, **corrupts output** |
| Q8_0 instead of Q4_K_M | +5% prompt, −12% generation, +71% VRAM |
| `-ub` tuning | 512 already optimal |
| Bigger prompts | Flat, 112→128 tok/s from 128 to 2048 |

**Ngram speculation nearly shipped.** On an echo prompt it hit 53.9 vs 15.2 tok/s. On three prose prompts it measured 15.36 vs 15.36 — free speed. Then I ran a code prompt:

| Code prompt, 6 runs | corrupt |
|---|---|
| `ngram-map-k` | **6 of 6** |
| no speculation | **0 of 6** |

Pure `?` at 95/95 draft acceptance — the verifier agreeing with nonsense. **Test output across prompt types, not just tok/s.** Echo and prose both looked perfect.

**MTP works.** It's the only thing that sped up ordinary generation. Needs draft heads in the model — Qwen3-8B has none and refuses to start. Qwen3.5 publishes MTP GGUFs:

| Config | prose | code |
|---|---|---|
| Qwen3.5-4B-MTP `n-max 2` | 17.1 | **21.9** |
| Qwen3.5-9B-MTP `n-max 2` | 14.3 | **18.1** |
| Qwen3.5-2B-MTP | 14.1 | 19.2 |

+28% (4B) and +57% (9B) on code over their own baselines. Drafting is near-free because the head is inside the model — same reason ngram was fast, unlike a separate draft model.

Don't raise `n-max`: acceptance falls and rejected tokens are wasted work. The 4B at `n-max 6` dropped to 9.97 tok/s, 42% below its own baseline.

I didn't switch. These models have lower baselines, so the 9B lands at −7% prose / +17% code against the plain 8B, and only fits at half the context. The 2B is pointless — slower than the 4B, because fixed overhead dominates at small sizes.

---

## Everything measured

Qwen3-8B Q4_K_M unless noted, `--parallel 1`, greedy:

| Config | Prompt | Generation |
|---|---|---|
| **GPU, production** | **113** | **15.3** |
| GPU, `llama-bench` | 128 | 16.5 |
| GPU, Ollama native | 111 | 16.7 |
| GPU, 4B | 235 | 20.5 |
| CPU, 4 threads | 19.1 | 5.2 |
| Docker/WSL | 18.4 | 5.3 |
| Ollama Docker | 11.0 | 3.4 |

The pattern: on a GPU with no fp16, no int-dot and no matrix cores, anything that batches work is either slow or wrong. Every real win came from removing stalls, not adding throughput.

---

## Prompt processing is the ceiling

128 tok/s, and it doesn't move. **The Pro 580 has no fp16 math at all** — `shaderFloat16 = false`, and llama.cpp reports `fp16: 0 | bf16: 0 | int dot: 0 | matrix cores: none`. Polaris is GCN 4; packed half-precision came with Vega. Every Q4_K block is unpacked to fp32 in-shader.

Keep these straight: `shaderFloat16` (fp16 **math**) is permanently false here. `storageBuffer16BitAccess` (16-bit **storage**) is what llama.cpp actually needs, and that's what the old driver was missing. People conflate them and conclude Polaris can't run this.

A 4,000-token document takes ~30 s before the first word. Fine for chat, annoying for RAG. The 4B is 1.8x faster at this.

Prompt caching does the real work: same 980-token prefix twice, 8.94 s cold → **0.87 s** warm.

---

## The driver blocks everything first

Apple's Boot Camp driver is from July 2020 and kills Vulkan outright:

    ggml_vulkan: device Vulkan0 does not support 16-bit storage

This is **not** a hardware limit. Install **AMD's Boot Camp Unified Driver R6.4** (Aug 2025), which lists this iMac. Driver goes 26.20.13001 → 30.0.13045, Vulkan 1.1.113 → 1.2.196, and it works.

Also: **Windows 11 isn't supported on this hardware.** i7-7700K is 7th-gen, and Intel Macs have no TPM 2.0. I bypassed the check. Runs fine, but you're off the supported path.

---

## Before you buy one

These turn up on Facebook Marketplace and local classifieds regularly — that's where mine came from. Things to check before handing over cash:

- **Confirm it's the 27", not the 21.5".** Only the 27" has upgradeable RAM.
- **Check the storage.** Fusion Drive and plain-HDD configs exist and listings often don't say which. Mine is NVMe at 2,062 MB/s. A Fusion config means a long wait every time you load a model.
- **Check the GPU.** Radeon Pro 570/575/580 all exist. The 580 is the 8 GB one.
- **It can't be an external display for another machine.** Target Display Mode ended with the 2014 models, so it's a whole computer or nothing.

Otherwise it's a 2017 machine: no warranty, glossy screen, audible fans.

---

**Verdict:** buy it because a 27" 5K machine with 64 GB of RAM for $250 is a good deal. Small models on top are a genuine bonus — 15 tok/s on an 8B, 20 on a 4B — once you get past a dead driver, a broken FA kernel, a corrupting speculation setting and two bad llama-server defaults. Not an LLM rig. A good cheap computer that also does this.

Everything — scripts, flags, every negative result: **https://github.com/hyper07/imac-llm**

Happy to run benchmarks if anyone wants a specific model tested.
