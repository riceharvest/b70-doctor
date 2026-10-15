#!/usr/bin/env bash
# CPU-only fixture tests: fake sysfs/proc trees + canned kernel logs and package lists.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
DOC="$HERE/../b70-doctor.sh"
TMP=$(mktemp -d); trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
PASS=0; FAILN=0

# mkfix DIR [key=value ...]
#   drv=xe|i915|none  bar=<bytes>  width=16  speed="16.0 GT/s PCIe"  vfs=0  render=rw|none  id=0xe223
#   os=fedora|ubuntu  swap=0|1
mkfix() {
  local F=$1; shift
  local drv=xe bar=34359738368 width=16 speed="16.0 GT/s PCIe" vfs=0 render=rw id=0xe223 os=fedora swap=0 dual=0
  local kv; for kv in "$@"; do eval "local ${kv%%=*}=\"\${kv#*=}\""; done
  local P="$F/sys/devices/pci0000:00/0000:00:03.1"
  local US="$P/0000:07:00.0" DS="$P/0000:07:00.0/0000:08:01.0"
  local D="$DS/0000:09:00.0"
  mkdir -p "$D/tile0/gt0/engines/ccs" "$D/drm/renderD128" "$F/sys/bus/pci/devices" "$F/sys/bus/pci/drivers/xe" \
           "$F/sys/bus/pci/drivers/i915" "$F/proc/sys/kernel" "$F/dev/dri" "$F/etc" "$F/usr/share/vulkan/icd.d"
  echo 0x1022 > "$P/vendor"; echo 0x060400 > "$P/class"; echo "16.0 GT/s PCIe" > "$P/max_link_speed"
  echo 0x8086 > "$US/vendor"; echo 0xe2ff > "$US/device"; echo 0x060400 > "$US/class"
  echo "$speed" > "$US/current_link_speed"; echo "$width" > "$US/current_link_width"
  echo "32.0 GT/s PCIe" > "$US/max_link_speed"; echo 16 > "$US/max_link_width"
  echo 0x8086 > "$DS/vendor"; echo 0xe2f0 > "$DS/device"; echo 0x060400 > "$DS/class"
  echo "2.5 GT/s PCIe" > "$DS/current_link_speed"; echo 1 > "$DS/current_link_width"
  echo 0x8086 > "$D/vendor"; echo "$id" > "$D/device"; echo 0x030000 > "$D/class"
  echo "2.5 GT/s PCIe" > "$D/current_link_speed"; echo 1 > "$D/current_link_width"
  echo "$vfs" > "$D/sriov_numvfs"; echo 1 > "$D/boot_vga"
  printf '0x0000007800000000 0x0000007800ffffff 0x000000000014220c\n0x0 0x0 0x0\n' > "$D/resource"
  printf '0x%016x 0x%016x 0x000000000014220c\n' $((0x7000000000)) $((0x7000000000 + bar - 1)) >> "$D/resource"
  echo 5000 > "$D/tile0/gt0/engines/ccs/job_timeout_ms"; echo 10000 > "$D/tile0/gt0/engines/ccs/job_timeout_max"
  echo 640000 > "$D/tile0/gt0/engines/ccs/preempt_timeout_us"
  ln -s "$D" "$F/sys/bus/pci/devices/0000:09:00.0"
  case "$drv" in xe|i915) ln -s "$F/sys/bus/pci/drivers/$drv" "$D/driver" ;; esac
  [ "$render" = rw ] && : > "$F/dev/dri/renderD128"
  echo "7.1.8-100.fc43.x86_64" > "$F/proc/sys/kernel/osrelease"
  echo "MemTotal:       65732608 kB" > "$F/proc/meminfo"
  printf 'Filename\tType\tSize\tUsed\tPriority\n' > "$F/proc/swaps"
  [ "$swap" = 1 ] && printf '/dev/zram0\tpartition\t8388604\t0\t100\n' >> "$F/proc/swaps"
  case "$os" in
    fedora) printf 'ID=fedora\nPRETTY_NAME="Fedora Linux 43"\n' > "$F/etc/os-release" ;;
    ubuntu) printf 'ID=ubuntu\nID_LIKE=debian\nPRETTY_NAME="Ubuntu 26.04 LTS"\n' > "$F/etc/os-release" ;;
  esac
  : > "$F/usr/share/vulkan/icd.d/intel_icd.x86_64.json"
  if [ "$dual" = 1 ]; then
    local D2="$F/sys/devices/pci0000:00/0000:00:01.1/0000:0b:00.0"
    mkdir -p "$D2/drm/renderD129"; echo 0x8086 > "$D2/vendor"; echo 0xe223 > "$D2/device"; echo 0x030000 > "$D2/class"
    cp "$D/resource" "$D2/resource"; ln -s "$D2" "$F/sys/bus/pci/devices/0000:0b:00.0"; ln -s "$F/sys/bus/pci/drivers/xe" "$D2/driver"
    : > "$F/dev/dri/renderD129"
  fi
}

