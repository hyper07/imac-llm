# Reddit post draft

A condensed write-up of the results in [README.md](README.md), aimed at
r/LocalLLaMA. Every number here is measured on the machine described below; the
full method, the flags and the negative results are in the README.

Note on the hardware: this is the *top* 2017 configuration (i7-7700K + Radeon
Pro 580 8 GB), and the 64 GB of RAM is an aftermarket upgrade rather than a
stock option.

---

**Title:** Benchmarked a $250 2017 iMac as a local LLM box: 16.7 tok/s on Qwen3-8B, and four config traps that cost me most of a day

---

Picked up a 27" 5K iMac (2017) for **$250** and ran a local LLM stack on it properly. Posting the full numbers plus the things that went wrong, because I couldn't find either when I was looking.

**Hardware:** Core i7-7700K (4c/8t), Radeon Pro 580 8 GB, 64 GB DDR4-2400, 1 TB **PCIe NVMe** SSD (`APPLE SSD SM1024L`, 2,062 MB/s measured unbuffered), Windows 11 Pro via Boot Camp. GPU inference through llama.cpp's Vulkan backend — no ROCm on Polaris.

**Check the storage before you buy one.** The 2017 27" shipped as a Fusion Drive (small SSD cache bolted onto a 5400 rpm spinner), a plain HDD, or a real PCIe NVMe blade SSD. Mine is the NVMe. GGUFs are big — the 8B is 4.7 GB — so a Fusion or HDD config means a long wait every time you cold-load a model, and the listings don't always make it obvious which you're getting. This is the spec people get burned on, more than the CPU.

Launch scripts, the full write-up and every benchmark command are here: **https://github.com/hyper07/imac-llm**

---

## What you actually get

Qwen3-8B Q4_K_M, identical 961-token prompt through each server's own API, 128 tokens generated, greedy, three runs each. This is served performance, not a synthetic bench:

