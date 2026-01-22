# Fedora 43 Quick Setup Script 🚀

This script automates the initial setup and configuration of Fedora 41/42/43, simplifying system optimization, customization, productivity improvements, and visual enhancements, resulting in a clean, efficient, and fully-featured Linux environment.

---

## 🚩 Quick Start

Clone or download the script, then execute:

```bash
cd ~/Downloads  
chmod +x fedora-setup.sh  
./fedora-setup.sh | tee fedora-install-log.txt  
```

- Logs of the installation process will be saved to `fedora-install-log.txt`.

---

## ⚙️ Features & Components

### System Optimization
- DNF Package Manager enhancements:
  - Faster mirrors  
  - Increased parallel downloads  
  - Delta RPMs enabled  
  - Caching enabled for performance boosts

### System Cleanup
- Removes unnecessary pre-installed applications:
  - Evince, Rhythmbox, ABRT, GNOME Tour, Fedora Media Writer

### Repositories and Firmware Updates
- Enables RPM Fusion repositories (free and non-free)  
- Firmware updates via `fwupd`

### Utilities & Essentials
- Installs essential tools:
  - Snap package manager, OpenSSL, curl, cabextract, and more  
- Installs and enables Cockpit:
  - A powerful web-based interface for managing system services, monitoring performance, and administering your Fedora machine remotely  
  - Cockpit is enabled to start on boot and accessible via HTTPS on port 9090

### GNOME Tweaks and UX Improvements
- GNOME Extensions and Tweaks for advanced customization  
- Configures font rendering and file chooser behavior  
- Optimizes window management shortcuts and behaviors

### Font Installation and Configuration
- Installs comprehensive open-source and Microsoft fonts  
- Optimized FontConfig settings for improved readability

### Productivity Suite
- Applications installed include Thunderbird, FileZilla, Flatseal, and additional Flatpak apps:  
  - GNOME Secrets, Amberol, PikaBackup, Blanket, Iconic, and more

### A.I. Tools
- Ollama: User-friendly and powerful software for running LLMs locally  
- Alpaca: Local and online AI GUI

### Web and Development Tools
- Google Chrome web browser  
- Visual Studio Code (official Microsoft repository)

### Visual Enhancements
- Powerline fonts and Meslo Nerd Fonts for advanced terminal customization

---

## 📋 Requirements

- Fedora 41 or 42 Workstation  
- Internet connection

---

## ⚠️ Recommendations

- Backup important data before running the script  
- Review the script to ensure it meets your requirements  
- After installation, reboot your system for all changes to take full effect

---

## 🖥️ Tested Environment

- Fedora Workstation 41/42 & 43
- GNOME Desktop Environment

---

## 🤝 Contributions & Issues

Feel free to report issues, request new features, or submit pull requests to improve this script.

---

**Enjoy your optimized Fedora experience! 🎉**