GOODLOG='Oct 14 kernel: xe 0000:09:00.0: [drm] Finished loading DMC firmware i915/bmg_dmc.bin (v2.6)
Oct 14 kernel: xe 0000:09:00.0: [drm] Tile0: GT0: Using GuC firmware from xe/bmg_guc_70.bin version 70.65.0
Oct 14 kernel: xe 0000:09:00.0: [drm] Tile0: GT1: Using HuC firmware from xe/bmg_huc.bin version 8.2.10'
GOODPKGS='intel-compute-runtime 26.18.38308.4
oneapi-level-zero 1.28.6
mesa-vulkan-drivers 26.2.5'

# run NAME FIXDIR LOGFILE PKGFILE HAVE [args...] -> sets OUT, RC
run() {
  local F=$2
  # never touch the real docker/podman or /proc: containers and GPU processes come from fixture files
  OUT=$(B70D_ROOT="$F" B70D_JOURNAL="$3" B70D_JOURNAL_PREV="$F/prev.log" B70D_PKGS="$4" B70D_HAVE="$5" \
        B70D_CONTAINERS="${CONTAINERS:-/dev/null}" B70D_DRI_PROCS="${DRIPROCS:-/dev/null}" HOME=/home \
        env -u VK_DRIVER_FILES -u VK_ICD_FILENAMES -u ONEAPI_ROOT ${VKDF:+VK_DRIVER_FILES=$VKDF} \
        bash "$DOC" --no-color "${@:6}" 2>&1); RC=$?
}
expect() { # NAME PATTERN
  if printf '%s\n' "$OUT" | grep -qE -- "$2"; then PASS=$((PASS+1)); else FAILN=$((FAILN+1)); echo "FAIL [$1]: expected /$2/"; printf '%s\n' "$OUT" | sed 's/^/    | /'; fi
}
reject() {
  if printf '%s\n' "$OUT" | grep -qE -- "$2"; then FAILN=$((FAILN+1)); echo "FAIL [$1]: unexpected /$2/"; printf '%s\n' "$OUT" | sed 's/^/    | /'; else PASS=$((PASS+1)); fi
}
rc_is() { if [ "$RC" = "$2" ]; then PASS=$((PASS+1)); else FAILN=$((FAILN+1)); echo "FAIL [$1]: exit $RC, want $2"; fi; }

case_dir() { local d="$TMP/$1"; mkdir -p "$d"; echo "$d"; }
writef() { printf '%s\n' "$2" > "$1"; }

