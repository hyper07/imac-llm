# Running this on Linux or macOS instead

The setup in [README.md](README.md) is Windows 11 under Boot Camp, which is
where every number in this repo was measured. The same iMac can boot Linux or
macOS Ventura, and the picture is meaningfully different on each.

**Everything in this file is research and reasoning, not measurement.** Only
the Windows numbers are measured. Where something is predicted, it says so.

## Short version

| | GPU backend | Expected vs Windows | Effort |
|---|---|---|---|
| **Windows 11** (current) | Vulkan | baseline: 14.3 tok/s served, 113 tok/s prompt | done |
| **Linux** | Vulkan (Mesa RADV) | plausibly **faster**, see below | moderate |
| **macOS Ventura** | Metal | likely **much slower than its own CPU** | low, but a trap |

Linux is the one worth trying. macOS is the one to be careful with.

---

## Linux

### Why it might actually be faster

Three concrete reasons, in order of confidence:

**1. Generation is running at 26% of memory bandwidth on Windows.** Measured:
4.68 GB of weights read per token at 14.3 tok/s is 67 GB/s effective, against
the RX 580's 256 GB/s spec. A well-tuned backend reaches 60-70%, which would be
~33 tok/s. The ceiling here is the driver and kernels, not the silicon, and
that is exactly the kind of gap a different driver stack can close.

**2. The driver changes completely.** Windows Polaris support is in maintenance
mode — AMD's shader compiler for this card is effectively frozen, and the Boot
Camp driver had to be chased down from AMD's site at all (see *GPU status* in
the README). Linux uses Mesa's RADV with the ACO compiler, which is actively
developed and generally considered the stronger Polaris backend now.

**3. Flash attention might work.** On Windows, upstream llama.cpp's Vulkan FA
kernel corrupts long prompts on this GPU in every build tested (b11026, b11063,
b11065) — but Ollama's bundled fork compiles a working one on the *same* card
and driver. That proves it is a shader-compiler bug, not a hardware limit. A
completely different compiler on RADV has a real chance of getting it right,
and FA was worth about +20% generation.

Plus one certainty: **headless frees 1.58 GB of VRAM**. Measured on Windows —
`dwm` alone holds 705 MB, and the 5K framebuffer and shell take the rest. That
is 19% of total VRAM spent drawing a desktop a server does not need. It buys a
larger context (8192 is currently a VRAM cap) or a bigger quant.

### What will not change

ROCm is not a path. Polaris (`gfx803`) was dropped from ROCm years ago; the
`ubuntu-rocm` release asset will not help this card. You are on Vulkan either
way.

Prompt processing is compute-bound on a GPU with no fp16, no integer dot
product and no matrix cores, so expect less improvement there than on
generation.

### Setup

Vulkan runtime and tools:

```bash
# Debian / Ubuntu
sudo apt install mesa-vulkan-drivers vulkan-tools
# Fedora
sudo dnf install mesa-vulkan-drivers vulkan-tools

vulkaninfo --summary        # expect: deviceName = AMD Radeon RX 580 Series (RADV POLARIS10)
```

Prebuilt llama.cpp, the exact Linux counterpart of the Windows zip this repo
uses:

```bash
curl -L -O https://github.com/ggml-org/llama.cpp/releases/download/b11063/llama-b11063-bin-ubuntu-vulkan-x64.tar.gz
tar xf llama-b11063-bin-ubuntu-vulkan-x64.tar.gz
./llama-server --list-devices    # expect: Vulkan0: AMD Radeon RX 580 ... (8192 MiB)
```

Newer builds: <https://github.com/ggml-org/llama.cpp/releases>

### Flags

The three flags this repo forces on Windows split into two categories.

**Hardware truths — keep these:**

| Flag | Why |
|---|---|
| `--parallel 1` | Four slots on a unified KV cache lose 24% generation as distinct prompts fill them. This is attention over more KV cells, not a driver bug, so it applies everywhere. |
| `--cache-ram 0` | The RAM prompt cache saves KV to host memory over a slow readback. Worth re-testing on Linux — if RADV's transfer path is faster the ~11.5 s stall may shrink — but start with it off. |

**Windows/driver-specific — re-test, do not assume:**

| Flag | Why |
|---|---|
| `--flash-attn off` | This is the one to re-test. If RADV compiles a correct FA kernel you get ~+20% generation, and it is the single biggest available win. |

Verify FA properly before trusting it. Short chats pass even on the broken
Windows build; it is long prompts that fail:

```bash
# send the same ~1000-token prompt 4x with caching off; every reply must
# continue the sentence, not drift into unrelated text or '?' spam
P=$(python3 -c "print('The quick brown fox jumps over the lazy dog while the system processes tokens efficiently. ' * 60)")
for i in 1 2 3 4; do
  curl -s localhost:8080/completion -H 'Content-Type: application/json' \
    -d "{\"prompt\":\"Variant $i. $P\",\"n_predict\":128,\"temperature\":0,\"cache_prompt\":false}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['content'][:80])"
done
```

