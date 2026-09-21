# Local LLM on the iMac 2017 (Radeon Pro 580)

Stack: **llama.cpp** (native Windows, OpenAI-compatible API) + **Open WebUI** (Docker).

Target machine: iMac (Retina 5K, 27-inch, 2017) — Radeon Pro 580 8 GB,
Core i7-7700K, 64 GB RAM, 1 TB PCIe NVMe SSD (`APPLE SSD SM1024L`, measured
2,062 MB/s unbuffered) — running Windows 11 Pro (10.0.26200) under Boot Camp.
Download links for every component are in *[Software sources](#software-sources)*.

Storage matters when buying one of these. The 2017 27" shipped in three
configurations: a **Fusion Drive** (a small SSD cache in front of a 5400 rpm
spinning disk), a plain hard disk, and a **PCIe NVMe blade SSD**. This machine
has the NVMe one. Model files are large — the 8B here is 4.7 GiB — so a Fusion
or spinning configuration adds a long wait on every cold model load and is
worth avoiding.

| Piece | Where |
|---|---|
| Web UI | http://localhost:3000 |
| LLM API | http://127.0.0.1:8080/v1 (API key `local-llama`) |
| Model in use | `models\Qwen3-8B-Q4_K_M.gguf` (4.7 GiB) |
| Also available | `models\Qwen3-4B-Q4_K_M.gguf` (2.3 GiB) — faster, less capable |

Open WebUI runs in Docker and reaches the natively-running llama-server via
`host.docker.internal:8080`. The GPU stays on the Windows side — Docker Desktop
cannot pass an AMD GPU into a Linux container, so the model server must run
natively for GPU acceleration to be possible at all. (On Linux that limitation
does not exist and the whole stack can be containerised — see
**[OTHER-OS.md](OTHER-OS.md)**.)

Thinking of running Linux or macOS on this machine instead?
**[OTHER-OS.md](OTHER-OS.md)** covers both: why Linux is plausibly faster, and
why macOS Ventura's Metal backend is a trap on a discrete AMD GPU.

## Daily use

1. Double-click **`start-llama-server.cmd`** and leave the window open.
2. Open http://localhost:3000 and pick **Qwen3-8B** in the model dropdown.

That runs in **fast mode**, with Qwen3's reasoning turned off — simple questions
answer in about a second. For hard maths or multi-step problems, stop it and run
**`start-llama-server-thinking.cmd`** instead, which reasons first and shows a
collapsible *Thinking* block in the UI at roughly 20-30 s per reply. Both use
port 8080, so only one can run at a time.

This model's chat template ignores the usual `/think` and `/no_think` prompt
tokens, so switching modes means restarting the server — there is no
per-message toggle.

Open WebUI starts automatically with Docker (`restart: always`); llama-server
does not, so it must be started manually after every reboot or logout. Closing
its window stops the model server, and the Web UI will then show no models.

To start it automatically at login, put a shortcut to the `.cmd` in the Startup
folder (no admin needed):

```powershell
$s = (New-Object -ComObject WScript.Shell).CreateShortcut(
    "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup\llama-server.lnk")
$s.TargetPath = "C:\llama-vulkan\start-llama-server.cmd"
$s.WindowStyle = 7   # minimised
$s.Save()
```

Delete that `.lnk` to undo it.

## GPU status: working

Resolved on 2026-09-20 by installing AMD's **Boot Camp Unified Driver R6.4**
(`driver\`, staged by `install-gpu-driver.cmd`).

Before, on the Apple-supplied Boot Camp driver **26.20.13001.53002
(2020-07-31)**, llama.cpp refused to load on the GPU:

```
ggml_vulkan: device Vulkan0 does not support 16-bit storage.
```

That driver advertised the `VK_KHR_16bit_storage` extension but reported no
16-bit storage feature struct, so `storageBuffer16BitAccess` read as
unsupported. It was a driver limitation, not a hardware one — Polaris does
support 16-bit storage under current drivers. (It genuinely lacks fp16 *math*,
`shaderFloat16 = false`, but llama.cpp does not require that.)

| | Old | New |
|---|---|---|
| Driver | 26.20.13001.53002 (2020-07-31) | 30.0.13045.22003 (2025-11-05) |
| Vulkan | 1.1.113 | 1.2.196 |
| GPU usable | no | yes |

If a future Windows update rolls the driver back, `check-gpu-ready.ps1` will
say so and `start-llama-server-cpu.cmd` remains as a fallback.

## Performance

Measured 2026-09-20 on this machine. Ollama imported the **identical GGUF
files** from `models\` via a Modelfile rather than pulling its own copies, so
weights and quantisation match exactly. Ollama placement was confirmed with
`ollama ps` for every run. Both native CPU runs are 4 threads / 100% CPU; the
Docker container sees 4 CPUs.

**Two different harnesses are mixed in these two tables.** The llama.cpp
columns are `llama-bench` (`-p 512 -n 128`, synthetic prompt, near-empty
context, flash attention off). The Ollama columns are its `/api/generate`
timing fields on a ~960-token `raw` prompt, with Ollama's default flash
attention *on*. They are not directly comparable, and `llama-bench` overstates
what the server delivers: served through the API with the same prompt, the 8B
measures **~113 pp / ~14.3 tg**, not 128 / 16.5. The like-for-like comparison
is in *What the numbers say*; these tables are kept for the CPU columns and the
4B-vs-8B ratios, which hold either way.

### Generation speed (tokens/sec — higher is better)

| Model | llama.cpp GPU (bench) | Ollama native GPU (FA on) | llama.cpp CPU | Ollama native CPU | Ollama Docker CPU |
|---|---|---|---|---|---|
| **Qwen3-8B** Q4_K_M | 16.48 | 16.73 | 5.20 | 4.53 | 3.36 |
| **Qwen3-4B** Q4_K_M | 20.51 | 20.82 | 9.50 | 7.53 | 5.07 |

### Prompt processing (tokens/sec)

| Model | llama.cpp GPU (bench) | Ollama native GPU (FA on) | llama.cpp CPU | Ollama native CPU | Ollama Docker CPU |
|---|---|---|---|---|---|
| **Qwen3-8B** Q4_K_M | 128.33 | 110.19 | 19.14 | 22.13 | 11.00 |
| **Qwen3-4B** Q4_K_M | 235.16 | 187.55 | 35.42 | 43.53 | 20.85 |

### What the numbers say

**The headline tables mix two harnesses**, and that hid something. The
llama.cpp rows are `llama-bench` (synthetic prompt, near-empty context); the
Ollama rows are its API timings on a ~960-token prompt. Measured the *same*
way — identical 961-token raw prompt through each server's API, 128 tokens,
greedy, three runs each, llama.cpp re-measured afterwards to rule out thermal
drift — the picture changes:

| 8B, GPU, same prompt, same harness | Prompt (tok/s) | Generation (tok/s) | Flash attention |
|---|---|---|---|
| llama.cpp b11063, production flags | 113 | 14.3 | off |
| llama.cpp b11063, `--flash-attn on` | **45** | 16.0–17.3 | on — corrupted 2 of 4 long prompts |
| Ollama native, defaults | 111 | **16.7** | on — 13 of 13 clean, incl. six fresh ~970-token prompts |
| Ollama native, `OLLAMA_FLASH_ATTENTION=false` | 114 | 14.4 | off |

Three conclusions. First, **with flash attention off the two engines are
identical** (113 vs 114, 14.3 vs 14.4) — unsurprising, since Ollama bundles a
llama.cpp fork (`build 1, commit 391fac164`). Second, **Ollama's 17% generation
lead is entirely its flash-attention kernel**, which its fork enables on this
GPU by default. Unlike upstream b11063's FA, Ollama's produced correct output
on every sample and kept prompt processing at full speed — so a Vulkan FA path
that works on Polaris exists; today's upstream build just does not have it.
Third, **`llama-bench` overstates what you get when serving**: 16.5 tok/s in
the bench versus 14.3 through the API with the same flags. Use the serving
numbers for expectations. The earlier claim that llama.cpp "keeps a 14–25% lead
on prompt processing" was a harness artifact and is withdrawn.

**Native Ollama uses this GPU.** It ships with `OLLAMA_VULKAN=true` and detects
the Radeon Pro 580 through Vulkan. The Docker container could not use the GPU
at all, because Docker Desktop cannot pass an AMD GPU into a Linux container —
that limitation is about Docker, not Ollama.

**Docker costs Ollama about a third of its CPU speed** (4.53 vs 3.36 tok/s on the
8B, 7.53 vs 5.07 on the 4B) from running inside a WSL2 VM. Do not benchmark
Ollama in Docker on Windows and treat the result as Ollama's speed — measured
that way it looks 55-87% slower than llama.cpp, when the real gap against the
native build is 15% on the 8B and 26% on the 4B.

**On the GPU, keep the 8B.** Dropping to 4B buys only 24% more generation speed
(20.5 vs 16.5 tok/s) for a large loss in capability — much less than halving the
parameters suggests, because on Polaris an 8B Q4 is not purely
memory-bandwidth bound. Prompt processing does scale properly (1.8x), so the 4B
is meaningfully quicker at digesting long documents.

**The 4B earns its place on CPU**, where it is 83% faster (9.5 vs 5.2 tok/s) —
the right choice if the GPU ever breaks and the CPU fallback is in use.

**GPU vs CPU** is 3.2x on the 8B and 2.2x on the 4B against llama.cpp's own CPU
backend.

In practice, in fast mode a short question answers in about 1.2 s end to end.

### Why prompt processing is only ~128 tok/s

Prompt processing is compute-bound — large matrix multiplies — where generation
is memory-bound. This GPU is poorly suited to that half of the job. llama.cpp
reports its capabilities as:

```
Radeon Pro 580 | fp16: 0 | bf16: 0 | int dot: 0 | matrix cores: none
```

All four of the accelerations llama.cpp's Vulkan backend would normally use are
absent, so every Q4_K block is dequantised to **fp32** in the shader and
multiplied with plain fp32 ALU math. The RX 580's ~6.2 TFLOPS fp32 against
~16.4 GFLOP per token for an 8B model gives a theoretical ceiling near 380
tok/s; 128 tok/s is about 34% of that, which is normal efficiency for a
dequantise-in-shader path with no matrix units.

It is a hardware ceiling, not a misconfiguration — two measurements confirm it:

| Prompt size | 128 | 512 | 1024 | 2048 |
|---|---|---|---|---|
| pp tok/s | 111.95 | 127.43 | 126.16 | 122.94 |

| `-ub` micro-batch | 128 | 256 | 512 | 1024 |
|---|---|---|---|---|
| pp512 tok/s | 109.79 | 58.61 | **128.05** | 128.29 |

Throughput is flat from 512 tokens upward, so it is steady-state cost rather
than fixed overhead, and the default `-ub 512` is already optimal — raising it
to 1024 gains 0.2%. Flash attention does not help either (122.15 with it on
versus 128.33 off), and it cannot be used here anyway.

What this means day to day: a 4,000-token document takes roughly 30 s to ingest
before the first word appears.

### Reducing prompt processing time

The ~128 tok/s ceiling itself cannot be moved, but you can avoid paying it
repeatedly. In order of measured impact:

**1. Prompt caching — 10x, and already on.** llama.cpp caches the prompt prefix,
so a continuing conversation only pays for genuinely new tokens. Measured with
the same ~980-token prefix sent twice:

| | Time | Cached tokens |
|---|---|---|
| Cold | 8.94 s | 0 / 981 |
| Same prefix again | **0.87 s** | 964 / 979 |

This is why the first long paste hurts and the rest of the conversation does not.

**2. Turn off Open WebUI's background task calls.** By default Open WebUI fires
extra LLM requests after every message, each re-sending the whole conversation
for its own prompt-processing pass:

```
task.tags.enable      = true     extra call per message
task.follow_up.enable = true     extra call per message
task.title.enable     = false    already off here
```

With both enabled a single message costs **three** prompt passes, not one.
Disabling them is free; the cost is losing auto-generated chat tags and the
suggested follow-up buttons. Set them under *Settings > Admin Settings >
Interface*, or directly:

```powershell
docker exec open-webui-vulkan python -c "import sqlite3,json,time;c=sqlite3.connect('/app/backend/data/webui.db');[c.execute('update config set value=?,updated_at=? where key=?',(json.dumps(False),int(time.time()),k)) for k in ('task.tags.enable','task.follow_up.enable')];c.commit()"
docker compose -f C:\llama-vulkan\docker-compose.yml restart
```

**3. `--cache-reuse N`** is off by default (`0`). It reuses cached chunks via KV
shifting when the prefix changes partway — history being trimmed, or a system
prompt edited. `--cache-reuse 256` is the usual value. Not enabled here because
KV shifting can slightly affect output quality; try it if you hit frequent
cache misses.

**4. Use the 4B for long documents** — 235 vs 128 tok/s, a real 1.8x on exactly
this task.

### Quantisation format: tested, not worth it

Polaris has no integer dot product, so weights are unpacked to fp32 in the
shader. Q8_0 has a far simpler structure than Q4_K's superblocks, so it should
dequantise more cheaply. It does — but not enough to matter:

| Quant | Prompt processing | Generation | Size |
|---|---|---|---|
| Q4_K_M | 235.46 | **20.47** | 2.32 GiB |
| Q8_0 | **247.88** | 18.09 | 3.98 GiB |

Only +5.3% on prompts, against −11.6% on generation and 1.7x the VRAM. Generation
is bandwidth-bound, so the extra bytes cost more than the simpler unpacking
saves. An 8B at Q8_0 would not fit in 8 GB regardless. **Stay on Q4_K_M.**

### Speculative decoding: tested, net loss

The one large software lever for *generation* speed. A small draft model
proposes several tokens; the big model verifies them in one batched pass. On
hardware where a batch of 6 costs little more than a batch of 1, that yields
1.5–2.5x. Tested here with Qwen3-0.6B Q8_0 as the draft
(`models\Qwen3-0.6B-Q8_0.gguf`, 610 MB), same tokenizer family as the 8B:

```
--spec-type draft-simple -md models\Qwen3-0.6B-Q8_0.gguf -ngld 99 --spec-draft-n-max 16 --spec-draft-p-min 0.8
```

Note `--spec-type` **defaults to `none`** in this build — `-md` alone loads the
draft model and then never uses it. The first attempt did exactly that and
produced five identical rows; acceptance stats in the log are the tell.

Server-side generation tok/s, greedy, 200-token code prompt and 125-token prose
prompt. Draft-on-GPU runs used `--ctx-size 4096` to make room in VRAM.

| Config | Code | Prose | Acceptance (code / prose) |
|---|---|---|---|
| **Baseline, no draft** | **13.65** | **15.36** | — |
| Draft on CPU, n-max 8, p-min 0.5 | 8.04 | 5.72 | 62% / 39% |
| Draft on GPU, n-max 8, p-min 0.5 | 8.88 | 6.31 | 61% / 37% |
| Draft on GPU, n-max 16, p-min 0.8 | 10.48 | 8.74 | 71% / 94% |
| Draft on GPU, n-max 4, p-min 0.0 | 10.16 | 5.89 | 72% / 32% |
| ngram-simple (no draft model) | 15.30 | 15.28 | no hits on chat prompts |

Every draft configuration is **24–63% slower** than no draft, even the one with
94% acceptance. The reason is the same one that caps prompt processing:
batch-1 decode runs on the fast, memory-bound mat-vec kernel, but verifying a
handful of draft tokens is a small-batch matmul, and on Polaris (no fp16, no
matrix cores) that path is slow enough that checking six tokens costs more than
generating them one by one. The draft model is not free either — with this
GPU's per-step overhead a 0.6B model is nowhere near 10x faster than the 8B.
Baseline code varied 13.7–15.4 between runs; the speculative results sit far
outside that.

Ngram speculation (`--spec-type ngram-simple`, no draft model) changed nothing
on chat prompts. It only helps when the output repeats the input verbatim, as
in code edits.

### Levers that do not work here

| Tried | Result |
|---|---|
| `-ub` micro-batch tuning | 512 already optimal; 1024 gains 0.2% |
| Larger prompts amortising overhead | Flat — 112 to 128 tok/s across 128-2048 |
| Flash attention | Slower on prompts (122 vs 128) *and* produces garbage |
| Q8_0 instead of Q4_K_M | +5% prompts, −12% generation, +71% VRAM |
| Speculative decoding, 0.6B draft, 4 configs | 24–63% **slower**; small-batch verify beats no batch here |
| ngram speculation | no measurable change on chat prompts |
| Pinning another upstream build to get flash attention | b11026 and b11065 corrupt long prompts and halve pp exactly like b11063; the working FA kernel is Ollama's fork only |
| Default 4 slots with unified KV | not a speedup lever but a **slowdown**: −24% by the fourth conversation; fixed with `--parallel 1` (*One server slot*) |

What *does* move the needle is not throughput but the two stalls: the
~11.5 s RAM-prompt-cache readback (*RAM prompt cache must be off*, fixed) and
Open WebUI's extra task calls (*Reducing prompt processing time*, item 2).
Raw tok/s on this card is a hardware ceiling; the remaining upgrade is a GPU
with fp16 and matrix cores.

### Reproducing the benchmark

llama.cpp, with the server stopped so it is not holding VRAM:

```powershell
# GPU
.\llama-bench.exe -m models\Qwen3-8B-Q4_K_M.gguf -ngl 99 -fa 0 -p 512 -n 128
# CPU
.\llama-bench.exe -m models\Qwen3-8B-Q4_K_M.gguf -dev none -ngl 0 -t 4 -r 2 -p 512 -n 128
# prompt-size scaling / micro-batch sweep
.\llama-bench.exe -m models\Qwen3-8B-Q4_K_M.gguf -ngl 99 -fa 0 -p 128,512,1024,2048 -n 0
.\llama-bench.exe -m models\Qwen3-8B-Q4_K_M.gguf -ngl 99 -fa 0 -p 512 -n 0 -ub 128,256,512,1024
```

`-fa 0` is essential — see *Flash attention must stay off*.

Ollama was run only to produce the comparison and is **not** part of the running
stack. Native Ollama 0.34.2 is installed at
`%LOCALAPPDATA%\Programs\Ollama\ollama.exe`; its server is stopped.

```powershell
$ol = "$env:LOCALAPPDATA\Programs\Ollama\ollama.exe"
& $ol serve                       # GPU via Vulkan, the default
$env:OLLAMA_LLM_LIBRARY = "cpu"   # forces 100% CPU, then restart serve
```

Note that `num_gpu: 0` alone does **not** give a clean CPU measurement — Ollama
still placed 2-3% on the GPU and used Vulkan for prompt processing, inflating
pp to 87.66 against a true CPU figure of 22.13. `OLLAMA_VULKAN=false` is not
enough either, because it re-detects the card through ROCm
(`HSA_OVERRIDE_GFX_VERSION=8.0.3` is set in this environment). Only
`OLLAMA_LLM_LIBRARY=cpu` produced `100% CPU` in `ollama ps`.

### Leftovers from benchmarking

| Item | Size | Remove with |
|---|---|---|
| Docker container `ollama-bench` (stopped) | — | `docker rm ollama-bench` |
| Docker volume `ollama` | ~7 GB | `docker volume rm ollama` |
| Native models `qwen3-8b-local`, `qwen3-4b-local` | ~7 GB | `ollama rm qwen3-8b-local qwen3-4b-local` |
| `models\Qwen3-4B-Q8_0.gguf` (quant test only) | 3.98 GB | `Remove-Item models\Qwen3-4B-Q8_0.gguf` |
| `models\Qwen3-0.6B-Q8_0.gguf` (speculative-decoding test only) | 610 MB | `Remove-Item models\Qwen3-0.6B-Q8_0.gguf` |
| `test-builds\` (upstream b11026 and b11065, flash-attention test only) | ~130 MB | `Remove-Item -Recurse test-builds` |

The native ones are duplicates of the GGUFs already in `models\`. Pre-existing
native models (`qwen3:4b`, `llama3.2`, `gemma4:e4b`) were not touched.

## Constraints and required flags

### Flash attention must stay off

`--flash-attn off` in the launch scripts is **required**, not a tuning choice.
llama.cpp defaults to `auto`, which resolves to *enabled* on this card, and the
Vulkan FA kernel is **intermittently wrong on Polaris**. Two failure modes were
observed:

- an unbroken run of `?` characters instead of an answer;
- fluent, confident English with no relation to the prompt — 961 tokens of a
  repeated sentence came back as *"peggy the cat is a cat who loves to play
  with balls"*. This one is worse, because it reads as a real answer.

It is non-deterministic and biased toward long prompts. Controlled retest with
FA on, same server, same day:

| Prompt | Passes | Fails |
|---|---|---|
| Short chat prompts (≤30 tokens) | 10 | 0 |
| 961-token raw prompt, `cache_prompt: false` | 2 | **2** |

Earlier the same day a *short* prompt failed reliably, so short prompts are not
safe either — they just fail less often. A few clean samples prove nothing.
The failures reproduced with both `--cache-ram 0` and the default, so the RAM
prompt cache is not involved (a hypothesis that was tested and dropped).

The bait is real, which is why this section exists: FA gives about **+20%
generation** (14.3 → 17.3 tok/s). It also **collapses prompt processing** on
the 961-token prompt from ~113 to ~45 tok/s, steadily, so it loses on
time-to-first-token as well as on correctness.

The fault is in the GPU backend, not the model: the identical model, flags and
prompt on the CPU backend (`--device none --n-gpu-layers 0`) answered correctly.

To re-verify after a llama.cpp upgrade, do not trust a couple of chats. Send a
~1,000-token raw prompt (one sentence repeated 60x) to `/completion` with
`cache_prompt: false` at least four times, and require every output to
continue the sentence.

Ollama's bundled fork (`build 1, commit 391fac164`) enables FA on this GPU by
default — its log shows `resolve_fused_ops: Flash Attention enabled` — and was
clean on 13 of 13 samples with prompt processing intact. So a Vulkan FA path
that works on Polaris exists. It is **not in upstream**, at any nearby version:
three upstream releases were tested the same way (four fresh ~960-token raw
prompts plus two short ones, FA on) and every one corrupted at least one long
prompt and collapsed prompt processing:

| Upstream build | Released | Long prompts corrupted | pp with FA on |
|---|---|---|---|
| b11026 | 2026-09-17 | 1 of 4 — `?` spam | ~43 tok/s |
| **b11063** (installed) | 2026-09-20 | 2 of 4 — `?` spam; off-topic English | ~45 tok/s |
| b11065 | 2026-09-20 | 1 of 4 — off-topic Chinese meta-commentary | ~43 tok/s |

b11026 predates Ollama's `ggml-vulkan.dll` (dated 2026-09-18), so this is not a
recent regression that an older pin would avoid — the working kernel is
Ollama's own. **Pinning a different upstream build is not a lever.** The only
way to get FA's ~17% generation gain on this GPU today is to serve with native
Ollama, which Open WebUI supports directly and for which `qwen3-8b-local` is
already imported; see *What the numbers say*. The two test builds are kept in
`test-builds\` for re-verification and are listed under *Leftovers*.

### VRAM is the binding constraint

llama-server holds ~5.6 GiB of the 8 GiB and the 5K display takes most of the
rest, leaving almost no headroom. Do not raise `--ctx-size` above 8192 without
testing — it will spill to system memory or fail to allocate.

### RAM prompt cache must be off

`--cache-ram 0` in the GPU launch script is **required**. Without it, some
requests sit for **~11.5 s before the first token** while the server's own
prompt and decode timers show nothing wrong. The server log pins it to the gap
between choosing a slot and starting the task:

```
0.08.990  get_availabl: selected slot by LCP similarity, f_sim_best = 1.000, f_keep = 0.391
0.20.519  launch_slot_: processing task 41                       <- 11.5 s later
```

Cause: llama-server's RAM prompt cache (default 8192 MiB) saves a slot's KV
state to host memory before reusing the slot with a different continuation.
That save is a GPU-to-host readback, and over this Vulkan path it runs at
roughly 100 MB/s, so ~1.2 GB of KV takes ~11.5 s. It fires whenever a slot is
reused while discarding tokens — regenerate, an edited message, switching
chats, and every one of Open WebUI's tag/follow-up task calls (they send a
different prompt onto the same slot). A plain follow-up in one chat keeps
almost everything (`f_keep` near 1) and dodges it, which is why the caching
test above looked fine.

Verified with five identical requests, before and after:

| | `--cache-ram` default | `--cache-ram 0` |
|---|---|---|
| Time outside prompt+decode, cache-hit requests | 10.9–11.7 s | 0.01–0.03 s |
| Slot-selection → launch gap | ~11.5 s | ~0.15 ms |
| In-slot prefix reuse (`cache_n`) | 24 | 24 |

The in-slot prefix cache — the thing that makes follow-ups fast — is a separate
mechanism and is unaffected. The only cost of disabling the RAM cache is that
switching back to a chat whose slot has since been reused re-processes that
prompt from scratch at ~128 tok/s.

A false lead worth recording: the stall first appeared to correlate with
`temperature: 0`. It did not — it was request order. Streaming time-to-first-
token showed the stall on default sampling too once the slot state lined up.

### One server slot

llama-server defaults to four slots sharing one unified KV cache
(`kv_unified = true`). Every decode step then attends across *all* slots'
cached tokens, so each distinct conversation that lands in a new slot slows
every subsequent reply — and slots hold their stale KV until evicted. Four
different ~960-token prompts, same server, FA off, generation tok/s:

| Config | Prompt 1 | Prompt 2 | Prompt 3 | Prompt 4 | Context per slot |
|---|---|---|---|---|---|
| 4 auto slots, unified KV (default) | 14.21 | 13.03 | 12.00 | **10.83** | 8192 |
| `--parallel 1` | 14.31 | 14.35 | 14.29 | 14.34 | 8192 |
| `--parallel 4 --no-kv-unified` | 13.99 | 14.03 | 14.03 | 14.09 | **2048** |

By the fourth conversation the default is **24% slower**, and prompt processing
sags too (113 → 100 tok/s). In Open WebUI every new chat — and every tag or
follow-up task call, which sends a different prompt — takes a slot, so a normal
session degrades within minutes and stays degraded until restart.
`--parallel 1` (now in the launch script) holds 14.3 flat with the full 8192
context. Splitting the KV instead keeps four slots but caps each at 2048
tokens, too small for pasted documents.

Trade-offs of one slot: requests serialize (Open WebUI's background task calls
queue behind or ahead of the next message — one more reason to disable them),
and only the most recent conversation stays cached, so alternating between two
chats re-processes each prompt at ~113 tok/s. Ollama's runner uses one slot by
default, which is part of why it looked faster in mixed use.

## Files

| File | Purpose |
|---|---|
| `start-llama-server.cmd` / `.ps1` | GPU launcher, fast mode — **this is the one to use** |
| `start-llama-server-thinking.cmd` | GPU launcher with Qwen3 reasoning enabled |
| `start-llama-server-cpu.cmd` / `.ps1` | CPU fallback, if the GPU ever breaks |
| `check-gpu-ready.ps1` | Verifies the GPU is still usable |
| `install-gpu-driver.cmd` | Launches the AMD R6.4 installer elevated (already done) |
| `docker-compose.yml` | Open WebUI container definition |
| `reddit-post.md` | Write-up draft for r/LocalLLaMA; numbers mirror this file |
| `OTHER-OS.md` | Running the same stack on Linux or macOS Ventura instead |
| `models\` | GGUF model files |
| `driver\` | AMD Boot Camp R6.4 installer |
| `downloads\` | Installers kept locally for a rebuild (see *Software sources*) |

## Software sources

Everything needed to rebuild this setup on an iMac (Retina 5K, 27-inch, 2017)
running Windows 11 under Boot Camp. All links verified 2026-09-20.

Anything under 100 MB is already saved in `downloads\`, so a rebuild does not
depend on those URLs still working.

### Held locally

| Component | Version | Size | Where | Source |
|---|---|---|---|---|
| llama.cpp, Vulkan build | `b11063` (commit `3d82ef62d`) | 30.4 MB | `downloads\llama-b11063-bin-win-vulkan-x64.zip` | [release b11063](https://github.com/ggml-org/llama.cpp/releases/tag/b11063) · [direct zip](https://github.com/ggml-org/llama.cpp/releases/download/b11063/llama-b11063-bin-win-vulkan-x64.zip) |
| Vulkan Runtime (LunarG) | latest | 24.5 MB | `downloads\vulkan-runtime.exe` | [direct exe](https://sdk.lunarg.com/sdk/download/latest/windows/vulkan-runtime.exe) |
| AMD Boot Camp Unified Driver | R6.4 (21.30.45.22), 2025-08-27 | 566 MB | `driver\` (extracted) | [direct zip](https://drivers.amd.com/drivers/unified_r6.4_21.30.45.22_whql_250611a-418524c.zip) |
| Qwen3-8B GGUF | Q4_K_M | 4.68 GiB | `models\` | [direct gguf](https://huggingface.co/Qwen/Qwen3-8B-GGUF/resolve/main/Qwen3-8B-Q4_K_M.gguf) |
| Qwen3-4B GGUF | Q4_K_M | 2.33 GiB | `models\` | [direct gguf](https://huggingface.co/Qwen/Qwen3-4B-GGUF/resolve/main/Qwen3-4B-Q4_K_M.gguf) |

The AMD and Qwen files are over 100 MB but were already downloaded, so they are
listed here for completeness.

### Not held locally (too large, or pulled by Docker)

| Component | Version here | Size | Source |
|---|---|---|---|
| Docker Desktop for Windows | 29.8.0 | 599 MB | [product page](https://www.docker.com/products/docker-desktop/) · [direct exe](https://desktop.docker.com/win/main/amd64/Docker%20Desktop%20Installer.exe) |
| Open WebUI | `ghcr.io/open-webui/open-webui:main` | 7.1 GB image | [GitHub](https://github.com/open-webui/open-webui) · [docs](https://docs.openwebui.com/) |
| Vulkan SDK (full) | latest | 275 MB | [LunarG SDK](https://vulkan.lunarg.com/sdk/home) |

Open WebUI is pulled automatically by `docker compose up -d`. The exact image
in use here is digest
`sha256:1a6399d237dc392a2313e0ca826020b3fd5d22536357840eb63393d18dc8b924`.

The full Vulkan SDK is **not required** — the AMD driver ships the runtime, and
`vulkan-runtime.exe` above covers `vulkaninfo` for diagnostics.

### Reference pages

| Topic | Link |
|---|---|
| llama.cpp project | https://github.com/ggml-org/llama.cpp |
| llama.cpp releases (newer builds) | https://github.com/ggml-org/llama.cpp/releases |
| Qwen3-8B GGUF model card | https://huggingface.co/Qwen/Qwen3-8B-GGUF |
| Qwen3-4B GGUF model card | https://huggingface.co/Qwen/Qwen3-4B-GGUF |
| Ollama (used only for the benchmark comparison) | https://github.com/ollama/ollama |
| Ollama for Windows (native, `winget install Ollama.Ollama`) | https://ollama.com/download/windows |
| AMD Boot Camp driver downloads | https://www.amd.com/en/support/graphics/mac-graphics/apple-boot-camp |
| AMD Boot Camp release notes | https://www.amd.com/en/resources/support-articles/release-notes/RN-RAD-MAC-BOOTCAMP.html |
| Apple: updating AMD drivers in Boot Camp | https://support.apple.com/en-us/102201 |

### Gotcha: AMD's direct download link

`drivers.amd.com` returns a small HTML page titled *"Download Not Complete"*
instead of the zip unless the request carries a referer of the AMD support page
plus session cookies. A plain `curl -O` silently produces a 0.1 MB HTML file.
Download it through a browser, or:

```powershell
$ua  = "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
$ref = "https://www.amd.com/en/support/graphics/mac-graphics/apple-boot-camp"
curl.exe -sL -A $ua -c "$env:TEMP\amd.cookies" -o NUL $ref
curl.exe -L --fail -A $ua -b "$env:TEMP\amd.cookies" -e $ref `
    -o driver\unified_r6.4.zip `
    "https://drivers.amd.com/drivers/unified_r6.4_21.30.45.22_whql_250611a-418524c.zip"
```

### Rebuilding from scratch

1. Install **Docker Desktop**, reboot, and let it start.
2. Install the **AMD R6.4 driver** from `driver\`, reboot, run
   `check-gpu-ready.ps1`.
3. Extract `downloads\llama-b11063-bin-win-vulkan-x64.zip` into `C:\llama-vulkan`.
4. Put the GGUFs in `models\` (links under *Held locally*).
5. `docker compose -f C:\llama-vulkan\docker-compose.yml up -d`
6. Point Open WebUI at the server — see *If the model dropdown is empty*, since
   the env vars alone will not do it on an existing volume.
7. Run `start-llama-server.cmd`.

## Managing the web UI

```powershell
docker compose -f C:\llama-vulkan\docker-compose.yml up -d      # start
docker compose -f C:\llama-vulkan\docker-compose.yml restart    # restart
docker compose -f C:\llama-vulkan\docker-compose.yml logs -f    # logs
```

Chats and accounts live in the `open-webui` Docker volume and survive
container recreation.

### If the model dropdown is empty

Open WebUI's connection settings are **PersistentConfig**: the environment
variables in `docker-compose.yml` only seed `webui.db` on a first run against an
empty volume. After that the database wins and the env vars are ignored. This
volume predates the llama.cpp setup, so it initially still pointed at
`https://api.openai.com/v1` (no key) and at Ollama on port 11434, and the
dropdown came up empty.

Fix it in the UI — *Settings > Admin Settings > Connections* — or check the
stored values directly:

```powershell
docker exec open-webui-vulkan python -c "import sqlite3;c=sqlite3.connect('/app/backend/data/webui.db');print([ (k,v) for k,v in c.execute(\"select key,value from config where key like 'openai%' or key like 'ollama.enable'\") ])"
```

They should read:

| Key | Value |
|---|---|
| `openai.api_base_urls` | `["http://host.docker.internal:8080/v1"]` |
| `openai.api_keys` | `["local-llama"]` |
| `openai.enable` | `true` |
| `ollama.enable` | `false` |

A backup of the database as it was before this change is kept at
`webui.db.bak-before-llamacpp` inside the volume.

## Adding or switching models

Both launch scripts hardcode the model in the `$Model` variable near the top.
To run the 4B instead of the 8B, edit that one line in
`start-llama-server.ps1`:

```powershell
$Model = Join-Path $Root "models\Qwen3-4B-Q4_K_M.gguf"
```

On the GPU this is rarely worth it — see *What the numbers say*; the 4B is only
24% faster at generation. It is the better choice on the CPU fallback, or if you
routinely paste long documents, where it processes prompts 1.8x faster.

Drop any other `.gguf` into `models\` and point `$Model` at it the same way. To
serve several models at once, run an instance per model on its own port and add
the extra endpoints under *Settings > Connections* in Open WebUI — but note that
only one 8B fits in VRAM at a time, so a second instance will run on CPU.