# 1. healthy box
F=$(case_dir healthy); mkfix "$F"; mkdir -p "$F/opt/intel/oneapi/compiler/2025.3" "$F/opt/intel/oneapi/compiler/latest"; writef "$F/log" "$GOODLOG"; : > "$F/prev.log"; writef "$F/pkgs" "$GOODPKGS"
run healthy "$F" "$F/log" "$F/pkgs" ""
rc_is healthy 0
expect healthy 'Arc Pro B70 at 0000:09:00.0'
expect healthy '\[ OK \] driver: xe'
expect healthy '\[ OK \] GuC firmware 70.65.0'
expect healthy '\[ OK \] PCIe link 16.0 GT/s PCIe x16'
expect healthy 'Resizable BAR on \(BAR 32 GiB\)'
expect healthy 'you can open /dev/dri/renderD128'
expect healthy 'compute-runtime: intel-compute-runtime 26.18'
expect healthy 'Summary: 0 problem\(s\), 0 warning\(s\)'
expect healthy 'Known problems and workarounds: https://riceharvest.github.io/awesome-b70/#known-problems-and-workarounds'
expect healthy 'oneAPI compiler: 2025.3 \(seen working'
expect healthy 'Vulkan decode on Mesa 26 is close to llama.cpp SYCL'
reject healthy 'Want speed\? On Mesa 25'
reject healthy 'Mesa 26.2.5: updating|older than 26'
reject healthy 'GPU in use'
reject healthy 'Multiple GPUs'
reject healthy 'Docker'

# 2. i915 bound
F=$(case_dir i915); mkfix "$F" drv=i915; writef "$F/log" "$GOODLOG"; : > "$F/prev.log"; writef "$F/pkgs" "$GOODPKGS"
run i915 "$F" "$F/log" "$F/pkgs" ""
rc_is i915 1; expect i915 '\[FAIL\] driver: i915'

# 3. no driver, probe error in log
F=$(case_dir nodrv); mkfix "$F" drv=none; writef "$F/log" 'kernel: xe 0000:09:00.0: probe with driver xe failed with error -22'
: > "$F/prev.log"; writef "$F/pkgs" "$GOODPKGS"
run nodrv "$F" "$F/log" "$F/pkgs" ""
rc_is nodrv 1; expect nodrv 'no driver bound'; expect nodrv 'failed with error -22'

# 4. small BAR, x8 link, gen3, SR-IOV VFs
F=$(case_dir hw); mkfix "$F" bar=268435456 width=8 vfs=2; writef "$F/log" "$GOODLOG"; : > "$F/prev.log"; writef "$F/pkgs" "$GOODPKGS"
run hw "$F" "$F/log" "$F/pkgs" ""
rc_is hw 0; expect hw 'VRAM BAR is only 256 MiB'; expect hw 'Above 4G Decoding'; expect hw 'PCIe link x8'; expect hw '2 SR-IOV virtual functions'
F=$(case_dir gen3); mkfix "$F" speed="8.0 GT/s PCIe"; writef "$F/log" "$GOODLOG"; : > "$F/prev.log"; writef "$F/pkgs" "$GOODPKGS"
run gen3 "$F" "$F/log" "$F/pkgs" ""
expect gen3 'PCIe link 8.0 GT/s PCIe, but both ends support 16 GT/s'

# 5. render node not accessible (skip as root: root can open anything)
if [ "$(id -u)" != 0 ]; then
  F=$(case_dir render); mkfix "$F"; chmod 000 "$F/dev/dri/renderD128"; writef "$F/log" "$GOODLOG"; : > "$F/prev.log"; writef "$F/pkgs" "$GOODPKGS"
  run render "$F" "$F/log" "$F/pkgs" ""
  rc_is render 1; expect render 'no read/write access to /dev/dri/renderD128'; expect render 'usermod -aG'
fi

