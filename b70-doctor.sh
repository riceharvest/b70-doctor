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
# Test hooks (fixtures): B70D_ROOT, B70D_JOURNAL, B70D_JOURNAL_PREV, B70D_PKGS, B70D_HAVE, B70D_ENV_SWAPCHECK,
# B70D_CONTAINERS (lines "runtime|name|image|started"), B70D_DRI_PROCS (lines "pid ppid comm").

VERSION=0.5.0
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
GOOD_ONEAPI="2025.3, 2026.0, 2026.1"
BUILDS="https://github.com/riceharvest/b70-llama-builds"
HUB="https://riceharvest.github.io/awesome-b70/"

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
ver_lt() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$1" ]; }
# oneAPI compiler versions found, newest last ("2025.3 2026.1")
oneapi_versions() {
  local b d out=""
  for b in "$R/opt/intel/oneapi" "${ONEAPI_ROOT:+$R$ONEAPI_ROOT}" "${HOME:+$R$HOME/intel/oneapi}" "${HOME:+$R$HOME/oneapi}"; do
    [ -n "$b" ] && [ -d "$b/compiler" ] || continue
    for d in "$b"/compiler/*; do
      d=${d##*/}; case "$d" in 20[0-9][0-9].[0-9]*) out="$out $d" ;; esac
    done
  done
  printf '%s\n' $out | sort -uV | tr '\n' ' ' | sed 's/ $//'
}
# Running containers that were given the GPU: "runtime|name|image|started"
gpu_containers() {
  if [ -n "${B70D_CONTAINERS+x}" ]; then cat "$B70D_CONTAINERS" 2>/dev/null; return; fi
  local rt id
  for rt in docker podman; do
    have "$rt" || continue
    for id in $("$rt" ps -q 2>/dev/null); do
      "$rt" inspect --format "$rt|{{.Name}}|{{.Config.Image}}|{{.State.StartedAt}}|{{.HostConfig.Privileged}}|{{range .HostConfig.Devices}}{{.PathOnHost}},{{end}}|{{.Path}} {{range .Args}}{{.}} {{end}}{{range .Config.Env}}{{.}} {{end}}" "$id" 2>/dev/null \
        | tr '\n' ' ' | sed 's/ $//'; echo
    done | awk -F'|' '$5=="true" || $6 ~ /\/dev\/dri/ {sub(/^\//,"",$2); a=$7; for (i=8;i<=NF;i++) a=a" "$i; print $1"|"$2"|"$3"|"substr($4,1,16)"|"a}'
  done
}
# Local container images: "repository:tag" per line
local_images() {
  if [ -n "${B70D_IMAGES+x}" ]; then cat "$B70D_IMAGES" 2>/dev/null; return; fi
  local rt
  for rt in docker podman; do
    have "$rt" || continue
    "$rt" image ls --format '{{.Repository}}:{{.Tag}}' 2>/dev/null
  done | sort -u
}
# Processes with a GPU render node open (own processes only without root): "pid ppid comm"
dri_procs() {
  if [ -n "${B70D_DRI_PROCS+x}" ]; then cat "$B70D_DRI_PROCS" 2>/dev/null; return; fi
  local f pid
  find "$R"/proc/[0-9]*/fd -maxdepth 1 -lname '/dev/dri/renderD*' 2>/dev/null | while IFS= read -r f; do
    pid=${f%/fd/*}; pid=${pid##*/}; printf '%s\n' "$pid"
  done | sort -un | while IFS= read -r pid; do
    printf '%s %s %s\n' "$pid" "$(awk '/^PPid:/{print $2}' "$R/proc/$pid/status" 2>/dev/null)" "$(cat "$R/proc/$pid/comm" 2>/dev/null)"
  done
}

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
  printf '},"swap_devices":%d,"oneapi":%s,"vk_driver_files":%s,"gpu_containers":%d}\n' "$(awk 'NR>1' "$R/proc/swaps" 2>/dev/null | wc -l)" \
    "$(jstr "$(oneapi_versions)")" "$(jstr "${VK_DRIVER_FILES:-${VK_ICD_FILENAMES:-}}")" "$(gpu_containers | grep -c .)"
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
  echo "oneAPI: $(oneapi_versions)"; echo "VK_DRIVER_FILES: ${VK_DRIVER_FILES:-${VK_ICD_FILENAMES:-}}"
  echo "GPU containers running: $(gpu_containers | grep -c .)"
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
        why "Known B70 issue family (compute-runtime#944, llama.cpp#25692, #27595). It tracks the driver release, not your app."
        fix "llama.cpp SYCL / oneAPI apps: try SYCL_UR_USE_LEVEL_ZERO_V2=0 (stopped the resets for one 26.27 user, llama.cpp#27595)"
        why "More reported mitigations: ${HUB}#gpu-hangs-and-resets"
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
  if [ "$NBMG" -ge 2 ]; then
    info "$NBMG Battlemage cards: known dual-card issues and what helped"
    why "llama.cpp SYCL --split-mode tensor crashes or hangs: GGML_SYCL_DEV2DEV_MEMCPY=2 (slower, stable; llama.cpp#27198),"
    why "  GGML_SYCL_ENABLE_VMM=0 for the quantized-KV hang (#26409), or use --split-mode layer"
    why "vLLM TP2 on boards without GPU P2P: CCL_SYCL_ALLREDUCE_SIMPLE_THRESHOLD, CCL_SYCL_REDUCE_SCATTER_SIMPLE_THRESHOLD and"
    why "  CCL_SYCL_ALLGATHERV_SIMPLE_THRESHOLD=4294967296 (SergiioB's cookbook, docs/DUAL-B70-TP2.md)"
  fi
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
if [ -n "$lz" ]; then
  ok "Level Zero loader: $lz"
