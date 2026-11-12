#!/bin/bash
# Switch the 14-inch M5 Max to Omarchy EDGE the way the official Mac image does, over Ethernet.
#
# pacman.conf and the mirrorlist come from the runtime's channel templates (omarchy-apply-pacman edge),
# the edge runtime is omarchy-dev + omarchy-settings-dev + omarchy-mac, then the runtime's own package
# lists, omarchy-apply-system's phases, omarchy-provision-user and (at first login)
# omarchy-provision-first-run. Everything that owns the boot chain is left alone.
# This Mac boots m1n1 -> custom kernel K114c from /boot/m1n1; no package here owns the kernel, m1n1,
# GRUB, Limine, U-Boot or the ESP, and the script proves that at the end.
#
# usage: m5-omarchy-install.sh check     read-only survey, no root needed, changes nothing
#        m5-omarchy-install.sh install   full install; re-runs itself through `sudo -n`
#
# needs the keys/ directory next to this file (public signing keys; fingerprints are pinned below).
# env: M5_USER      account that becomes the Omarchy owner (default: the user who ran sudo, else the caller)
#      M5_KEYS_DIR  key directory (default: keys/ next to the script)
set -euo pipefail
export LC_ALL=C.UTF-8
export PATH=/usr/local/sbin:/usr/local/bin:/usr/bin
# The omarchy pre-transaction hook refuses a direct `pacman -Syu`; this script is the install path.
export OMARCHY_ALLOW_DIRECT_PACMAN=1

readonly OMARCHY_FPR=40DFB630FF42BCFFB047046CF0134EE680CAC571
readonly ASAHI_FPR=12CE6799A94A3F1B5DDFFE88F576553597FB8FEB
readonly KERNEL_RE='k114c'
readonly IGNORE='linux-aurora* linux-asahi* m1n1* grub limine* uboot-asahi omarchy-mac-boot'
readonly DENY='^(linux-aurora.*|linux-asahi.*|m1n1.*|grub.*|limine.*|uboot-asahi|omarchy-mac-boot|dracut|systemd-boot.*)$'
readonly WORK=/var/tmp/m5-omarchy
readonly STATE=/var/lib/omarchy/m5-install
readonly MANIFESTS=(omarchy-base omarchy-aarch64 omarchy-aarch64-apple)

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
keys=${M5_KEYS_DIR:-$here/keys}
owner=${M5_USER:-${SUDO_USER:-$(id -un)}}

say() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { printf '%s FAIL: %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; exit 1; }
[[ $owner != root ]] || die "the Omarchy owner would be root; run through sudo from your account or set M5_USER"

fpr_of() { gpg --batch --show-keys --with-colons "$1" 2>/dev/null | awk -F: '$1=="fpr"{print $10; exit}'; }

check_keys() {
  local f name want got
  for f in "omarchy-pkgs.gpg $OMARCHY_FPR" "asahi-alarm.gpg $ASAHI_FPR"; do
    read -r name want <<<"$f"
    [[ -r $keys/$name ]] || die "missing key file $keys/$name"
    got=$(fpr_of "$keys/$name")
    [[ $got == "$want" ]] || die "$name fingerprint is $got, want $want"
  done
  say "keys ok (omarchy packages $OMARCHY_FPR, asahi-alarm $ASAHI_FPR)"
}

# Read-only facts. Runs in check mode as any user; install mode runs it as root first.
preflight() {
  local compat free_gib model t
  [[ $(uname -m) == aarch64 ]] || die "not aarch64"
  compat=$(tr '\0' ' ' </proc/device-tree/compatible 2>/dev/null || true)
  [[ $compat == *apple,* ]] || die "no Apple device tree (compatible: $compat)"
  model=$(tr -d '\0' </proc/device-tree/model)
  [[ $(uname -r) == *$KERNEL_RE* ]] || die "running kernel $(uname -r) is not the K114c boot kernel"
  mountpoint -q /boot || die "/boot is not a mount point"
  [[ -f /boot/m1n1/boot.bin && -f /boot/m1n1/k114c-Image.gz ]] || die "/boot/m1n1 boot files are missing"
  ! mountpoint -q /boot/efi 2>/dev/null || die "an ESP is mounted at /boot/efi; this script must not run here"
  free_gib=$(df -BG --output=avail / | tail -n 1 | tr -dc 0-9)
  (( free_gib >= 25 )) || die "only ${free_gib} GiB free on /"
  [[ -z $(swapon --show=NAME --noheadings 2>/dev/null | grep -v '^/dev/zram') ]] || die "swap on a disk is active; disable it first"
  say "model: $model"
  say "compatible: $compat"
  say "kernel: $(uname -r), root $(findmnt -no FSTYPE,SOURCE /), ${free_gib} GiB free"
  say "boot.bin sha256: $(sha256sum /boot/m1n1/boot.bin | cut -c1-16)"
  for t in bsdtar gpg curl vercmp sha256sum pacman pacman-key sudo; do command -v "$t" >/dev/null || die "missing tool: $t"; done
  if pacman -Q omarchy >/dev/null 2>&1; then say "omarchy already installed: $(pacman -Q omarchy)"; fi
}

survey() {
  say "sudo -n: $(sudo -n true 2>&1 | head -n 1 || true)"
  say "resolv.conf: $(stat -c '%a %U' /etc/resolv.conf) ($(readlink /etc/resolv.conf || echo file))"
  say "dns as non-root: $(getent hosts pkgs.omarchy.org | head -n 1 || echo FAILS)"
  say "default route: $(ip route show default | head -n 1)"
  say "units: $(systemctl is-enabled sshd systemd-networkd systemd-resolved NetworkManager ufw 2>&1 | tr '\n' ' ')"
  say "users with a home: $(getent passwd | awk -F: '$6 ~ /^\/home\// {print $1}' | tr '\n' ' ')"
  say "repos: $(pacman-conf --repo-list | tr '\n' ' ')"
}

phase_done() { [[ -e $STATE/$1.done ]]; }
phase_mark() { : >"$STATE/$1.done"; }

snapshot_boot() {
  snap=/var/lib/omarchy/backups/m5-$(date +%Y%m%d%H%M%S)
  install -d -m 0700 "$snap"
  cp -a /etc/pacman.conf /etc/pacman.d /etc/systemd/network /etc/fstab "$snap/"
  cp -a /etc/sudoers.d /etc/ssh /etc/resolv.conf "$snap/" 2>/dev/null || true
  systemctl list-unit-files --state=enabled --no-legend >"$snap/enabled-units.txt"
  pacman -Q >"$snap/installed.txt"
  ip -br a >"$snap/ip.txt"
  cat /proc/cmdline >"$snap/cmdline.txt"
  (cd /boot/m1n1 && sha256sum -- * >"$snap/boot-m1n1.sha256")
  ( cd "/home/$owner" && tar -cf "$snap/home-dotfiles.tar" --ignore-failed-read .bashrc .bash_profile .profile .bash_logout .config 2>/dev/null ) || true
  echo "$snap" >"$STATE/snapshot-dir"
  say "snapshot $snap"
}

fix_dns() {
  chmod 0644 /etc/resolv.conf
  if ! runuser -u alpm -- getent hosts pkgs.omarchy.org >/dev/null 2>&1; then
    local gw
    gw=$(ip route show default | awk '{print $3; exit}')
    printf 'nameserver %s\nnameserver 1.1.1.1\n' "$gw" >/etc/resolv.conf
    runuser -u alpm -- getent hosts pkgs.omarchy.org >/dev/null || die "pacman's download user cannot resolve pkgs.omarchy.org"
  fi
  say "dns ok for the pacman download user"
}

# pacman.conf and the mirrorlist come from the runtime's own channel templates, the way
# omarchy-channel-set and the image builder write them. The one addition is IgnorePkg: the kernel
# and boot chain of this Mac are ours, and no upgrade may replace them.
edge_conf() {
  [[ -x /usr/bin/omarchy-apply-pacman ]] || die "no omarchy runtime installed; omarchy-apply-pacman is missing"
  OMARCHY_PATH=/usr/share/omarchy omarchy-apply-pacman edge
  grep -q '^IgnorePkg' /etc/pacman.conf || sed -i "/^\[options\]/a IgnorePkg = $IGNORE" /etc/pacman.conf
  # A database left by an earlier [omarchy] source would pair its old signature with the new database.
  rm -f /var/lib/pacman/sync/omarchy.db /var/lib/pacman/sync/omarchy.db.sig
  import_keys
  say "repos: $(pacman-conf --repo-list | tr '\n' ' ')"
}

import_keys() {
  pacman-key --init
  pacman-key --populate archlinux archlinuxarm
  pacman-key --add "$keys/asahi-alarm.gpg" "$keys/omarchy-pkgs.gpg"
  pacman-key --lsign-key "$ASAHI_FPR"
  pacman-key --lsign-key "$OMARCHY_FPR"
}

# The edge runtime is omarchy-dev and omarchy-settings-dev. They replace the stable pair, and
# --ask 4 lets pacman remove those conflicts. omarchy-mac is the Apple Silicon layer (audio, Wi-Fi,
# notch, sleep key, browser flags). The transaction must not pull a kernel or boot-chain package.
install_core() {
  local -a pkgs=(base-devel sudo xdg-user-dirs jq omarchy-dev omarchy-settings-dev omarchy-mac)
  # The base image ships the Apple Silicon keyring files unowned; the package takes them over.
  pacman -Syu --noconfirm --needed --ask 4 --overwrite '/usr/share/pacman/keyrings/asahi-alarm*' --print-format '%n' -p "${pkgs[@]}" >"$WORK/core-plan.txt" ||
    die "the omarchy-dev transaction does not resolve"
  if grep -E "$DENY" "$WORK/core-plan.txt"; then die "the transaction pulls a kernel or boot-chain package"; fi
  say "core plan: $(wc -l <"$WORK/core-plan.txt") packages"
  pacman -Syu --noconfirm --needed --ask 4 --overwrite '/usr/share/pacman/keyrings/asahi-alarm*' "${pkgs[@]}"
  say "installed: $(pacman -Q omarchy-dev omarchy-settings-dev omarchy-mac | tr '\n' ' ')"
}

# The Apple Silicon package list the runtime ships, as the installer composes it.
# Boot-chain packages are dropped, and so is any name no configured repository carries.
install_manifest() {
  local m
  local -a want=() have=()
  for m in "${MANIFESTS[@]}"; do
    [[ -r /usr/share/omarchy/install/$m.packages ]] || die "the runtime has no package list $m"
    mapfile -t -O "${#want[@]}" want < <(sed 's/#.*//' "/usr/share/omarchy/install/$m.packages" | awk 'NF==1{print $1}')
  done
  ((${#want[@]} > 100)) || die "could not read the runtime package manifest"
  mapfile -t have < <(printf '%s\n' "${want[@]}" | sort -u | comm -12 - <(pacman -Slq | sort -u) | grep -vE "$DENY" |
    comm -23 - <(pacman -Qq | sort -u))
  printf '%s\n' "${want[@]}" | sort -u | comm -23 - <(pacman -Slq | sort -u) >"$WORK/manifest-unavailable.txt"
  say "manifest: ${#want[@]} names, ${#have[@]} installable, $(wc -l <"$WORK/manifest-unavailable.txt") left out (list in $WORK/manifest-unavailable.txt)"
  pacman -Sup --print-format '%n' --needed --noconfirm --ask 4 "${have[@]}" >"$WORK/plan.txt" 2>"$WORK/plan.err" ||
    { cat "$WORK/plan.txt" "$WORK/plan.err" | head -30; die "the manifest transaction does not resolve"; }
  if grep -E "$DENY" "$WORK/plan.txt"; then die "the transaction pulls a kernel or boot-chain package"; fi
  # An installed name is left as it is: the edge repository can carry an older build than the Mac has.
  pacman -S --needed --noconfirm --ask 4 "${have[@]}"
}

# The Apple Silicon first-boot service would randomise the root UUID (this Mac boots m5.root=/dev/nvme0n1p5).
# kernel-modules-hook's cleanup would delete /usr/lib/modules/* that no package owns.
mask_boot_hazards() { systemctl mask first-boot.service linux-modules-cleanup.service; }

apply_system() {
  export OMARCHY_PATH=/usr/share/omarchy OMARCHY_INSTALL=/usr/share/omarchy/install
  getent passwd "$owner" >/dev/null || die "no account $owner"
  # The stock config step enables linux-modules-cleanup, which fails on a masked unit. The trap
  # masks both units again however this run ends.
  systemctl unmask first-boot.service linux-modules-cleanup.service
  trap mask_boot_hazards EXIT
  apply_phases
  reset_home
  local home
  home=$(getent passwd "$owner" | cut -d: -f6)
  runuser -u "$owner" -- env HOME="$home" USER="$owner" LOGNAME="$owner" OMARCHY_PATH=/usr/share/omarchy \
    OMARCHY_INSTALL=/usr/share/omarchy/install OMARCHY_SETUP_CONTEXT=provision-owner \
    OMARCHY_INSTALL_LOG_FILE=/var/log/omarchy-install.log OMARCHY_LOG_TO_STDOUT=1 \
    PATH="/usr/share/omarchy/bin:/usr/local/sbin:/usr/local/bin:/usr/bin" omarchy-provision-user --force --first-install
}

# omarchy-apply-system and omarchy-apply-hardware step for step, minus the two steps that own the boot
# chain or need a btrfs root:
#   config/snapper.sh          makes a btrfs snapper config and enables limine-snapper-sync (this Mac: ext4, no Limine)
#   hardware/platform-setup.sh runs setup-boot from omarchy-mac-boot, which writes the Limine boot chain
# Its setup-system half, from omarchy-mac, runs below. The kernel image and initramfs are not built
# here either; they live in /boot/m1n1.
apply_phases() {
  (
    export OMARCHY_INSTALL_USER=$owner OMARCHY_FIRST_INSTALL=1 OMARCHY_UPGRADE=0
    export OMARCHY_INSTALL_LOG_FILE=/var/log/omarchy-install.log PATH="$OMARCHY_PATH/bin:$PATH"
    # shellcheck disable=SC1091
    source "$OMARCHY_INSTALL/helpers/logging.sh"
    eval "stock_$(declare -f run_logged)"
    run_logged() {
      case $1 in
        */config/snapper.sh | */hardware/platform-setup.sh) say "skipped $1 (boot chain or btrfs only)"; return 0 ;;
      esac
      stock_run_logged "$@"
    }
    start_install_log
    # shellcheck disable=SC1091
    source "$OMARCHY_INSTALL/config/all.sh"
    # shellcheck disable=SC1091
    source "$OMARCHY_INSTALL/hardware/all.sh"
    omarchy-lifecycle-dispatch setup-system
    # shellcheck disable=SC1091
    source "$OMARCHY_INSTALL/login/all.sh"
    # shellcheck disable=SC1091
    source "$OMARCHY_INSTALL/post-install/all.sh"
    stop_install_log
  )
}

# Fresh account state for the edge runtime. omarchy-provision-owner makes the owner with `useradd -m`
# (a copy of /etc/skel) and then runs omarchy-provision-user. The owner here exists already and holds
# an earlier Omarchy's files, so they move to $WORK/home-before-edge (a rename, nothing is deleted) and
# /etc/skel is copied in, which is what useradd -m does. omarchy-provision-first-run then finishes the
# user at the first login.
reset_home() {
  local home keep=$WORK/home-before-edge item
  home=$(getent passwd "$owner" | cut -d: -f6)
  [[ ! -e $keep/.moved ]] || return 0
  install -d -m 0700 "$keep/.local/state" "$keep/.local/share"
  for item in .bashrc .bash_profile .profile .config .local/state/omarchy .local/share/omarchy; do
    [[ ! -e $home/$item ]] || mv "$home/$item" "$keep/$item"
  done
  : >"$keep/.moved"
  runuser -u "$owner" -- cp -a /etc/skel/. "$home/"
}

# What this one Mac needs that a normal Omarchy install would break.
m5_guards() {
  local unit
  # Ethernet stays with systemd-networkd (reachability over ssh); NetworkManager keeps Wi-Fi.
  for unit in systemd-networkd.service systemd-networkd.socket systemd-networkd-varlink.socket systemd-networkd-varlink-metrics.socket systemd-networkd-resolve-hook.socket; do
    systemctl enable "$unit" 2>/dev/null || true
  done
  # Omarchy's network step stops networkd when NetworkManager runs; ssh rides on it.
  systemctl start systemd-networkd.service
  install -Dm644 /dev/stdin /etc/NetworkManager/conf.d/90-m5-ethernet-networkd.conf <<'EOF'
[keyfile]
unmanaged-devices=interface-name:en*
EOF
  # post-install/pacman.sh restores /etc/pacman.conf from the channel template; keep the boot-chain
  # packages out of every later upgrade.
  grep -q '^IgnorePkg' /etc/pacman.conf || sed -i "/^\[options\]/a IgnorePkg = $IGNORE" /etc/pacman.conf
  # ufw denies incoming by default and starts at boot; keep ssh open. The rule is stored even when
  # the live reload fails because ufw is not running yet, so the exit code is not the check.
  ufw allow 22/tcp >/dev/null 2>&1 || true
  # Same seed as the Omarchy Mac installer: the Omarchy greeter passes the remembered user to PAM,
  # and state.conf is empty on a fresh install, so every password fails as "user unknown".
  install -d -m 0755 -o sddm -g sddm /var/lib/sddm
  printf '[Last]\nSession=omarchy.desktop\nUser=%s\n' "$owner" >/var/lib/sddm/state.conf
  chown sddm:sddm /var/lib/sddm /var/lib/sddm/state.conf
  mask_boot_hazards
  systemctl enable sshd.service
  if [[ ${M5_HAD_NOPASSWD:-0} == 1 ]]; then
    install -Dm440 /dev/stdin /etc/sudoers.d/90-m5-lab-nopasswd <<'EOF'
%wheel ALL=(ALL:ALL) NOPASSWD: ALL
EOF
    visudo -cf /etc/sudoers.d/90-m5-lab-nopasswd >/dev/null || { rm -f /etc/sudoers.d/90-m5-lab-nopasswd; die "sudoers drop-in is invalid"; }
  fi
  ln -sfn /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
}

verify_result() {
  local snap bad=0
  snap=$(<"$STATE/snapshot-dir")
  (cd /boot/m1n1 && sha256sum --check --quiet "$WORK/run-boot.sha256") || { say "BOOT FILES CHANGED since this run started"; bad=1; }
  [[ $(cat /proc/cmdline) == "$(cat "$WORK/run-cmdline.txt")" ]] || { say "cmdline changed"; bad=1; }
  if pacman -Qq | grep -E "$DENY"; then say "a boot-chain package is installed"; bad=1; fi
  [[ ! -e /var/lib/omarchy/limine.enabled && ! -e /boot/efi/limine.conf ]] || { say "Limine gate present"; bad=1; }
  pacman -Q omarchy-dev omarchy-settings-dev omarchy-mac networkmanager iwd >/dev/null || bad=1
  [[ $(OMARCHY_PATH=/usr/share/omarchy omarchy-channel-current) == edge ]] || { say "omarchy-channel-current is not edge"; bad=1; }
  systemctl is-enabled sshd systemd-networkd >/dev/null || { say "sshd or networkd not enabled"; bad=1; }
  grep -q '22' /etc/ufw/user.rules 2>/dev/null || { say "ufw has no ssh rule"; bad=1; }
  sshd -t || bad=1
  ip -4 -br a show enu1 | grep -q 'UP .*[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+/' || { say "enu1 lost its address"; bad=1; }
  say "systemd-networkd active: $(systemctl is-active systemd-networkd)"
  (( bad == 0 )) || die "verification failed; do not reboot. Snapshot: $snap"
  say "DONE: $(pacman -Q omarchy-dev omarchy-settings-dev omarchy-mac | tr '\n' ' ')"
  say "boot files, kernel and cmdline are unchanged. Reboot is optional; the Mac keeps its ssh path."
}

case ${1:-} in
  check)
    say "check mode: read-only"
    check_keys
    preflight
    survey
    ;;
  install)
    if (( EUID != 0 )); then
      sudo -n true 2>/dev/null || die "sudo needs a password; run again once sudo works without one"
      exec sudo -n env M5_HAD_NOPASSWD=1 M5_USER="$owner" M5_KEYS_DIR="$keys" bash "$0" install
    fi
    if [[ -z ${M5_HAD_NOPASSWD:-} ]]; then
      M5_HAD_NOPASSWD=0
      sudo -l -U "$owner" 2>/dev/null | grep -q NOPASSWD && M5_HAD_NOPASSWD=1
    fi
    install -d -m 0755 "$WORK" "$STATE"
    exec > >(tee -a /var/log/m5-omarchy-install.log) 2>&1
    say "install start; log /var/log/m5-omarchy-install.log"
    check_keys
    preflight
    (cd /boot/m1n1 && sha256sum -- * >"$WORK/run-boot.sha256")
    cat /proc/cmdline >"$WORK/run-cmdline.txt"
    survey
    phase_done snapshot || { snapshot_boot; phase_mark snapshot; }
    fix_dns
    phase_done official-conf || { edge_conf; phase_mark official-conf; }
    phase_done official-core || { install_core; phase_mark official-core; }
    phase_done official-manifest || { install_manifest; phase_mark official-manifest; }
    phase_done official-apply || { apply_system; phase_mark official-apply; }
    m5_guards
    verify_result
    ;;
  *)
    sed -n '2,15p' "$0"
    exit 2
    ;;
esac
