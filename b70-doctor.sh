#!/usr/bin/env bash
# b70-doctor: read-only setup check for Intel Arc Pro B70 and other Battlemage GPUs on Linux.
# It never changes your system. It reads sysfs, /proc, the kernel log and package versions,
# then prints what looks wrong and the command that would fix it. You run the fixes yourself.
#
#   curl -fsSL https://raw.githubusercontent.com/riceharvest/b70-doctor/main/b70-doctor.sh | bash
#   bash b70-doctor.sh --report     # paste-ready environment block for bug reports
#   bash b70-doctor.sh --json       # the same environment as JSON (used by b70-bench)
#   bash b70-doctor.sh --probe      # also run vulkaninfo / sycl-ls / clinfo (opens the GPU, runs no kernels)
#
# https://github.com/riceharvest/b70-doctor  (MIT)
# Test hooks (fixtures): B70D_ROOT, B70D_JOURNAL, B70D_JOURNAL_PREV, B70D_PKGS, B70D_HAVE, B70D_ENV_SWAPCHECK.

VERSION=0.2.0
set -u

R="${B70D_ROOT:-}"
MODE=check
PROBE=0
COLOR=0
[ -t 1 ] && [ -z "${NO_COLOR:-}" ] && COLOR=1
for a in "$@"; do
  case "$a" in
    --report) MODE=report ;;
    --json) MODE=json ;;
    --probe) PROBE=1 ;;
    --no-color) COLOR=0 ;;
    --version) echo "b70-doctor $VERSION"; exit 0 ;;
    -h|--help) echo "usage: b70-doctor.sh [--report] [--json] [--probe] [--no-color] [--version]"; exit 0 ;;
    *) echo "unknown option: $a (try --help)" >&2; exit 2 ;;
  esac
done

# Versions this tool has seen working on a B70. "Known good", not minimums.
GOOD_KERNEL="7.0 (Ubuntu 26.04), 7.1.8 (Fedora 43)"
GOOD_GUC="70.65.0"
GOOD_CR="26.18 (Fedora 43), 26.27 (vLLM 0.31 XPU image)"

NFAIL=0; NWARN=0
if [ "$COLOR" = 1 ]; then
  C_OK=$'\e[32m'; C_W=$'\e[33m'; C_F=$'\e[31m'; C_I=$'\e[36m'; C_B=$'\e[1m'; C_0=$'\e[0m'
else
  C_OK=; C_W=; C_F=; C_I=; C_B=; C_0=
fi
section() { [ "$MODE" = check ] && printf '\n%s== %s ==%s\n' "$C_B" "$1" "$C_0"; }
ok()   { [ "$MODE" = check ] && printf '  %s[ OK ]%s %s\n' "$C_OK" "$C_0" "$1"; }
info() { [ "$MODE" = check ] && printf '  %s[INFO]%s %s\n' "$C_I" "$C_0" "$1"; }
warn() { NWARN=$((NWARN+1)); [ "$MODE" = check ] && printf '  %s[WARN]%s %s\n' "$C_W" "$C_0" "$1"; }
fail() { NFAIL=$((NFAIL+1)); [ "$MODE" = check ] && printf '  %s[FAIL]%s %s\n' "$C_F" "$C_0" "$1"; }
# Printed only. Nothing in this script executes a fix.
fix()  { [ "$MODE" = check ] && printf '         fix: %s\n' "$1"; }
why()  { [ "$MODE" = check ] && printf '         %s\n' "$1"; }

