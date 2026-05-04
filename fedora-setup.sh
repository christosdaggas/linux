#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s extglob

# ============================================================
# Fedora 44 / GNOME 50 Interactive Workstation Setup
# Revised for DNF5, GNOME 50, fwupd, Nerd Fonts, ROCm, TPM2/LUKS2,
# GNOME extensions, Docker Engine, Docker Desktop for Linux, Proton VPN,
# SSH, GNOME Remote Desktop, and late-stage repository workarounds.
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

run_as_real_user(){
  local username uid
  username="$(real_user)"
  uid="$(id -u "$username")"
  sudo -u "$username" -H env \
    XDG_RUNTIME_DIR="/run/user/${uid}" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" \
    "$@"
}

run_user_systemctl(){
  run_as_real_user systemctl --user "$@"
}

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

ensure_docker_desktop_pass_initialized(){
  local username home gpg_id gpg_name gpg_email host_fqdn
  username="$(real_user)"
  home="$(real_home)"

  install_if_missing pass gnupg2 pinentry

  if [[ -f "$home/.password-store/.gpg-id" ]]; then
    info "pass is already initialized for $username."
    return 0
  fi

  gpg_id="$(run_as_real_user bash -lc 'gpg --list-secret-keys --with-colons 2>/dev/null | awk -F: '\''$1=="sec" {print $5; exit}'\''' || true)"

  if [[ -z "$gpg_id" ]]; then
    warn "No existing GPG secret key was found for $username. Docker Desktop for Linux uses pass for credential storage."
    if ask_user "Generate a local GPG key now for Docker Desktop/pass?"; then
      read -rp "GPG name [${username}]: " gpg_name
      gpg_name="${gpg_name:-$username}"
      host_fqdn="$(hostname -f 2>/dev/null || hostname || printf 'localhost')"
      read -rp "GPG email [${username}@${host_fqdn}.local]: " gpg_email
      gpg_email="${gpg_email:-${username}@${host_fqdn}.local}"

      info "Generating GPG key for ${gpg_name} <${gpg_email}>. If prompted, choose a passphrase you can remember."
      if ! run_as_real_user gpg --quick-generate-key "${gpg_name} <${gpg_email}>" default default 2y; then
        warn "GPG key generation failed or was cancelled. Docker Desktop can still be installed, but sign-in may warn until pass is initialized."
        warn "Manual fix later: gpg --generate-key ; pass init YOUR_GPG_ID"
        return 0
      fi

      gpg_id="$(run_as_real_user bash -lc 'gpg --list-secret-keys --with-colons 2>/dev/null | awk -F: '\''$1=="sec" {print $5; exit}'\''' || true)"
    else
      warn "Skipping pass initialization. Docker Desktop sign-in may warn until you run: pass init YOUR_GPG_ID"
      return 0
    fi
  fi

  if [[ -n "$gpg_id" ]]; then
    info "Initializing pass for Docker Desktop credentials with GPG key: $gpg_id"
    run_as_real_user pass init "$gpg_id" || warn "pass init failed. Docker Desktop sign-in may warn until pass is initialized manually."
  else
    warn "Could not determine a GPG key ID. Docker Desktop sign-in may warn until pass is initialized manually."
  fi
}

