#!/usr/bin/env bash
#
# diskwarden - watch for configured disks, mount them on arrival, and unmount
#              them when the user deletes the "mounted" flag file.
#
# Lifecycle of every configured disk:
#
#   disk connected      -> mounted at MOUNT_POINT, MOUNTED flag file created
#   MOUNTED flag deleted -> disk unmounted, SAFE flag file created
#                           (name carries its creation time, removed after
#                           SAFE_FLAG_TTL seconds)
#   disk disconnected   -> ready to be mounted again on next connection
#
# All settings live in /etc/diskwarden/diskwarden.conf (see that file).
#
# Usage: diskwarden.sh [--config FILE] [--check] [--help] [--version]
#
set -uo pipefail
shopt -s nullglob

readonly PROG=diskwarden
readonly VERSION=1.0.0

CONF_FILE=${DISKWARDEN_CONF:-/etc/diskwarden/diskwarden.conf}
LOCK_FILE=${DISKWARDEN_LOCK:-/run/diskwarden.lock}
# Where udev publishes UUID symlinks. Overridable for testing only.
BY_UUID_DIR=${DISKWARDEN_BY_UUID_DIR:-/dev/disk/by-uuid}

# ---------------------------------------------------------------------------
# Logging. Under systemd, stderr goes to the journal and the <N> prefix sets
# the syslog priority (see sd-daemon(3)). On a terminal, print plain text.
# ---------------------------------------------------------------------------
if [[ -n ${JOURNAL_STREAM:-} ]]; then
    log()  { printf '<6>%s\n' "$*" >&2; }
    warn() { printf '<4>WARNING: %s\n' "$*" >&2; }
    err()  { printf '<3>ERROR: %s\n' "$*" >&2; }
else
    log()  { printf '%s %s: %s\n' "$(date '+%F %T')" "$PROG" "$*" >&2; }
    warn() { printf '%s %s: WARNING: %s\n' "$(date '+%F %T')" "$PROG" "$*" >&2; }
    err()  { printf '%s %s: ERROR: %s\n' "$(date '+%F %T')" "$PROG" "$*" >&2; }
fi

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# Keys allowed only in [global].
GLOBAL_ONLY_KEYS=(POLL_INTERVAL)

# Keys allowed in [mount NAME]; may also be set in [global] as defaults.
# Value is the built-in default ("" = no default).
declare -A MOUNT_KEY_DEFAULTS=(
    [UUID]=""
    [MOUNT_POINT]=""
    [FS_TYPE]="auto"
    [MOUNT_OPTIONS]="defaults"
    [CREATE_MOUNT_POINT]="yes"
    [MOUNTED_FLAG_DIR]="/run/diskwarden"
    [MOUNTED_FLAG_NAME]="%NAME%.MOUNTED"
    [SAFE_FLAG_DIR]="/run/diskwarden"
    [SAFE_FLAG_NAME]="%NAME%.SAFE_TO_DISCONNECT.%TS%"
    [SAFE_FLAG_TTL]="300"
    [TIMESTAMP_FORMAT]="%Y-%m-%d_%H-%M-%S"
    [FLAG_OWNER]=""
    [FLAG_MODE]="0664"
    [FLAG_DIR_MODE]="0775"
    [UMOUNT_RETRIES]="3"
)

declare -A GLOBAL_KEY_DEFAULTS=(
    [POLL_INTERVAL]="2"
)

# Parser output (raw, per section): P["section|KEY"]=value ; PM=(mount names)
declare -A P=()
declare -a PM=()
# Active, validated configuration: R["mount|KEY"]=value ; MOUNTS=(names)
declare -A R=()
declare -a MOUNTS=()
POLL_INTERVAL=2

is_global_only_key() {
    local k
    for k in "${GLOBAL_ONLY_KEYS[@]}"; do [[ $k == "$1" ]] && return 0; done
    return 1
}