rd() { cat "$R$1" 2>/dev/null | head -n1; }
have() {
  if [ -n "${B70D_HAVE+x}" ]; then case " $B70D_HAVE " in *" $1 "*) return 0 ;; esac; return 1; fi
  command -v "$1" >/dev/null 2>&1
}
# Kernel log for this boot (arg 0) or the previous one (arg -1).
klog() {
  if [ "$1" = 0 ] && [ -n "${B70D_JOURNAL+x}" ]; then cat "$B70D_JOURNAL" 2>/dev/null; return; fi
  if [ "$1" = -1 ] && [ -n "${B70D_JOURNAL_PREV+x}" ]; then cat "$B70D_JOURNAL_PREV" 2>/dev/null; return; fi
  if [ -n "${B70D_JOURNAL+x}" ]; then return; fi
  local out=""
  have journalctl && out=$(journalctl -k -b "$1" --no-pager -q 2>/dev/null)
  if [ -n "$out" ]; then printf '%s\n' "$out"; return; fi
  [ "$1" = 0 ] && dmesg 2>/dev/null
}
# "name version" lines for installed packages we care about.
pkgs() {
  if [ -n "${B70D_PKGS+x}" ]; then cat "$B70D_PKGS" 2>/dev/null; return; fi
  if have rpm; then
    rpm -qa --qf '%{NAME} %{VERSION}\n' 2>/dev/null
  elif have dpkg-query; then
    dpkg-query -W -f '${Package} ${Version} ${Status}\n' 2>/dev/null | awk '/ installed$/{print $1, $2}'
  elif have pacman; then
    pacman -Q 2>/dev/null
  fi
}
pkgver() { printf '%s\n' "$PKGS" | awk -v n="$1" '$1==n{print $2; exit}'; }

OS_ID=$(. "$R/etc/os-release" 2>/dev/null; echo "${ID:-unknown}")
OS_LIKE=$(. "$R/etc/os-release" 2>/dev/null; echo "${ID_LIKE:-}")
OS_NAME=$(. "$R/etc/os-release" 2>/dev/null; echo "${PRETTY_NAME:-unknown}")
case " $OS_ID $OS_LIKE " in
  *" fedora "*|*" rhel "*) DISTRO=fedora ;;
  *" ubuntu "*|*" debian "*) DISTRO=debian ;;
  *" arch "*) DISTRO=arch ;;
  *) DISTRO=other ;;
esac
install_cmd() { # $1 = what: compute | vulkan
  case "$DISTRO:$1" in
    fedora:compute) echo "sudo dnf install intel-compute-runtime intel-level-zero oneapi-level-zero" ;;
    debian:compute) echo "sudo apt install intel-opencl-icd libze-intel-gpu1 libze1   (Ubuntu: newest builds are in Intel's kobuk-team/intel-graphics PPA)" ;;
    arch:compute)   echo "sudo pacman -S intel-compute-runtime level-zero-loader" ;;
    fedora:vulkan)  echo "sudo dnf install mesa-vulkan-drivers vulkan-tools" ;;
    debian:vulkan)  echo "sudo apt install mesa-vulkan-drivers vulkan-tools" ;;
    arch:vulkan)    echo "sudo pacman -S vulkan-intel vulkan-tools" ;;
    *:compute)      echo "install Intel compute-runtime (Level Zero + OpenCL): https://github.com/intel/compute-runtime/releases" ;;
    *:vulkan)       echo "install Mesa's Intel Vulkan driver (ANV) from your distro" ;;
  esac
}

gpu_name() {
  case "$1" in
    0xe223) echo "Arc Pro B70" ;;
    0xe211) echo "Arc Pro B60" ;;
    0xe212) echo "Arc Pro B50" ;;
    0xe20b) echo "Arc B580" ;;
    0xe20c) echo "Arc B570" ;;
    0xe2[0-2]?) echo "Battlemage ($1)" ;;
    *) echo "Intel GPU ($1)" ;;
  esac
}
is_bmg() { case "$1" in 0xe2[0-2]?) return 0 ;; esac; return 1; }
human_bytes() { awk -v b="$1" 'BEGIN{ if (b>=1073741824) printf "%.0f GiB", b/1073741824; else printf "%.0f MiB", b/1048576 }'; }
speed_num() { printf '%s' "$1" | awk '{print $1+0}'; }

