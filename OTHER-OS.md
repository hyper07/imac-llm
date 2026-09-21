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

### Why WSL2 or Docker on Windows is not a shortcut

Reasonable question: if a Linux container can reach the GPU through `/dev/dri`,
and Windows 11 exposes GPUs to WSL2, can you skip the reboot and run the Vulkan
container on Windows? **No.** Tested on this machine:

| Check | Result |
|---|---|
| `/dev/dxg` in Ubuntu WSL2 | present |
| `/usr/lib/wsl/lib` (`libd3d12.so`) | present |
| `/dev/dri` | **missing** |
| `amdgpu` kernel module | **not loaded** |
| Vulkan devices found | **`llvmpipe` only** — a CPU software rasterizer |
| `llama-server --list-devices` | **`(none)`** |

The GPU *is* paravirtualised into WSL2, but that channel speaks **D3D12**, not
Vulkan. Translating Vulkan onto it needs Mesa's Dozen driver (`dzn`), which
Ubuntu's `mesa-vulkan-drivers` does not ship — the installed ICDs are RADV,
Intel, lavapipe and friends, and RADV needs the `/dev/dri` node that does not
exist here. So the only Vulkan implementation available is lavapipe on the CPU,
and llama.cpp rejects it outright.

**The dangerous part is that it fails silently.** With `-ngl 99` and the Vulkan
build, llama-bench still prints `backend = Vulkan` and runs anyway — on the CPU:

```
| qwen3 8B Q4_K - Medium | Vulkan | ngl 99 | pp512 | 18.37 |
| qwen3 8B Q4_K - Medium | Vulkan | ngl 99 | tg128 |  5.28 |
```

18.37 / 5.28 tok/s is native Windows CPU speed (19.14 / 5.20), not GPU speed
(128 / 16.5). Nothing errors; `-ngl 99` is simply ignored. If you try this,
check `--list-devices` first — `(none)` is the tell.

| Where llama.cpp runs | Prompt tok/s | Generation tok/s |
|---|---|---|
| Windows native, GPU | 128 | **16.5** |
| **WSL2 / Docker on Windows, `-ngl 99`** | 18.4 | **5.3** |
| Windows native, CPU | 19.1 | 5.2 |
| Ollama in Docker (CPU) | 11.0 | 3.4 |

Running Linux on the metal is what unlocks the GPU-in-a-container setup above.
Under WSL2 it is CPU inference with extra steps.

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

### Hardware drivers: audio and networking

These are the two that people most often cannot find. Identified from the live
Windows install on this machine (iMac18,3), so the IDs are exact rather than
generic Mac advice — check yours with `lspci -nn` and `lsusb` before assuming
they match.

| Device | Windows driver in use | Hardware ID | Linux driver | Works out of the box? |
|---|---|---|---|---|
| **Ethernet** | Broadcom NetXtreme 214.0.0.1 (2018) | PCI `14e4:1686` — BCM57766 | `tg3` | **Yes**, in-kernel |
| **Wi-Fi** | Broadcom 802.11ac 7.77.119.0 (2020) | PCI `14e4:43ba` — BCM43602 | `brcmfmac` | Needs firmware + a kernel flag |
| **Audio** | Cirrus Logic CS8409 6.6001.3.38 (2017) | HDA `1013:8409`, subsys `106b` (Apple) | `snd_hda_codec_cs8409` | **Usually not** — see below |
| **HDMI/DP audio** | AMD HD Audio 10.0.1.21 | HDA `1002:aa01` | `snd_hda_intel` | Yes |
| **Bluetooth** | Apple Broadcom 6.1.6700.0 (2016) | USB `05ac:8296` | `btbcm` / `hci_bcm` | Usually, sometimes needs firmware |
| **Webcam** | FaceTime HD | USB `05ac:8511` | `facetimehd` (out-of-tree) | No — build the module |

**Ethernet — nothing to do.** `tg3` is in every mainline kernel. If networking
works before Wi-Fi does, this is why; use it to fetch everything else.

**Wi-Fi — driver is in-kernel, firmware is not.** `brcmfmac` handles BCM43602,
but the firmware blob ships separately:

```bash
sudo apt install firmware-brcm80211      # Debian/Ubuntu
sudo dnf install linux-firmware          # Fedora
```

Firmware source: <https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/tree/brcm>

The known quirk for this exact PCI ID is a feature flag — without it the
adapter may associate and then drop:

