# b70-doctor

A setup check for the Intel Arc Pro B70 and other Battlemage cards (B60, B50, B580, B570) on Linux. It reads your
driver, firmware, PCIe, BAR, permissions and kernel log, then tells you what's wrong and which command fixes it. It's
useful whether you run llama.cpp (SYCL or Vulkan), Ollama, LM Studio or vLLM.

It is **read-only**. It never changes anything on your system. Every `fix:` line is a command for you to read and
run yourself.

Made by [@imdariotoo](https://x.com/imdariotoo). I post my B70 and local-model releases on X, so follow there for the next ones.

## Run it

```bash
curl -fsSL https://raw.githubusercontent.com/riceharvest/b70-doctor/main/b70-doctor.sh | bash
```

Or download it, read it, and run it:

```bash
curl -fsSLO https://raw.githubusercontent.com/riceharvest/b70-doctor/main/b70-doctor.sh
bash b70-doctor.sh
```

| option | what it does |
|---|---|
| `--report` | prints a paste-ready environment block for bug reports (GPU, link, BAR, firmware, timeouts, package versions) |
| `--json` | the same environment as JSON (b70-bench attaches it to results) |
| `--probe` | also runs `vulkaninfo --summary`, `sycl-ls` and `clinfo -l`. These open the GPU but run no kernels |
| `--no-color` | plain output |

With pipes, pass options like this: `curl ... | bash -s -- --report`.

If your distro restricts the kernel log (`dmesg_restrict`), run it with `sudo` so the firmware and GPU-hang checks
work. Even with sudo it only reads.

The exit code is 1 if it found a problem and 0 otherwise, so you can use it in scripts.

## What it checks

| check | what you get |
|---|---|
| driver | whether `xe` is bound (Battlemage doesn't work with `i915`), with the probe error if nothing bound |
| firmware | GuC / HuC / DMC versions as loaded in this boot, and any firmware load errors |
| PCIe link | the real slot link. The card has its own PCIe switch, whose internal ports always show 2.5 GT/s x1, so it reads the card's upstream port instead. Warns on x8/x4 or a lower generation than both ends support |
| Resizable BAR | warns when the VRAM BAR is under 1 GiB (ReBAR off) and names the BIOS settings to turn on |
| permissions | whether you can open `/dev/dri/renderD*`, and which group to join if you can't |
| SR-IOV | warns when virtual functions are enabled, since they take VRAM from the host |
| GPU hangs | counts this boot's and the previous boot's xe job timeouts, compute and copy engine resets, CAT errors and **wedges**, shows the last line, and links the matching upstream issues |
| engine timeouts | current `job_timeout_ms` and the max you can raise it to |
| compute-runtime | Level Zero / OpenCL GPU driver and loader versions, with the install command for Fedora, Ubuntu/Debian or Arch if missing |
| Vulkan | whether Mesa ANV is installed, plus the current state of llama.cpp Vulkan on Xe2 |
| several GPUs | how to pin the B70 in llama.cpp SYCL/Vulkan and vLLM |
| swap, docker, oneAPI | the container flags that work, a swap note for vLLM UVA offload, and `setvars.sh` |

Sample (a box with Resizable BAR off):

```
== Arc Pro B70 at 0000:09:00.0 ==
  [ OK ] driver: xe
  [ OK ] GuC firmware 70.65.0
  [ OK ] HuC firmware 8.2.10
  [ OK ] DMC firmware 2.6
  [ OK ] PCIe link 16.0 GT/s PCIe x16 (slot max 16.0 GT/s PCIe)
  [WARN] VRAM BAR is only 256 MiB: Resizable BAR is off
         fix: BIOS: enable 'Above 4G Decoding' and 'Re-Size BAR Support' (CSM off), then reboot
  [ OK ] you can open /dev/dri/renderD128
  [INFO] compute engine job_timeout_ms 5000 (max 10000), preempt_timeout_us 640000
```

## Known-good versions

These are versions I've run a B70 on. They aren't minimums.

- kernel 7.0 (Ubuntu 26.04) and 7.1.8 (Fedora 43)
- GuC 70.65.0, HuC 8.2.10, DMC 2.6 (linux-firmware 20260622)
- compute-runtime 26.18 (Fedora 43), 26.27 (vLLM 0.31 XPU image), Mesa 25.3.6

If your box works with other versions, or the doctor says something wrong about it, please open an issue with the
`--report` output.

## Tests

```bash
bash tests/run.sh
```

The tests build fake sysfs/proc trees, kernel logs and package lists, so they run on any Linux machine without a GPU.
They also check that the script never writes anything: a run against a read-only fixture leaves it unchanged, and a
static check confirms system-changing commands only appear inside printed `fix:` text.

## Related

- [b70-qwen38-cookbook](https://github.com/riceharvest/b70-qwen38-cookbook): Qwen3.8-27B with 262K context on one B70 (vLLM)

MIT license.