elif [ -n "$cr" ]; then
  zl=""; for d in /usr/lib64 /usr/lib/x86_64-linux-gnu /usr/lib /usr/local/lib; do [ -e "$R$d/libze_loader.so.1" ] && zl="$d/libze_loader.so.1"; done
  if [ -n "$zl" ]; then ok "Level Zero loader: $zl"
  else
    warn "compute-runtime is installed but the Level Zero loader (libze_loader.so.1) is missing"
    why "llama.cpp SYCL, oneAPI apps and the prebuilt SYCL binaries load the GPU through it."
    fix "$(install_cmd compute)"
  fi
fi
crv=$(printf '%s' "${cr#* }" | sed -E 's/^[0-9]+://; s/[^0-9.].*$//')
if [ -n "$cr" ] && [ -n "$crv" ] && [ "${crv%%.*}" = 25 ] && ver_lt "$crv" 25.48; then
  info "compute-runtime $crv: 25.48 and newer lowered the B70 reset/DEVICE_LOST rate (compute-runtime#944)"
  why "releases: https://github.com/intel/compute-runtime/releases"
fi

if [ -e "$R/usr/share/vulkan/icd.d/intel_icd.x86_64.json" ] || [ -e "$R/usr/share/vulkan/icd.d/intel_icd.json" ]; then
  mv=""; for p in mesa-vulkan-drivers vulkan-intel; do v=$(pkgver "$p"); [ -n "$v" ] && { mv="$p $v"; break; }; done
  ok "Vulkan: Mesa ANV installed${mv:+ ($mv)}"
  why "llama.cpp Vulkan on Xe2: flash attention falls back to a slow scalar path (llama.cpp#30503, #27638)."
  mver=$(printf '%s' "${mv#* }" | sed -E 's/^[0-9]+://; s/[^0-9.].*$//')
  vkd="${VK_DRIVER_FILES:-${VK_ICD_FILENAMES:-}}"
  if [ -z "$vkd" ] && [ -n "$mver" ] && ver_lt "$mver" 26.0; then
    info "Want speed? On Mesa 25.x use llama.cpp SYCL: on a B70 it decoded 1.7x faster than Vulkan (what Ollama and"
    why "LM Studio use) and ran prompts after 32K of context 8x faster (Qwen3.8-27B Q4_K_XL, Mesa 25.3.6)."
  else
    info "Vulkan decode on Mesa 26 is close to llama.cpp SYCL on a B70 (Mesa 26.2.5: 35B-A3B MoE 86 vs SYCL 98 tok/s,"
    why "27B 22.9 vs 21.9; short prompts ~10% slower than on Mesa 25). For long context, SYCL is still much faster."
  fi
  why "https://riceharvest.github.io/awesome-b70/#measured-sycl-vs-vulkan-on-a-b70"
  if [ -n "$vkd" ]; then
    info "VK_DRIVER_FILES/VK_ICD_FILENAMES is set in this shell: Vulkan apps use $vkd, not the distro Mesa${mver:+ $mver}"
  elif [ -n "$mver" ] && ver_lt "$mver" 26.0; then
    warn "Mesa $mver is older than 26: Vulkan LLM decode on Battlemage is much slower on Mesa 25.x"
    why "On a B70, Mesa 26.2.5 took llama.cpp Vulkan decode from 39 to 86 tok/s (Qwen3.6-35B-A3B) and 13.2 to 22.9 (Qwen3.8-27B),"
    why "close to SYCL. Only matters for Vulkan apps (llama.cpp Vulkan, Ollama, LM Studio)."
    osver=$(. "$R/etc/os-release" 2>/dev/null; echo "${VERSION_ID:-}")
    case "$OS_ID:$DISTRO" in
      ubuntu:*) fix "sudo add-apt-repository ppa:kisak/kisak-mesa && sudo apt update && sudo apt upgrade   (Mesa 26.2.4 for 24.04 and 26.04)" ;;
      fedora:*) if [ -n "$osver" ] && ver_lt "$osver" 44; then
                  fix "Fedora 44 ships Mesa 26.2.4 (Fedora $osver updates have 25.x): sudo dnf system-upgrade download --releasever=44 && sudo dnf system-upgrade reboot"
                else fix "sudo dnf upgrade --refresh mesa-vulkan-drivers"; fi ;;
      arch:*|*:arch) fix "sudo pacman -Syu   (Arch has Mesa 26.2.x)" ;;
      *) fix "update Mesa to 26.1.7+ (newer distro release or backports)" ;;
    esac
    why "     Without touching the system: the b70-llama image has both llama.cpp builds and its own Mesa 26.2.4:"
    why "     docker run --rm -it --device /dev/dri -v ~/models:/models -p 8080:8080 ghcr.io/riceharvest/b70-llama vulkan -m /models/<model>.gguf"
    why "     Or build Mesa into a local prefix: VK_DRIVER_FILES=<prefix>/share/vulkan/icd.d/intel_icd.x86_64.json <app>   (or use llama.cpp SYCL)"
  elif [ -n "$mver" ] && ver_lt "$mver" 26.1.7; then
    info "Mesa $mver: updating to 26.1.7 or newer doubled Vulkan decode on a B580 (llama.cpp discussion #27777)"
  fi