install_docker_desktop_stack(){
  info "Installing Docker Desktop for Linux on Fedora..."

  warn "Docker Desktop commercial use in larger enterprises may require a paid Docker subscription. Review Docker's terms before using it in that context."
  warn "Docker Desktop Fedora documentation currently lists Fedora 42 or Fedora 43 as the Fedora prerequisite. This Fedora 44 script will attempt the install, but Docker may not officially support this target yet."

  if [[ "$(uname -m)" != "x86_64" ]]; then
    error "Docker Desktop Linux RPM is for x86_64/amd64. Detected architecture: $(uname -m)."
    return 1
  fi

  if ! grep -Eq '(vmx|svm)' /proc/cpuinfo 2>/dev/null; then
    warn "CPU virtualization extensions were not detected. Docker Desktop runs a VM and needs virtualization enabled in firmware/BIOS."
  else
    info "CPU virtualization extensions detected."
  fi

  install_if_missing curl dnf5-plugins qemu-kvm qemu-img pass gnupg2 pinentry gnome-terminal procps-ng

  if grep -q GenuineIntel /proc/cpuinfo 2>/dev/null; then
    sudo modprobe kvm kvm_intel 2>/dev/null || warn "Could not load kvm_intel now. Check firmware virtualization settings if Docker Desktop fails."
  elif grep -q AuthenticAMD /proc/cpuinfo 2>/dev/null; then
    sudo modprobe kvm kvm_amd 2>/dev/null || warn "Could not load kvm_amd now. Check firmware virtualization settings if Docker Desktop fails."
  else
    sudo modprobe kvm 2>/dev/null || true
  fi

  if [[ -e /dev/kvm ]]; then
    sudo getent group kvm >/dev/null && sudo usermod -aG kvm "$(real_user)" || true
    info "/dev/kvm exists. Added $(real_user) to kvm group where available. Log out/in or reboot for group membership to apply."
  else
    warn "/dev/kvm was not found. Docker Desktop may not start until KVM is available."
  fi

  if has_gnome_shell; then
    install_if_missing gnome-extensions-app gnome-shell-extension-appindicator
    enable_gnome_extension appindicatorsupport@rgcjonas.gmail.com
  fi

  add_repo_from_url https://download.docker.com/linux/fedora/docker-ce.repo /etc/yum.repos.d/docker-ce.repo

  local tmp_rpm docker_desktop_url
  tmp_rpm="$(mktemp --suffix=.rpm)"
  docker_desktop_url="https://desktop.docker.com/linux/main/amd64/docker-desktop-x86_64.rpm"

  info "Downloading latest Docker Desktop RPM..."
  if ! curl -fL --retry 3 --connect-timeout 30 -o "$tmp_rpm" "$docker_desktop_url"; then
    rm -f "$tmp_rpm"
    warn "Docker Desktop RPM download failed. Check network/DNS or download it manually from Docker's Fedora Desktop page."
    return 1
  fi

  info "Installing Docker Desktop RPM with dnf..."
  if ! sudo dnf -y install "$tmp_rpm"; then
    rm -f "$tmp_rpm"
    warn "Docker Desktop RPM install failed. On Fedora 44 this may be due to unsupported Fedora Desktop metadata or dependency availability."
    return 1
  fi
  rm -f "$tmp_rpm"

  ensure_docker_desktop_pass_initialized

  if systemctl list-unit-files docker.service --no-legend 2>/dev/null | awk '{print $1}' | grep -Fxq 'docker.service'; then
    warn "Docker Desktop and Docker Engine can coexist, but both running together can cause port/resource conflicts."
    if ask_user "Stop and disable system Docker Engine while using Docker Desktop?"; then
      sudo systemctl disable --now docker docker.socket containerd 2>/dev/null || warn "Could not disable one or more Docker Engine units."
    fi
  fi

  if ask_user "Enable Docker Desktop to start when you sign in?"; then
    run_user_systemctl enable docker-desktop || warn "Could not enable Docker Desktop user service. Try manually: systemctl --user enable docker-desktop"
  fi

  if ask_user "Start Docker Desktop now?"; then
    run_user_systemctl start docker-desktop || warn "Could not start Docker Desktop user service. Try manually: systemctl --user start docker-desktop"
  fi

  info "Docker Desktop installed. First launch requires accepting Docker Desktop terms in the UI. Then sign in from the Docker Desktop dashboard."
  info "If Docker Desktop cannot access KVM immediately, log out/in or reboot so kvm group membership applies."
}


enable_ssh_server(){
  info "Enabling SSH server for remote shell access..."
  install_if_missing openssh-server firewalld

  sudo systemctl enable --now sshd
  sudo systemctl enable --now firewalld
  sudo firewall-cmd --permanent --add-service=ssh || warn "Could not add SSH service to firewalld."
  sudo firewall-cmd --reload || true

  local ip
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  info "SSH enabled. Example: ssh $(real_user)@${ip:-YOUR_MACHINE_IP}"
  warn "For Internet-facing access, prefer SSH keys and/or VPN. Do not expose password SSH directly to the Internet unless you harden sshd_config."
}