KREL=$(rd /proc/sys/kernel/osrelease); [ -z "$KREL" ] && KREL=$(uname -r)
MEM_KB=$(awk '/^MemTotal:/{print $2}' "$R/proc/meminfo" 2>/dev/null)
PKGS=$(pkgs)
KLOG0=$(klog 0)
KLOG1=$(klog -1)
KLOG_OK=1; [ -z "$KLOG0" ] && KLOG_OK=0

# --- find GPUs ---------------------------------------------------------------
GPUS=(); OTHER_GPUS=0
for d in "$R"/sys/bus/pci/devices/*; do
  [ -e "$d/class" ] || continue
  cls=$(head -n1 "$d/class" 2>/dev/null)
  case "$cls" in 0x03*) ;; *) continue ;; esac
  if [ "$(head -n1 "$d/vendor" 2>/dev/null)" = 0x8086 ]; then GPUS+=("$(basename "$d")"); else OTHER_GPUS=$((OTHER_GPUS+1)); fi
done

dev_driver() { local l; l=$(readlink "$R/sys/bus/pci/devices/$1/driver" 2>/dev/null) && basename "$l"; }
dev_path() { # real sysfs path of the device, with B70D_ROOT kept as prefix
  local p; p=$(cd "$R/sys/bus/pci/devices/$1" 2>/dev/null && pwd -P) && printf '%s' "$p"
}
# The GPU sits behind its own PCIe switch (e2ff upstream, e2f0 downstream). The slot link
# is the link of the topmost Intel bridge; its parent is the CPU/chipset root port.
slot_link() { # prints: speed width max_speed max_width root_max_speed
  local p up=""; p=$(dev_path "$1") || return 1
  local cur; cur=$(dirname "$p")
  while [ -e "$cur/vendor" ] && [ "$(head -n1 "$cur/vendor")" = 0x8086 ] && \
        case "$(head -n1 "$cur/class" 2>/dev/null)" in 0x0604*) true ;; *) false ;; esac; do
    up=$cur; cur=$(dirname "$cur")
  done
  [ -z "$up" ] && up=$p
  local rootmax=""; [ -e "$cur/max_link_speed" ] && rootmax=$(head -n1 "$cur/max_link_speed")
  printf '%s|%s|%s|%s|%s\n' "$(head -n1 "$up/current_link_speed" 2>/dev/null)" "$(head -n1 "$up/current_link_width" 2>/dev/null)" \
    "$(head -n1 "$up/max_link_speed" 2>/dev/null)" "$(head -n1 "$up/max_link_width" 2>/dev/null)" "$rootmax"
}
bar_bytes() { # largest BAR of the device (the VRAM aperture with ReBAR on); bash math, mawk has no strtonum
  local s e m=0 n i=0
  while read -r s e _ && [ "$i" -lt 6 ]; do
    i=$((i+1)); n=$(( e - s + 1 )); [ $(( e > s )) = 1 ] && [ "$n" -gt "$m" ] && m=$n
  done < "$R/sys/bus/pci/devices/$1/resource" 2>/dev/null
  echo "$m"
}
fw_line() { printf '%s\n' "$KLOG0" | grep -E "xe $1: .*Using $2 firmware" | tail -n1 | sed -E 's/.*version //'; }
dmc_ver() { printf '%s\n' "$KLOG0" | grep -E "xe $1: .*Finished loading DMC firmware" | tail -n1 | sed -E 's/.*\(v([0-9.]+)\).*/\1/'; }

