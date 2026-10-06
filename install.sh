#!/usr/bin/env bash
#
# Install, upgrade or uninstall diskwarden. Safe to run any number of times:
# a run with nothing to change changes nothing.
#
#   sudo ./install.sh              install, or upgrade an existing installation
#   sudo ./install.sh --uninstall  stop and remove everything except the
#                                  config directory /etc/diskwarden
#
# Where the program goes is read from the config file:
#   PROGRAM_DIR   directory of the executable  (default /usr/libexec/diskwarden)
#   COMMAND_LINK  symlink for the admin command (default /usr/sbin/diskwarden)
# After changing either, run ./install.sh again; the old copy is removed.
#
# Upgrade rules:
#   - The existing config is never modified. The config is validated with the
#     NEW program before anything is installed; if it is not valid, nothing
#     changes. The new example config is written next to it as
#     diskwarden.conf.new (only when it differs), and settings that are new in
#     this version are listed.
#   - Files are replaced only when their content changes. The service is
#     restarted only if it is running and the program or unit changed.
#   - Files of an older installation that are no longer needed (e.g. after
#     moving PROGRAM_DIR, or the version 1 layout in /etc) are removed.
#
set -euo pipefail

SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")/diskwarden" && pwd)
CONF_DIR=/etc/diskwarden
CONF=$CONF_DIR/diskwarden.conf
UNIT=/etc/systemd/system/diskwarden.service
SERVICE=diskwarden.service
DOC_DIR=/usr/share/doc/diskwarden
STATE_DIR=/var/lib/diskwarden
MANIFEST=$STATE_DIR/installed-files
OLD_MANIFEST=$CONF_DIR/.installed-files     # location used by version 2.0

((EUID == 0)) || { echo "run as root" >&2; exit 1; }

# Only one installer at a time.
exec 8>/run/diskwarden-install.lock
flock -n 8 || { echo "another install.sh is running" >&2; exit 1; }

say() { printf '%s\n' "$@"; }
CHANGED=()   # human-readable list of changes made in this run

# The manifest lists what the installer created, one "TYPE PATH" per line
# (TYPE: file, link, dir). Directories are removed only when empty.
read_manifest() {
    local f
    for f in "$MANIFEST" "$OLD_MANIFEST"; do
        [[ -f $f ]] || continue
        while IFS= read -r line; do
            [[ -n $line ]] || continue
            # 2.0 manifests hold bare paths.
            if [[ $line != @(file|link|dir)\ * ]]; then
                if [[ -L $line ]]; then line="link $line"
                elif [[ -d $line ]]; then line="dir $line"
                else line="file $line"; fi
            fi
            printf '%s\n' "$line"
        done < "$f"
    done | sort -u
}

# Remove manifest entries ($1: newline list) - files and links first, then
# directories deepest first, and only if empty.
remove_entries() {
    local type path
    while read -r type path; do
        [[ -n $path ]] || continue
        case $type in
            file|link)
                if [[ -e $path || -L $path ]]; then
                    rm -f -- "$path"; CHANGED+=("removed $path")
                fi ;;
        esac
    done <<< "$1"
    while read -r type path; do
        [[ $type == dir && -d $path ]] || continue
        if rmdir -- "$path" 2>/dev/null; then CHANGED+=("removed $path/"); fi
    done < <(grep '^dir ' <<< "$1" | awk '{ print length($0) " " $0 }' | sort -rn | cut -d' ' -f2-)
}