else
  info "no Intel Vulkan driver (Mesa ANV) found; only matters for Vulkan builds (llama.cpp Vulkan, LM Studio Vulkan)"
  fix "$(install_cmd vulkan)"
fi

ONEAPI_VERS=$(oneapi_versions)
if [ -n "$ONEAPI_VERS" ]; then
  newest=${ONEAPI_VERS##* }
  if ver_lt "$newest" 2025.0; then
    warn "oneAPI $newest predates Battlemage; B70 llama.cpp SYCL builds use 2025.3 or newer"
    fix "install a current oneAPI Base Toolkit, or use prebuilt B70 binaries that bundle the runtime: $BUILDS"
  else
    ok "oneAPI compiler: $ONEAPI_VERS (seen working on a B70: $GOOD_ONEAPI)"
  fi
else
  info "no oneAPI found: you don't need it to run llama.cpp SYCL on a B70"
  why "prebuilt SYCL binaries (AOT for the B70, oneAPI runtime bundled): $BUILDS"
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

# --- image versions and serving flags ---------------------------------------------------
# image_advice IMAGE: known newer releases of B70 images (as of 2026-10-15)
image_advice() {
  local img=$1 tag=${1##*:}
  case "$img" in
    ghcr.io/riceharvest/b70-vllm:v0.31.0-b70.1|ghcr.io/riceharvest/b70-vllm:v0.31.0-b70.2)
      info "$img is older than ghcr.io/riceharvest/b70-vllm:v0.31.0-b70.3"
      why "b70.2: packed MTP verify '!!!!' fix; b70.3: Qwen3.6-35B-A3B MoE decode GEMV + fp8 linears (MTP4 175.9 -> 243.7 tok/s code)"
      fix "docker pull ghcr.io/riceharvest/b70-vllm:latest   (then recreate the container)" ;;
    intel/llm-scaler-vllm:*)
      local v=${tag%%-*}
      if printf '%s' "$v" | grep -qE '^[0-9]+\.[0-9]+(\.[0-9]+)?$' && ver_lt "$v" 0.26.0; then
        warn "$img: prefix caching + MTP gives corrupted output on Qwen3.5/3.8 before 0.26.0-b2"
        fix "docker pull intel/llm-scaler-vllm:0.26.0-b2   (or newer)"
      fi ;;
  esac
}
# container_advice NAME IMAGE ARGS: serving flags that matter on a B70
container_advice() {
  local name=$1 img=$2 args=" $3 "
  case "$args$img" in *vllm*) ;; *) return 0 ;; esac
  # Qwen3.5 / 3.6 / 3.8 / Qwen3-Next (GDN): the recurrent state is fp32 per the model config; at many concurrent
  # requests it is a large share of the bytes read per step
  if printf '%s' "$args$img" | grep -qiE 'qwen3[._-]?(5|6|8)|qwen3-?next|b70-vllm' && [ "${args#* --mamba-ssm-cache-dtype}" = "$args" ]; then
    local seqs; seqs=$(printf '%s' "$args" | sed -nE 's/.* --max-num-seqs[ =]([0-9]+).*/\1/p')
    if [ -z "$seqs" ] || [ "$seqs" -ge 16 ]; then
      info "$name: GDN model served with the default fp32 recurrent state and up to ${seqs:-the default number of} concurrent requests"
      why "Qwen3.5/3.6/3.8 store the linear-attention state in fp32 (60 MiB per request for Qwen3.6-35B-A3B). At 64 requests that is"
      why "~1/3 of the bytes moved per decode step on a B70, and it limited one run to 61 concurrent requests. fp16 halves it."
      why "The kernels support it; output quality vs fp32 is not measured yet, so compare outputs on your own prompts."
      fix "add --mamba-ssm-cache-dtype float16 to the vllm serve arguments of $name"
    fi
  fi
}