# --- json mode -------------------------------------------------------------------
jstr() { local s=${1-}; s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/ }; s=${s//$'\t'/ }; printf '"%s"' "$s"; }
if [ "$MODE" = json ]; then
  printf '{"tool":"b70-doctor","version":%s,"os":%s,"kernel":%s,"ram_gib":%d,"gpus":[' \
    "$(jstr "$VERSION")" "$(jstr "$OS_NAME")" "$(jstr "$KREL")" $(( ${MEM_KB:-0} / 1048576 ))
  first=1
  for g in "${GPUS[@]}"; do
    id=$(rd "/sys/bus/pci/devices/$g/device")
    IFS='|' read -r sp w msp mw rmax <<< "$(slot_link "$g")"
    [ "$first" = 1 ] || printf ','; first=0
    printf '{"name":%s,"pci_id":%s,"addr":%s,"driver":%s,"bar_bytes":%s,"link":%s,"link_width":%s,"card_max_link":%s,"slot_max_link":%s,"guc":%s,"huc":%s,"dmc":%s,"ccs_job_timeout_ms":%s,"sriov_vfs":%s}' \
      "$(jstr "$(gpu_name "$id")")" "$(jstr "8086:${id#0x}")" "$(jstr "$g")" "$(jstr "$(dev_driver "$g")")" \
      "$(b=$(bar_bytes "$g"); echo "${b:-0}")" "$(jstr "$sp")" "$(jstr "$w")" "$(jstr "$msp")" "$(jstr "$rmax")" \
      "$(jstr "$(fw_line "$g" GuC | head -c 20)")" "$(jstr "$(fw_line "$g" HuC | head -c 20)")" "$(jstr "$(dmc_ver "$g")")" \
      "$(jstr "$(rd "/sys/bus/pci/devices/$g/tile0/gt0/engines/ccs/job_timeout_ms")")" "$(jstr "$(rd "/sys/bus/pci/devices/$g/sriov_numvfs")")"
  done
  printf '],"packages":{'
  first=1
  for p in intel-compute-runtime intel-level-zero intel-opencl intel-opencl-icd libze-intel-gpu1 libze1 oneapi-level-zero level-zero-loader intel-igc-core-2 intel-igc mesa-vulkan-drivers vulkan-intel linux-firmware; do
    v=$(pkgver "$p"); [ -n "$v" ] || continue
    [ "$first" = 1 ] || printf ','; first=0; printf '%s:%s' "$(jstr "$p")" "$(jstr "$v")"
  done
  printf '},"swap_devices":%d}\n' "$(awk 'NR>1' "$R/proc/swaps" 2>/dev/null | wc -l)"
  exit 0
fi

# --- report mode ---------------------------------------------------------------
if [ "$MODE" = report ]; then
  echo '```'
  echo "b70-doctor $VERSION report"
  echo "OS: $OS_NAME, kernel $KREL, RAM $(( ${MEM_KB:-0} / 1048576 )) GiB"
  for g in "${GPUS[@]}"; do
    id=$(rd "/sys/bus/pci/devices/$g/device")
    IFS='|' read -r sp w msp mw rmax <<< "$(slot_link "$g")"
    echo "GPU: $(gpu_name "$id") [8086:${id#0x}] at $g, driver $(dev_driver "$g"), BAR $(human_bytes "$(bar_bytes "$g")"), link $sp x$w (card max $msp x$mw, slot max ${rmax:-?})"
    echo "  firmware: GuC $(fw_line "$g" GuC | head -c 20), HuC $(fw_line "$g" HuC | head -c 20), DMC $(dmc_ver "$g")"
    e="/sys/bus/pci/devices/$g/tile0/gt0/engines/ccs"
    echo "  ccs job_timeout_ms $(rd "$e/job_timeout_ms"), preempt_timeout_us $(rd "$e/preempt_timeout_us"), SR-IOV VFs $(rd "/sys/bus/pci/devices/$g/sriov_numvfs")"
  done
  for p in intel-compute-runtime intel-level-zero intel-opencl intel-opencl-icd libze-intel-gpu1 libze1 oneapi-level-zero level-zero-loader intel-igc-core-2 intel-igc mesa-vulkan-drivers vulkan-intel linux-firmware; do
    v=$(pkgver "$p"); [ -n "$v" ] && echo "pkg: $p $v"
  done
  sw=$(awk 'NR>1' "$R/proc/swaps" 2>/dev/null | wc -l); echo "swap devices active: $sw"
  echo '```'
  exit 0
fi

printf '%sb70-doctor %s%s: read-only check. It changes nothing; every "fix:" line is for you to run.\n' "$C_B" "$VERSION" "$C_0"

# --- system --------------------------------------------------------------------
section "System"
info "$OS_NAME, kernel $KREL, RAM $(( ${MEM_KB:-0} / 1048576 )) GiB"
[ "$KLOG_OK" = 0 ] && warn "can't read the kernel log, so firmware and GPU-hang checks are skipped" && \
  fix "sudo bash b70-doctor.sh  or  curl -fsSL https://raw.githubusercontent.com/riceharvest/b70-doctor/main/b70-doctor.sh | sudo bash   (sudo only lets it read the log; it still changes nothing)"

# --- GPUs ----------------------------------------------------------------------
if [ "${#GPUS[@]}" = 0 ]; then
  section "GPU"
  fail "no Intel GPU on the PCI bus"
  why "Check the card is seated and powered (both 8-pin/12V-2x6 cables). In a container, the host must pass the device in."
fi
NBMG=0
for g in "${GPUS[@]}"; do
  id=$(rd "/sys/bus/pci/devices/$g/device"); name=$(gpu_name "$id"); drv=$(dev_driver "$g")
  is_bmg "$id" && NBMG=$((NBMG+1))
  section "$name at $g"
  if ! is_bmg "$id"; then info "not a Battlemage card; skipping B-series checks"; continue; fi

  case "$drv" in
    xe) ok "driver: xe" ;;
    i915) fail "driver: i915. Battlemage only works with the xe driver"
          fix "remove i915.force_probe=... from the kernel command line; use a kernel whose xe driver knows this card (known good: $GOOD_KERNEL)" ;;
    "") fail "no driver bound to the GPU"
        if printf '%s\n' "$KLOG0" | grep -qE "xe $g:.*(probe|failed|error)"; then
          why "kernel log: $(printf '%s\n' "$KLOG0" | grep -E "xe $g:.*(probe|failed|error)" | tail -n1 | cut -c1-160)"
        fi
        fix "use a kernel whose xe driver knows device ${id#0x} (known good: $GOOD_KERNEL); check 'lsmod | grep xe'" ;;
    *) warn "driver: $drv (expected xe)" ;;
  esac
  [ "$drv" = xe ] || continue

  # firmware
  guc=$(fw_line "$g" GuC); huc=$(fw_line "$g" HuC); dmc=$(dmc_ver "$g")
  if [ "$KLOG_OK" = 1 ]; then
    if [ -n "$guc" ]; then
      if [ "$guc" = "$GOOD_GUC" ]; then ok "GuC firmware $guc"; else info "GuC firmware $guc (known good: $GOOD_GUC)"; fi
    else
      warn "no GuC firmware load line in this boot's kernel log"
      fix "update linux-firmware (needs xe/bmg_guc_70.bin); then reboot"
    fi
    [ -n "$huc" ] && ok "HuC firmware $huc" || info "HuC firmware not reported (only matters for media encode/decode)"
    [ -n "$dmc" ] && ok "DMC firmware $dmc"
    if printf '%s\n' "$KLOG0" | grep -qE "xe $g:.*(firmware.*(failed|not found|error)|failed to load)"; then
      warn "firmware load error in kernel log: $(printf '%s\n' "$KLOG0" | grep -E "xe $g:.*(firmware.*(failed|not found|error)|failed to load)" | tail -n1 | cut -c1-140)"
      fix "update linux-firmware, then reboot"
    fi
  fi

  # PCIe slot link
  IFS='|' read -r sp w msp mw rmax <<< "$(slot_link "$g")"
  if [ -n "$sp" ]; then
    want=$(speed_num "$msp"); [ -n "$rmax" ] && [ "$(speed_num "$rmax")" != 0 ] && \
      awk -v a="$(speed_num "$rmax")" -v b="$want" 'BEGIN{exit !(a<b)}' && want=$(speed_num "$rmax")
    if [ "${w:-0}" -lt "${mw:-16}" ] 2>/dev/null; then
      warn "PCIe link x$w (card supports x$mw): model loading and host-offloaded weights get slower"
      fix "move the card to a full x16 slot, or check BIOS lane bifurcation / riser cable"
    elif awk -v a="$(speed_num "$sp")" -v b="$want" 'BEGIN{exit !(a<b)}'; then
      warn "PCIe link $sp, but both ends support $want GT/s"
      fix "set the slot to Auto/Gen4+ in BIOS, reseat the card, or replace the riser"
      why "(an idle link can downclock; re-run while the GPU is busy before acting on this)"
    else
      ok "PCIe link $sp x$w (slot max ${rmax:-?})"
    fi
  fi

  # Resizable BAR
  bb=$(bar_bytes "$g")
  if [ -n "$bb" ] && [ "$bb" != 0 ]; then
    if [ "$bb" -lt 1073741824 ]; then
      warn "VRAM BAR is only $(human_bytes "$bb"): Resizable BAR is off"
      fix "BIOS: enable 'Above 4G Decoding' and 'Re-Size BAR Support' (CSM off), then reboot"
    else
      ok "Resizable BAR on (BAR $(human_bytes "$bb"))"
    fi
  fi

  # render node access
  rn=""; for x in "$R/sys/bus/pci/devices/$g/drm"/renderD*; do [ -e "$x" ] && { rn=$(basename "$x"); break; }; done
  if [ -n "$rn" ]; then
    node="$R/dev/dri/$rn"
    if [ ! -e "$node" ]; then
      warn "/dev/dri/$rn missing (container without --device /dev/dri?)"
    elif [ -r "$node" ] && [ -w "$node" ]; then
      ok "you can open /dev/dri/$rn"
    else
      grp=$(stat -c %G "$node" 2>/dev/null)
      fail "no read/write access to /dev/dri/$rn (group ${grp:-?})"
      fix "sudo usermod -aG ${grp:-render} \$USER   then log out and back in"
    fi
  fi

  # SR-IOV
  vfs=$(rd "/sys/bus/pci/devices/$g/sriov_numvfs")
  if [ -n "$vfs" ] && [ "$vfs" != 0 ]; then
    warn "$vfs SR-IOV virtual functions enabled: they take VRAM from the host"
    fix "echo 0 | sudo tee /sys/bus/pci/devices/$g/sriov_numvfs   (if you don't use VMs on this GPU)"
  fi

  # display
  if [ "$(rd "/sys/bus/pci/devices/$g/boot_vga")" = 1 ]; then
    info "this GPU also drives your desktop: the compositor uses some VRAM, and a GPU wedge takes the desktop down too"
  fi

  # engine timeouts
  e="/sys/bus/pci/devices/$g/tile0/gt0/engines/ccs"
  jt=$(rd "$e/job_timeout_ms"); jmax=$(rd "$e/job_timeout_max")
  [ -n "$jt" ] && info "compute engine job_timeout_ms $jt (max ${jmax:-?}), preempt_timeout_us $(rd "$e/preempt_timeout_us")"

  # hangs in the kernel log
  if [ "$KLOG_OK" = 1 ]; then
    for b in 0 -1; do
      if [ "$b" = 0 ]; then L=$KLOG0; when="this boot"; else L=$KLOG1; when="previous boot"; fi
      [ -z "$L" ] && continue
      L=$(printf '%s\n' "$L" | grep -E "xe $g:")
      wedge=$(printf '%s\n' "$L" | grep -c "declared device .* as wedged")
      n_to=$(printf '%s\n' "$L" | grep -cE "Timedout job")
      rs_ccs=$(printf '%s\n' "$L" | grep -cE "Engine reset: engine_class=ccs")
      rs_bcs=$(printf '%s\n' "$L" | grep -cE "Engine reset: engine_class=bcs")
      cat_e=$(printf '%s\n' "$L" | grep -cE "CAT error")
      if [ "$wedge" -gt 0 ]; then
        if [ "$b" = 0 ]; then
          fail "GPU is WEDGED ($when). Nothing will run on it until you reboot"
        else
          warn "GPU wedged in the $when"
        fi
        why "Seen when a job runs close to the VRAM limit (drm/xe#7893). Leave a few GB of VRAM headroom."
        [ "$b" = 0 ] && fix "reboot (or, as root, unbind and rebind the xe driver)"
      fi
      if [ "$rs_ccs" -gt 0 ]; then
        warn "$when: $rs_ccs compute-engine resets ($n_to job timeouts on any engine)"
        why "last: $(printf '%s\n' "$L" | grep -E "engine_class=ccs" | tail -n1 | sed -E 's/.*\[drm\] //' | cut -c1-130)"
        why "Known B70 reports: llama.cpp#25692 (SYCL FA + quantized KV under load), compute-runtime#944."
        [ -n "$jmax" ] && [ -n "$jt" ] && [ "$jt" -lt "$jmax" ] 2>/dev/null && \
          fix "for long single kernels you can try: echo $jmax | sudo tee $e/job_timeout_ms   (resets at reboot; may not help real hangs)"
      fi
      if [ "$cat_e" -gt 0 ] || [ "$rs_bcs" -gt 0 ]; then
        warn "$when: $cat_e engine memory (CAT) errors, $rs_bcs copy-engine resets"
        why "last: $(printf '%s\n' "$L" | grep -E "CAT error|engine_class=bcs" | tail -n1 | sed -E 's/.*\[drm\] //' | cut -c1-130)"
        why "Seen with vLLM XPU while loading weights / host-offloaded (UVA) memory (vllm#61300)."
      fi
      if [ "$n_to" -gt 0 ] && [ "$rs_ccs" = 0 ] && [ "$cat_e" = 0 ] && [ "$rs_bcs" = 0 ]; then
        warn "$when: $n_to GPU job timeouts"
        why "last: $(printf '%s\n' "$L" | grep -E "Timedout job" | tail -n1 | sed -E 's/.*\[drm\] //' | cut -c1-130)"
      fi
      if printf '%s\n' "$L" | grep -q "page allocation failure"; then
        info "$when: an xe page allocation failure (usually while capturing a crash dump under memory pressure)"
      fi
    done
  fi