```bash
# /etc/modprobe.d/brcmfmac.conf
options brcmfmac feature_disable=0x82000
```

Some Macs also want an NVRAM `.txt` next to the firmware
(`brcmfmac43602-pcie.txt`) carrying the adapter's MAC. It is not distributed
with linux-firmware. Background: <https://wiki.archlinux.org/title/Broadcom_wireless>

Note this is **not** one of the chips needing Broadcom's proprietary `wl`
driver — `brcmfmac` is open and in-tree, which makes this Mac easier than most.

**Audio — the one that actually bites.** The Cirrus CS8409 bridge with its
CS42L83 companion is the classic "dummy output / no sound" on Linux Macs. A
`snd_hda_codec_cs8409` driver has been in the kernel since ~5.13 and will
*detect* the chip, but on iMac18,3 it does not always select the Apple-specific
init path, so you get a recognised card and silence. Options, best first:

- Try a current kernel first — the in-tree driver has improved and may just work.
- iMac18,3-specific patches: <https://github.com/jackdanyell/imac18-3-cs8409-linux-audio>
- Standalone DKMS module: <https://github.com/egorenar/snd-hda-codec-cs8409>
- Broader Mac audio project: <https://github.com/davidjo/snd_hda_macbookpro>

Microphone support lags behind playback in all of them. HDMI/DisplayPort audio
through the GPU (`snd_hda_intel`) is unaffected and works regardless.

**Webcam** needs the out-of-tree `facetimehd` module plus firmware extracted
from macOS or Boot Camp: <https://github.com/patjak/facetimehd>

General reference for Apple hardware on Linux:
<https://wiki.archlinux.org/title/Mac>

### Other rough edges

- **The 5K internal panel** is an internal dual-DisplayPort link and has
  historically needed work on Linux. Irrelevant headless, which is the
  configuration that makes the most sense anyway.
- **Fan control** via `applesmc` is mediocre on Apple hardware. Watch thermals
  under sustained load.

---

## macOS Ventura

Ventura (13.x) is the last macOS this iMac officially supports. It is also the
**worst of the three options for GPU inference**, for a specific and
well-documented reason.

### Does this Mac even have Metal?

Yes — but **Metal 2, not Metal 3**, and llama.cpp's official Intel build ships
no Metal backend at all. Three separate facts, worth keeping apart because they
are easy to conflate:

**1. The GPU supports Metal 2.** The Radeon Pro 580 is Polaris, and macOS uses
Metal for the window server on it. Metal is not missing from this machine.

**2. It does not support Metal 3.** Apple's Metal 3 on Intel Macs requires AMD
Radeon Pro Vega or the 5000/6000 series; Polaris predates all of them. The card
keeps working under Ventura, on Metal 2. So a 2017 iMac can run Ventura and
still be excluded from Metal 3 — the model year and the GPU are separate
questions.

**3. The shipped llama.cpp Intel binary has no Metal in it.** Listing every
entry in `llama-b11063-bin-macos-x64.tar.gz` gives these backends:

```
libggml-base.dylib   libggml-blas.dylib   libggml-cpu.dylib   libggml-rpc.dylib
```

No `libggml-metal.dylib`, no `.metallib`, no file matching *metal* anywhere in
the archive — against the Windows build, which ships `ggml-vulkan.dll`. The
official Intel macOS release is **CPU, BLAS and RPC only**. Downloading it and
passing `--n-gpu-layers 99` will not touch the GPU, because there is no GPU
backend present to touch.

### And if you build Metal yourself

You would have to compile from source with `-DGGML_METAL=ON`. Do not expect a
win. On Intel Macs with a *discrete* AMD GPU, llama.cpp's Metal backend maps
weights with shared storage (`newBufferWithBytesNoCopy`). On Apple Silicon,
where CPU and GPU share memory, that costs nothing. On a discrete card it means
the GPU re-reads the weights across PCIe on **every token**. Reported result on
an AMD 6900 XT — far stronger than the Pro 580 — was **0.8 tok/s on Metal
versus 21 tok/s on the same machine's CPU**.

The fix (move weights into private VRAM once, select the discrete GPU
automatically, raise command-buffer parallelism) was written and proposed
upstream. The issue was **closed as not planned**; nothing was merged:
<https://github.com/ggml-org/llama.cpp/issues/15228>

So the GPU is unreachable on the stock build, and reachable-but-slower-than-CPU
if you build it yourself. Either way, macOS means CPU inference on this
machine.

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