setup_gnome_file_sharing_webdav(){
  info "Configuring GNOME Public folder / WebDAV file sharing..."
  install_if_missing gnome-user-share httpd httpd-tools avahi firewalld

  local public_dir
  public_dir="$(real_home)/Public"
  mkdir -p "$public_dir"
  sudo chown "$(real_user):$(id -gn "$(real_user)")" "$public_dir" 2>/dev/null || true

  if ask_user "Allow GNOME Public folder sharing without a password?"; then
    run_as_real_user gsettings set org.gnome.desktop.file-sharing require-password 'never' || \
      warn "Could not set GNOME file-sharing password policy."
  else
    run_as_real_user gsettings set org.gnome.desktop.file-sharing require-password 'always' || \
      warn "Could not set GNOME file-sharing password policy."
  fi

  if run_user_systemctl start gnome-user-share-webdav.service; then
    info "Started GNOME user WebDAV file sharing service."
  else
    warn "Could not start gnome-user-share-webdav.service now. It may require an active graphical user session."
  fi

  sudo systemctl enable --now avahi-daemon || warn "Could not enable avahi-daemon."
  sudo systemctl enable --now firewalld || true
  sudo firewall-cmd --permanent --add-service=mdns || true

  if sudo firewall-cmd --get-services 2>/dev/null | tr ' ' '\n' | grep -Fxq webdav; then
    sudo firewall-cmd --permanent --add-service=webdav || true
  else
    sudo firewall-cmd --permanent --add-port=8080/tcp || true
  fi
  sudo firewall-cmd --reload || true

  info "GNOME Public folder sharing configured for $(real_user)."
}

setup_gnome_system_rdp(){
  info "Configuring GNOME Remote Desktop system-level RDP login..."
  install_if_missing gnome-remote-desktop freerdp firewalld

  if ! command -v grdctl &>/dev/null; then
    error "grdctl was not found after installing gnome-remote-desktop. Cannot configure GNOME Remote Desktop automatically."
    return 1
  fi
  if ! command -v winpr-makecert &>/dev/null; then
    error "winpr-makecert was not found after installing freerdp. Cannot generate RDP TLS certificate automatically."
    return 1
  fi
  if ! sudo getent passwd gnome-remote-desktop >/dev/null; then
    error "System user gnome-remote-desktop was not found. Reinstall gnome-remote-desktop and try again."
    return 1
  fi

  local rdp_user rdp_pass rdp_pass_confirm cert_dir ip
  if ask_user "Use your Fedora username ($(real_user)) as the RDP gateway username?"; then
    rdp_user="$(real_user)"
  else
    read -rp "RDP gateway username, e.g. rdpadmin: " rdp_user
    if [[ -z "$rdp_user" ]]; then
      warn "Empty RDP username. Skipping GNOME Remote Desktop configuration."
      return 0
    fi
  fi

  warn "The RDP gateway password is stored separately from your Fedora account password."
  warn "You may type the same password as your Fedora login password, but it will not stay synchronized automatically."
  while true; do
    read -rsp "RDP gateway password: " rdp_pass
    echo
    if [[ -z "$rdp_pass" ]]; then
      warn "Empty RDP password. Try again or press Ctrl+C to cancel."
      continue
    fi
    read -rsp "Confirm RDP gateway password: " rdp_pass_confirm
    echo
    if [[ "$rdp_pass" == "$rdp_pass_confirm" ]]; then
      break
    fi
    warn "Passwords did not match. Try again."
  done
  unset rdp_pass_confirm

  cert_dir="/var/lib/gnome-remote-desktop/.local/share/gnome-remote-desktop"
  sudo -u gnome-remote-desktop mkdir -p "$cert_dir"

  if [[ ! -f "$cert_dir/rdp-tls.crt" || ! -f "$cert_dir/rdp-tls.key" ]]; then
    sudo -u gnome-remote-desktop winpr-makecert \
      -silent -rdp \
      -path "$cert_dir" \
      rdp-tls
  fi

  sudo grdctl --system rdp set-tls-key "$cert_dir/rdp-tls.key"
  sudo grdctl --system rdp set-tls-cert "$cert_dir/rdp-tls.crt"
  printf '%s\n%s\n' "$rdp_user" "$rdp_pass" | sudo grdctl --system rdp set-credentials
  unset rdp_pass
  sudo grdctl --system rdp enable

  sudo systemctl enable --now gdm.service
  sudo systemctl enable --now gnome-remote-desktop.service
  sudo systemctl set-default graphical.target

  sudo systemctl enable --now firewalld
  sudo firewall-cmd --permanent --add-service=rdp || sudo firewall-cmd --permanent --add-port=3389/tcp
  sudo firewall-cmd --reload || true

  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  info "GNOME Remote Desktop RDP enabled. Connect to ${ip:-YOUR_MACHINE_IP}:3389 with username: $rdp_user"
  warn "For stronger security, use this through a VPN or SSH tunnel instead of exposing RDP directly to the Internet."
}