done

# --- multiple GPUs ---------------------------------------------------------------
if [ $(( ${#GPUS[@]} + OTHER_GPUS )) -gt 1 ]; then
  section "Multiple GPUs"
  info "${#GPUS[@]} Intel + $OTHER_GPUS other GPU(s). Pick the card explicitly:"
  why "llama.cpp SYCL: ONEAPI_DEVICE_SELECTOR=level_zero:N   llama.cpp Vulkan: GGML_VK_VISIBLE_DEVICES=N"
  why "vLLM / PyTorch XPU: ZE_AFFINITY_MASK=N   (list devices with: sycl-ls, vulkaninfo --summary)"
fi

# --- userspace ---------------------------------------------------------------------
section "Userspace drivers"
cr=""
for p in intel-compute-runtime libze-intel-gpu1 intel-level-zero intel-opencl-icd intel-opencl; do
  v=$(pkgver "$p"); [ -n "$v" ] && { cr="$p $v"; break; }
done
if [ -n "$cr" ]; then
  ok "compute-runtime: $cr (known good: $GOOD_CR)"
  major=$(printf '%s' "${cr#* }" | sed -E 's/^[0-9]+://' | cut -d. -f1)
  if [ -n "$major" ] && [ "$major" -lt 25 ] 2>/dev/null; then
    warn "compute-runtime $major.x likely predates good Battlemage support"
    fix "$(install_cmd compute)"
  fi
else
  if [ -n "${B70D_PKGS+x}" ] || [ -n "$PKGS" ]; then
    warn "no Intel compute-runtime (Level Zero / OpenCL GPU driver) found"
    why "Needed for llama.cpp SYCL, oneAPI builds and bare-metal vLLM/PyTorch XPU. Not needed for Vulkan or Docker images."
    fix "$(install_cmd compute)"
  else
    info "couldn't query packages (no rpm/dpkg/pacman)"
  fi
fi
lz=""; for p in oneapi-level-zero libze1 level-zero-loader level-zero; do v=$(pkgver "$p"); [ -n "$v" ] && { lz="$p $v"; break; }; done
[ -n "$lz" ] && ok "Level Zero loader: $lz"

if [ -e "$R/usr/share/vulkan/icd.d/intel_icd.x86_64.json" ] || [ -e "$R/usr/share/vulkan/icd.d/intel_icd.json" ]; then
  mv=""; for p in mesa-vulkan-drivers vulkan-intel; do v=$(pkgver "$p"); [ -n "$v" ] && { mv="$p $v"; break; }; done
  ok "Vulkan: Mesa ANV installed${mv:+ ($mv)}"
  why "llama.cpp Vulkan on Xe2: flash attention falls back to a slow scalar path (llama.cpp#30503, #27638)."
  why "At long context SYCL is usually faster (llama.cpp#28721)."
else
  info "no Intel Vulkan driver (Mesa ANV) found; only matters for Vulkan builds (llama.cpp Vulkan, LM Studio Vulkan)"
  fix "$(install_cmd vulkan)"
fi

if [ -d "$R/opt/intel/oneapi" ] && [ -z "${ONEAPI_ROOT:-}" ]; then
  info "oneAPI is installed but not loaded in this shell"
  fix "source /opt/intel/oneapi/setvars.sh   (before building or running llama.cpp SYCL)"
fi

# --- memory / swap ---------------------------------------------------------------------
section "Host memory"
sw=$(awk 'NR>1{print $1}' "$R/proc/swaps" 2>/dev/null | tr '\n' ' ')
if [ -n "${sw// /}" ]; then
  if have docker || have vllm; then
    info "swap is on ($sw)"
    why "If vLLM XPU with --cpu-offload / host (UVA) weights hits 'CAT error' or bcs resets at startup, test once with swap off."
    why "On one B70 box this correlated with active zram; it is not proven, and these errors also occur without swap."
  else
    ok "swap on ($sw)"
  fi
else
  ok "no swap"
fi

# --- containers ----------------------------------------------------------------------
if have docker; then
  section "Docker"
  rg=$(stat -c %g "$R/dev/dri/renderD128" 2>/dev/null)
  info "run GPU containers with: --device /dev/dri --group-add ${rg:-<render gid>}"
  why "vLLM XPU: also pass -e ZE_AFFINITY_MASK=0 (pick the card); on a B70 with vLLM UVA offload, leaving it out gave UR OUT_OF_DEVICE_MEMORY."
fi

# --- probe -------------------------------------------------------------------------------
if [ "$PROBE" = 1 ]; then
  section "Probe (opens the GPU, runs no kernels)"
  if have vulkaninfo; then vulkaninfo --summary 2>/dev/null | grep -E 'deviceName|driverName|driverInfo|apiVersion' | sed 's/^/    /'
  else info "vulkaninfo not installed"; fi
  if have sycl-ls; then sycl-ls 2>/dev/null | sed 's/^/    /'; else info "sycl-ls not found (comes with oneAPI)"; fi
  if have clinfo; then clinfo -l 2>/dev/null | sed 's/^/    /'; fi
fi

# --- summary ---------------------------------------------------------------------------------
printf '\n%sSummary:%s %d problem(s), %d warning(s).' "$C_B" "$C_0" "$NFAIL" "$NWARN"
[ "$NBMG" = 0 ] && [ "${#GPUS[@]}" -gt 0 ] && printf ' No Battlemage GPU found.'
printf '\nFor a bug report, run it again with --report (piped: ... | bash -s -- --report)\n'
[ "$NFAIL" -gt 0 ] && exit 1
exit 0