# ensure_dir PATH: create PATH (and parents); record every directory created.
NEW_DIRS=()
ensure_dir() {
    local d=$1 missing=()
    while [[ $d != / && ! -d $d ]]; do
        missing+=("$d"); d=$(dirname -- "$d")
    done
    ((${#missing[@]})) || return 0
    install -d -m 0755 -- "$1"
    local i
    for ((i = ${#missing[@]} - 1; i >= 0; i--)); do
        NEW_DIRS+=("${missing[i]}"); CHANGED+=("created ${missing[i]}/")
    done
}

# put_file SRC DEST MODE: install only if content or mode differ.
# Returns 0 if the file was (re)written.
put_file() {
    local src=$1 dest=$2 mode=$3
    if [[ -f $dest && ! -L $dest ]] && cmp -s -- "$src" "$dest" \
        && [[ $(stat -c %a -- "$dest") == "${mode#0}" ]]; then
        return 1
    fi
    ensure_dir "$(dirname -- "$dest")"
    local tmp
    tmp=$(mktemp -- "$dest.XXXXXX")
    cat -- "$src" > "$tmp"
    chmod "$mode" -- "$tmp"
    mv -f -- "$tmp" "$dest"
    CHANGED+=("installed $dest")
    return 0
}

if [[ ${1:-} == --uninstall ]]; then
    if [[ -e $UNIT ]] || systemctl is-enabled --quiet "$SERVICE" 2>/dev/null; then
        systemctl disable --now "$SERVICE" 2>/dev/null || true
    fi
    remove_entries "$(read_manifest)"
    if [[ -e $UNIT ]]; then
        rm -f -- "$UNIT"; CHANGED+=("removed $UNIT")
        systemctl daemon-reload || true
    fi
    rm -f -- "$MANIFEST" "$OLD_MANIFEST"
    rmdir -- "$STATE_DIR" 2>/dev/null || true
    if ((${#CHANGED[@]})); then
        printf '  %s\n' "${CHANGED[@]}"
        say "diskwarden removed. Config left in $CONF_DIR (delete it manually if unwanted)."
    else
        say "diskwarden is not installed; nothing to do."
    fi
    exit 0
fi

NEW_VERSION=$(bash "$SRC/diskwarden.sh" --version | awk '{ print $2 }')

# --- 1. config ---------------------------------------------------------------
install -d -m 0755 "$CONF_DIR"
FRESH=0
if [[ ! -e $CONF ]]; then
    install -m 0644 "$SRC/diskwarden.conf" "$CONF"
    CHANGED+=("installed example config $CONF")
    FRESH=1
else
    if cmp -s "$SRC/diskwarden.conf" "$CONF"; then
        rm -f -- "$CONF.new"
    elif ! cmp -s "$SRC/diskwarden.conf" "$CONF.new" 2>/dev/null; then
        install -m 0644 "$SRC/diskwarden.conf" "$CONF.new"
        CHANGED+=("wrote new example config $CONF.new")
    fi
fi

# Validate the (existing) config with the NEW program before touching
# anything else.
if ! bash "$SRC/diskwarden.sh" --config "$CONF" --check >/dev/null; then
    say "" "$CONF is not valid for diskwarden $NEW_VERSION (errors above)." \
        "Nothing was installed. Fix the config (compare with $CONF.new) and run $0 again." >&2
    exit 1
fi

get() { bash "$SRC/diskwarden.sh" --config "$CONF" --get "$1"; }
PROGRAM_DIR=$(get PROGRAM_DIR)
COMMAND_LINK=$(get COMMAND_LINK)
PROGRAM=$PROGRAM_DIR/diskwarden.sh

OLD_ENTRIES=$(read_manifest)
OLD_PROGRAM=$(awk '$1 == "file" && $2 ~ /\/diskwarden\.sh$/ { print $2; exit }' <<< "$OLD_ENTRIES")
[[ -z $OLD_PROGRAM && -f $CONF_DIR/diskwarden.sh ]] && OLD_PROGRAM=$CONF_DIR/diskwarden.sh
OLD_VERSION=""
[[ -n $OLD_PROGRAM && -f $OLD_PROGRAM ]] \
    && OLD_VERSION=$(bash "$OLD_PROGRAM" --version 2>/dev/null | awk '{ print $2 }')

# Settings in the new example that the existing config does not mention.
NEW_KEYS=()
if ((!FRESH)); then
    while read -r key; do
        grep -Eq "^[[:space:]]*$key[[:space:]]*=" "$CONF" || NEW_KEYS+=("$key")
    done < <(grep -Eo '^[#;]?[A-Z_]+=' "$SRC/diskwarden.conf" | tr -d '#;=' | sort -u)
fi

# --- 2. program, docs, command link, unit ------------------------------------
PROGRAM_CHANGED=0
put_file "$SRC/diskwarden.sh" "$PROGRAM" 0755 && PROGRAM_CHANGED=1
put_file "$SRC/README.md" "$DOC_DIR/README.md" 0644 || true

if [[ -n $COMMAND_LINK ]]; then
    if [[ $(readlink -- "$COMMAND_LINK" 2>/dev/null) != "$PROGRAM" ]]; then
        if [[ -e $COMMAND_LINK && ! -L $COMMAND_LINK ]]; then
            say "$COMMAND_LINK exists and is not a symlink; refusing to replace it." >&2
            exit 1
        fi
        ensure_dir "$(dirname -- "$COMMAND_LINK")"
        ln -sfn -- "$PROGRAM" "$COMMAND_LINK"
        CHANGED+=("linked $COMMAND_LINK -> $PROGRAM")
    fi
fi

UNIT_CHANGED=0
unit_tmp=$(mktemp)
trap 'rm -f -- "$unit_tmp"' EXIT
sed "s#@PROGRAM@#$PROGRAM#g" "$SRC/diskwarden.service.in" > "$unit_tmp"
put_file "$unit_tmp" "$UNIT" 0644 && UNIT_CHANGED=1

# --- 3. manifest and cleanup of the previous installation --------------------
NEW_ENTRIES=$(
    {
        printf 'file %s\n' "$PROGRAM" "$DOC_DIR/README.md"
        [[ -n $COMMAND_LINK ]] && printf 'link %s\n' "$COMMAND_LINK"
        for d in "${NEW_DIRS[@]}"; do printf 'dir %s\n' "$d"; done
        # Keep directories created earlier that still hold our files.
        while read -r type path; do
            [[ $type == dir ]] || continue
            for f in "$PROGRAM" "$DOC_DIR/README.md" "$COMMAND_LINK"; do
                [[ -n $f && $f == "$path"/* ]] && { printf 'dir %s\n' "$path"; break; }
            done
        done <<< "$OLD_ENTRIES"
    } | sort -u
)
# Everything recorded before but not needed now (plus the version 1 layout).
STALE=$(comm -23 <(printf '%s\n' "$OLD_ENTRIES" | sed '/^$/d' | sort -u) \
                 <(printf '%s\n' "$NEW_ENTRIES" | sort -u))
for f in "$CONF_DIR/diskwarden.sh" "$CONF_DIR/README.md"; do
    [[ -e $f && $f != "$PROGRAM" ]] && STALE+=$'\n'"file $f"
done
remove_entries "$STALE"

install -d -m 0755 "$STATE_DIR"
if [[ ! -f $MANIFEST ]] || [[ $(< "$MANIFEST") != "$NEW_ENTRIES" ]]; then
    printf '%s\n' "$NEW_ENTRIES" > "$MANIFEST"
fi
rm -f -- "$OLD_MANIFEST"

# --- 4. SELinux labels, systemd ----------------------------------------------
if command -v restorecon >/dev/null; then
    restorecon -R "$CONF_DIR" "$PROGRAM_DIR" "$DOC_DIR" "$UNIT" ${COMMAND_LINK:+"$COMMAND_LINK"} || true
fi
((UNIT_CHANGED)) && systemctl daemon-reload
if ((PROGRAM_CHANGED || UNIT_CHANGED)) && systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
    systemctl restart "$SERVICE"
    CHANGED+=("restarted $SERVICE")
fi

# --- 5. report ---------------------------------------------------------------
cmd=${COMMAND_LINK:-$PROGRAM}
if [[ -z $OLD_VERSION ]]; then
    say "diskwarden $NEW_VERSION installed."
elif [[ $OLD_VERSION != "$NEW_VERSION" ]]; then
    say "diskwarden upgraded: $OLD_VERSION -> $NEW_VERSION."
elif ((${#CHANGED[@]})); then
    say "diskwarden $NEW_VERSION updated."
else
    say "diskwarden $NEW_VERSION is already installed and up to date; nothing changed."
fi
((${#CHANGED[@]})) && printf '  %s\n' "${CHANGED[@]}"

if ((${#NEW_KEYS[@]})) && [[ -n $OLD_VERSION && $OLD_VERSION != "$NEW_VERSION" ]]; then
    say "" "Settings available in this version that $CONF does not set" \
        "(their built-in defaults apply; see $CONF.new):"
    printf '  %s\n' "${NEW_KEYS[@]}"
fi

if [[ -z $OLD_VERSION ]]; then
    cat <<EOF

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
fi