# 6. wedge this boot + ccs resets + CAT error previous boot
F=$(case_dir wedge); mkfix "$F"; writef "$F/pkgs" "$GOODPKGS"
writef "$F/log" "$GOODLOG
kernel: xe 0000:09:00.0: [drm] Tile0: GT0: Timedout job: seqno=1, lrc_seqno=1, guc_id=76, flags=0x0 in python [1]
kernel: xe 0000:09:00.0: [drm] Tile0: GT0: Engine reset: engine_class=ccs, logical_mask: 0x1, guc_id=76, state=0x29
kernel: xe 0000:09:00.0: [drm] CRITICAL: Xe has declared device 0000:09:00.0 as wedged."
writef "$F/prev.log" 'kernel: xe 0000:09:00.0: [drm] Tile0: GT0: Engine memory CAT error [18]: class=bcs, logical_mask: 0x1, guc_id=111'
run wedge "$F" "$F/log" "$F/pkgs" ""
rc_is wedge 1
expect wedge 'GPU is WEDGED \(this boot\)'
expect wedge 'fix: reboot'
expect wedge 'this boot: 1 compute-engine resets'
expect wedge 'job_timeout_ms   \(resets at reboot'
expect wedge 'fix: llama.cpp SYCL / oneAPI apps: try SYCL_UR_USE_LEVEL_ZERO_V2=0'
expect wedge 'awesome-b70/#gpu-hangs-and-resets'
expect wedge 'previous boot: 1 engine memory \(CAT\) errors'

# 7. kernel log unreadable
F=$(case_dir nolog); mkfix "$F"; : > "$F/log"; : > "$F/prev.log"; writef "$F/pkgs" "$GOODPKGS"
run nolog "$F" "$F/log" "$F/pkgs" ""
expect nolog "can't read the kernel log"; reject nolog 'GuC firmware'

# 8. Ubuntu without compute-runtime, with docker + swap
F=$(case_dir ubuntu); mkfix "$F" os=ubuntu swap=1; writef "$F/log" "$GOODLOG"; : > "$F/prev.log"; writef "$F/pkgs" 'mesa-vulkan-drivers 25.2.0'
run ubuntu "$F" "$F/log" "$F/pkgs" "docker"
expect ubuntu 'no Intel compute-runtime'; expect ubuntu 'sudo apt install intel-opencl-icd libze-intel-gpu1 libze1'
expect ubuntu 'swap is on \(/dev/zram0'; expect ubuntu '== Docker =='; expect ubuntu 'ZE_AFFINITY_MASK=0'

# 8b. two B70s: dual-card hints; new Mesa: no update hint
F=$(case_dir dual); mkfix "$F" dual=1; writef "$F/log" "$GOODLOG"; : > "$F/prev.log"
writef "$F/pkgs" "intel-compute-runtime 26.18.38308.4
mesa-vulkan-drivers 26.2.1"
run dual "$F" "$F/log" "$F/pkgs" ""
expect dual 'Arc Pro B70 at 0000:0b:00.0'
expect dual '2 Battlemage cards: known dual-card issues'
expect dual 'GGML_SYCL_DEV2DEV_MEMCPY=2'
expect dual 'CCL_SYCL_ALLGATHERV_SIMPLE_THRESHOLD=4294967296 \(SergiioB'
reject dual 'Mesa 26.2.1: updating'

