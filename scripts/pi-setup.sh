#!/usr/bin/env bash
# First-time setup on a Raspberry Pi, typed at the Pi's own keyboard:
#
#   git clone https://github.com/Viv-411/OpenCourt.git
#   OpenCourt/scripts/pi-setup.sh
#
# It changes two things, both needed to run the Pi from the Mac over the home network:
#   1. turns on SSH (remote login);
#   2. lets in the Mac's key (below), so logging in needs no password.
# It also reports the board and whether the OS can run the detector (it must be 64-bit).
#
# The key is the *public* half of the key on the development Mac. Publishing it grants
# nothing: logging in also needs the private half, which never leaves the Mac. To take the
# access away again, delete the line ending "opencourt-mac" from ~/.ssh/authorized_keys.
set -euo pipefail

MAC_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAjDOrAY9eS+hYaxBh9wxTKxO40dBEF4bprGK8JEw5kz opencourt-mac"

if [ "$(uname -s)" != "Linux" ]; then
    echo "Run this on the Raspberry Pi, not on this computer."
    exit 1
fi

model="$( (tr -d '\0' < /proc/device-tree/model) 2>/dev/null || echo "unknown board")"
os="$( (. /etc/os-release && echo "$PRETTY_NAME") 2>/dev/null || echo "unknown OS")"
bits="$(getconf LONG_BIT 2>/dev/null || echo "?")"
ram_mb="$(awk '/MemTotal/ {print int($2 / 1024)}' /proc/meminfo)"
disk_gb="$(df -Pm "$HOME" | awk 'NR == 2 {print int($4 / 1024)}')"

echo "== this Pi =="
echo "board : $model"
echo "OS    : $os, ${bits}-bit programs"
echo "memory: ${ram_mb} MB, disk: ${disk_gb} GB free"

echo
echo "== turning on SSH =="
if command -v raspi-config >/dev/null; then
    sudo raspi-config nonint do_ssh 0      # 0 means "enable" in raspi-config's scripting mode
else
    sudo systemctl enable --now ssh
fi
echo "SSH is on."

echo
echo "== letting the Mac in =="
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
touch "$HOME/.ssh/authorized_keys"
if grep -qF "$MAC_KEY" "$HOME/.ssh/authorized_keys"; then
    echo "The Mac's key was already there."
else
    echo "$MAC_KEY" >> "$HOME/.ssh/authorized_keys"
    echo "Added the Mac's key."
fi
chmod 600 "$HOME/.ssh/authorized_keys"

echo
echo "== can it run the detector? =="
if [ "$bits" = "64" ]; then
    echo "Yes: the OS is 64-bit."
else
    echo "Not yet: the OS is 32-bit, and the detector needs 64-bit."
    case "$model" in
        *"Pi 5"* | *"Pi 4"* | *"Pi 400"*)
            echo "This board can reinstall itself with no other computer (Network Install):"
            echo "  plug in an Ethernet cable, switch off, then hold Shift while switching on."
            echo "  Choose Raspberry Pi OS Lite (64-bit) and this SD card. It erases the card." ;;
        *"Pi 3"* | *"Zero 2"*)
            echo "This board supports 64-bit, but reinstalling needs the SD card in another"
            echo "computer: a USB SD card reader for the Mac (about \$10) does it." ;;
        *)
            echo "This board can't run a 64-bit OS at all. The test needs newer hardware." ;;
    esac
fi

addr="$(hostname -I 2>/dev/null | awk '{print $1}')"
echo
echo "== tell Claude this line =="
echo "$(whoami)@${addr:-NO-NETWORK}   (or $(whoami)@$(hostname).local)"
[ -z "$addr" ] && echo "No network yet: connect Wi-Fi (top-right icon) or an Ethernet cable, then run this again."
exit 0