# --- containers ----------------------------------------------------------------------
if have docker; then
  section "Docker"
  rg=$(stat -c %g "$R/dev/dri/renderD128" 2>/dev/null)
  info "run GPU containers with: --device /dev/dri --group-add ${rg:-<render gid>}"
  why "vLLM XPU: also pass -e ZE_AFFINITY_MASK=0 (pick the card); on a B70 with vLLM UVA offload, leaving it out gave UR OUT_OF_DEVICE_MEMORY."
fi
if have docker || have podman; then
  while IFS= read -r img; do [ -n "$img" ] && image_advice "$img"; done <<< "$(local_images)"
fi

# --- GPU users ---------------------------------------------------------------------------
CONTAINERS=$(gpu_containers)
DRIP=$(dri_procs)
if [ -n "$CONTAINERS" ] || [ -n "$DRIP" ]; then
  section "GPU in use"
  if [ -n "$CONTAINERS" ]; then
    while IFS='|' read -r crt cname cimg cstart cargs; do
      [ -n "$cname" ] || continue
      info "$crt container $cname ($cimg) has the GPU, running since ${cstart/T/ }"
      container_advice "$cname" "$cimg" "$cargs"
    done <<< "$CONTAINERS"
    why "A container left over from an earlier job keeps VRAM and can keep running kernels. On one B70, leftover vLLM"
    why "workers kept running and faulted the GPU during later jobs."
    fix "if it's left over: docker rm -f <name>   (podman rm -f <name>)"
  fi
  orphans=$(printf '%s\n' "$DRIP" | awk '$2==1 && $3 ~ /^(VLLM|vllm|python|python3|llama|ollama|ray|torchrun|pt_main_thread)/ {print $3" (pid "$1")"}' | tr '\n' ',' | sed 's/,$//; s/,/, /g')
  if [ -n "$orphans" ]; then
    warn "orphaned GPU process(es), parent gone: $orphans"
    why "Their launcher exited but they still hold the GPU (and VRAM). Typical after a killed vLLM or llama.cpp run."
    fix "kill <pid>   (check with: ps -o pid,etime,args -p <pid>)"
  fi
  others=$(printf '%s\n' "$DRIP" | awk '$2!=1 && $3 !~ /^(gnome-|kwin|Xorg|Xwayland|xwayland|plasma|kde|krunner|mutter|sway|Hyprland|weston|firefox|chrome|chromium|brave|Web Content|code|electron|steam|obs|gst|mpv|vlc|discord|slack|spotify)/ && NF>=3 {print $3" (pid "$1")"}' | sort -u | head -n 8 | tr '\n' ',' | sed 's/,$//; s/,/, /g')
  [ -n "$others" ] && info "other processes with the GPU open: $others"
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
printf '\nKnown problems and workarounds: %s#known-problems-and-workarounds' "$HUB"
printf '\nFor a bug report, run it again with --report (piped: ... | bash -s -- --report)\n'
[ "$NFAIL" -gt 0 ] && exit 1
exit 0
