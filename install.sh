#!/usr/bin/env bash
#
# Install or uninstall diskwarden.
#
#   sudo ./install.sh              install (keeps an existing config)
#   sudo ./install.sh --uninstall  stop, disable and remove the service
#                                  (the config directory is left in place)
#
set -euo pipefail

SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")/diskwarden" && pwd)
DEST=/etc/diskwarden
UNIT=/etc/systemd/system/diskwarden.service

((EUID == 0)) || { echo "run as root" >&2; exit 1; }

if [[ ${1:-} == --uninstall ]]; then
    systemctl disable --now diskwarden.service 2>/dev/null || true
    rm -f "$UNIT"
    systemctl daemon-reload
    echo "diskwarden service removed. Config left in $DEST (delete it manually if unwanted)."
    exit 0
fi

install -d -m 0755 "$DEST"
install -m 0755 "$SRC/diskwarden.sh" "$DEST/diskwarden.sh"
install -m 0644 "$SRC/README.md" "$DEST/README.md"
if [[ -e $DEST/diskwarden.conf ]]; then
    install -m 0644 "$SRC/diskwarden.conf" "$DEST/diskwarden.conf.new"
    echo "Existing $DEST/diskwarden.conf kept; new example written to diskwarden.conf.new"
else
    install -m 0644 "$SRC/diskwarden.conf" "$DEST/diskwarden.conf"
fi
install -m 0644 "$SRC/diskwarden.service" "$UNIT"

command -v restorecon >/dev/null && restorecon -R "$DEST" "$UNIT"
systemctl daemon-reload

cat <<EOF
diskwarden installed to $DEST.

Next steps:
  1. Edit $DEST/diskwarden.conf (find UUIDs with: lsblk -o NAME,SIZE,FSTYPE,UUID)
  2. Check it:   $DEST/diskwarden.sh --check
  3. Start it:   systemctl enable --now diskwarden
  4. Watch it:   journalctl -u diskwarden -f
EOF