# 8c. Mesa 25 warns with the local-prefix route; old Mesa 26.1 only gets the info line; VK_DRIVER_FILES overrides
F=$(case_dir mesa25); mkfix "$F"; writef "$F/log" "$GOODLOG"; : > "$F/prev.log"
writef "$F/pkgs" "intel-compute-runtime 26.18.38308.4
oneapi-level-zero 1.28.6
mesa-vulkan-drivers 25.3.6"
run mesa25 "$F" "$F/log" "$F/pkgs" ""
rc_is mesa25 0
expect mesa25 '\[WARN\] Mesa 25.3.6 is older than 26'
expect mesa25 'VK_DRIVER_FILES=<prefix>/share/vulkan/icd.d/intel_icd.x86_64.json'
expect mesa25 'no oneAPI found: you don.t need it'
expect mesa25 'riceharvest/b70-llama-builds'
expect mesa25 'Want speed\? On Mesa 25.x use llama.cpp SYCL'
expect mesa25 'Mesa 26.2.5 took llama.cpp Vulkan decode from 39 to 86'
VKDF=/opt/mesa26/share/vulkan/icd.d/intel_icd.x86_64.json run mesa25vk "$F" "$F/log" "$F/pkgs" ""
expect mesa25vk 'Vulkan apps use /opt/mesa26/share/vulkan/icd.d/intel_icd.x86_64.json, not the distro Mesa 25.3.6'
reject mesa25vk 'older than 26'
writef "$F/pkgs" "intel-compute-runtime 26.18.38308.4
oneapi-level-zero 1.28.6
mesa-vulkan-drivers 26.1.2"
run mesa261 "$F" "$F/log" "$F/pkgs" ""
expect mesa261 'Mesa 26.1.2: updating to 26.1.7'; reject mesa261 'WARN'

# 8d. old oneAPI in the user's home, compute-runtime 25.40 without a Level Zero loader
F=$(case_dir oldstack); mkfix "$F"; mkdir -p "$F/home/oneapi/compiler/2024.2"; writef "$F/log" "$GOODLOG"; : > "$F/prev.log"
writef "$F/pkgs" "intel-compute-runtime 25.40.35563.4
mesa-vulkan-drivers 26.2.5"
run oldstack "$F" "$F/log" "$F/pkgs" ""
expect oldstack '\[WARN\] oneAPI 2024.2 predates Battlemage'
expect oldstack 'Level Zero loader \(libze_loader.so.1\) is missing'
expect oldstack 'compute-runtime 25.40.35563.4: 25.48 and newer lowered'
mkdir -p "$F/usr/lib64"; : > "$F/usr/lib64/libze_loader.so.1"
run oldstack2 "$F" "$F/log" "$F/pkgs" ""
expect oldstack2 '\[ OK \] Level Zero loader: /usr/lib64/libze_loader.so.1'

# 8e. GPU in use: a leftover container, an orphaned vLLM worker, a desktop compositor (ignored)
F=$(case_dir gpuuse); mkfix "$F"; writef "$F/log" "$GOODLOG"; : > "$F/prev.log"; writef "$F/pkgs" "$GOODPKGS"
writef "$F/containers" "docker|vllm-old|intel/vllm:0.31-xpu|2026-10-15T07:12"
writef "$F/procs" "4242 1 VLLM::Worker_TP
2000 1999 gnome-shell
5151 5100 llama-server"
CONTAINERS="$F/containers" DRIPROCS="$F/procs" run gpuuse "$F" "$F/log" "$F/pkgs" ""
expect gpuuse '== GPU in use =='
expect gpuuse 'docker container vllm-old \(intel/vllm:0.31-xpu\) has the GPU, running since 2026-10-15 07:12'
expect gpuuse 'docker rm -f <name>'
expect gpuuse '\[WARN\] orphaned GPU process\(es\), parent gone: VLLM::Worker_TP \(pid 4242\)'
expect gpuuse 'other processes with the GPU open: llama-server \(pid 5151\)'
reject gpuuse 'gnome-shell'
CONTAINERS="$F/containers" DRIPROCS="$F/procs" run gpuusej "$F" "$F/log" "$F/pkgs" "" --json
if printf '%s' "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["gpu_containers"]==1' 2>/dev/null; then
  PASS=$((PASS+1)); else FAILN=$((FAILN+1)); echo "FAIL [gpuusej]: json gpu_containers"; printf '%s\n' "$OUT" | sed 's/^/    | /'; fi

# 9. no GPU at all
F=$(case_dir nogpu); mkdir -p "$F/sys/bus/pci/devices" "$F/proc/sys/kernel"; : > "$F/log"; : > "$F/prev.log"; writef "$F/pkgs" ""
run nogpu "$F" "$F/log" "$F/pkgs" ""
rc_is nogpu 1; expect nogpu 'no Intel GPU on the PCI bus'

