#!/usr/bin/env bash
#
# Install, upgrade or uninstall diskwarden.
#
#   sudo ./install.sh              install or upgrade (keeps an existing config)
#   sudo ./install.sh --uninstall  stop and remove everything except the
#                                  config directory /etc/diskwarden
#
# Where the program goes is read from the config file:
#   PROGRAM_DIR   directory of the executable  (default /usr/libexec/diskwarden)
#   COMMAND_LINK  symlink for the admin command (default /usr/sbin/diskwarden)
# After changing either, run ./install.sh again; the old copy is removed.
#
set -euo pipefail

SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")/diskwarden" && pwd)
CONF_DIR=/etc/diskwarden
CONF=$CONF_DIR/diskwarden.conf
UNIT=/etc/systemd/system/diskwarden.service
DOC_DIR=/usr/share/doc/diskwarden
MANIFEST=$CONF_DIR/.installed-files

((EUID == 0)) || { echo "run as root" >&2; exit 1; }

# Remove the files recorded by a previous installation.
remove_previous() {
    local f
    [[ -f $MANIFEST ]] || return 0
    while IFS= read -r f; do
        [[ -n $f ]] || continue
        if [[ -d $f && ! -L $f ]]; then
            rmdir --ignore-fail-on-non-empty -- "$f"
        else
            rm -f -- "$f"
        fi
    done < <(tac "$MANIFEST")
    rm -f -- "$MANIFEST"
}

if [[ ${1:-} == --uninstall ]]; then
    systemctl disable --now diskwarden.service 2>/dev/null || true
    remove_previous
    rm -f -- "$UNIT"
    systemctl daemon-reload
    echo "diskwarden removed. Config left in $CONF_DIR (delete it manually if unwanted)."
    exit 0
fi

# Config first: it decides where the program goes.
install -d -m 0755 "$CONF_DIR"
if [[ -e $CONF ]]; then
    install -m 0644 "$SRC/diskwarden.conf" "$CONF.new"
    echo "Existing $CONF kept; new example written to $CONF.new"
else
    install -m 0644 "$SRC/diskwarden.conf" "$CONF"
fi

get() { bash "$SRC/diskwarden.sh" --config "$CONF" --get "$1"; }
if ! PROGRAM_DIR=$(get PROGRAM_DIR) || ! COMMAND_LINK=$(get COMMAND_LINK); then
    echo "Fix $CONF (see errors above) and run $0 again." >&2
    exit 1
fi
PROGRAM=$PROGRAM_DIR/diskwarden.sh

was_active=0
systemctl is-active --quiet diskwarden.service 2>/dev/null && was_active=1

remove_previous
# Files of version 1, which kept the program in /etc/diskwarden.
rm -f -- "$CONF_DIR/diskwarden.sh" "$CONF_DIR/README.md"

install -d -m 0755 "$PROGRAM_DIR" "$DOC_DIR"
install -m 0755 "$SRC/diskwarden.sh" "$PROGRAM"
install -m 0644 "$SRC/README.md" "$DOC_DIR/README.md"
{
    echo "$PROGRAM_DIR"
    echo "$PROGRAM"
    echo "$DOC_DIR"
    echo "$DOC_DIR/README.md"
} > "$MANIFEST"
if [[ -n $COMMAND_LINK ]]; then
    install -d -m 0755 "$(dirname "$COMMAND_LINK")"
    ln -sfn "$PROGRAM" "$COMMAND_LINK"
    echo "$COMMAND_LINK" >> "$MANIFEST"
fi

sed "s#@PROGRAM@#$PROGRAM#g" "$SRC/diskwarden.service.in" > "$UNIT"
chmod 0644 "$UNIT"

if command -v restorecon >/dev/null; then
    restorecon -R "$CONF_DIR" "$PROGRAM_DIR" "$DOC_DIR" "$UNIT" ${COMMAND_LINK:+"$COMMAND_LINK"}
fi
systemctl daemon-reload
((was_active)) && systemctl restart diskwarden.service

cmd=${COMMAND_LINK:-$PROGRAM}
cat <<EOF
diskwarden installed:
  program : $PROGRAM
  command : ${COMMAND_LINK:-(no link; use $PROGRAM)}
  config  : $CONF
  unit    : $UNIT
  docs    : $DOC_DIR/README.md

Next steps:
  1. Edit $CONF (find UUIDs with: lsblk -o NAME,SIZE,FSTYPE,UUID)
  2. Check it:   $cmd --check
  3. Start it:   systemctl enable --now diskwarden
  4. Status:     $cmd --status
  5. Logs:       journalctl -u diskwarden -f
EOF