setup_remote_access_stack(){
  info "Remote access setup selected."

  if ask_user "Enable SSH server now?"; then
    enable_ssh_server
  fi

  if ask_user "Enable GNOME Remote Desktop system-level RDP login?"; then
    setup_gnome_system_rdp
  fi

  if ask_user "Enable GNOME Public folder / WebDAV file sharing?"; then
    setup_gnome_file_sharing_webdav
  fi
}

install_proton_vpn_gui(){
  info "Installing Proton VPN GUI app for Fedora GNOME..."
  install_if_missing curl wget ca-certificates libappindicator-gtk3 gnome-shell-extension-appindicator gnome-extensions-app

  local fedora_version release_rpm release_url
  fedora_version="$(rpm -E %fedora)"
  release_rpm="$(mktemp --suffix=.rpm)"
  release_url="https://repo.protonvpn.com/fedora-${fedora_version}-stable/protonvpn-stable-release/protonvpn-stable-release-1.0.3-1.noarch.rpm"

  info "Downloading Proton VPN Fedora ${fedora_version} stable repository package..."
  if ! curl -fL --retry 3 --connect-timeout 30 -o "$release_rpm" "$release_url"; then
    rm -f "$release_rpm"
    warn "Could not download Proton VPN repository package for Fedora ${fedora_version}. Check Proton's Fedora support page or network/DNS."
    return 1
  fi

  sudo dnf -y install "$release_rpm"
  rm -f "$release_rpm"

  sudo dnf check-update --refresh || true
  install_if_missing proton-vpn-gnome-desktop

  if has_gnome_shell; then
    enable_gnome_extension appindicatorsupport@rgcjonas.gmail.com
    warn "For the Proton VPN tray icon, reboot or log out/in, then verify AppIndicator and KStatusNotifierItem Support is enabled in Extensions."
  fi

  info "Proton VPN GUI installed. Open Proton VPN from the app grid and sign in with your Proton account."
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
if [[ $EUID -eq 0 ]]; then
  error "Do not run this script as root. Run it as your normal user: bash fedora-setup.sh"
  exit 1
fi

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

# -------------------- REMOTE ACCESS -------------------------
if ask_user "Configure remote access options (SSH, GNOME RDP, Public folder sharing)?"; then
  setup_remote_access_stack
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
  if ask_user "Enable Snapper for Btrfs root (1 weekly backup only)?"; then
    install_if_missing snapper
    sudo snapper -c root create-config / || true
    # Keep the timeline on, but only keep 1 weekly backup
    sudo sed -i 's/^TIMELINE_LIMIT_HOURLY=.*/TIMELINE_LIMIT_HOURLY="0"/' /etc/snapper/configs/root
    sudo sed -i 's/^TIMELINE_LIMIT_DAILY=.*/TIMELINE_LIMIT_DAILY="0"/' /etc/snapper/configs/root
    sudo sed -i 's/^TIMELINE_LIMIT_WEEKLY=.*/TIMELINE_LIMIT_WEEKLY="1"/' /etc/snapper/configs/root
    sudo sed -i 's/^TIMELINE_LIMIT_MONTHLY=.*/TIMELINE_LIMIT_MONTHLY="0"/' /etc/snapper/configs/root
    sudo sed -i 's/^TIMELINE_LIMIT_YEARLY=.*/TIMELINE_LIMIT_YEARLY="0"/' /etc/snapper/configs/root
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
  install_if_missing tailscale
  ask_user "Enable tailscaled service?" && sudo systemctl enable --now tailscaled
fi

if ask_user "Install Proton VPN GUI app?"; then
  install_proton_vpn_gui
fi

if ask_user "Install Visual Studio Code (Microsoft)?"; then
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
  install_if_missing code
fi

if ask_user "Install VSCodium (Open Source)?"; then
  install_if_missing curl
  sudo tee /etc/yum.repos.d/vscodium.repo >/dev/null <<'EOF_VSCODIUM'
[vscodium]
name=VSCodium
baseurl=https://paulcarroty.gitlab.io/vscodium-deb-rpm-repo/rpms/
enabled=1
gpgcheck=1
gpgkey=https://gitlab.com/paulcarroty/vscodium-deb-rpm-repo/raw/master/pub.gpg
metadata_expire=1h
EOF_VSCODIUM
  install_if_missing codium
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
  remove_if_installed \
    docker docker-client docker-client-latest docker-common docker-latest \
    docker-latest-logrotate docker-logrotate docker-selinux \
    docker-engine-selinux docker-engine podman-docker
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

if ask_user "Install Docker Desktop for Linux?"; then
  install_docker_desktop_stack
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

ask_user "Install LibreOffice (EN + EL) & Greek spellcheck?" && install_if_missing libreoffice libreoffice-langpack-en libreoffice-langpack-el hunspell-el
ask_user "Install GIMP & Inkscape?" && install_if_missing gimp inkscape

if ask_user "Install Cockpit?"; then
  install_if_missing cockpit firewalld
  sudo systemctl enable --now cockpit.socket
  sudo firewall-cmd --add-service=cockpit --permanent && sudo firewall-cmd --reload || true
fi

# -------------------- EXTRA OPTIONAL SOFTWARE ---------------

ensure_flatpak_user_flathub(){
  install_if_missing flatpak
  flatpak remote-add --user --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
}

if ask_user "Install Pika Backup?"; then
  ensure_flatpak_user_flathub
  flatpak install --user -y --noninteractive flathub org.gnome.World.PikaBackup || warn "Flatpak failed: Pika Backup"
fi

if ask_user "Install disk health and hardware diagnostic tools?"; then
  install_if_missing smartmontools nvme-cli lm_sensors hdparm pciutils usbutils lshw util-linux
  sudo systemctl enable --now smartd || warn "Could not enable smartd."
fi

if ask_user "Install printer and scanner support?"; then
  install_if_missing cups system-config-printer simple-scan sane-backends sane-airscan ipp-usb avahi firewalld
  sudo systemctl enable --now cups
  sudo systemctl enable --now avahi-daemon || warn "Could not enable avahi-daemon."
  sudo systemctl enable --now firewalld || true
  sudo firewall-cmd --permanent --add-service=mdns || true
  sudo firewall-cmd --reload || true
fi

if ask_user "Install OBS Studio for screen recording/streaming?"; then
  ensure_flatpak_user_flathub
  install_if_missing wf-recorder slurp
  flatpak install --user -y --noninteractive flathub com.obsproject.Studio || warn "Flatpak failed: OBS Studio"
fi

if ask_user "Install Podman and Distrobox developer container tools?"; then
  install_if_missing podman podman-compose buildah skopeo distrobox toolbox
  if ask_user "Enable rootless Podman user socket now?"; then
    run_user_systemctl enable --now podman.socket || warn "Could not enable rootless Podman socket."
  fi
fi

if ask_user "Install shell power-user tools?"; then
  install_if_missing zsh fish starship tmux btop htop fastfetch neofetch ncdu tree eza fd-find ripgrep bat fzf zoxide direnv
fi

if ask_user "Install network diagnostic tools?"; then
  install_if_missing nmap nmap-ncat wireshark-cli wireshark iperf3 bind-utils whois traceroute mtr tcpdump openssl
  if ask_user "Add $(real_user) to wireshark group if available?"; then
    sudo getent group wireshark >/dev/null && sudo usermod -aG wireshark "$(real_user)" || warn "wireshark group not found."
  fi
fi

if ask_user "Install Python developer tools?"; then
  install_if_missing python3 python3-pip python3-virtualenv pipx
  command -v pipx &>/dev/null && run_as_real_user pipx ensurepath || true
fi

if ask_user "Install Node.js and npm?"; then
  install_if_missing nodejs npm
fi

if ask_user "Install Go development tools?"; then
  install_if_missing golang
fi

if ask_user "Install Rust development tools?"; then
  install_if_missing rust cargo
fi

if ask_user "Install PHP and Composer?"; then
  install_if_missing php php-cli composer
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
  flatpak remote-add --user --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo

  APPS=(
    org.signal.Signal
    com.mattjakeman.ExtensionManager
    io.missioncenter.MissionCenter
    it.mijorus.gearlever
  )
  # Whaler / Docker GUI apps are intentionally not installed here.

  for a in "${APPS[@]}"; do
    flatpak install --user -y --noninteractive flathub "$a" || warn "Flatpak failed: $a"
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

# -------------------- FINAL REPOSITORY WORKAROUNDS ----------
if ask_user "Apply GNOME Software repo_gpgcheck=1 workaround now for all repos added by this script?"; then
  apply_repo_gpgcheck_workaround
fi

# -------------------- FINAL ---------------------------------
info "Setup completed. A reboot is recommended if you changed extensions, groups, kernel args, firmware, Docker, Docker Desktop, Proton VPN, remote access, virtualization, or system services."
ask_user "Reboot now?" && sudo reboot || info "Reboot skipped."