### Bonus: Docker can use the GPU on Linux

On Windows, Docker Desktop cannot pass an AMD GPU into a Linux container, which
is why this repo runs llama-server natively and containerises only the web UI.
On Linux that limitation disappears — pass the render node through and the
whole stack can be containerised:

```yaml
services:
  llama:
    image: ghcr.io/ggml-org/llama.cpp:server-vulkan
    devices:
      - /dev/dri:/dev/dri
    group_add:
      - video
    volumes:
      - ./models:/models
    command: >
      --model /models/Qwen3-8B-Q4_K_M.gguf --host 0.0.0.0 --port 8080
      --n-gpu-layers 99 --ctx-size 8192 --parallel 1 --flash-attn off
      --cache-ram 0 --jinja --reasoning-format deepseek
```

### Cheapest way to find out: a live USB

No install, nothing written to disk. Boot Fedora or Ubuntu from USB — RADV
ships in Mesa by default — put the GGUF on a second USB stick or mount the
Windows partition read-only, download the Vulkan tarball, and run:

```bash
./llama-bench -m Qwen3-8B-Q4_K_M.gguf -ngl 99 -fa 0 -p 512 -n 128   # compare: 128.33 pp / 16.48 tg
./llama-bench -m Qwen3-8B-Q4_K_M.gguf -ngl 99 -fa 1 -p 512 -n 128   # then run the FA correctness check above
```

An hour, zero commitment, and it answers all three questions: does RADV close
the bandwidth gap, does flash attention work, and does the 5K panel come up.

### Known rough edges on this hardware

- **The 5K internal panel** is an internal dual-DisplayPort link and has
  historically needed work on Linux. Irrelevant headless, which is the
  configuration that makes the most sense anyway.
- **Wi-Fi** is Broadcom and usually needs the proprietary `wl` driver.
- **Fan control** via `applesmc` is mediocre on Apple hardware. Watch thermals
  under sustained load.

---

## macOS Ventura

Ventura (13.x) is the last macOS this iMac officially supports. It is also the
**worst of the three options for GPU inference**, for a specific and
well-documented reason.

### The Metal trap

llama.cpp has a Metal backend, and an Intel macOS build ships with every
release, so this looks like the obvious path. It is not.

On Intel Macs with a *discrete* AMD GPU, llama.cpp's Metal backend maps model
weights with shared storage (`newBufferWithBytesNoCopy`). On Apple Silicon,
where CPU and GPU share memory, that is free. On a discrete card it means the
GPU re-reads the weights across PCIe on **every token**. The reported result on
an AMD 6900 XT — a far stronger card than the Pro 580 — was **0.8 tok/s on
Metal versus 21 tok/s on the same machine's CPU**.

A fix was written (move weights into private VRAM once, select the discrete GPU
automatically, raise command-buffer parallelism) and proposed upstream. The
issue was **closed as not planned** and nothing was merged:
<https://github.com/ggml-org/llama.cpp/issues/15228>

So on stock llama.cpp under Ventura, expect Metal to be *slower than doing
nothing*. Verify before believing any Metal number on this hardware.

### What actually works on Ventura

**CPU only**, which is a known quantity — the Windows CPU measurements in the
README are the same silicon: **5.2 tok/s** on the 8B, 9.5 on the 4B.

```bash
curl -L -O https://github.com/ggml-org/llama.cpp/releases/download/b11063/llama-b11063-bin-macos-x64.tar.gz
tar xf llama-b11063-bin-macos-x64.tar.gz
./llama-server --model Qwen3-8B-Q4_K_M.gguf --n-gpu-layers 0 --threads 4 \
               --ctx-size 8192 --parallel 1 --jinja --reasoning-format none
```

Or `brew install llama.cpp`. Either way pass `--n-gpu-layers 0` explicitly so
it does not quietly fall into the slow Metal path.

**A third-party fork** keeps the private-VRAM work alive:
<https://github.com/jadentripp/llama.cpp>. It is unverified on Polaris
specifically and is a fork of a fast-moving project, so treat it as an
experiment rather than a recommendation.

Ignore any guide telling you to build with `LLAMA_CLBLAST=1` — the CLBlast
OpenCL backend was removed from llama.cpp.

### Docker

Docker Desktop for Mac cannot pass a GPU into a container either, so the same
split applies: run llama-server natively, containerise only Open WebUI. The
`docker-compose.yml` in this repo works unchanged — `host.docker.internal`
resolves on macOS without the `extra_hosts` entry, which is harmless to leave.

---

## Which to pick

**Stay on Windows** if the current setup is working. It is measured, the flags
are known, and 14.3 tok/s served is usable.

**Try Linux** if you want more speed and are willing to spend an evening. The
26% bandwidth figure says roughly 2x is theoretically on the table, flash
attention may work, and headless returns 1.58 GB of VRAM. Test from a live USB
before committing the disk.

**Pick macOS** only if you want the machine to be a Mac again. For LLM work it
means CPU-only inference at roughly a third of the Windows GPU speed, unless
you are willing to run an unmerged fork.
