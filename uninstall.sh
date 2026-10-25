#!/bin/bash
# Removes the daemon and its pf rules. Run with sudo.
set -uo pipefail
[[ $EUID -eq 0 ]] || { echo "run as root: sudo ./uninstall.sh" >&2; exit 1; }
launchctl bootout system/local.rs-nest 2>/dev/null
pfctl -a rs-nest -F all 2>/dev/null
rm -f /Library/LaunchDaemons/local.rs-nest.plist /usr/local/sbin/rs-nest.sh
rm -rf "/Library/Application Support/rs-nest"
echo "removed; Red Shield's own pf ruleset is restored on its next (re)connect"
