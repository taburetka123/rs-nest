#!/bin/bash
# Installs rs-nest as a root LaunchDaemon. Run with sudo.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run as root: sudo ./install.sh" >&2; exit 1; }
cd "$(dirname "$0")"
mkdir -p /usr/local/sbin "/Library/Application Support/rs-nest"
chmod 755 "/Library/Application Support/rs-nest"
install -o root -g wheel -m 755 rs-nest.sh /usr/local/sbin/rs-nest.sh
install -o root -g wheel -m 644 local.rs-nest.plist /Library/LaunchDaemons/local.rs-nest.plist
launchctl bootout system/local.rs-nest 2>/dev/null || true
launchctl bootstrap system /Library/LaunchDaemons/local.rs-nest.plist
launchctl print system/local.rs-nest | grep -E 'state =|pid ='
echo "installed; log: /Library/Application Support/rs-nest/rs-nest.log"