# Parse the INI-like config file into P / PM. The file is parsed, never
# sourced, so it cannot execute code.
parse_config() {
    local file=$1 line lineno=0 section=global key value
    P=(); PM=()

    if [[ ! -r $file ]]; then
        err "cannot read config file $file"
        return 1
    fi

    while IFS= read -r line || [[ -n $line ]]; do
        ((lineno++))
        line=${line%$'\r'}
        line="${line#"${line%%[![:space:]]*}"}"   # ltrim
        line="${line%"${line##*[![:space:]]}"}"   # rtrim
        [[ -z $line || $line == '#'* || $line == ';'* ]] && continue

        if [[ $line =~ ^\[[[:space:]]*global[[:space:]]*\]$ ]]; then
            section=global
            continue
        fi
        if [[ $line =~ ^\[[[:space:]]*mount[[:space:]]+([A-Za-z0-9_-]+)[[:space:]]*\]$ ]]; then
            section=${BASH_REMATCH[1]}
            if [[ $section == global ]]; then
                err "$file:$lineno: 'global' cannot be used as a mount name"
                return 1
            fi
            local m
            for m in "${PM[@]}"; do
                if [[ $m == "$section" ]]; then
                    err "$file:$lineno: duplicate section [mount $section]"
                    return 1
                fi
            done
            PM+=("$section")
            continue
        fi
        if [[ $line =~ ^([A-Z_]+)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
            key=${BASH_REMATCH[1]}
            value=${BASH_REMATCH[2]}
            # Strip one pair of matching surrounding quotes.
            if [[ $value =~ ^\"(.*)\"$ || $value =~ ^\'(.*)\'$ ]]; then
                value=${BASH_REMATCH[1]}
            fi
            if is_global_only_key "$key"; then
                if [[ $section != global ]]; then
                    err "$file:$lineno: $key is only allowed in [global]"
                    return 1
                fi
            elif [[ ! -v MOUNT_KEY_DEFAULTS[$key] ]]; then
                err "$file:$lineno: unknown setting '$key'"
                return 1
            fi
            P["$section|$key"]=$value
            continue
        fi

        err "$file:$lineno: cannot parse line: $line"
        return 1
    done < "$file"

    if ((${#PM[@]} == 0)); then
        err "$file: no [mount NAME] sections defined"
        return 1
    fi
}

# Build and validate the effective config from P / PM. On success replace
# R / MOUNTS / POLL_INTERVAL; on failure leave the active config untouched.
resolve_config() {
    local -A NR=()
    local m k v errors=0 poll
    poll=${P["global|POLL_INTERVAL"]-${GLOBAL_KEY_DEFAULTS[POLL_INTERVAL]}}
    if [[ ! $poll =~ ^[0-9]+(\.[0-9]+)?$ ]] || [[ $poll =~ ^0+(\.0+)?$ ]]; then
        err "POLL_INTERVAL must be a positive number (got '$poll')"
        ((errors++))
    fi

    local -A seen_uuid=() seen_mp=() seen_flag=() safe_globs=()
    for m in "${PM[@]}"; do
        for k in "${!MOUNT_KEY_DEFAULTS[@]}"; do
            if [[ -v P["$m|$k"] ]]; then
                v=${P["$m|$k"]}
            elif [[ -v P["global|$k"] ]]; then
                v=${P["global|$k"]}
            else
                v=${MOUNT_KEY_DEFAULTS[$k]}
            fi
            # Placeholders usable in names and directories.
            case $k in
                MOUNTED_FLAG_NAME|SAFE_FLAG_NAME|MOUNTED_FLAG_DIR|SAFE_FLAG_DIR|MOUNT_POINT)
                    v=${v//%NAME%/$m}
                    v=${v//%UUID%/${P["$m|UUID"]-}}
                    ;;
            esac
            NR["$m|$k"]=$v
        done

        local pre="[mount $m]"
        local uuid=${NR["$m|UUID"]} mp=${NR["$m|MOUNT_POINT"]}

        if [[ -z $uuid ]]; then
            err "$pre UUID is required"; ((errors++))
        elif [[ ! $uuid =~ ^[A-Za-z0-9-]+$ ]]; then
            err "$pre UUID '$uuid' contains invalid characters"; ((errors++))
        elif [[ -v seen_uuid[$uuid] ]]; then
            err "$pre UUID $uuid already used by [mount ${seen_uuid[$uuid]}]"; ((errors++))
        else
            seen_uuid[$uuid]=$m
        fi

        mp=${mp%/}
        NR["$m|MOUNT_POINT"]=$mp
        if [[ -z $mp ]]; then
            err "$pre MOUNT_POINT is required and must not be /"; ((errors++))
        elif [[ $mp != /* ]]; then
            err "$pre MOUNT_POINT must be an absolute path"; ((errors++))
        elif [[ -v seen_mp[$mp] ]]; then
            err "$pre MOUNT_POINT $mp already used by [mount ${seen_mp[$mp]}]"; ((errors++))
        else
            seen_mp[$mp]=$m
        fi

        for k in MOUNTED_FLAG_DIR SAFE_FLAG_DIR; do
            v=${NR["$m|$k"]%/}
            [[ -z $v ]] && v=/
            NR["$m|$k"]=$v
            if [[ $v != /* ]]; then
                err "$pre $k must be an absolute path"; ((errors++))
            fi
        done
        local sdir=${NR["$m|SAFE_FLAG_DIR"]}
        if [[ -n $mp && ( $sdir == "$mp" || $sdir == "$mp"/* ) ]]; then
            err "$pre SAFE_FLAG_DIR must not be on the disk itself (inside $mp)"; ((errors++))
        fi

        for k in MOUNTED_FLAG_NAME SAFE_FLAG_NAME; do
            v=${NR["$m|$k"]}
            if [[ -z $v || $v == */* || $v == . || $v == .. ]]; then
                err "$pre $k must be a plain file name"; ((errors++))
            elif [[ $v == *[\*\?\[\]]* ]]; then
                err "$pre $k must not contain * ? [ ]"; ((errors++))
            fi
        done
        if [[ ${NR["$m|MOUNTED_FLAG_NAME"]} == *%TS%* ]]; then
            err "$pre MOUNTED_FLAG_NAME must not contain %TS%"; ((errors++))
        fi
        v=${NR["$m|SAFE_FLAG_NAME"]}
        if [[ $v != *%TS%* || ${v#*%TS%} == *%TS%* ]]; then
            err "$pre SAFE_FLAG_NAME must contain the %TS% placeholder exactly once"; ((errors++))
        fi

        local ts
        ts=$(printf "%(${NR["$m|TIMESTAMP_FORMAT"]})T" -1)
        if [[ -z $ts || $ts == */* ]]; then
            err "$pre TIMESTAMP_FORMAT must produce a non-empty string without '/'"; ((errors++))
        fi

        for k in SAFE_FLAG_TTL UMOUNT_RETRIES; do
            if [[ ! ${NR["$m|$k"]} =~ ^[0-9]+$ ]]; then
                err "$pre $k must be a non-negative integer"; ((errors++))
            fi
        done
        for k in FLAG_MODE FLAG_DIR_MODE; do
            if [[ ! ${NR["$m|$k"]} =~ ^[0-7]{3,4}$ ]]; then
                err "$pre $k must be an octal mode like 0664"; ((errors++))
            fi
        done
        case ${NR["$m|CREATE_MOUNT_POINT"],,} in
            yes|no|true|false|1|0) ;;
            *) err "$pre CREATE_MOUNT_POINT must be yes or no"; ((errors++)) ;;
        esac
        if [[ -n ${NR["$m|FLAG_OWNER"]} && ! ${NR["$m|FLAG_OWNER"]} =~ ^[A-Za-z0-9_.][A-Za-z0-9_.-]*\$?(:[A-Za-z0-9_.][A-Za-z0-9_.-]*\$?)?$ ]]; then
            err "$pre FLAG_OWNER must be 'user' or 'user:group'"; ((errors++))
        fi

        # Flag files of different mounts must not collide.
        local mflag=${NR["$m|MOUNTED_FLAG_DIR"]}/${NR["$m|MOUNTED_FLAG_NAME"]}
        local sflag=${NR["$m|SAFE_FLAG_DIR"]}/${NR["$m|SAFE_FLAG_NAME"]}
        if [[ -v seen_flag[$mflag] ]]; then
            err "$pre flag file $mflag collides with [mount ${seen_flag[$mflag]}]"; ((errors++))
        else
            seen_flag[$mflag]=$m
        fi
        safe_globs[$m]=${sflag//%TS%/*}
    done

    # A safe-flag pattern must never match a mounted flag (expiry deletes
    # whatever matches it), nor another mount's safe-flag pattern.
    local g f o
    for m in "${!safe_globs[@]}"; do
        g=${safe_globs[$m]}
        for f in "${!seen_flag[@]}"; do
            # shellcheck disable=SC2053  # $g is intentionally a pattern
            if [[ $f == $g ]]; then
                err "[mount $m] SAFE_FLAG_NAME pattern $g matches mounted flag $f"; ((errors++))
            fi
        done
        for o in "${!safe_globs[@]}"; do
            [[ $o == "$m" ]] && continue
            # shellcheck disable=SC2053
            if [[ ${safe_globs[$o]} == $g ]]; then
                err "[mount $m] SAFE_FLAG_NAME pattern $g overlaps with [mount $o]"; ((errors++))
            fi
        done
    done

    ((errors == 0)) || return 1

    R=()
    for k in "${!NR[@]}"; do R[$k]=${NR[$k]}; done
    MOUNTS=("${PM[@]}")
    POLL_INTERVAL=$poll
}

load_config() {
    parse_config "$CONF_FILE" && resolve_config
}

print_config() {
    local m
    printf 'Config file   : %s\n' "$CONF_FILE"
    printf 'Poll interval : %ss\n' "$POLL_INTERVAL"
    for m in "${MOUNTS[@]}"; do
        printf '\n[mount %s]\n' "$m"
        printf '  device        : %s/%s\n' "$BY_UUID_DIR" "${R["$m|UUID"]}"
        printf '  mount point   : %s (type %s, options %s)\n' \
            "${R["$m|MOUNT_POINT"]}" "${R["$m|FS_TYPE"]}" "${R["$m|MOUNT_OPTIONS"]}"
        printf '  mounted flag  : %s\n' "$(mounted_flag "$m")"
        printf '  safe flag     : %s/%s (kept %ss)\n' \
            "${R["$m|SAFE_FLAG_DIR"]}" "${R["$m|SAFE_FLAG_NAME"]}" "${R["$m|SAFE_FLAG_TTL"]}"
    done
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

is_yes() { [[ ${1,,} == @(yes|true|1) ]]; }

mounted_flag() { printf '%s/%s' "${R["$1|MOUNTED_FLAG_DIR"]}" "${R["$1|MOUNTED_FLAG_NAME"]}"; }

device_path() { printf '%s/%s' "$BY_UUID_DIR" "${R["$1|UUID"]}"; }

# Print the source device of the topmost mount on $1 (empty if none).
mount_source() {
    findmnt -rn -o SOURCE --mountpoint "$1" 2>/dev/null | tail -n 1
}

# True if the disk of mount $1 is currently mounted on its mount point.
is_mounted_here() {
    local m=$1 dev src
    dev=$(readlink -f "$(device_path "$m")") || return 1
    src=$(mount_source "${R["$m|MOUNT_POINT"]}")
    [[ -n $src && $(readlink -f "$src") == "$dev" ]]
}

# Ensure directory $2 exists; apply owner/mode of mount $1 only if we create it.
ensure_dir() {
    local m=$1 dir=$2
    [[ -d $dir ]] && return 0
    if ! mkdir -p -- "$dir"; then
        err "[$m] cannot create directory $dir"
        return 1
    fi
    chmod "${R["$m|FLAG_DIR_MODE"]}" -- "$dir" 2>/dev/null \
        || warn "[$m] cannot chmod $dir"
    if [[ -n ${R["$m|FLAG_OWNER"]} ]]; then
        chown "${R["$m|FLAG_OWNER"]}" -- "$dir" 2>/dev/null \
            || warn "[$m] cannot chown $dir to ${R["$m|FLAG_OWNER"]}"
    fi
}

# write_flag MOUNT PATH TEXT
write_flag() {
    local m=$1 path=$2 text=$3
    ensure_dir "$m" "${path%/*}" || return 1
    if ! printf '%s\n' "$text" > "$path"; then
        err "[$m] cannot write flag file $path"
        return 1
    fi
    chmod "${R["$m|FLAG_MODE"]}" -- "$path" 2>/dev/null \
        || warn "[$m] cannot chmod $path (filesystem may not support it)"
    if [[ -n ${R["$m|FLAG_OWNER"]} ]]; then
        chown "${R["$m|FLAG_OWNER"]}" -- "$path" 2>/dev/null \
            || warn "[$m] cannot chown $path (filesystem may not support it)"
    fi
}

create_mounted_flag() {
    local m=$1 note=${2:-}
    local text
    text="Disk '$m' (UUID ${R["$m|UUID"]}) is MOUNTED at ${R["$m|MOUNT_POINT"]}
Mounted since: $(date '+%F %T %Z')

Delete this file to unmount the disk safely.
When unmounting has finished, a file named like
  ${R["$m|SAFE_FLAG_DIR"]}/${R["$m|SAFE_FLAG_NAME"]}
appears; the disk can then be disconnected."
    [[ -n $note ]] && text+=$'\n\n'"$note"
    write_flag "$m" "$(mounted_flag "$m")" "$text"
}

# List existing SAFE flag files of mount $1 into the array SAFE_FILES.
list_safe_flags() {
    local name=${R["$1|SAFE_FLAG_NAME"]} dir=${R["$1|SAFE_FLAG_DIR"]}
    SAFE_FILES=("$dir/${name%%%TS%*}"*"${name#*%TS%}")
}

create_safe_flag() {
    local m=$1 now ts name path ttl=${R["$1|SAFE_FLAG_TTL"]}
    now=$(date +%s)
    ts=$(printf "%(${R["$m|TIMESTAMP_FORMAT"]})T" "$now")
    name=${R["$m|SAFE_FLAG_NAME"]//%TS%/$ts}
    path=${R["$m|SAFE_FLAG_DIR"]}/$name
    write_flag "$m" "$path" \
"Disk '$m' (UUID ${R["$m|UUID"]}) was UNMOUNTED from ${R["$m|MOUNT_POINT"]}
Unmounted at: $(date -d "@$now" '+%F %T %Z')

It is now SAFE TO DISCONNECT the disk.
This notice is removed automatically at $(date -d "@$((now + ttl))" '+%F %T %Z')." \
        && log "[$m] safe-to-disconnect flag created: $path (expires in ${ttl}s)"
}

remove_safe_flags() {
    local m=$1 f
    list_safe_flags "$m"
    for f in "${SAFE_FILES[@]}"; do
        [[ -f $f ]] && rm -f -- "$f" && log "[$m] removed old safe flag $f"
    done
}

# Delete SAFE flags older than their TTL (based on file modification time).
expire_safe_flags() {
    local m=$1 f mtime now ttl=${R["$1|SAFE_FLAG_TTL"]}
    now=$(date +%s)
    list_safe_flags "$m"
    for f in "${SAFE_FILES[@]}"; do
        [[ -f $f ]] || continue
        mtime=$(stat -c %Y -- "$f" 2>/dev/null) || continue
        if ((now - mtime >= ttl)); then
            rm -f -- "$f" && log "[$m] safe flag expired, removed $f"
        fi
    done
}

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

declare -A STATE=()   # mount -> absent | mounted | released | failed

do_mount() {
    local m=$1 dev mp=${R["$1|MOUNT_POINT"]} out other
    dev=$(readlink -f "$(device_path "$m")")
    log "[$m] disk UUID ${R["$m|UUID"]} detected ($dev)"

    # Let udev finish probing the new device before mounting it.
    command -v udevadm >/dev/null && udevadm settle --timeout=10 2>/dev/null

    if [[ ! -d $mp ]]; then
        if is_yes "${R["$m|CREATE_MOUNT_POINT"]}"; then
            if ! mkdir -p -- "$mp"; then
                err "[$m] cannot create mount point $mp"
                STATE[$m]=failed
                return 1
            fi
        else
            err "[$m] mount point $mp does not exist (CREATE_MOUNT_POINT=no)"
            STATE[$m]=failed
            return 1
        fi
    fi

    if [[ -n $(mount_source "$mp") ]]; then
        err "[$m] $mp is already used by another mount ($(mount_source "$mp")); not mounting"
        STATE[$m]=failed
        return 1
    fi

    other=$(findmnt -rn -o TARGET --source "$dev" 2>/dev/null | head -n 1)
    if [[ -n $other ]]; then
        warn "[$m] $dev is also mounted at $other (desktop automounter?)"
    fi

    local -a cmd=(mount)
    [[ ${R["$m|FS_TYPE"]} != auto ]] && cmd+=(-t "${R["$m|FS_TYPE"]}")
    cmd+=(-o "${R["$m|MOUNT_OPTIONS"]}" -- "$dev" "$mp")

    if ! out=$("${cmd[@]}" 2>&1); then
        err "[$m] mount failed: ${out:-unknown error} (will retry when the disk is reconnected or the service restarts)"
        STATE[$m]=failed
        return 1
    fi

    remove_safe_flags "$m"
    create_mounted_flag "$m"
    STATE[$m]=mounted
    log "[$m] mounted $dev at $mp; delete $(mounted_flag "$m") to unmount"
}

do_unmount() {
    local m=$1 mp=${R["$1|MOUNT_POINT"]} out i tries=${R["$1|UMOUNT_RETRIES"]}
    log "[$m] mounted flag removed, unmounting $mp"
    sync -f -- "$mp" 2>/dev/null || sync

    for ((i = 0; i <= tries; i++)); do
        ((i > 0)) && sleep 1
        if out=$(umount -- "$mp" 2>&1); then
            STATE[$m]=released
            log "[$m] unmounted $mp"
            create_safe_flag "$m"
            return 0
        fi
    done

    local users=""
    if command -v fuser >/dev/null; then
        users=$(fuser -vm "$mp" 2>&1 | tail -n +2)
    fi
    err "[$m] unmount of $mp failed: ${out:-unknown error}"
    [[ -n $users ]] && err "[$m] processes using $mp:"$'\n'"$users"
    # Put the flag back so the user sees the disk is still mounted and can
    # retry by deleting it again.
    create_mounted_flag "$m" "LAST UNMOUNT ATTEMPT FAILED at $(date '+%F %T'): ${out:-unknown error}
Close all programs using ${R["$m|MOUNT_POINT"]} and delete this file again.
${users:+Processes using the disk:
$users}"
}

# One poll step for mount $1.
process_mount() {
    local m=$1 present=0 here=0 mflag
    mflag=$(mounted_flag "$m")
    [[ -e $(device_path "$m") ]] && present=1
    ((present)) && is_mounted_here "$m" && here=1

    # udev may briefly drop the by-uuid link (e.g. while re-probing). If our
    # mount's block device itself still exists, the disk is still there.
    if ((!present)) && [[ ${STATE[$m]:-} == mounted ]]; then
        local src
        src=$(mount_source "${R["$m|MOUNT_POINT"]}")
        if [[ -n $src && -b $src ]]; then
            present=1 here=1
        fi
    fi

    case ${STATE[$m]:-absent} in
        absent)
            if ((here)); then
                log "[$m] already mounted at ${R["$m|MOUNT_POINT"]}, taking over"
                [[ -e $mflag ]] || create_mounted_flag "$m"
                STATE[$m]=mounted
            elif ((present)); then
                do_mount "$m"
            fi
            ;;
        mounted)
            if ((!present)); then
                warn "[$m] disk disappeared while mounted (unplugged without unmounting?)"
                if [[ -n $(mount_source "${R["$m|MOUNT_POINT"]}") ]]; then
                    umount -l -- "${R["$m|MOUNT_POINT"]}" 2>/dev/null \
                        && log "[$m] lazily unmounted stale ${R["$m|MOUNT_POINT"]}"
                fi
                rm -f -- "$mflag"
                STATE[$m]=absent
            elif ((!here)); then
                log "[$m] ${R["$m|MOUNT_POINT"]} was unmounted externally"
                rm -f -- "$mflag"
                STATE[$m]=released
                create_safe_flag "$m"
            elif [[ ! -e $mflag ]]; then
                do_unmount "$m"
            fi
            ;;
        released|failed)
            # Do not remount until the disk has been disconnected.
            if ((!present)); then
                log "[$m] disk disconnected"
                STATE[$m]=absent
            elif ((here)); then
                log "[$m] mounted externally at ${R["$m|MOUNT_POINT"]}, taking over"
                remove_safe_flags "$m"
                create_mounted_flag "$m"
                STATE[$m]=mounted
            fi
            ;;
    esac

    expire_safe_flags "$m"
}

# Remove MOUNTED flags left behind by a previous run for disks not mounted now.
startup_cleanup() {
    local m
    for m in "${MOUNTS[@]}"; do
        if ! is_mounted_here "$m" && [[ -e $(mounted_flag "$m") ]]; then
            rm -f -- "$(mounted_flag "$m")"
            log "[$m] removed stale mounted flag $(mounted_flag "$m")"
        fi
    done
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

usage() {
    cat <<EOF
$PROG $VERSION - mount configured disks on arrival, unmount on flag removal

Usage: $0 [options]
  -c, --config FILE   use FILE instead of $CONF_FILE
      --check         validate the config, print it, and exit
  -h, --help          show this help
  -V, --version       show version
EOF
}

RELOAD=0
RUNNING=1

main() {
    local check=0
    while (($#)); do
        case $1 in
            -c|--config) CONF_FILE=${2:?--config needs a file}; shift ;;
            --check) check=1 ;;
            -h|--help) usage; exit 0 ;;
            -V|--version) echo "$PROG $VERSION"; exit 0 ;;
            *) usage >&2; exit 2 ;;
        esac
        shift
    done

    if ((check)); then
        load_config || exit 1
        print_config
        exit 0
    fi

    if ((EUID != 0)); then
        err "must run as root"
        exit 1
    fi

    local cmd
    for cmd in findmnt mount umount readlink stat flock; do
        command -v "$cmd" >/dev/null || { err "required command '$cmd' not found"; exit 1; }
    done

    load_config || exit 1

    exec 9>"$LOCK_FILE" || { err "cannot open lock file $LOCK_FILE"; exit 1; }
    if ! flock -n 9; then
        err "another instance is already running (lock $LOCK_FILE)"
        exit 1
    fi

    trap 'RELOAD=1' HUP
    trap 'RUNNING=0' TERM INT

    log "$PROG $VERSION started: ${#MOUNTS[@]} mount(s) from $CONF_FILE, polling every ${POLL_INTERVAL}s"
    startup_cleanup

    local m
    while ((RUNNING)); do
        if ((RELOAD)); then
            RELOAD=0
            if load_config; then
                log "configuration reloaded: ${#MOUNTS[@]} mount(s)"
            else
                err "configuration reload failed, keeping previous configuration"
            fi
        fi
        for m in "${MOUNTS[@]}"; do
            process_mount "$m"
        done
        # Sleep in the background so signals are handled immediately.
        sleep "$POLL_INTERVAL" &
        wait $! 2>/dev/null
    done

    log "$PROG stopping (mounted disks stay mounted)"
}

main "$@"