# 10. other Battlemage name + report mode
F=$(case_dir b60); mkfix "$F" id=0xe211; writef "$F/log" "$GOODLOG"; : > "$F/prev.log"; writef "$F/pkgs" "$GOODPKGS"
run b60 "$F" "$F/log" "$F/pkgs" "" --report
rc_is b60 0
expect b60 'GPU: Arc Pro B60 \[8086:e211\] at 0000:09:00.0, driver xe, BAR 32 GiB, link 16.0 GT/s PCIe x16'
expect b60 'firmware: GuC 70.65.0, HuC 8.2.10, DMC 2.6'
expect b60 'pkg: intel-compute-runtime 26.18.38308.4'
reject b60 '\[ OK \]'

# 10b. json mode: valid JSON, escaped strings, same facts as --report
F=$(case_dir json); mkfix "$F"; printf 'ID=fedora\nPRETTY_NAME="Weird \\"quoted\\" OS"\n' > "$F/etc/os-release"
writef "$F/log" "$GOODLOG"; : > "$F/prev.log"; writef "$F/pkgs" "$GOODPKGS"
run json "$F" "$F/log" "$F/pkgs" "" --json
rc_is json 0
if printf '%s' "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); g=d["gpus"][0]; assert g["name"]=="Arc Pro B70" and g["guc"]=="70.65.0" and g["bar_bytes"]==34359738368 and d["packages"]["intel-compute-runtime"]=="26.18.38308.4" and "quoted" in d["os"]' 2>/dev/null; then
  PASS=$((PASS+1)); else FAILN=$((FAILN+1)); echo "FAIL [json]: bad JSON"; printf '%s\n' "$OUT" | sed 's/^/    | /'; fi

# 11. read-only: the fixture tree is unchanged after a run (and nothing writes even with it read-only)
F=$(case_dir ro); mkfix "$F" vfs=1; writef "$F/log" "$GOODLOG"; : > "$F/prev.log"; writef "$F/pkgs" "$GOODPKGS"
before=$(cd "$F" && find . -printf '%p %s %T@\n' | sort | md5sum)
chmod -R a-w "$F"
run ro "$F" "$F/log" "$F/pkgs" "docker"
after=$(cd "$F" && find . -printf '%p %s %T@\n' | sort | md5sum)
if [ "$before" = "$after" ]; then PASS=$((PASS+1)); else FAILN=$((FAILN+1)); echo "FAIL [ro]: fixture changed"; fi
reject ro 'Permission denied|Read-only'

# 12. static guard: system-changing commands only ever appear inside printed fix/why strings
bad=$(grep -nE '^\s*[^#]*\b(sudo|tee|usermod|modprobe|sysctl|swapoff|swapon|rmmod)\b' "$DOC" | grep -vE '\b(fix|why|install_cmd|echo) ' | grep -vE '^\s*[0-9]+:\s*(fedora|debian|arch|\*):')
if [ -z "$bad" ]; then PASS=$((PASS+1)); else FAILN=$((FAILN+1)); echo "FAIL [static]: possible side effect:"; echo "$bad"; fi
# any '>' file redirect other than to /dev/null or stderr (awk / $(( )) comparisons excluded)
bad=$(sed -E 's#[0-9&]*>[[:space:]]*/dev/null##g; s#>&2##g' "$DOC" | grep -nE '[^-=<]>[^=&]' | grep -vE 'awk |\$\(\(|^[0-9]+:\s*#|^[0-9]+:\s*(info|warn|fail|ok|why|fix) "')
if [ -z "$bad" ]; then PASS=$((PASS+1)); else FAILN=$((FAILN+1)); echo "FAIL [static]: write redirect:"; echo "$bad"; fi

echo "passed $PASS, failed $FAILN"
[ "$FAILN" = 0 ]
