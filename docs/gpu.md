# The GPU engine: the Mac's GPU in Linux containers

The default engine (Virtualization.framework) has no GPU. The GPU engine boots the same VM, with the
same disks, images and containers, on libkrun with a virtual GPU whose Vulkan commands run on the Mac
through MoltenVK and Metal (Venus → virglrenderer → MoltenVK → Metal).

## Set up

macOS 26 or later for stock Mesa in containers (see the 4 KiB IPA granule patch below).

```sh
brew install rust lld meson ninja go pkg-config dtc libepoxy molten-vk vulkan-headers
gpu/build.sh                     # one time: builds the GPU stack from source into gpu/prefix
gpu/guest/build.sh               # optional: the mdock/gpu image (OpenCL), Mesa from source
mdock stop && mdock start --gpu  # the choice is remembered; mdock start --no-gpu switches back
mdock gpu-check                  # what containers get: Vulkan, OpenGL, OpenCL
docker run --device mdock.dev/gpu=all <image>
```

`mdock.dev/gpu=all` is a [CDI](https://github.com/cncf-tags/container-device-interface) device the
guest publishes at boot. It adds `/dev/dri` and turns off Mesa's Asahi driver, which otherwise
crashes the Vulkan loader on this device. The image brings its own Mesa:

| API | In a container | Notes |
|---|---|---|
| Vulkan 1.2 | any image with Mesa's Venus driver (Fedora or Debian/Ubuntu `mesa-vulkan-drivers`) | [examples/llama-vulkan](../examples/llama-vulkan/Dockerfile) builds llama.cpp with the Vulkan backend |
| OpenGL 2.1, OpenGL ES 2.0 | the image's Mesa with `-e GALLIUM_DRIVER=zink` (Zink: OpenGL on Vulkan) | rendering checked pixel-exact. GL 3.0 needs transform feedback, which MoltenVK doesn't have; without the variable Mesa uses llvmpipe (GL 4.5 on the CPU) |
| OpenCL 3.0 | the `mdock/gpu` image: rusticl on Zink, Mesa 25.1.9 built from source with the two patches in `gpu/guest/` | a 1024² matrix multiply checks out against the CPU; 36.8 GFLOP/s with a naive kernel vs 1.6 on one CPU core |

`gpu/guest/*.patch` make Zink work on a Mac host: Venus can't export memory as fds there, which stock
Zink treats as fatal on the DRM path (so rusticl found no device), and MoltenVK can't alias a binding in
a push-descriptor set (Zink reads OpenCL kernel arguments as 32- and 64-bit), so Zink skips push
descriptors on Venus/Apple.

## How fast

llama.cpp, Qwen2.5-0.5B Q4_K_M, M1 (tokens/s):

| | prompt (pp512) | generation (tg128) |
|---|---:|---:|
| Container, CPU only (8 vCPUs) | 148 | 10.8 |
| **Container, mdock GPU (Venus)** | **970** | **32.6** |
| Native macOS, Vulkan on MoltenVK | 916 | 32.4 |
| Native macOS, Metal backend | 1,739 | 98.4 |

The container is as fast as native Vulkan on the same Mac, so virtualization adds no measurable cost.
The gap to the Metal row is llama.cpp's Vulkan backend on MoltenVK versus its Metal backend. For LLMs,
the Metal LLM server (`http://llm.mdock.internal:8200`, see [accel/llm](../accel/llm/README.md)) is
faster and works on both engines.

## How the engines differ

| | default engine | GPU engine |
|---|---|---|
| Hypervisor | Virtualization.framework | libkrun on Hypervisor.framework |
| linux/amd64 images | Rosetta | FEX ([x86.md](x86.md)) |
| Networking | vmnet NAT (fastest) | gvproxy (userspace) |
| Memory | a balloon caps the guest; macOS gets it back when the VM stops | memory the guest frees returns to macOS within seconds |

## The GPU stack, built from source

`gpu/build.sh` fetches checksum-verified sources and compiles them with `-mcpu=apple-m1` /
`target-cpu=apple-m1`, `-O3` and LTO into `gpu/prefix`:

- **virglrenderer** (krunkit branch) with Venus, linked to MoltenVK, plus
  `virglrenderer-no-pipeline-guard.patch`: MoltenVK dereferences the bound pipeline when it encodes
  a draw or dispatch, so a guest that recorded one without a pipeline (after its pipeline failed to
  compile) crashed the whole VM. Such commands are dropped instead.
- **libkrun 1.19.6** with block, net and GPU only, plus mdock patches in `gpu/patches/`:
  - `libkrun-hvf-tso.patch`: the guest sees Apple's TSO capability (AIDR_EL1) and can set the TSO bit
    in ACTLR_EL1, which Hypervisor.framework exposes from macOS 15; an x86 translator in the guest
    then runs in x86's memory order ([x86.md](x86.md)). Stock libkrun panics on a system register it
    doesn't know, which would stop the VM at the guest's first access.
  - `libkrun-vsock-bursts.patch`: a deeper listen backlog and receive queue for vsock connections,
    and a full file table refuses a connection instead of aborting the VM, so 64 parallel docker
    clients × 50 requests all succeed.
  - `libkrun-hvf-4k-ipa-granule.patch`: on macOS 26 the VM maps memory at 4 KiB granularity
    (`hv_vm_config_set_ipa_granule`). With the default 16 KiB, `hv_vm_map` rejects Venus blobs at
    4 KiB-aligned guest offsets and stock Mesa fails with `VK_ERROR_OUT_OF_HOST_MEMORY`. That is the
    reason other setups need a patched Mesa or guest kernel.
  - `libkrun-free-page-reporting.patch`: free page reporting returns memory for real. A plain
    `madvise` is a no-op on pages the guest wrote while they are mapped into the VM, and `MADV_FREE`
    never lowers the footprint, so each reported range is unmapped, marked `MADV_FREE_REUSABLE` and
    mapped back.
  - `libkrun-vsock-half-close.patch`: a host EOF on a vsock↔unix connection is sent as a vsock
    `SHUTDOWN(SEND)`, not a reset. Without it, `docker run`/`attach` loses all output.
  - `libkrun-vsock-prompt-close.patch`: macOS refuses `shutdown(SHUT_RDWR)` (ENOTCONN, and shuts
    nothing) on a unix socket whose peer already half-closed, so the host end of a finished
    connection stayed open until libkrun's 5 s reaper: every attached `docker run` took 5 s longer
    (now 0.18 s). It also stops polling finished connections, which spun the event loop meanwhile.
  - `libkrun-quiet-vsock.patch`: no time-sync datagrams (only libkrunfw's kernel reads them) and no
    error line for the resets the guest answers them with.
- **gvproxy 0.8.9** for guest networking

mdock loads libkrun with `dlopen` and boots the same guest kernel directly (mdock's, else Alpine's),
without krunkit or EFI firmware. MoltenVK comes from homebrew-core, because building it needs a full
Xcode.

## Limits

Vulkan 1.2; OpenGL stops at 2.1 / ES 2.0 because MoltenVK has no transform feedback (which GL 3.0
requires); no CUDA or Metal inside Linux. Containers also see llvmpipe, a CPU fallback.