| Engine | Prompt tok/s | Generation tok/s |
|---|---|---|
| llama.cpp b11063, flash attn off | 113 | 14.3 |
| llama.cpp b11063, flash attn **on** | 45 | 16–17 *(corrupts output — see #2)* |
| **Ollama native, defaults** | **111** | **16.7** |
| Ollama native, `OLLAMA_FLASH_ATTENTION=false` | 114 | 14.4 |

**With flash attention off the two engines are identical** (113 vs 114, 14.3 vs 14.4). Unsurprising — Ollama bundles a llama.cpp fork. Ollama's entire 17% lead is its flash-attention kernel, which works on this GPU where upstream's does not.

Scale across models and backends (`llama-bench` for llama.cpp, API timings for Ollama — see the harness note at the end):

| Model | GPU | CPU (4 threads) | Ollama CPU | Docker/WSL `-ngl 99` | Ollama in Docker |
|---|---|---|---|---|---|
| Qwen3-8B Q4_K_M | 16.5 tok/s | 5.2 | 4.5 | 5.3 | 3.4 |
| Qwen3-4B Q4_K_M | 20.5 tok/s | 9.5 | 7.5 | 9.7 | 5.1 |

GPU is 3.2x CPU on the 8B. **Docker costs Ollama a third of its CPU speed** (WSL2 VM).

**And no, you can't containerize the GPU on Windows** — I tried properly. You *can* pass `--device /dev/dxg` into a container and mount `/usr/lib/wsl`, so the GPU is reachable. But that channel is D3D12, not Vulkan; translating needs Mesa's Dozen driver (`dzn`), which isn't packaged in Ubuntu or Debian, and RADV needs a `/dev/dri` node that doesn't exist under WSL. The only Vulkan device is `llvmpipe`, a CPU rasterizer, and `llama-server --list-devices` returns `(none)`. It fails **silently**: with `-ngl 99` llama-bench still prints `backend = Vulkan` and hands you 5.28 tok/s, which is CPU speed (native CPU: 5.20), not the 16.5 of the real GPU. On Linux this works fine via `/dev/dri` — it's specifically a Windows limitation.

**16.7 tok/s is faster than reading speed.** This machine is genuinely usable as a daily chat box.

---

## The four config traps

Each of these cost real time and none are obvious from the docs.

**1. `--cache-ram 0` — an ~11.5 second stall that reports nothing wrong.** llama-server's RAM prompt cache saves a slot's KV state to host memory before reusing that slot with a different continuation: regenerate, an edited message, a chat switch, or any front-end background call. That save is a GPU-to-host readback, and over Vulkan on Polaris it runs at roughly 100 MB/s, so ~1.2 GB of KV takes ~11.5 s — *before the first token*, while `prompt_ms` and `predicted_ms` both look perfectly normal. I found it by diffing wall time against the server's own timers, then spotting the gap between `get_availabl` and `launch_slot_` in the log:

    0.08.990  get_availabl: selected slot by LCP similarity, f_sim_best = 1.000
    0.20.519  launch_slot_: processing task 41          <- 11.5 s later

Disabling it takes that to ~0.15 ms. In-slot prefix caching is a separate mechanism and still works. If your TTFT is randomly terrible on an old AMD card, check this first.

**2. `--flash-attn off`, and a quick test will lie to you.** `--flash-attn auto` resolves to *on* here, and the Vulkan FA kernel is intermittently wrong on Polaris. Two failure modes: an endless stream of `?`, and — nastier — fluent, confident text with nothing to do with the prompt. A 961-token repeated sentence came back as *"peggy the cat is a cat who loves to play with balls"*. That one reads like a real answer.

It's non-deterministic and biased toward long prompts. Controlled retest, same server, same day:

| Prompt | Pass | Fail |
|---|---|---|
| Short chats (≤30 tokens) | 10 | 0 |
| 961-token raw, caching off | 2 | **2** |

So a handful of clean chats prove nothing. The bait is real — FA is ~20% faster at generation (14.3 → 17.3) — but it also collapses prompt processing from ~113 to ~45 tok/s, so it loses on time-to-first-token too. I isolated it by running the identical model, flags and prompt on the CPU backend, which answered correctly.

**You can't dodge it by pinning an older build.** I ran the same test on upstream b11026 (Sep 17), b11063 and b11065 (Sep 20): all three corrupted at least one of four long prompts. Ollama's fork was clean on 13/13 including six fresh ~1000-token prompts, with prompt processing intact. A working Vulkan FA path for Polaris exists — upstream just doesn't have it. That's the one concrete reason to run Ollama here instead.

To verify on your own card: send a ~1000-token repeated-sentence prompt with prompt caching off, at least four times, and require every output to continue the sentence.

**3. `--parallel 1` if you're the only user.** llama-server defaults to 4 slots sharing a unified KV cache, and every decode step attends across *all* slots' cached tokens. Each new conversation that lands in a fresh slot slows everything after it, and slots keep their stale KV until restart:

| Config | Prompt 1 | 2 | 3 | 4 |
|---|---|---|---|---|
| 4 slots, unified KV (default) | 14.2 | 13.0 | 12.0 | **10.8** |
| `--parallel 1` | 14.3 | 14.4 | 14.3 | 14.3 |

−24% by the fourth conversation. In a web UI every new chat is a distinct prompt, so a normal session degrades within minutes. Ollama's runner uses one slot by default, which is part of why it looks faster in mixed use. (`--no-kv-unified` with 4 slots also fixes it but caps each slot at 2048 tokens.)

This also poisons benchmarks: if you send several *different* prompts to a multi-slot server you're measuring slot fill, not whatever you think you're testing. It cost me a couple of bogus results before I caught it.

**4. Your front-end is making extra calls.** Open WebUI defaults to generating chat tags and follow-up suggestions after every message, each re-sending the whole conversation as its own prompt pass. That's three passes per message instead of one. Free to turn off.

---

## What did NOT help

Negative results, all measured:

| Tried | Result |
|---|---|
| **Speculative decoding** (Qwen3-0.6B draft, 4 configs) | **24–63% slower.** Acceptance was fine, 61–94% |
| Q8_0 instead of Q4_K_M | +5.3% prompt, −11.6% generation, +71% VRAM |
| `-ub` micro-batch tuning | 512 already optimal; 1024 gains 0.2% |
| Larger prompts amortizing overhead | Flat, 112→128 tok/s from 128 to 2048 tokens |
| ngram speculation | No measurable change on chat prompts |

**Speculative decoding deserves a note** because it's the lever everyone reaches for. It failed for a structural reason: batch-1 decode uses llama.cpp's fast memory-bound mat-vec kernel, but *verifying* 5–6 draft tokens is a small-batch matmul, and on Polaris — `fp16: 0`, `int dot: 0`, `matrix cores: none` — that path is slow enough that checking six tokens costs more than generating them one at a time. Same weakness caps prompt processing. Gotcha if you try it: `--spec-type` defaults to `none`, so `-md` alone loads the draft model and silently never uses it. Look for `draft acceptance` in the log.

**Prompt caching, by contrast, does most of the real work** — same ~980-token prefix twice: 8.94 s cold → **0.87 s** warm, 964/979 tokens reused. The first long paste hurts; the rest of the conversation doesn't.

---

## Prompt processing is the real ceiling

128 tok/s, and it doesn't move. **The Pro 580 has no fp16 math at all** — Vulkan reports `shaderFloat16 = false`, llama.cpp reports `fp16: 0 | bf16: 0 | int dot: 0 | matrix cores: none`. Polaris is GCN 4; packed half-precision arrived with Vega, so anything half-precision here is widened and executed as fp32 at best. With no fp16, no bf16, no DP4A and no matrix cores, every Q4_K block is unpacked to fp32 in-shader and multiplied with plain ALU math. ~6.2 TFLOPS against ~16.4 GFLOP/token puts the theoretical ceiling near 380 tok/s; 128 is about 34% of that, which is normal for a dequantize-in-shader path.

Worth keeping straight, since people conflate them: `shaderFloat16` (fp16 **math**) is permanently false in this silicon, while `storageBuffer16BitAccess` (16-bit **storage**) is what llama.cpp actually requires — and that is what Apple's 2020 driver failed to expose. Missing fp16 math costs speed; missing 16-bit storage stopped it running at all. Anyone telling you "Polaris can't do it" is usually mixing these two up.

Practically: a 4,000-token document takes ~30 s before the first word. Fine for chat, annoying for long-document RAG. The 4B is 1.8x faster at this specific task (235 tok/s) if you paste a lot.

---

## Before any of this works: the driver

Apple's Boot Camp GPU driver is from **July 2020** and blocks Vulkan outright. It advertises `VK_KHR_16bit_storage` but doesn't expose `storageBuffer16BitAccess`, so llama.cpp refuses to load:

    ggml_vulkan: device Vulkan0 does not support 16-bit storage

This is **not** a Polaris hardware limit — you'll see people claim the card can't do it, conflating it with `shaderFloat16`, which Polaris genuinely lacks and llama.cpp doesn't need. Install **AMD's Boot Camp Unified Driver R6.4** (Aug 2025), which officially lists this iMac. Driver 26.20.13001 → 30.0.13045, Vulkan 1.1.113 → 1.2.196, and the GPU works.

Also note **Windows 11 isn't supported on this hardware** — the i7-7700K is 7th-gen (Win11 wants 8th+) and Intel Macs have no TPM 2.0. I bypassed the install check. Runs fine, but you're off the supported path.

---

## On the hardware itself

Briefly, since this is a performance post: 5120x2880 at 27" for $250 is the part that's hard to argue with — a standalone 5K panel still costs more than the whole machine. RAM is user-upgradeable on the 27" (not the 21.5"): a hatch above the power port, four SO-DIMM slots, five minutes, no disassembly. 64 GB of DDR4-2400 SO-DIMM is cheap now, and that's the main reason to pick this over other all-in-ones.

Downsides are what you'd expect from a 2017 machine: no warranty, glossy screen, audible fans under load, and 8 GB of VRAM that the 5K display is already eating into — llama-server holds ~5.6 GB of it, so 8192 context is about the ceiling.

**Verdict:** ~16.7 tok/s on an 8B for $250, once you get past a dead driver, a broken FA kernel, and two llama-server defaults that are wrong for single-user use. If you want something that works out of the box, buy something else.

Scripts with all the flags baked in, the long-form write-up and the exact `llama-bench` / API commands used for every number above: **https://github.com/hyper07/imac-llm** — happy to answer questions or run extra benchmarks if anyone wants a specific model tested.

---

*Harness note: the engine-comparison table is like-for-like through each server's API. The model/backend table mixes `llama-bench` (llama.cpp) with API timings (Ollama) — `llama-bench` overstates what you get when serving, 16.5 vs 14.3 on the same flags, so trust the first table for absolute numbers and the second for ratios.*
