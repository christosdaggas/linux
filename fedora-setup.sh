#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s extglob

# ============================================================
# Fedora 44 / GNOME 50 Interactive Workstation Setup
# Revised for DNF5, GNOME 50, fwupd, Nerd Fonts, ROCm, TPM2/LUKS2, and extensions.
# Includes GNOME Software repo_gpgcheck=1 workaround for Fedora 44.
# ============================================================

# -------------------- UI / HELPERS --------------------------
info(){ echo -e "\e[36m[INFO]\e[0m $*"; }
warn(){ echo -e "\e[33m[WARN]\e[0m $*"; }
error(){ echo -e "\e[31m[ERROR]\e[0m $*"; }

on_error(){
  local line="$1" cmd="$2"
  error "Command failed at line ${line}: ${cmd}"
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

ask_user(){
  local p="$1" r
  while true; do
    read -rp "$(echo -e "\e[44m\e[1m$p [y/n]:\e[0m ")" r
    case "$r" in
      [Yy]) return 0 ;;
      [Nn]) return 1 ;;
      *) echo "y/n only" ;;
    esac
  done
}

pause(){ read -n1 -s -rp "Press any key to continue..."; echo; }

backup_file(){
  [[ -f "$1" ]] || return 0
  sudo cp -a "$1" "$1.bak.$(date +%F_%H-%M-%S)"
}

real_user(){ printf '%s\n' "${SUDO_USER:-${USER:-$(id -un)}}"; }
real_home(){ getent passwd "$(real_user)" | cut -d: -f6; }
require_fedora(){
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    if [[ "${ID:-}" != "fedora" ]]; then
      warn "This script is intended for Fedora. Detected: ${PRETTY_NAME:-unknown}."
      ask_user "Continue anyway?" || exit 1
    fi
    if [[ "${VERSION_ID:-}" != "44" ]]; then
      warn "This script is tuned for Fedora 44. Detected: ${PRETTY_NAME:-unknown}."
      ask_user "Continue anyway?" || exit 1
    fi
  fi
}

install_if_missing(){
  (( $# > 0 )) || return 0
  local pkg missing=()
  for pkg in "$@"; do
    rpm -q "$pkg" &>/dev/null || missing+=("$pkg")
  done
  (( ${#missing[@]} == 0 )) && return 0

  info "Installing: ${missing[*]}"
  if ! sudo dnf -y install "${missing[@]}"; then
    warn "Bulk install failed. Retrying packages one by one so the script can continue."
    for pkg in "${missing[@]}"; do
      sudo dnf -y install "$pkg" || warn "Skipped unavailable or failed package: $pkg"
    done
  fi
}

remove_if_installed(){
  (( $# > 0 )) || return 0
  local pkg installed=()
  for pkg in "$@"; do
    rpm -q "$pkg" &>/dev/null && installed+=("$pkg")
  done
  (( ${#installed[@]} == 0 )) && return 0
  info "Removing: ${installed[*]}"
  sudo dnf -y remove "${installed[@]}" || warn "Some packages could not be removed."
}

safe_gsettings_set(){
  local schema="$1" key="$2" value="$3"
  command -v gsettings &>/dev/null || return 0
  if ! gsettings writable "$schema" "$key" &>/dev/null; then
    warn "Skipping unavailable or non-writable gsetting: $schema $key"
    return 0
  fi
  gsettings set "$schema" "$key" "$value" || warn "Failed gsetting: $schema $key"
}

show_package_group(){
  local title="$1" description="$2"
  shift 2
  echo
  info "$title"
  echo "  $description"
  echo "  Packages: $*"
}

set_dnf_main_option(){
  local key="$1" value="$2" file="/etc/dnf/dnf.conf"
  sudo touch "$file"
  if ! sudo grep -q '^\[main\]' "$file"; then
    sudo sed -i '1i[main]' "$file"
  fi
  if sudo grep -qE "^${key}[[:space:]]*=" "$file"; then
    sudo sed -i -E "s|^${key}[[:space:]]*=.*|${key}=${value}|" "$file"
  else
    echo "${key}=${value}" | sudo tee -a "$file" >/dev/null
  fi
}

add_repo_from_url(){
  local url="$1" fallback_file="$2"
  install_if_missing dnf5-plugins curl
  if sudo dnf config-manager addrepo --from-repofile="$url"; then
    return 0
  fi
  warn "dnf config-manager failed; falling back to writing $fallback_file directly."
  sudo curl -fsSL --retry 3 --connect-timeout 20 -o "$fallback_file" "$url"
}

set_repo_gpgcheck_zero(){
  local repo="$1"
  install_if_missing dnf5-plugins
  if sudo dnf config-manager setopt "${repo}.repo_gpgcheck=0"; then
    info "Set ${repo}.repo_gpgcheck=0"
  else
    warn "Could not set ${repo}.repo_gpgcheck=0. The repo may not exist yet."
  fi
}

list_repo_gpgcheck_one(){
  sudo awk '
    BEGIN { repo="" }
    /^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
      repo=$0
      gsub(/^[[:space:]]*\[/, "", repo)
      gsub(/\][[:space:]]*$/, "", repo)
    }
    /^[[:space:]]*repo_gpgcheck[[:space:]]*=[[:space:]]*1[[:space:]]*$/ && repo != "" {
      print repo
    }
  ' /etc/yum.repos.d/*.repo 2>/dev/null | sort -u
}

apply_repo_gpgcheck_workaround(){
  # Fedora 44 / DNF5 daemon bug workaround:
  # GNOME Software can hang when a repo has repo_gpgcheck=1.
  # Keep package gpgcheck=1, but disable repository metadata GPG verification
  # only for repos that currently set repo_gpgcheck=1.
  local repos=() repo
  install_if_missing dnf5-plugins

  mapfile -t repos < <(list_repo_gpgcheck_one || true)

  if (( ${#repos[@]} == 0 )); then
    info "No repo files with repo_gpgcheck=1 were found in /etc/yum.repos.d."
    return 0
  fi

  warn "Found repositories with repo_gpgcheck=1: ${repos[*]}"
  for repo in "${repos[@]}"; do
    set_repo_gpgcheck_zero "$repo"
  done

  info "Verification command: grep -r 'repo_gpgcheck=1' /etc/yum.repos.d/"
  warn "Revert later, after the Fedora/DNF5 bug is fixed, with: sudo dnf config-manager unsetopt REPOID.repo_gpgcheck"
}

ensure_rpmfusion(){
  rpm -q rpmfusion-free-release rpmfusion-nonfree-release &>/dev/null && return 0
  sudo dnf -y install \
    "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm" \
    "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm"
}

has_gnome_shell(){ command -v gnome-shell &>/dev/null; }

GNOME_MAJOR(){
  local raw major
  raw="$(gnome-shell --version 2>/dev/null || true)"
  major="$(awk '{print $3}' <<<"$raw" | cut -d. -f1)"
  [[ "$major" =~ ^[0-9]+$ ]] || major="50"
  printf '%s\n' "$major"
}

enable_gnome_extension(){
  local uuid="$1"
  command -v gnome-extensions &>/dev/null || { warn "gnome-extensions command not found."; return 0; }
  if gnome-extensions list 2>/dev/null | grep -Fxq "$uuid"; then
    gnome-extensions enable "$uuid" || warn "Could not enable $uuid now. Log out/in, then enable it in Extensions."
  else
    warn "$uuid is installed but not visible to the current GNOME Shell session yet. Log out/in, then enable it in Extensions."
  fi
}

install_ego_extension(){
  local id="$1" uuid="$2" name="$3"
  local major versions=() ver info_json download_url zip extdir

  install_if_missing curl jq unzip glib2 gnome-extensions-app
  major="$(GNOME_MAJOR)"
  versions=("$major" "$((major-1))" "$((major-2))" 50 49 48)

  download_url=""
  for ver in "${versions[@]}"; do
    [[ "$ver" =~ ^[0-9]+$ ]] || continue
    (( ver > 0 )) || continue
    info_json="$(curl -fsSL --retry 3 --connect-timeout 20 \
      "https://extensions.gnome.org/extension-info/?pk=${id}&shell_version=${ver}" || true)"
    download_url="$(jq -r '.download_url // empty' <<<"$info_json" 2>/dev/null || true)"
    if [[ -n "$download_url" && "$download_url" != "null" ]]; then
      info "Found $name release for GNOME Shell $ver"
      break
    fi
  done

  if [[ -z "$download_url" || "$download_url" == "null" ]]; then
    warn "No compatible extensions.gnome.org release found for $name on GNOME Shell $major. Skipping."
    return 0
  fi

  zip="$(mktemp --suffix=.zip)"
  curl -fsSL --retry 3 --connect-timeout 20 -o "$zip" "https://extensions.gnome.org${download_url}"

  if ! gnome-extensions install --force "$zip"; then
    warn "gnome-extensions install failed for $name; trying manual user install."
    extdir="$(real_home)/.local/share/gnome-shell/extensions/${uuid}"
    rm -rf "$extdir"
    mkdir -p "$extdir"
    unzip -oq "$zip" -d "$extdir"
    [[ -d "$extdir/schemas" ]] && glib-compile-schemas "$extdir/schemas" || true
  fi
  rm -f "$zip"

  [[ -d "$(real_home)/.local/share/gnome-shell/extensions/${uuid}/schemas" ]] && \
    glib-compile-schemas "$(real_home)/.local/share/gnome-shell/extensions/${uuid}/schemas" || true

  enable_gnome_extension "$uuid"
}

install_meslo_nerd_fonts(){
  install_if_missing curl fontconfig
  local dest base font encoded failed=0
  dest="$(real_home)/.local/share/fonts/MesloLGS-NF"
  base="https://github.com/romkatv/powerlevel10k-media/raw/master"
  mkdir -p "$dest"

  local fonts=(
    "MesloLGS NF Regular.ttf"
    "MesloLGS NF Bold.ttf"
    "MesloLGS NF Italic.ttf"
    "MesloLGS NF Bold Italic.ttf"
  )

  for font in "${fonts[@]}"; do
    encoded="${font// /%20}"
    info "Downloading $font"
    if ! curl -fL --retry 3 --connect-timeout 20 -o "$dest/$font" "$base/$encoded"; then
      warn "Failed to download $font"
      failed=1
    fi
  done

  fc-cache -f "$dest" || true
  (( failed == 0 )) && info "MesloLGS Nerd Fonts installed in $dest" || warn "Some MesloLGS files failed to download."
}

install_virtualization_stack(){
  info "Installing Fedora KVM/QEMU/libvirt virtualization stack..."

  if grep -Eq '(vmx|svm)' /proc/cpuinfo 2>/dev/null; then
    info "CPU virtualization extensions detected."
  else
    warn "CPU virtualization extensions were not detected. Enable Intel VT-x or AMD-V/SVM in firmware/BIOS if VMs do not start."
  fi

  # Fedora's documented host setup is the virtualization package group.
  # Keep explicit packages as a fallback/extension so virt-manager and common VM features are always covered.
  if ! sudo dnf -y install @virtualization; then
    warn "The @virtualization group install failed or is unavailable. Installing explicit KVM/libvirt packages instead."
  fi

  install_if_missing \
    virt-manager virt-install virt-viewer \
    qemu-kvm qemu-img \
    libvirt-client libvirt-daemon-kvm libvirt-daemon-config-network libvirt-daemon-driver-qemu \
    edk2-ovmf swtpm swtpm-tools \
    libosinfo osinfo-db-tools \
    guestfs-tools libguestfs \
    virt-top virt-what bridge-utils dnsmasq passt

  # Fedora uses libvirt modular daemons by default. Enable sockets where present.
  local enabled_modular=0 unit
  for unit in \
    virtqemud.socket \
    virtnetworkd.socket \
    virtstoraged.socket \
    virtsecretd.socket \
    virtnodedevd.socket \
    virtinterfaced.socket \
    virtnwfilterd.socket \
    virtproxyd.socket; do
    if systemctl list-unit-files "$unit" --no-legend 2>/dev/null | awk '{print $1}' | grep -Fxq "$unit"; then
      sudo systemctl enable --now "$unit" || warn "Could not enable $unit"
      enabled_modular=1
    fi
  done

  # Fallback for systems that still provide monolithic libvirtd instead of modular daemons.
  if (( enabled_modular == 0 )) && \
     systemctl list-unit-files libvirtd.service --no-legend 2>/dev/null | awk '{print $1}' | grep -Fxq 'libvirtd.service'; then
    sudo systemctl enable --now libvirtd.service || warn "Could not enable libvirtd.service"
  fi

  # Allow the real desktop user to manage local VMs without running virt-manager as root.
  sudo getent group libvirt >/dev/null && sudo usermod -aG libvirt "$(real_user)" || true
  sudo getent group kvm >/dev/null && sudo usermod -aG kvm "$(real_user)" || true

  # Make the default NAT network available immediately when libvirt created it.
  if command -v virsh &>/dev/null; then
    if sudo virsh net-info default &>/dev/null; then
      sudo virsh net-autostart default || true
      sudo virsh net-start default || true
    else
      warn "Libvirt default network was not found. virt-manager can create one from Edit → Connection Details → Virtual Networks."
    fi
  fi

  info "Virtualization stack installed. Log out/in or reboot before using libvirt group permissions."
}

install_rocm_stack(){
  info "Installing Fedora ROCm stack for AMD GPU compute..."
  install_if_missing pciutils rocm rocminfo

  if command -v lspci &>/dev/null; then
    local gpu_lines
    gpu_lines="$(lspci -nn | grep -Ei 'VGA|3D|Display' || true)"
    if grep -Eiq 'AMD|ATI' <<<"$gpu_lines"; then
      info "AMD graphics hardware detected."
    else
      warn "No AMD GPU was detected by lspci. ROCm may install, but GPU compute may not work on this hardware."
    fi
  fi

  sudo getent group render >/dev/null && sudo usermod -aG render "$(real_user)" || true
  sudo getent group video  >/dev/null && sudo usermod -aG video  "$(real_user)" || true

  if ask_user "Install ROCm development packages too (rocm-devel)?"; then
    install_if_missing rocm-devel
  fi

  info "ROCm installed. Log out/in or reboot so render/video group membership applies."
  info "After reboot, test with: rocminfo"
}


update_crypttab_for_tpm2(){
  local uuid="$1" pcrs="$2" file="/etc/crypttab" tmp
  local opt="tpm2-device=auto,tpm2-pcrs=${pcrs}"

  if [[ ! -f "$file" ]]; then
    warn "$file does not exist. Cannot automatically update initramfs unlock configuration."
    warn "Add this option manually to the matching crypttab line: $opt"
    return 1
  fi

  backup_file "$file"
  tmp="$(mktemp)"

  if ! awk -v uuid="$uuid" -v opt="$opt" '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { print; next }
    {
      if ($1 == "luks-" uuid || $2 == "UUID=" uuid || $2 == "/dev/disk/by-uuid/" uuid || index($0, uuid) > 0) {
        found=1
        if (NF < 3) {
          print
          next
        }
        if (NF == 3) {
          print $1, $2, $3, opt
          changed=1
          next
        }
        if ($4 ~ /(^|,)tpm2-device=auto(,|$)/) {
          print
          next
        }
        if ($4 == "-" || $4 == "none") {
          $4=opt
        } else {
          $4=$4 "," opt
        }
        print $1, $2, $3, $4
        changed=1
        next
      }
      print
    }
    END { if (!found) exit 2 }
  ' "$file" > "$tmp"; then
    rm -f "$tmp"
    warn "Could not find a matching /etc/crypttab line for UUID=$uuid."
    warn "Add this option manually to the matching crypttab line, then run: sudo dracut -f"
    warn "$opt"
    return 1
  fi

  sudo cp "$tmp" "$file"
  rm -f "$tmp"
  info "Updated $file for TPM2 auto-unlock."
}

enable_luks2_tpm2_unlock(){
  warn "This adds TPM2 as an alternative LUKS2 unlock method. Keep your passphrase slot as fallback."
  warn "If firmware, Secure Boot, bootloader, kernel, initramfs, or PCR policy changes, TPM2 unlock may fail and you will need the passphrase."

  install_if_missing cryptsetup dracut tpm2-tools

  if ! command -v systemd-cryptenroll &>/dev/null; then
    error "systemd-cryptenroll was not found. Install/repair systemd first."
    return 1
  fi

  info "Detected TPM2 devices:"
  if ! systemd-cryptenroll --tpm2-device=list; then
    warn "No usable TPM2 device was detected. Enable TPM2/fTPM/PTT in firmware/UEFI, then try again."
    return 1
  fi

  info "Detected LUKS devices:"
  mapfile -t LUKS_DEVS < <(blkid -t TYPE=crypto_LUKS -o device | sort -u)
  if (( ${#LUKS_DEVS[@]} == 0 )); then
    error "No LUKS devices were found."
    return 1
  fi

  local i=1 dev selected version uuid pcrs
  for dev in "${LUKS_DEVS[@]}"; do
    uuid="$(blkid -s UUID -o value "$dev" 2>/dev/null || true)"
    version="$(sudo cryptsetup luksDump "$dev" 2>/dev/null | awk '/Version:/ {print $2; exit}')"
    echo "[$i] $dev UUID=${uuid:-unknown} LUKS${version:-unknown}"
    i=$((i+1))
  done

  while true; do
    read -rp "Select LUKS device number for TPM2 enrollment: " i
    if [[ "$i" =~ ^[0-9]+$ ]] && (( i >= 1 && i <= ${#LUKS_DEVS[@]} )); then
      selected="${LUKS_DEVS[$((i-1))]}"
      break
    fi
    warn "Invalid selection. Try again."
  done

  version="$(sudo cryptsetup luksDump "$selected" 2>/dev/null | awk '/Version:/ {print $2; exit}')"
  if [[ "$version" != "2" ]]; then
    error "$selected is not LUKS2. systemd-cryptenroll TPM2 enrollment requires LUKS2."
    return 1
  fi

  uuid="$(blkid -s UUID -o value "$selected")"
  [[ -n "$uuid" ]] || { error "Could not read UUID for $selected"; return 1; }

  echo "Choose TPM2 PCR policy:"
  echo "  [1] PCR 7 only: practical for Fedora desktops; usually survives kernel/initramfs updates if Secure Boot policy is stable."
  echo "  [2] Fedora Magazine strict example: 0+1+2+3+4+5+7+9; more tamper-sensitive, but may require re-enrollment after updates/firmware changes."
  echo "  [3] Custom PCR list, e.g. 7 or 0+1+2+3+4+5+7+9"
  read -rp "Choice [1]: " pcr_choice
  case "${pcr_choice:-1}" in
    1) pcrs="7" ;;
    2) pcrs="0+1+2+3+4+5+7+9" ;;
    3)
      while true; do
        read -rp "Enter PCR list: " pcrs
        [[ "$pcrs" =~ ^[0-9]+(\+[0-9]+)*$ ]] && break
        warn "Invalid PCR list. Use a format like: 7 or 0+1+2+3+4+5+7+9"
      done
      ;;
    *) pcrs="7" ;;
  esac

  warn "About to enroll TPM2 unlock for $selected using PCRs: $pcrs"
  warn "You will be asked for the existing LUKS passphrase."
  ask_user "Continue with TPM2 enrollment?" || return 0

  sudo mkdir -p /etc/dracut.conf.d
  echo 'add_dracutmodules+=" tpm2-tss "' | sudo tee /etc/dracut.conf.d/tpm2.conf >/dev/null

  sudo systemd-cryptenroll --wipe-slot=tpm2 --tpm2-device=auto --tpm2-pcrs="$pcrs" "$selected"

  if update_crypttab_for_tpm2 "$uuid" "$pcrs"; then
    info "Rebuilding current initramfs with dracut..."
    sudo dracut -f
    info "TPM2 LUKS2 auto-unlock configured for $selected. Reboot to test."
    warn "Do not remove your LUKS passphrase. It is your recovery path if TPM2 unlock fails."
  else
    warn "TPM2 enrollment completed, but crypttab was not updated automatically. Initramfs was not rebuilt."
  fi
}

run_firmware_updates(){
  install_if_missing fwupd
  sudo systemctl start fwupd.service 2>/dev/null || true

  info "Detected fwupd devices:"
  fwupdmgr get-devices || warn "fwupdmgr could not list devices. Firmware may not be supported on this hardware."

  info "Configured fwupd remotes:"
  fwupdmgr get-remotes || true

  if ask_user "Enable LVFS firmware remote if available?"; then
    sudo fwupdmgr enable-remote lvfs || warn "Could not enable LVFS remote; it may already be enabled or unavailable."
  fi

  info "Refreshing firmware metadata with --force..."
  if ! sudo fwupdmgr refresh --force; then
    warn "Firmware metadata refresh failed. Common causes: disabled LVFS, unsupported hardware, network/DNS issue, or vendor firmware not published to LVFS."
    return 0
  fi

  info "Checking firmware updates..."
  if ! fwupdmgr get-updates; then
    warn "No firmware updates were found, or this hardware is not supported by LVFS. This is not fatal."
    return 0
  fi

  if ask_user "Apply available firmware updates now? This can stage updates for next reboot"; then
    sudo fwupdmgr update || warn "Firmware update failed or was cancelled. Check fwupdmgr get-history after reboot."
  fi
}

setup_secondary_disk(){
  info "Starting Disk Setup..."
  install_if_missing util-linux parted

  local USERNAME USERID GROUPID
  USERNAME="$(real_user)"
  USERID="$(id -u "$USERNAME")"
  GROUPID="$(id -g "$USERNAME")"

  echo "=== Available Disks ==="
  mapfile -t DISKS < <(lsblk -dpno NAME,TYPE | awk '$2=="disk"{print $1}')
  if (( ${#DISKS[@]} == 0 )); then
    error "No disks found."
    return 1
  fi

  local i=1 DISK SIZE
  for DISK in "${DISKS[@]}"; do
    SIZE="$(lsblk -dnbo SIZE "$DISK" | numfmt --to=iec-i --suffix=B)"
    echo "[$i] $DISK ($SIZE)"
    i=$((i+1))
  done

  local DISK_NUMBER SELECTED_DISK
  while true; do
    read -rp "Select disk number: " DISK_NUMBER
    if [[ "$DISK_NUMBER" =~ ^[0-9]+$ ]] && (( DISK_NUMBER >= 1 && DISK_NUMBER <= ${#DISKS[@]} )); then
      SELECTED_DISK="${DISKS[$((DISK_NUMBER-1))]}"
      break
    fi
    warn "Invalid selection. Try again."
  done

  echo "=== Partitions on $SELECTED_DISK ==="
  mapfile -t PART_INFO < <(
    lsblk -nrpo NAME,SIZE,FSTYPE,MOUNTPOINT,TYPE "$SELECTED_DISK" |
    awk '$5=="part"{print $1 "|" $2 "|" $3 "|" $4}'
  )

  if (( ${#PART_INFO[@]} == 0 )); then
    warn "No partitions found on $SELECTED_DISK."
    if ! ask_user "Create a new partition on $SELECTED_DISK? THIS WILL ERASE DATA"; then
      warn "Partition creation skipped."
      return 1
    fi

    echo "Choose filesystem for the new partition:"
    select FS_CHOICE in ext4 xfs btrfs ntfs; do
      case "$FS_CHOICE" in
        ext4|xfs|btrfs|ntfs) break ;;
        *) echo "Invalid choice" ;;
      esac
    done

    case "$FS_CHOICE" in
      xfs) install_if_missing xfsprogs ;;
      btrfs) install_if_missing btrfs-progs ;;
      ntfs) install_if_missing ntfsprogs ntfs-3g ;;
    esac

    info "Creating GPT partition table on $SELECTED_DISK"
    sudo parted -s "$SELECTED_DISK" mklabel gpt
    sudo parted -s "$SELECTED_DISK" mkpart primary 1MiB 100%
    sudo partprobe "$SELECTED_DISK" || true
    sleep 2

    PARTITION="$(lsblk -nrpo NAME,TYPE "$SELECTED_DISK" | awk '$2=="part"{print $1; exit}')"
    [[ -n "${PARTITION:-}" ]] || { error "Could not detect new partition."; return 1; }

    info "Formatting $PARTITION as $FS_CHOICE"
    case "$FS_CHOICE" in
      ext4) sudo mkfs.ext4 -F "$PARTITION" ;;
      xfs) sudo mkfs.xfs -f "$PARTITION" ;;
      btrfs) sudo mkfs.btrfs -f "$PARTITION" ;;
      ntfs) sudo mkfs.ntfs -f "$PARTITION" ;;
    esac

    mapfile -t PART_INFO < <(
      lsblk -nrpo NAME,SIZE,FSTYPE,MOUNTPOINT,TYPE "$SELECTED_DISK" |
      awk '$5=="part"{print $1 "|" $2 "|" $3 "|" $4}'
    )
  fi

  i=1
  local LINE PNAME PSIZE PFSTYPE PMOUNT
  for LINE in "${PART_INFO[@]}"; do
    IFS="|" read -r PNAME PSIZE PFSTYPE PMOUNT <<< "$LINE"
    [[ -z "$PFSTYPE" ]] && PFSTYPE="unknown"
    [[ -z "$PMOUNT" ]] && PMOUNT="-"
    echo "[$i] $PNAME ($PSIZE) fstype=$PFSTYPE mount=$PMOUNT"
    i=$((i+1))
  done

  local PART_NUMBER PARTITION
  while true; do
    read -rp "Select partition number: " PART_NUMBER
    if [[ "$PART_NUMBER" =~ ^[0-9]+$ ]] && (( PART_NUMBER >= 1 && PART_NUMBER <= ${#PART_INFO[@]} )); then
      IFS="|" read -r PARTITION _ <<< "${PART_INFO[$((PART_NUMBER-1))]}"
      break
    fi
    warn "Invalid selection. Try again."
  done

  if findmnt -rn --source "$PARTITION" >/dev/null 2>&1; then
    warn "Partition already mounted."
    return 0
  fi

  if sudo blkid "$PARTITION" | grep -iq bitlocker; then
    warn "BitLocker detected."
    install_if_missing dislocker fuse-dislocker fuse fuse-libs
    sudo mkdir -p /mnt/bitlocker /mnt/data
    read -rsp "Enter BitLocker password: " BL_PASS
    echo
    sudo dislocker -V "$PARTITION" -u"$BL_PASS" -- /mnt/bitlocker
    sudo mount -o loop,uid="$USERID",gid="$GROUPID" /mnt/bitlocker/dislocker-file /mnt/data
    info "Mounted BitLocker volume at /mnt/data"
    return 0
  fi

  local FS_TYPE UUID MOUNT_NAME MOUNT_DIR OPTS FSTAB_TYPE
  FS_TYPE="$(blkid -s TYPE -o value "$PARTITION")"
  UUID="$(blkid -s UUID -o value "$PARTITION")"
  [[ -n "$UUID" ]] || { error "No UUID found for $PARTITION"; return 1; }

  read -rp "Enter mount folder name (e.g. storage): " MOUNT_NAME
  MOUNT_NAME="$(echo "$MOUNT_NAME" | tr -cd '[:alnum:]_.-')"
  [[ -n "$MOUNT_NAME" ]] || { error "Invalid mount name."; return 1; }
  MOUNT_DIR="/mnt/$MOUNT_NAME"
  sudo mkdir -p "$MOUNT_DIR"

  case "$FS_TYPE" in
    ntfs)
      FSTAB_TYPE="ntfs3"
      OPTS="defaults,uid=$USERID,gid=$GROUPID,umask=000,nofail,x-systemd.device-timeout=10s"
      ;;
    vfat|fat|exfat)
      FSTAB_TYPE="$FS_TYPE"
      OPTS="defaults,uid=$USERID,gid=$GROUPID,umask=000,nofail,x-systemd.device-timeout=10s"
      ;;
    btrfs)
      FSTAB_TYPE="btrfs"
      OPTS="defaults,compress=zstd:1,nofail,x-systemd.device-timeout=10s"
      ;;
    *)
      FSTAB_TYPE="$FS_TYPE"
      OPTS="defaults,nofail,x-systemd.device-timeout=10s"
      ;;
  esac

  if ! sudo grep -q "UUID=$UUID" /etc/fstab; then
    echo "UUID=$UUID $MOUNT_DIR $FSTAB_TYPE $OPTS 0 2" | sudo tee -a /etc/fstab >/dev/null
  else
    warn "An fstab entry for UUID=$UUID already exists."
  fi

  sudo mount -a
  info "Disk mounted at $MOUNT_DIR"
}

# -------------------- PRIVILEGES ----------------------------
clear
info "Fedora 44 / GNOME 50 Interactive Workstation Setup"
pause
require_fedora
sudo -v
while true; do sudo -v; sleep 60; done & SUDO_PID=$!
trap 'kill "$SUDO_PID" 2>/dev/null || true' EXIT

# -------------------- BASIC SYSTEM --------------------------
if ask_user "Optimize DNF5 configuration?"; then
  backup_file /etc/dnf/dnf.conf
  set_dnf_main_option max_parallel_downloads 10
  set_dnf_main_option fastestmirror False
  set_dnf_main_option keepcache True
  set_dnf_main_option installonly_limit 3
  info "DNF configuration updated."
fi

if ask_user "Enable periodic SSD TRIM (fstrim.timer)?"; then
  sudo systemctl enable --now fstrim.timer
fi

if ask_user "Change hostname?"; then
  read -rp "New hostname: " H
  [[ -n "$H" ]] && sudo hostnamectl set-hostname "$H" || warn "Empty hostname skipped."
fi

if ask_user "Add Greek keyboard (GNOME user-level)?"; then
  safe_gsettings_set org.gnome.desktop.input-sources sources "[('xkb', 'us'), ('xkb', 'gr')]"
fi

# -------------------- REMOVE DEFAULT APPS -------------------
UNWANTED=(evince rhythmbox abrt gnome-tour mediawriter)
if ask_user "Remove selected preinstalled Fedora apps (${UNWANTED[*]})?"; then
  remove_if_installed "${UNWANTED[@]}"
fi

# -------------------- SYSTEM UPDATE -------------------------
if ask_user "Run full system upgrade (dnf upgrade --refresh)?"; then
  sudo dnf -y upgrade --refresh
fi

# -------------------- PACKAGE GROUPS ------------------------
CORE_PACKAGES=(
  ca-certificates curl wget jq unzip tar openssl fontconfig xorg-x11-font-utils glib2
  dnf5 dnf5-plugins fuse fuse-libs fuse3 fuse3-libs
)
SECURITY_PACKAGES=(firewalld fail2ban lynis rkhunter)
TWEAK_PACKAGES=(gnome-color-manager zram-generator-defaults)
PRODUCTIVITY_APPS=(filezilla flatseal decibels dconf-editor papers showtime)

show_package_group "CORE packages" \
  "Base command-line/system tools used by this script: downloads, archives, JSON parsing, certificates, fonts, DNF5 plugins, and FUSE support." \
  "${CORE_PACKAGES[@]}"
ask_user "Install CORE packages listed above?" && install_if_missing "${CORE_PACKAGES[@]}"

show_package_group "SECURITY packages" \
  "Firewall, SSH/login brute-force protection, local security audit, and rootkit scanning tools." \
  "${SECURITY_PACKAGES[@]}"
ask_user "Install SECURITY packages listed above?" && install_if_missing "${SECURITY_PACKAGES[@]}"

show_package_group "TWEAK packages" \
  "Small system/desktop helpers: color profile tools and Fedora's default zram generator configuration." \
  "${TWEAK_PACKAGES[@]}"
ask_user "Install TWEAK packages listed above?" && install_if_missing "${TWEAK_PACKAGES[@]}"

show_package_group "PRODUCTIVITY apps" \
  "Desktop apps: FileZilla, Flatseal, Decibels, dconf Editor, Papers document viewer, and Showtime video player." \
  "${PRODUCTIVITY_APPS[@]}"
ask_user "Install PRODUCTIVITY apps listed above?" && install_if_missing "${PRODUCTIVITY_APPS[@]}"

# -------------------- SECURITY / FIREWALL -------------------
if rpm -q usbguard &>/dev/null; then
  ask_user "USBGuard is installed. Remove it?" && remove_if_installed usbguard
fi

if ask_user "Enable firewalld?"; then
  install_if_missing firewalld
  sudo systemctl enable --now firewalld
fi

if ask_user "Set firewall default zone to FedoraWorkstation?"; then
  install_if_missing firewalld
  sudo systemctl enable --now firewalld
  sudo firewall-cmd --set-default-zone=FedoraWorkstation || warn "FedoraWorkstation zone unavailable; keeping current zone."
fi

if ask_user "Enable fail2ban service?"; then
  install_if_missing fail2ban
  sudo systemctl enable --now fail2ban || warn "fail2ban failed to start. Check journalctl -u fail2ban."
fi

if ask_user "Enable DNF5 automatic update downloads (download only, not install)?"; then
  install_if_missing dnf5-plugin-automatic
  sudo mkdir -p /etc/dnf
  sudo tee /etc/dnf/automatic.conf >/dev/null <<'AUTOEOF'
[commands]
download_updates = yes
apply_updates = no

[emitters]
emit_via = stdio
AUTOEOF
  sudo systemctl enable --now dnf5-automatic.timer
fi

getenforce 2>/dev/null | grep -q Enforcing || warn "SELinux is not enforcing."

# -------------------- GNOME SOFTWARE REPO_GPGCHECK BUG FIX --
if ask_user "Apply GNOME Software repo_gpgcheck=1 workaround for existing third-party repos?"; then
  apply_repo_gpgcheck_workaround
fi

# -------------------- SPEED / PERFORMANCE -------------------
if ask_user "Apply conservative system speed/performance optimizations?"; then
  info "Applying conservative performance optimizations..."

  sudo mkdir -p /etc/systemd/system.conf.d
  sudo tee /etc/systemd/system.conf.d/timeout.conf >/dev/null <<'EOF_TIMEOUT'
[Manager]
DefaultTimeoutStartSec=30s
DefaultTimeoutStopSec=30s
EOF_TIMEOUT

  sudo tee /etc/sysctl.d/99-swappiness.conf >/dev/null <<'EOF_SWAP'
vm.swappiness=10
EOF_SWAP

  sudo tee /etc/sysctl.d/99-inotify.conf >/dev/null <<'EOF_INOTIFY'
fs.inotify.max_user_watches=524288
fs.inotify.max_user_instances=1024
EOF_INOTIFY

  sudo sysctl --system

  # Do not disable PackageKit on Fedora 44 GNOME: GNOME Software uses the DNF5 backend.
  # Do not mask GNOME LocalSearch by default: Fedora 44/GNOME 50 use localsearch/tinysparql.

  safe_gsettings_set org.gnome.desktop.interface enable-animations false
  safe_gsettings_set org.gnome.desktop.interface clock-show-seconds true
  safe_gsettings_set org.gnome.desktop.interface show-battery-percentage true

  sudo mkdir -p /var/log/journal
  sudo systemctl restart systemd-journald

  info "Performance optimizations applied. Reboot recommended."
fi

# -------------------- SNAPD ---------------------------------
if ask_user "Enable snapd support?"; then
  install_if_missing snapd
  sudo systemctl enable --now snapd.socket
  sudo ln -sfn /var/lib/snapd/snap /snap
fi

# -------------------- BTRFS / SNAPPER -----------------------
if mount | grep -q ' on / type btrfs'; then
  if ask_user "Enable Snapper for Btrfs root?"; then
    install_if_missing snapper
    sudo snapper -c root create-config / || true
    sudo systemctl enable --now snapper-timeline.timer snapper-cleanup.timer
  fi
fi

# -------------------- REPOS ---------------------------------
if ask_user "Enable RPM Fusion (free + nonfree)?"; then
  ensure_rpmfusion
fi

# -------------------- SOFTWARE BLOCKS -----------------------
if ask_user "Install Tailscale VPN CLI/daemon?"; then
  install_if_missing curl
  sudo curl -fsSL --retry 3 --connect-timeout 20 -o /etc/yum.repos.d/tailscale.repo \
    https://pkgs.tailscale.com/stable/fedora/tailscale.repo
  set_repo_gpgcheck_zero tailscale-stable
  install_if_missing tailscale
  ask_user "Enable tailscaled service?" && sudo systemctl enable --now tailscaled
fi

if ask_user "Install VS Code + VSCodium?"; then
  install_if_missing curl
  sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc || true
  sudo tee /etc/yum.repos.d/vscode.repo >/dev/null <<'EOF_VSCODE'
[code]
name=Visual Studio Code
baseurl=https://packages.microsoft.com/yumrepos/vscode
enabled=1
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
EOF_VSCODE
  sudo tee /etc/yum.repos.d/vscodium.repo >/dev/null <<'EOF_VSCODIUM'
[vscodium]
name=VSCodium
baseurl=https://paulcarroty.gitlab.io/vscodium-deb-rpm-repo/rpms/
enabled=1
gpgcheck=1
repo_gpgcheck=0
gpgkey=https://gitlab.com/paulcarroty/vscodium-deb-rpm-repo/raw/master/pub.gpg
metadata_expire=1h
EOF_VSCODIUM
  set_repo_gpgcheck_zero vscodium
  install_if_missing code codium
fi

if ask_user "Install Google Chrome?"; then
  sudo tee /etc/yum.repos.d/google-chrome.repo >/dev/null <<'EOF_CHROME'
[google-chrome]
name=google-chrome
baseurl=https://dl.google.com/linux/chrome/rpm/stable/x86_64
enabled=1
gpgcheck=1
gpgkey=https://dl.google.com/linux/linux_signing_key.pub
EOF_CHROME
  install_if_missing google-chrome-stable
fi

ask_user "Install Git?" && install_if_missing git

if ask_user "Install AMD ROCm GPU compute stack?"; then
  install_rocm_stack
fi

if ask_user "Install Docker CE?"; then
  add_repo_from_url https://download.docker.com/linux/fedora/docker-ce.repo /etc/yum.repos.d/docker-ce.repo
  if ! sudo dnf -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
    warn "Docker CE install failed. Docker may not have Fedora 44 repo metadata yet."
    if ask_user "Install Fedora's moby-engine fallback instead?"; then
      install_if_missing moby-engine docker-compose-plugin
    fi
  fi
  ask_user "Enable Docker service?" && sudo systemctl enable --now docker
  sudo getent group docker >/dev/null || sudo groupadd docker
  sudo usermod -aG docker "$(real_user)"
fi

if ask_user "Install virt-manager and KVM/QEMU/libvirt virtualization stack?"; then
  install_virtualization_stack
fi

if ask_user "Install Microsoft Core Fonts via legacy RPM?"; then
  install_if_missing curl cabextract fontconfig
  tmp_rpm="$(mktemp --suffix=.rpm)"
  curl -fL --retry 3 --connect-timeout 20 -o "$tmp_rpm" \
    https://downloads.sourceforge.net/project/mscorefonts2/rpms/msttcore-fonts-installer-2.6-1.noarch.rpm
  sudo rpm -Uvh --nodigest --nofiledigest "$tmp_rpm" || warn "Microsoft Core Fonts RPM install failed."
  rm -f "$tmp_rpm"
  sudo fc-cache -rv
fi

ask_user "Install LibreOffice (EN + EL)?" && install_if_missing libreoffice libreoffice-langpack-en libreoffice-langpack-el
ask_user "Install GIMP & Inkscape?" && install_if_missing gimp inkscape

if ask_user "Install Cockpit?"; then
  install_if_missing cockpit firewalld
  sudo systemctl enable --now cockpit.socket
  sudo firewall-cmd --add-service=cockpit --permanent && sudo firewall-cmd --reload || true
fi

# -------------------- GNOME TWEAKS / UI ---------------------
if ask_user "Apply GNOME UI tweaks?"; then
  install_if_missing gnome-tweaks gnome-extensions-app gnome-usage
  safe_gsettings_set org.gnome.desktop.interface enable-animations false
  safe_gsettings_set org.gnome.desktop.wm.preferences button-layout ':minimize,maximize,close'
  safe_gsettings_set org.gnome.settings-daemon.plugins.color night-light-enabled true
  safe_gsettings_set org.gnome.nautilus.preferences show-hidden-files true
  safe_gsettings_set org.gnome.nautilus.preferences show-image-thumbnails 'always'
  safe_gsettings_set org.gnome.nautilus.preferences always-use-location-entry true
  safe_gsettings_set org.gnome.nautilus.preferences recursive-search 'never'
  safe_gsettings_set org.gnome.mutter experimental-features "['scale-monitor-framebuffer']"
  safe_gsettings_set org.gnome.desktop.interface clock-show-seconds true
  safe_gsettings_set org.gnome.desktop.interface show-battery-percentage true
  safe_gsettings_set org.gnome.desktop.peripherals.touchpad tap-to-click true
  safe_gsettings_set org.gnome.desktop.peripherals.touchpad natural-scroll true
fi

# -------------------- GNOME EXTENSIONS ----------------------
if ask_user "Install GNOME Shell extension tools?"; then
  install_if_missing gnome-extensions-app gnome-tweaks jq unzip curl glib2
fi

if has_gnome_shell && ask_user "Install Fedora-packaged GNOME Shell extensions?"; then
  info "GNOME Shell detected: $(gnome-shell --version)"
  install_if_missing \
    gnome-shell-extension-appindicator \
    gnome-shell-extension-user-theme

  enable_gnome_extension appindicatorsupport@rgcjonas.gmail.com
  enable_gnome_extension user-theme@gnome-shell-extensions.gcampax.github.com

  if ask_user "Install Dash to Dock? Choose NO if you prefer Dash to Panel"; then
    install_if_missing gnome-shell-extension-dash-to-dock
    enable_gnome_extension dash-to-dock@micxgx.gmail.com
  elif ask_user "Install Dash to Panel instead?"; then
    install_if_missing gnome-shell-extension-dash-to-panel
    enable_gnome_extension dash-to-panel@jderose9.github.com
  fi
fi

if has_gnome_shell && ask_user "Install extra GNOME extensions from extensions.gnome.org (ArcMenu...)?"; then
  install_if_missing gnome-menus lm_sensors
  install_ego_extension 3628 arcmenu@arcmenu.com "ArcMenu"
  warn "For newly installed extensions on Wayland, log out and back in before judging whether they loaded."
fi

# -------------------- GNOME TEMPLATES -----------------------
if ask_user "Add GNOME Templates (Text, Markdown, HTML)?"; then
  TEMPLATES_DIR="$(real_home)/Templates"
  info "Creating GNOME Templates in $TEMPLATES_DIR"
  mkdir -p "$TEMPLATES_DIR"
  touch "$TEMPLATES_DIR/Text Document.txt"
  cat > "$TEMPLATES_DIR/Markdown.md" <<'EOF_MD'
# Title

Write here...
EOF_MD
  cat > "$TEMPLATES_DIR/HTML Document.html" <<'EOF_HTML'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>Document</title>
</head>
<body>

</body>
</html>
EOF_HTML
  nautilus -q 2>/dev/null || true
  info "GNOME New Document templates added."
fi

# -------------------- FLATPAK APPS --------------------------
if ask_user "Install Flatpak user applications?"; then
  install_if_missing flatpak
  flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo

  APPS=(
    org.signal.Signal
    com.mattjakeman.ExtensionManager
    it.mijorus.gearlever
  )
  # Whaler / Docker GUI apps are intentionally not installed here.

  for a in "${APPS[@]}"; do
    flatpak install -y --noninteractive flathub "$a" || warn "Flatpak failed: $a"
  done
fi

# -------------------- CLI / DEV -----------------------------
ask_user "Install CLI tools (fzf, bat, ripgrep)?" && install_if_missing fzf bat ripgrep

if ask_user "Increase file watcher limits (dev-friendly)?"; then
  sudo tee /etc/sysctl.d/99-dev.conf >/dev/null <<'EOF_DEV'
fs.inotify.max_user_watches=524288
fs.inotify.max_user_instances=1024
EOF_DEV
  sudo sysctl --system
fi

if ask_user "Improve Bash defaults (history, colors, completion)?"; then
  if ! grep -q "HISTSIZE=10000" "$(real_home)/.bashrc"; then
    cat >> "$(real_home)/.bashrc" <<'EOF_BASH'
HISTSIZE=10000
HISTFILESIZE=20000
shopt -s histappend
bind '"\e[A": history-search-backward'
bind '"\e[B": history-search-forward'
EOF_BASH
  fi
fi

# -------------------- FONTS ---------------------------------
if ask_user "Install extra fonts (Noto, Roboto, JetBrains Mono, etc.)?"; then
  install_if_missing \
    fira-code-fonts jetbrains-mono-fonts google-roboto-fonts \
    google-noto-sans-fonts google-noto-serif-fonts google-noto-mono-fonts \
    liberation-sans-fonts liberation-serif-fonts liberation-mono-fonts rsms-inter-fonts
fi

if ask_user "Install MesloLGS Nerd Fonts (Powerlevel10k)?"; then
  install_meslo_nerd_fonts
fi

if ask_user "Apply font rendering tweaks (fontconfig)?"; then
  mkdir -p "$(real_home)/.config/fontconfig"
  cat > "$(real_home)/.config/fontconfig/fonts.conf" <<'EOF_FONTCONFIG'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
  <match target="font">
    <edit name="hinting" mode="assign"><bool>true</bool></edit>
    <edit name="hintstyle" mode="assign"><const>hintslight</const></edit>
    <edit name="antialias" mode="assign"><bool>true</bool></edit>
    <edit name="rgba" mode="assign"><const>rgb</const></edit>
  </match>
</fontconfig>
EOF_FONTCONFIG
  fc-cache -f
fi

# -------------------- MEDIA CODECS --------------------------
if ask_user "Install media codecs (RPM Fusion: libavcodec-freeworld)?"; then
  ensure_rpmfusion
  install_if_missing libavcodec-freeworld
fi

# -------------------- ADVANCED ------------------------------
if ask_user "Advanced: GRUB remember last entry?"; then
  backup_file /etc/default/grub
  sudo sed -i \
    -e 's/^#\?GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' \
    -e 's/^#\?GRUB_SAVEDEFAULT=.*/GRUB_SAVEDEFAULT=true/' \
    -e 's/^#\?GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=menu/' \
    -e 's/^#\?GRUB_TIMEOUT=.*/GRUB_TIMEOUT=5/' /etc/default/grub
  sudo grub2-editenv /boot/grub2/grubenv create || true
  sudo grub2-mkconfig -o /boot/grub2/grub.cfg
fi

if ask_user "Advanced: keep only 2 kernels?"; then
  backup_file /etc/dnf/dnf.conf
  set_dnf_main_option installonly_limit 2
  mapfile -t OLD_KERNELS < <(dnf repoquery --installonly --latest-limit=-2 -q || true)
  if (( ${#OLD_KERNELS[@]} > 0 )); then
    printf '%s\n' "${OLD_KERNELS[@]}"
    ask_user "Remove older kernels now?" && sudo dnf -y remove "${OLD_KERNELS[@]}"
  else
    info "No old installonly kernels found."
  fi
fi

if ask_user "Advanced: apply AMD kernel args? Only use if you know these exact args are needed"; then
  sudo grubby --update-kernel=ALL --args="amd_iommu=off amdgpu.gttsize=126976 ttm.pages_limit=32505856"
  sudo grubby --info=DEFAULT | grep '^args='
fi

if ask_user "Advanced: enable TPM2 auto-unlock for a LUKS2 encrypted disk?"; then
  enable_luks2_tpm2_unlock
fi

if ask_user "Check firmware updates (fwupd)?"; then
  run_firmware_updates
fi

# -------------------- EXTRA DISKS ---------------------------
if ask_user "Setup a second internal disk (Mount/BitLocker)?"; then
  setup_secondary_disk
fi

# -------------------- FINAL ---------------------------------
info "Setup completed. A reboot is recommended if you changed extensions, groups, kernel args, firmware, Docker, virtualization, or system services."
ask_user "Reboot now?" && sudo reboot || info "Reboot skipped."
