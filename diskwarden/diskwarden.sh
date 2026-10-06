#!/usr/bin/env bash
#
# diskwarden - watch for configured disks, mount them on arrival, and unmount
#              them when the user deletes the "mounted" flag file.
#
# Lifecycle of every configured disk:
#
#   disk connected       -> optional fsck, mounted at MOUNT_POINT,
#                           MOUNTED flag file created
#   MOUNTED flag deleted -> disk unmounted, SAFE flag file created
#                           (name carries its creation time, removed after
#                           SAFE_FLAG_TTL seconds)
#   disk disconnected    -> ready to be mounted again on next connection
#
# If the filesystem cannot be checked or mounted (unsupported type, fsck
# errors, mount errors) a WARNING flag file explains why.
#
# All settings live in /etc/diskwarden/diskwarden.conf (see that file).
#
set -uo pipefail
shopt -s nullglob extglob

readonly PROG=diskwarden
readonly VERSION=2.1.0

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

# Keys allowed only in [global], with their defaults.
declare -A GLOBAL_KEY_DEFAULTS=(
    [POLL_INTERVAL]="2"
    [CONTROL_DIR]="/run/diskwarden/control"
    [PROGRAM_DIR]="/usr/libexec/diskwarden"
    [COMMAND_LINK]="/usr/sbin/diskwarden"
)

# Keys allowed in [mount NAME]; may also be set in [global] as defaults.
declare -A MOUNT_KEY_DEFAULTS=(
    [UUID]=""
    [MOUNT_POINT]=""
    [FS_TYPE]="auto"
    [MOUNT_OPTIONS]="defaults"
    [CREATE_MOUNT_POINT]="yes"
    [UMOUNT_RETRIES]="3"
    [FSCK]="no"
    [FSCK_OPTIONS]="-p"
    [FSCK_UNSUPPORTED_ACTION]="mount"
    [MOUNTED_FLAG_DIR]="/run/diskwarden/flags"
    [MOUNTED_WORD]="MOUNTED"
    [SAFE_WORD]="SAFE_TO_DISCONNECT"
    [WARNING_WORD]="WARNING"
    [MOUNTED_FLAG_NAME]="%NAME%.%STATUS%"
    [SAFE_FLAG_DIR]="/run/diskwarden/flags"
    [SAFE_FLAG_NAME]="%NAME%.%STATUS%.%TS%"
    [SAFE_FLAG_TTL]="300"
    [WARNING_FLAG_DIR]="/run/diskwarden/flags"
    [WARNING_FLAG_NAME]="%NAME%.%STATUS%"
    [WARNING_FLAG_TTL]="0"
    [TIMESTAMP_FORMAT]="%Y-%m-%d_%H-%M-%S"
    [FLAG_OWNER]=""
    [FLAG_MODE]="0664"
    [FLAG_DIR_MODE]="0775"
    [ON_MOUNT]=""
    [ON_UNMOUNT]=""
    [ON_DISCONNECT]=""
    [ON_WARNING]=""
    [ON_ERROR]=""
    [HOOK_TIMEOUT]="60"
    [AUDIT_LOG]=""
    [AUDIT_JOURNAL_IDENTIFIER]="smbd_audit"
)

# Parser output (raw, per section): P["section|KEY"]=value ; PM=(mount names)
declare -A P=()
declare -a PM=()
# Active, validated configuration: R["mount|KEY"]=value, R["global|KEY"]
declare -A R=()
declare -a MOUNTS=()

# Parse the INI-like config file into P / PM. The file is parsed, never
# sourced, so it cannot execute code.
parse_config() {
    local file=$1 line lineno=0 section=global key value m
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
            if [[ -v GLOBAL_KEY_DEFAULTS[$key] ]]; then
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

# Is path $1 equal to or inside directory $2?
path_within() { [[ $1 == "$2" || $1 == "$2"/* ]]; }

# Build and validate the effective config from P / PM. On success replace
# R / MOUNTS; on failure leave the active config untouched.
resolve_config() {
    local -A NR=()
    local m k v errors=0

    for k in "${!GLOBAL_KEY_DEFAULTS[@]}"; do
        NR["global|$k"]=${P["global|$k"]-${GLOBAL_KEY_DEFAULTS[$k]}}
    done
    v=${NR["global|POLL_INTERVAL"]}
    if [[ ! $v =~ ^[0-9]+(\.[0-9]+)?$ ]] || [[ $v =~ ^0+(\.0+)?$ ]]; then
        err "POLL_INTERVAL must be a positive number (got '$v')"; ((errors++))
    fi
    for k in CONTROL_DIR PROGRAM_DIR; do
        v=${NR["global|$k"]%/}
        NR["global|$k"]=$v
        if [[ $v != /?* ]]; then
            err "$k must be an absolute path other than /"; ((errors++))
        fi
    done
    v=${NR["global|COMMAND_LINK"]}
    if [[ -n $v && ( $v != /* || $v == */ ) ]]; then
        err "COMMAND_LINK must be empty or an absolute file path"; ((errors++))
    fi
    local ctl=${NR["global|CONTROL_DIR"]}

    local -A seen_uuid=() seen_mp=()
    # Every flag file (literal path) and flag pattern (with * for %TS%),
    # used to make sure no pattern can match another mount's / type's flag.
    local -A flag_owner=()
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
                *_FLAG_NAME|*_FLAG_DIR|*_WORD|MOUNT_POINT)
                    v=${v//%NAME%/$m}
                    v=${v//%UUID%/${P["$m|UUID"]-}}
                    ;;
            esac
            NR["$m|$k"]=$v
        done

        local pre="[mount $m]"
        local uuid=${NR["$m|UUID"]} mp=${NR["$m|MOUNT_POINT"]%/}
        NR["$m|MOUNT_POINT"]=$mp

        if [[ -z $uuid ]]; then
            err "$pre UUID is required"; ((errors++))
        elif [[ ! $uuid =~ ^[A-Za-z0-9-]+$ ]]; then
            err "$pre UUID '$uuid' contains invalid characters"; ((errors++))
        elif [[ -v seen_uuid[$uuid] ]]; then
            err "$pre UUID $uuid already used by [mount ${seen_uuid[$uuid]}]"; ((errors++))
        else
            seen_uuid[$uuid]=$m
        fi

        if [[ -z $mp ]]; then
            err "$pre MOUNT_POINT is required and must not be /"; ((errors++))
        elif [[ $mp != /* ]]; then
            err "$pre MOUNT_POINT must be an absolute path"; ((errors++))
        elif [[ -v seen_mp[$mp] ]]; then
            err "$pre MOUNT_POINT $mp already used by [mount ${seen_mp[$mp]}]"; ((errors++))
        else
            seen_mp[$mp]=$m
        fi

        local t
        for t in MOUNTED SAFE WARNING; do
            v=${NR["$m|${t}_FLAG_DIR"]%/}
            [[ -z $v ]] && v=/
            NR["$m|${t}_FLAG_DIR"]=$v
            if [[ $v != /* ]]; then
                err "$pre ${t}_FLAG_DIR must be an absolute path"; ((errors++))
            elif path_within "$v" "$ctl" || path_within "$ctl" "$v"; then
                err "$pre ${t}_FLAG_DIR must not overlap CONTROL_DIR $ctl"; ((errors++))
            fi
            if [[ $t != MOUNTED && -n $mp ]] && path_within "$v" "$mp"; then
                err "$pre ${t}_FLAG_DIR must not be on the disk itself (inside $mp)"; ((errors++))
            fi

            # %STATUS% = the user-facing word of this flag type.
            v=${NR["$m|${t}_WORD"]}
            if [[ -z $v || $v == */* || $v == *[%\*\?\[\]]* ]]; then
                err "$pre ${t}_WORD must be non-empty and must not contain / % * ? [ ]"; ((errors++))
            fi
            v=${NR["$m|${t}_FLAG_NAME"]//%STATUS%/$v}
            NR["$m|${t}_FLAG_NAME"]=$v
            if [[ -z $v || $v == */* || $v == . || $v == .. || $v == .diskwarden.* ]]; then
                err "$pre ${t}_FLAG_NAME must be a plain file name"; ((errors++))
            elif [[ $v == *[\*\?\[\]]* ]]; then
                err "$pre ${t}_FLAG_NAME must not contain * ? [ ]"; ((errors++))
            fi
            case $t in
                MOUNTED) [[ $v == *%TS%* ]] && { err "$pre MOUNTED_FLAG_NAME must not contain %TS%"; ((errors++)); } ;;
                SAFE)    [[ $v != *%TS%* ]] && { err "$pre SAFE_FLAG_NAME must contain %TS%"; ((errors++)); } ;;
            esac
            if [[ ${v#*%TS%} == *%TS%* ]]; then
                err "$pre ${t}_FLAG_NAME may contain %TS% only once"; ((errors++))
            fi
            v=${NR["$m|${t}_FLAG_DIR"]}/$v
            flag_owner[${v//%TS%/*}]="[mount $m] ${t} flag"
        done

        local ts
        ts=$(printf "%(${NR["$m|TIMESTAMP_FORMAT"]})T" -1)
        if [[ -z $ts || $ts == */* ]]; then
            err "$pre TIMESTAMP_FORMAT must produce a non-empty string without '/'"; ((errors++))
        fi

        for k in SAFE_FLAG_TTL WARNING_FLAG_TTL UMOUNT_RETRIES HOOK_TIMEOUT; do
            if [[ ! ${NR["$m|$k"]} =~ ^[0-9]+$ ]]; then
                err "$pre $k must be a non-negative integer"; ((errors++))
            fi
        done
        # No execute or special bits: flags are created through the umask.
        if [[ ! ${NR["$m|FLAG_MODE"]} =~ ^0?[0-6]{3}$ ]]; then
            err "$pre FLAG_MODE must be an octal mode without execute bits, like 0664"; ((errors++))
        fi
        if [[ ! ${NR["$m|FLAG_DIR_MODE"]} =~ ^[0-7]{3,4}$ ]]; then
            err "$pre FLAG_DIR_MODE must be an octal mode like 0775"; ((errors++))
        fi
        for k in CREATE_MOUNT_POINT FSCK; do
            case ${NR["$m|$k"],,} in
                yes|no|true|false|1|0) ;;
                *) err "$pre $k must be yes or no"; ((errors++)) ;;
            esac
        done
        v=${NR["$m|AUDIT_LOG"]}
        if [[ -n $v && $v != journal && $v != /* ]]; then
            err "$pre AUDIT_LOG must be empty, 'journal' or an absolute file path"; ((errors++))
        fi
        case ${NR["$m|FSCK_UNSUPPORTED_ACTION"],,} in
            mount|skip) ;;
            *) err "$pre FSCK_UNSUPPORTED_ACTION must be mount or skip"; ((errors++)) ;;
        esac
        if [[ -n ${NR["$m|FLAG_OWNER"]} && ! ${NR["$m|FLAG_OWNER"]} =~ ^[A-Za-z0-9_.][A-Za-z0-9_.-]*\$?(:[A-Za-z0-9_.][A-Za-z0-9_.-]*\$?)?$ ]]; then
            err "$pre FLAG_OWNER must be 'user' or 'user:group'"; ((errors++))
        fi
    done

    # A flag pattern must never match another flag (expiry and cleanup
    # delete whatever matches it).
    local a b
    for a in "${!flag_owner[@]}"; do
        for b in "${!flag_owner[@]}"; do
            [[ $a == "$b" ]] && continue
            # shellcheck disable=SC2053  # $a is intentionally a pattern
            if [[ $b == $a ]]; then
                err "${flag_owner[$a]} ($a) overlaps ${flag_owner[$b]} ($b)"; ((errors++))
            fi
        done
    done
    if ((${#flag_owner[@]} != ${#PM[@]} * 3)); then
        err "two flag files have the same path; give every flag of every mount its own name"
        ((errors++))
    fi

    ((errors == 0)) || return 1

    R=()
    for k in "${!NR[@]}"; do R[$k]=${NR[$k]}; done
    MOUNTS=("${PM[@]}")
}

load_config() {
    parse_config "$CONF_FILE" && resolve_config
}

print_config() {
    local m
    printf 'Config file   : %s\n' "$CONF_FILE"
    printf 'Poll interval : %ss\n' "${R["global|POLL_INTERVAL"]}"
    printf 'Program dir   : %s\n' "${R["global|PROGRAM_DIR"]}"
    printf 'Command link  : %s\n' "${R["global|COMMAND_LINK"]:-(none)}"
    printf 'Control dir   : %s\n' "${R["global|CONTROL_DIR"]}"
    for m in "${MOUNTS[@]}"; do
        printf '\n[mount %s]\n' "$m"
        printf '  device        : %s/%s\n' "$BY_UUID_DIR" "${R["$m|UUID"]}"
        printf '  mount point   : %s (type %s, options %s)\n' \
            "${R["$m|MOUNT_POINT"]}" "${R["$m|FS_TYPE"]}" "${R["$m|MOUNT_OPTIONS"]}"
        printf '  fsck          : %s' "${R["$m|FSCK"]}"
        is_yes "${R["$m|FSCK"]}" && printf ' (options %s, if unsupported: %s)' \
            "${R["$m|FSCK_OPTIONS"]}" "${R["$m|FSCK_UNSUPPORTED_ACTION"]}"
        printf '\n'
        printf '  mounted flag  : %s/%s\n' "${R["$m|MOUNTED_FLAG_DIR"]}" "${R["$m|MOUNTED_FLAG_NAME"]}"
        printf '  safe flag     : %s/%s (kept %ss)\n' \
            "${R["$m|SAFE_FLAG_DIR"]}" "${R["$m|SAFE_FLAG_NAME"]}" "${R["$m|SAFE_FLAG_TTL"]}"
        printf '  warning flag  : %s/%s (kept %s)\n' \
            "${R["$m|WARNING_FLAG_DIR"]}" "${R["$m|WARNING_FLAG_NAME"]}" \
            "$( ((${R["$m|WARNING_FLAG_TTL"]})) && echo "${R["$m|WARNING_FLAG_TTL"]}s" || echo "until disconnected")"
        [[ -n ${R["$m|AUDIT_LOG"]} ]] && printf '  who deleted   : from Samba audit log %s%s\n' "${R["$m|AUDIT_LOG"]}" \
            "$([[ ${R["$m|AUDIT_LOG"]} == journal ]] && echo " (identifier ${R["$m|AUDIT_JOURNAL_IDENTIFIER"]})")"
        local h
        for h in ON_MOUNT ON_UNMOUNT ON_DISCONNECT ON_WARNING ON_ERROR; do
            [[ -n ${R["$m|$h"]} ]] && printf '  %-13s : %s\n' "$h" "${R["$m|$h"]}"
        done
    done
    return 0
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

is_yes() { [[ ${1,,} == @(yes|true|1) ]]; }

device_path() { printf '%s/%s' "$BY_UUID_DIR" "${R["$1|UUID"]}"; }

# flag_path MOUNT TYPE [TIMESTAMP]  (TYPE: MOUNTED | SAFE | WARNING)
flag_path() {
    local name=${R["$1|${2}_FLAG_NAME"]}
    printf '%s/%s' "${R["$1|${2}_FLAG_DIR"]}" "${name//%TS%/${3:-}}"
}

# List existing flag files of MOUNT/TYPE into the array FLAG_FILES.
list_flags() {
    local name=${R["$1|${2}_FLAG_NAME"]} dir=${R["$1|${2}_FLAG_DIR"]}
    if [[ $name == *%TS%* ]]; then
        FLAG_FILES=("$dir/${name%%%TS%*}"*"${name#*%TS%}")
    else
        FLAG_FILES=()
        [[ -e $dir/$name || -L $dir/$name ]] && FLAG_FILES=("$dir/$name")
    fi
}

# Remove all flag files of MOUNT/TYPE.
remove_flags() {
    local m=$1 f
    list_flags "$m" "$2"
    for f in "${FLAG_FILES[@]}"; do
        rm -f -- "$f" && log "[$m] removed $f"
    done
}

# Remove flag files of MOUNT/TYPE older than TTL seconds (0 = never).
expire_flags() {
    local m=$1 type=$2 ttl=$3 f mtime now
    ((ttl > 0)) || return 0
    now=$(date +%s)
    list_flags "$m" "$type"
    for f in "${FLAG_FILES[@]}"; do
        mtime=$(stat -c %Y -- "$f" 2>/dev/null) || continue
        if ((now - mtime >= ttl)); then
            rm -f -- "$f" && log "[$m] ${type,,} flag expired, removed $f"
        fi
    done
}

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

# Ensure flag directory $2 exists and is not a symlink. Owner and mode of
# mount $1 are applied only if diskwarden creates the directory itself.
ensure_dir() {
    local m=$1 dir=$2
    if [[ -L $dir ]]; then
        err "[$m] refusing to use $dir: it is a symbolic link"
        return 1
    fi
    [[ -d $dir ]] && return 0
    if ! mkdir -p -- "$dir"; then
        err "[$m] cannot create directory $dir"
        return 1
    fi
    chmod "${R["$m|FLAG_DIR_MODE"]}" -- "$dir" 2>/dev/null \
        || warn "[$m] cannot chmod $dir"
    if [[ -n ${R["$m|FLAG_OWNER"]} ]]; then
        chown -h "${R["$m|FLAG_OWNER"]}" -- "$dir" 2>/dev/null \
            || warn "[$m] cannot chown $dir to ${R["$m|FLAG_OWNER"]}"
    fi
}

# write_flag MOUNT PATH TEXT
#
# Flag directories are normally writable by users, so this must never follow
# a symlink planted at PATH. The content goes to a new file with a random
# name created with O_EXCL (noclobber) and the configured mode (via umask),
# and is then renamed over PATH; rename replaces a symlink instead of
# writing through it.
write_flag() {
    local m=$1 path=$2 text=$3 dir tmp mode rc=0
    dir=${path%/*}
    ensure_dir "$m" "$dir" || return 1
    tmp=$(mktemp -u -p "$dir" .diskwarden.XXXXXXXXXX) || return 1
    mode=$((8#${R["$m|FLAG_MODE"]}))
    if ! ( umask "$(printf '%04o' $((0777 & ~mode)))"
           set -o noclobber
           printf '%s\n' "$text" > "$tmp" ) 2>/dev/null; then
        err "[$m] cannot create flag file in $dir"
        return 1
    fi
    if [[ -n ${R["$m|FLAG_OWNER"]} ]]; then
        chown -h "${R["$m|FLAG_OWNER"]}" -- "$tmp" 2>/dev/null \
            || warn "[$m] cannot chown $path (filesystem may not support it)"
    fi
    if ! mv -fT -- "$tmp" "$path" 2>/dev/null; then
        err "[$m] cannot create flag file $path"
        rc=1
    fi
    rm -f -- "$tmp"
    return $rc
}

# run_hook MOUNT EVENT MESSAGE  - run ON_<EVENT> in the background.
# Values are passed as environment variables, never substituted into the
# command, so they cannot inject shell code.
run_hook() {
    local m=$1 event=$2 msg=${3:-} cmd
    cmd=${R["$m|ON_$event"]}
    [[ -n $cmd ]] || return 0
    (
        export DISKWARDEN_EVENT=$event
        export DISKWARDEN_NAME=$m
        export DISKWARDEN_UUID=${R["$m|UUID"]}
        export DISKWARDEN_DEVICE
        DISKWARDEN_DEVICE=$(readlink -f "$(device_path "$m")" 2>/dev/null)
        export DISKWARDEN_MOUNT_POINT=${R["$m|MOUNT_POINT"]}
        export DISKWARDEN_MESSAGE=$msg
        export DISKWARDEN_REQUESTED_BY=${WHO[$m]:-}
        export DISKWARDEN_MOUNTED_FLAG
        DISKWARDEN_MOUNTED_FLAG=$(flag_path "$m" MOUNTED)
        local out rc
        out=$(timeout -k 5 "${R["$m|HOOK_TIMEOUT"]}" bash -c "$cmd" </dev/null 2>&1)
        rc=$?
        if ((rc == 0)); then
            log "[$m] ON_$event hook finished${out:+: $out}"
        elif ((rc == 124 || rc == 137)); then
            warn "[$m] ON_$event hook timed out after ${R["$m|HOOK_TIMEOUT"]}s${out:+: $out}"
        else
            warn "[$m] ON_$event hook failed (exit $rc)${out:+: $out}"
        fi
    ) 9>&- &
}

# ---------------------------------------------------------------------------
# Flag file reports
#
# Every flag file is a small report for the user who finds it on the share:
# a headline, what to do, the disk, its space, and every step diskwarden ran
# with exit codes and output.
# ---------------------------------------------------------------------------

declare -A STEPS=()    # mount -> steps of the operation in progress
declare -A MSTEPS=()   # mount -> steps of the last successful mount
declare -A DINFO=()    # mount -> disk details (taken when the disk is seen)
declare -A DFINFO=()   # mount -> space usage snapshot
declare -A WHO=()      # mount -> who requested the last unmount

readonly RULE_HEAVY="======================================================================"
readonly RULE_LIGHT="----------------------------------------------------------------------"

# Time stamp for %TS% (epoch $2) of mount $1.
timestamp() { printf "%(${R["$1|TIMESTAMP_FORMAT"]})T" "$2"; }

banner()  { printf '%s\n  %s\n%s\n' "$RULE_HEAVY" "$1" "$RULE_HEAVY"; }
section() { local t="--- $1 "; printf '\n%s%s\n' "$t" "${RULE_LIGHT:${#t}}"; }
kv()      { [[ -n $2 ]] && printf '  %-14s %s\n' "$1" "$2"; return 0; }
indent()  { sed 's/^/  /'; }
footer() {
    printf '\n%s\n  diskwarden %s on %s, file written %s\n' \
        "$RULE_LIGHT" "$VERSION" "${HOSTNAME:-localhost}" "$(date '+%F %T %Z')"
}

steps_reset() { STEPS[$1]=""; }

# step MOUNT DESCRIPTION [EXIT_CODE [MEANING [OUTPUT]]]
# Records one step for the flag files; output is limited to 15 lines.
step() {
    local m=$1 desc=$2 rc=${3-} meaning=${4-} out=${5-} s
    s="  $(date +%T)  $desc"$'\n'
    if [[ -n $rc ]]; then
        s+="            -> exit $rc${meaning:+  ($meaning)}"$'\n'
    elif [[ -n $meaning ]]; then
        s+="            -> $meaning"$'\n'
    fi
    if [[ -n $out ]]; then
        s+=$(head -n 15 <<< "$out" | sed 's/^/            | /')$'\n'
        (($(wc -l <<< "$out") > 15)) && s+="            | ... (truncated, see journalctl -u diskwarden)"$'\n'
    fi
    STEPS[$m]+=$s
}

# Collect disk details (type, label, size, model) while the device exists.
collect_disk_info() {
    local m=$1 dev=$2 type=$3 label="" size="" model="" pk=""
    label=$(blkid -p -o value -s LABEL -- "$dev" 2>/dev/null)
    if command -v lsblk >/dev/null; then
        size=$(lsblk -dno SIZE -- "$dev" 2>/dev/null | tr -d ' ')
        pk=$(lsblk -no PKNAME -- "$dev" 2>/dev/null | head -n 1 | tr -d ' ')
        [[ -n $pk ]] && model=$(lsblk -dno VENDOR,MODEL -- "/dev/$pk" 2>/dev/null | tr -s ' ' | sed 's/^ //; s/ $//')
    fi
    DINFO[$m]=$(
        kv "Name"        "$m"
        kv "UUID"        "${R["$m|UUID"]}"
        kv "Device"      "$dev"
        kv "Filesystem"  "${type:-unknown}${label:+, label \"$label\"}"
        kv "Size"        "$size"
        kv "Model"       "$model"
        kv "Mount point" "${R["$m|MOUNT_POINT"]}"
        kv "Options"     "${R["$m|MOUNT_OPTIONS"]}"
    )
}

# Snapshot of space usage on the mounted disk.
collect_df() {
    local m=$1 mp=${R["$1|MOUNT_POINT"]} size used avail pcent iused ipcent
    read -r size used avail pcent < <(df -h --output=size,used,avail,pcent -- "$mp" 2>/dev/null | tail -n 1)
    read -r iused ipcent < <(df --output=iused,ipcent -- "$mp" 2>/dev/null | tail -n 1)
    if [[ -z $size ]]; then
        DFINFO[$m]="  (not available)"
        return
    fi
    DFINFO[$m]=$(
        kv "Total"     "$size"
        kv "Used"      "$used ($pcent)"
        kv "Free"      "$avail"
        [[ $ipcent != - ]] && kv "Files/dirs" "$iused inodes used ($ipcent)"
        printf '  %s\n' "$(usage_bar "${pcent%\%}")"
    )
}

# usage_bar PERCENT -> [##########----------] 50 %
usage_bar() {
    local p=${1:-0} n bar=""
    [[ $p =~ ^[0-9]+$ ]] || p=0
    n=$((p * 40 / 100))
    printf -v bar '%*s' "$n" ''
    bar=${bar// /#}
    printf -v bar '%-40s' "$bar"
    printf '[%s] %s%% used' "${bar// /.}" "$p"
}

create_mounted_flag() {
    local m=$1 failure=${2:-} text safe_example
    safe_example=$(flag_path "$m" SAFE '<time>')
    text=$(
        banner "DISK \"$m\" IS MOUNTED - do not unplug it now"
        section "WHAT TO DO"
        printf '%s\n' \
            "  The disk is in use. Its files are at ${R["$m|MOUNT_POINT"]}." \
            "" \
            "  When you have finished, DELETE THIS FILE. The disk is then unmounted" \
            "  and a file named" \
            "      ${safe_example##*/}" \
            "  appears in ${safe_example%/*} (usually within seconds)." \
            "  Unplug the disk only after that file has appeared."
        if [[ -n $failure ]]; then
            section "LAST UNMOUNT ATTEMPT FAILED"
            printf '%s\n' "$failure" | indent
            printf '\n%s\n' "${STEPS[$m]}"
        fi
        section "DISK"
        printf '%s\n' "${DINFO[$m]}"
        section "SPACE (at mount time)"
        printf '%s\n' "${DFINFO[$m]}"
        section "WHAT DISKWARDEN DID TO MOUNT IT"
        printf '%s' "${MSTEPS[$m]:-  (disk was already mounted when diskwarden started)
}"
        footer
    )
    write_flag "$m" "$(flag_path "$m" MOUNTED)" "$text"
}

create_safe_flag() {
    local m=$1 now path text ttl=${R["$1|SAFE_FLAG_TTL"]}
    now=$(date +%s)
    path=$(flag_path "$m" SAFE "$(timestamp "$m" "$now")")
    text=$(
        banner "DISK \"$m\" IS UNMOUNTED - SAFE TO DISCONNECT"
        section "WHAT TO DO"
        printf '%s\n' \
            "  You can unplug the disk now." \
            "  To use it again, plug it in again; it is mounted automatically." \
            "" \
            "  This notice is removed at $(date -d "@$((now + ttl))" '+%F %T') (after ${ttl}s)."
        if [[ -n ${WHO[$m]:-} ]]; then
            section "UNMOUNT REQUESTED BY"
            printf '  %s\n' "${WHO[$m]}"
        fi
        section "DISK"
        printf '%s\n' "${DINFO[$m]}"
        section "SPACE (just before unmounting)"
        printf '%s\n' "${DFINFO[$m]}"
        section "WHAT DISKWARDEN DID TO UNMOUNT IT"
        printf '%s' "${STEPS[$m]}"
        footer
    )
    write_flag "$m" "$path" "$text" \
        && log "[$m] safe-to-disconnect flag created: $path (expires in ${ttl}s)"
}

# create_warning_flag MOUNT HEADLINE WHAT_HAPPENED WHAT_TO_DO
create_warning_flag() {
    local m=$1 headline=$2 what=$3 todo=$4 now path text ttl=${R["$1|WARNING_FLAG_TTL"]}
    now=$(date +%s)
    remove_flags "$m" WARNING
    path=$(flag_path "$m" WARNING "$(timestamp "$m" "$now")")
    text=$(
        banner "DISK \"$m\": $headline"
        section "WHAT HAPPENED"
        printf '%s\n' "$what" | fold -s -w 66 | sed "s/ *$//" | indent
        section "WHAT TO DO"
        printf '%s\n' "$todo" | fold -s -w 66 | sed "s/ *$//" | indent
        if ((ttl > 0)); then
            printf '\n  This notice is removed at %s.\n' "$(date -d "@$((now + ttl))" '+%F %T')"
        else
            printf '\n  This notice is removed when the disk is disconnected or mounted.\n'
        fi
        section "DISK"
        printf '%s\n' "${DINFO[$m]}"
        section "WHAT DISKWARDEN DID"
        printf '%s' "${STEPS[$m]}"
        footer
    )
    write_flag "$m" "$path" "$text" && log "[$m] warning flag created: $path"
}

# ---------------------------------------------------------------------------
# Who deleted the mounted flag? (optional, from Samba full_audit logs)
# ---------------------------------------------------------------------------

# find_requester MOUNT SINCE_EPOCH -> prints a description or nothing.
#
# Reads Samba "vfs objects = full_audit" records, e.g. with
#   full_audit:prefix = %u|%I|%m|%S   full_audit:success = unlinkat renameat
# a record looks like  alice|192.168.1.20|pc-alice|disks|unlinkat|ok|backup1_MOUNTED
find_requester() {
    local m=$1 since=$2 src=${R["$1|AUDIT_LOG"]} name lines line
    [[ -n $src ]] || return 0
    name=$(flag_path "$m" MOUNTED); name=${name##*/}

    if [[ $src == journal ]]; then
        command -v journalctl >/dev/null || return 0
        lines=$(journalctl -q --no-pager -o cat --since "@$since" \
                    -t "${R["$m|AUDIT_JOURNAL_IDENTIFIER"]}" 2>/dev/null)
    else
        [[ -r $src ]] || return 0
        lines=$(tail -n 5000 -- "$src" 2>/dev/null)
    fi

    line=$(grep -E "\|(unlink|unlinkat|rename|renameat)\|ok\|" <<< "$lines" \
           | grep -F -- "$name" | tail -n 1)
    [[ -n $line ]] || return 0
    line=${line#*: }                     # drop a syslog "host prog[pid]: " head

    local -a f; local i op=-1
    IFS='|' read -r -a f <<< "$line"
    for i in "${!f[@]}"; do
        [[ ${f[i]} == @(unlink|unlinkat|rename|renameat) ]] && { op=$i; break; }
    done
    if ((op == 4)); then                 # %u|%I|%m|%S
        printf 'user "%s" from %s (computer %s), share "%s"' "${f[0]}" "${f[1]}" "${f[2]}" "${f[3]}"
    elif ((op > 0)); then
        local IFS='|'
        printf '%s' "${f[*]:0:op}"
    fi
}

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

declare -A STATE=()    # mount -> absent | mounted | released | failed
declare -A SINCE=()    # mount -> epoch of last state change
declare -A LASTMSG=()  # mount -> last notable event
declare -A PRESENT=()  # mount -> 1 if the disk is connected
declare -A FLAG_SEEN=() # mount -> last epoch the mounted flag was seen

set_state() {
    local m=$1 s=$2
    if [[ ${STATE[$m]:-} != "$s" ]]; then
        STATE[$m]=$s
        SINCE[$m]=$(date +%s)
    fi
    [[ -n ${3:-} ]] && LASTMSG[$m]=$3
    return 0
}

# Something prevents mounting: log, warning flag, hook, state "failed".
# fail_mount MOUNT KIND(WARNING|ERROR) MESSAGE ADVICE
fail_mount() {
    local m=$1 kind=$2 msg=$3 advice=${4:-}
    if [[ $kind == WARNING ]]; then warn "[$m] $msg"; else err "[$m] $msg"; fi
    create_warning_flag "$m" "NOT MOUNTED" "$msg" \
        "${advice:+$advice

}The disk was NOT mounted and can be disconnected at any time."
    set_state "$m" failed "$msg"
    run_hook "$m" "$kind" "$msg"
}

# ---------------------------------------------------------------------------
# Filesystem support
# ---------------------------------------------------------------------------

# Filesystem type of mount $1 on device $2: configured, or detected.
detect_fstype() {
    local m=$1 dev=$2
    if [[ ${R["$m|FS_TYPE"]} != auto ]]; then
        printf '%s' "${R["$m|FS_TYPE"]}"
    else
        blkid -p -o value -s TYPE -- "$dev" 2>/dev/null
    fi
}

# Can this system mount filesystem type $1? (kernel driver loaded, module
# available, or a userspace mount helper such as mount.ntfs-3g installed)
# Sets FS_SUPPORT to a description of how.
fs_supported() {
    local type=$1 f
    FS_SUPPORT=""
    while read -r f; do
        [[ ${f##*[[:space:]]} == "$type" ]] && { FS_SUPPORT="kernel driver loaded"; return 0; }
    done < /proc/filesystems
    for f in /usr/sbin/mount."$type" /sbin/mount."$type"; do
        [[ -x $f ]] && { FS_SUPPORT="mount helper $f"; return 0; }
    done
    if command -v modprobe >/dev/null && modprobe -n -q -- "$type" 2>/dev/null; then
        FS_SUPPORT="kernel module available"
        return 0
    fi
    FS_SUPPORT="no kernel driver, module or mount helper"
    return 1
}

# Meaning of an fsck exit code (bit mask, see fsck(8)).
fsck_meaning() {
    local rc=$1 s=()
    ((rc == 0)) && { echo "no errors"; return; }
    ((rc & 1))   && s+=("errors corrected")
    ((rc & 2))   && s+=("system should be rebooted")
    ((rc & 4))   && s+=("errors left uncorrected")
    ((rc & 8))   && s+=("operational error")
    ((rc & 16))  && s+=("usage or syntax error")
    ((rc & 32))  && s+=("cancelled by user")
    ((rc & 128)) && s+=("shared library error")
    local IFS=','
    echo "${s[*]}" | sed 's/,/, /g'
}

# run_fsck MOUNT DEVICE FSTYPE ; returns 0 if mounting may proceed.
run_fsck() {
    local m=$1 dev=$2 type=$3 out rc msg
    local -a opts
    read -r -a opts <<< "${R["$m|FSCK_OPTIONS"]}"

    if ! command -v "fsck.$type" >/dev/null; then
        msg="Filesystem type '$type' cannot be checked: fsck.$type is not installed."
        step "$m" "look for fsck.$type" "" "not installed"
        if [[ ${R["$m|FSCK_UNSUPPORTED_ACTION"],,} == skip ]]; then
            fail_mount "$m" WARNING "$msg" \
                "Install the fsck tool for '$type', or set FSCK=no or FSCK_UNSUPPORTED_ACTION=mount for this disk."
            return 1
        fi
        warn "[$m] $msg Mounting without a check."
        step "$m" "skip the filesystem check" "" "FSCK_UNSUPPORTED_ACTION=mount"
        WARN_PENDING=("MOUNTED WITHOUT FILESYSTEM CHECK" "$msg
The disk was mounted anyway (FSCK_UNSUPPORTED_ACTION=mount) and can be used normally." \
            "Nothing, if you trust the disk. To have it checked, install the fsck tool for '$type'. To silence this notice, set FSCK=no for this disk.")
        LASTMSG[$m]="mounted without fsck (no fsck.$type)"
        run_hook "$m" WARNING "$msg"
        return 0
    fi

    log "[$m] checking filesystem: fsck ${opts[*]} -t $type $dev"
    out=$(fsck "${opts[@]}" -t "$type" "$dev" 2>&1)
    rc=$?
    step "$m" "fsck ${opts[*]} -t $type $dev" "$rc" "$(fsck_meaning "$rc")" "$out"
    case $rc in
        0) log "[$m] filesystem is clean" ;;
        1) warn "[$m] fsck corrected filesystem errors: $out"
           LASTMSG[$m]="fsck corrected errors" ;;
        *) fail_mount "$m" ERROR "The filesystem check failed: fsck exit code $rc ($(fsck_meaning "$rc"))." \
               "Have an administrator repair the filesystem (fsck -t $type $dev), then run 'diskwarden --mount $m' or reconnect the disk."
           return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

do_mount() {
    local m=$1 dev mp=${R["$1|MOUNT_POINT"]} out rc other type
    dev=$(readlink -f "$(device_path "$m")")
    log "[$m] disk UUID ${R["$m|UUID"]} detected ($dev)"
    steps_reset "$m"
    WARN_PENDING=()
    step "$m" "disk UUID ${R["$m|UUID"]} connected as $dev"

    # Let udev finish probing the new device before mounting it.
    command -v udevadm >/dev/null && udevadm settle --timeout=10 2>/dev/null

    type=$(detect_fstype "$m" "$dev")
    collect_disk_info "$m" "$dev" "$type"
    if [[ ${R["$m|FS_TYPE"]} == auto ]]; then
        step "$m" "blkid -p $dev (detect filesystem)" "" "${type:-no filesystem found}"
    fi
    if [[ -z $type ]]; then
        fail_mount "$m" WARNING "No recognisable filesystem was found on the disk ($dev)." \
            "The disk may be empty, encrypted or damaged. Check it on another computer or ask an administrator."
        return 1
    fi
    fs_supported "$type"; rc=$?
    step "$m" "check system support for '$type'" "" "$FS_SUPPORT"
    if ((rc != 0)); then
        fail_mount "$m" WARNING "This server cannot read the filesystem type '$type' ($FS_SUPPORT)." \
            "Ask an administrator to install support for '$type' (a kernel module or mount.$type helper), then reconnect the disk. Or reformat the disk with a supported filesystem such as ext4, xfs or exfat."
        return 1
    fi

    if [[ ! -d $mp ]]; then
        if ! is_yes "${R["$m|CREATE_MOUNT_POINT"]}"; then
            fail_mount "$m" ERROR "The mount point $mp does not exist (CREATE_MOUNT_POINT=no)." \
                "Ask an administrator to create $mp."
            return 1
        elif ! out=$(mkdir -p -- "$mp" 2>&1); then
            step "$m" "mkdir -p $mp" 1 "" "$out"
            fail_mount "$m" ERROR "The mount point $mp could not be created." "Ask an administrator."
            return 1
        fi
        step "$m" "mkdir -p $mp" 0
    fi

    if [[ -n $(mount_source "$mp") ]]; then
        fail_mount "$m" ERROR "$mp is already used by another mount ($(mount_source "$mp"))." \
            "Ask an administrator to unmount it."
        return 1
    fi

    other=$(findmnt -rn -o TARGET --source "$dev" 2>/dev/null | head -n 1)
    if [[ -n $other ]]; then
        warn "[$m] $dev is also mounted at $other (desktop automounter?)"
        step "$m" "note: $dev is also mounted at $other"
    fi

    # Clear warnings from an earlier attempt; fsck may create a new one.
    remove_flags "$m" WARNING
    LASTMSG[$m]=""

    if is_yes "${R["$m|FSCK"]}"; then
        run_fsck "$m" "$dev" "$type" || return 1
    else
        step "$m" "filesystem check" "" "disabled (FSCK=no)"
    fi

    local -a cmd=(mount)
    [[ ${R["$m|FS_TYPE"]} != auto ]] && cmd+=(-t "${R["$m|FS_TYPE"]}")
    cmd+=(-o "${R["$m|MOUNT_OPTIONS"]}" -- "$dev" "$mp")

    out=$("${cmd[@]}" 2>&1); rc=$?
    step "$m" "${cmd[*]}" "$rc" "$( ((rc == 0)) && echo "mounted" || echo "failed")" "$out"
    if ((rc != 0)); then
        if [[ $out == *"unknown filesystem type"* ]]; then
            fail_mount "$m" WARNING "This server cannot read the filesystem type '$type'." \
                "Ask an administrator to install support for '$type', then reconnect the disk. Or reformat the disk."
        else
            fail_mount "$m" ERROR "Mounting failed: ${out:-unknown error}" \
                "Reconnect the disk to try again. If the problem stays, ask an administrator (journalctl -u diskwarden)."
        fi
        return 1
    fi

    remove_flags "$m" SAFE
    collect_df "$m"
    MSTEPS[$m]=${STEPS[$m]}
    create_mounted_flag "$m"
    ((${#WARN_PENDING[@]})) && create_warning_flag "$m" "${WARN_PENDING[@]}"
    FLAG_SEEN[$m]=$(date +%s)
    set_state "$m" mounted "${LASTMSG[$m]:-mounted ($type)}"
    log "[$m] mounted $dev ($type) at $mp; delete $(flag_path "$m" MOUNTED) to unmount"
    run_hook "$m" MOUNT "mounted $dev at $mp"
}

# do_unmount MOUNT [REQUESTED_BY]
do_unmount() {
    local m=$1 by=${2:-} mp=${R["$1|MOUNT_POINT"]} out rc i tries=${R["$1|UMOUNT_RETRIES"]}
    steps_reset "$m"
    if [[ -z $by ]]; then
        step "$m" "mounted flag $(flag_path "$m" MOUNTED) was deleted"
    else
        step "$m" "unmount requested: $by"
    fi
    log "[$m] unmount requested${by:+ ($by)}, unmounting $mp"
    collect_df "$m"
    out=$(sync -f -- "$mp" 2>&1); rc=$?
    step "$m" "sync -f $mp (write cached data to the disk)" "$rc" "" "$out"

    for ((i = 0; i <= tries; i++)); do
        ((i > 0)) && sleep 1
        out=$(umount -- "$mp" 2>&1); rc=$?
        step "$m" "umount $mp (attempt $((i + 1)) of $((tries + 1)))" "$rc" \
            "$( ((rc == 0)) && echo "unmounted" || echo "failed")" "$out"
        ((rc == 0)) && break
    done

    if ((rc == 0)); then
        if [[ -z $by ]]; then
            # The audit record may reach the log a moment after the deletion.
            by=$(find_requester "$m" "$((${FLAG_SEEN[$m]:-$(date +%s)} - 2))")
            if [[ -z $by && -n ${R["$m|AUDIT_LOG"]} ]]; then
                sleep 1
                by=$(find_requester "$m" "$((${FLAG_SEEN[$m]:-$(date +%s)} - 2))")
            fi
            [[ -n ${R["$m|AUDIT_LOG"]} ]] && by=${by:-unknown (no matching Samba audit record; deleted locally?)}
            [[ -n $by ]] && by="$by - deleted the mounted flag"
        fi
        WHO[$m]=$by
        log "[$m] unmounted $mp${by:+; requested by $by}"
        set_state "$m" released "unmounted${by:+ (by ${by%% - *})}"
        create_safe_flag "$m"
        run_hook "$m" UNMOUNT "unmounted $mp"
        return 0
    fi

    local users=""
    if command -v fuser >/dev/null; then
        users=$(fuser -vm "$mp" 2>&1 | tail -n +2)
        step "$m" "fuser -vm $mp (who is using the disk)" "" "" "$users"
    fi
    err "[$m] unmount of $mp failed: ${out:-unknown error}"
    [[ -n $users ]] && err "[$m] processes using $mp:"$'\n'"$users"
    LASTMSG[$m]="unmount failed: ${out:-unknown error}"
    # Put the flag back so the user sees the disk is still mounted and can
    # retry by deleting it again.
    create_mounted_flag "$m" "At $(date '+%F %T') the disk could not be unmounted:
  ${out:-unknown error}
The disk is STILL MOUNTED - do not unplug it.
Close all programs and files that use ${R["$m|MOUNT_POINT"]},
then delete this file again."
    FLAG_SEEN[$m]=$(date +%s)
    run_hook "$m" ERROR "unmount of $mp failed: ${out:-unknown error}"
}

disk_gone() {
    local m=$1
    log "[$m] disk disconnected"
    remove_flags "$m" WARNING
    set_state "$m" absent "disconnected"
    run_hook "$m" DISCONNECT "disk disconnected"
}

# Take one pending request (mount/unmount) for mount $1, if any.
take_request() {
    local m=$1 ctl=${R["global|CONTROL_DIR"]} r
    REQUEST="" REQUEST_BY=""
    for r in mount unmount; do
        if [[ -e $ctl/$r.$m ]]; then
            REQUEST_BY=$(head -c 200 -- "$ctl/$r.$m" | tr -cd '[:print:]')
            rm -f -- "$ctl/$r.$m"
            REQUEST=$r
        fi
    done
}

# Adopt a disk that is already mounted on its mount point.
take_over() {
    local m=$1 dev
    dev=$(readlink -f "$(device_path "$m")")
    collect_disk_info "$m" "$dev" "$(findmnt -rn -o FSTYPE --mountpoint "${R["$m|MOUNT_POINT"]}" | tail -n 1)"
    collect_df "$m"
    MSTEPS[$m]=""
    FLAG_SEEN[$m]=$(date +%s)
}

# One poll step for mount $1.
process_mount() {
    local m=$1 present=0 here=0 mflag REQUEST REQUEST_BY
    mflag=$(flag_path "$m" MOUNTED)
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
    PRESENT[$m]=$present

    take_request "$m"
    [[ -n $REQUEST ]] && log "[$m] '$REQUEST' requested from the command line${REQUEST_BY:+ by $REQUEST_BY}"

    case ${STATE[$m]:-absent} in
        absent)
            if ((here)); then
                log "[$m] already mounted at ${R["$m|MOUNT_POINT"]}, taking over"
                take_over "$m"
                [[ -e $mflag ]] || create_mounted_flag "$m"
                set_state "$m" mounted "taken over at startup"
            elif ((present)); then
                do_mount "$m"
            elif [[ $REQUEST == mount ]]; then
                warn "[$m] cannot mount: disk is not connected"
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
                disk_gone "$m"
                LASTMSG[$m]="disconnected while mounted"
            elif ((!here)); then
                log "[$m] ${R["$m|MOUNT_POINT"]} was unmounted externally"
                steps_reset "$m"
                step "$m" "${R["$m|MOUNT_POINT"]} was unmounted outside diskwarden (by an administrator?)"
                WHO[$m]=""
                DFINFO[$m]="  (not available - unmounted outside diskwarden)"
                rm -f -- "$mflag"
                set_state "$m" released "unmounted externally"
                create_safe_flag "$m"
                run_hook "$m" UNMOUNT "unmounted externally"
            elif [[ $REQUEST == unmount ]]; then
                rm -f -- "$mflag"
                do_unmount "$m" "${REQUEST_BY:-root} via 'diskwarden --unmount $m'"
            elif [[ ! -e $mflag ]]; then
                do_unmount "$m"
            else
                FLAG_SEEN[$m]=$(date +%s)
            fi
            ;;
        released|failed)
            # Do not remount until the disk has been disconnected, unless
            # requested from the command line.
            if ((!present)); then
                disk_gone "$m"
            elif ((here)); then
                log "[$m] mounted externally at ${R["$m|MOUNT_POINT"]}, taking over"
                take_over "$m"
                remove_flags "$m" SAFE
                remove_flags "$m" WARNING
                create_mounted_flag "$m"
                set_state "$m" mounted "mounted externally"
            elif [[ $REQUEST == mount ]]; then
                do_mount "$m"
            fi
            ;;
    esac

    expire_flags "$m" SAFE "${R["$m|SAFE_FLAG_TTL"]}"
    expire_flags "$m" WARNING "${R["$m|WARNING_FLAG_TTL"]}"
}

# Remove MOUNTED flags left behind by a previous run for disks not mounted now.
startup_cleanup() {
    local m f
    for m in "${MOUNTS[@]}"; do
        f=$(flag_path "$m" MOUNTED)
        if ! is_mounted_here "$m" && [[ -e $f || -L $f ]]; then
            rm -f -- "$f"
            log "[$m] removed stale mounted flag $f"
        fi
    done
}

# Create CONTROL_DIR (root only) and verify nobody else can tamper with it.
ensure_control_dir() {
    local ctl=${R["global|CONTROL_DIR"]}
    if [[ -L $ctl ]]; then
        err "CONTROL_DIR $ctl is a symbolic link"
        return 1
    fi
    mkdir -p -m 0755 -- "$(dirname -- "$ctl")" && mkdir -p -m 0700 -- "$ctl" || {
        err "cannot create CONTROL_DIR $ctl"
        return 1
    }
    if [[ $(stat -c '%u %a' -- "$ctl") != "0 700" ]]; then
        chown root:root -- "$ctl" && chmod 0700 -- "$ctl" || {
            err "CONTROL_DIR $ctl must be owned by root with mode 0700"
            return 1
        }
    fi
}

STATUS_LAST=""
write_status() {
    local m s text="" ctl=${R["global|CONTROL_DIR"]} tmp
    for m in "${MOUNTS[@]}"; do
        [[ -v SINCE[$m] ]] || SINCE[$m]=$(date +%s)
        case ${STATE[$m]:-absent} in
            absent)   s="not connected" ;;
            mounted)  s="mounted" ;;
            released) s="unmounted, safe to disconnect" ;;
            failed)   s="connected, NOT mounted (see warning)" ;;
        esac
        text+="$m"$'\t'"$s"$'\t'"${R["$m|MOUNT_POINT"]}"$'\t'"$(date -d "@${SINCE[$m]}" '+%F %T')"$'\t'"${LASTMSG[$m]:-}"$'\n'
    done
    [[ $text == "$STATUS_LAST" ]] && return 0
    tmp=$ctl/.status.$$
    printf '%s' "$text" > "$tmp" && mv -f -- "$tmp" "$ctl/status" && STATUS_LAST=$text
}

# ---------------------------------------------------------------------------
# Command line client
# ---------------------------------------------------------------------------

daemon_running() {
    [[ -e $LOCK_FILE ]] || return 1
    ! flock -n "$LOCK_FILE" true 2>/dev/null
}

show_status() {
    local ctl=${R["global|CONTROL_DIR"]} name state mp since msg
    if daemon_running; then
        echo "$PROG daemon: running"
    else
        echo "$PROG daemon: NOT running"
    fi
    if [[ ! -r $ctl/status ]]; then
        echo "no status available"
        return 1
    fi
    printf '\n%-12s %-38s %-24s %-19s %s\n' NAME STATE "MOUNT POINT" SINCE "LAST EVENT"
    while IFS=$'\t' read -r name state mp since msg; do
        printf '%-12s %-38s %-24s %-19s %s\n' "$name" "$state" "$mp" "$since" "$msg"
    done < "$ctl/status"
}

# send_request mount|unmount NAME : ask the daemon and wait for the result.
send_request() {
    local req=$1 m=$2 ctl=${R["global|CONTROL_DIR"]} i line
    if [[ ! -v R["$m|UUID"] ]]; then
        err "no [mount $m] in $CONF_FILE"
        return 1
    fi
    daemon_running || { err "$PROG daemon is not running"; return 1; }
    printf '%s\n' "${SUDO_USER:-${USER:-root}}" > "$ctl/$req.$m" || return 1
    echo "Request '$req $m' sent, waiting for the daemon..."
    for ((i = 0; i < 60; i++)); do
        sleep 1
        [[ -e $ctl/$req.$m ]] && continue
        # Request taken; give the daemon a moment to finish the action.
        sleep 2
        line=$(grep -m1 "^$m"$'\t' "$ctl/status" 2>/dev/null)
        printf '%s: %s\n' "$m" "$(cut -f2 <<< "$line")"
        [[ -n $(cut -f5 <<< "$line") ]] && printf '  last event: %s\n' "$(cut -f5 <<< "$line")"
        return 0
    done
    rm -f -- "$ctl/$req.$m"
    err "the daemon did not pick up the request within 60s"
    return 1
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

usage() {
    cat <<EOF
$PROG $VERSION - mount configured disks on arrival, unmount on flag removal

Usage: $PROG [-c FILE] [command]

Commands:
  (none)            run the daemon (normally started by systemd)
  --status          show the state of every configured disk
  --mount NAME      mount disk NAME again without reconnecting it
                    (after it was unmounted or a mount failed)
  --unmount NAME    unmount disk NAME (same as deleting its mounted flag)
  --check           validate the config, print it, and exit
  --get KEY         print a [global] setting (used by install.sh)
  -h, --help        show this help
  -V, --version     show version

Options:
  -c, --config FILE use FILE instead of $CONF_FILE
EOF
}

RELOAD=0
RUNNING=1

main() {
    local action=daemon arg=""
    while (($#)); do
        case $1 in
            -c|--config) CONF_FILE=${2:?--config needs a file}; shift ;;
            --check) action=check ;;
            --status) action=status ;;
            --mount|--unmount|--get)
                action=${1#--}; arg=${2:?$1 needs an argument}; shift ;;
            -h|--help) usage; exit 0 ;;
            -V|--version) echo "$PROG $VERSION"; exit 0 ;;
            *) usage >&2; exit 2 ;;
        esac
        shift
    done

    case $action in
        check)
            load_config || exit 1
            print_config
            exit 0 ;;
        get)
            load_config || exit 1
            [[ -v R["global|$arg"] ]] || { err "unknown global setting $arg"; exit 1; }
            printf '%s\n' "${R["global|$arg"]}"
            exit 0 ;;
    esac

    if ((EUID != 0)); then
        err "must run as root"
        exit 1
    fi
    load_config || exit 1

    case $action in
        status) show_status; exit ;;
        mount|unmount) send_request "$action" "$arg"; exit ;;
    esac

    local cmd
    for cmd in findmnt mount umount blkid readlink stat flock mktemp timeout; do
        command -v "$cmd" >/dev/null || { err "required command '$cmd' not found"; exit 1; }
    done

    exec 9>"$LOCK_FILE" || { err "cannot open lock file $LOCK_FILE"; exit 1; }
    if ! flock -n 9; then
        err "another instance is already running (lock $LOCK_FILE)"
        exit 1
    fi
    ensure_control_dir || exit 1
    rm -f -- "${R["global|CONTROL_DIR"]}"/mount.* "${R["global|CONTROL_DIR"]}"/unmount.*

    trap 'RELOAD=1' HUP
    trap 'RUNNING=0' TERM INT

    log "$PROG $VERSION started: ${#MOUNTS[@]} mount(s) from $CONF_FILE, polling every ${R["global|POLL_INTERVAL"]}s"
    startup_cleanup

    local m old_ctl
    while ((RUNNING)); do
        if ((RELOAD)); then
            RELOAD=0
            old_ctl=${R["global|CONTROL_DIR"]}
            if load_config; then
                log "configuration reloaded: ${#MOUNTS[@]} mount(s)"
                if [[ ${R["global|CONTROL_DIR"]} != "$old_ctl" ]]; then
                    ensure_control_dir || R["global|CONTROL_DIR"]=$old_ctl
                    STATUS_LAST=""
                fi
            else
                err "configuration reload failed, keeping previous configuration"
            fi
        fi
        for m in "${MOUNTS[@]}"; do
            process_mount "$m"
        done
        write_status
        # Sleep in the background so signals are handled immediately.
        sleep "${R["global|POLL_INTERVAL"]}" &
        wait $! 2>/dev/null
    done

    log "$PROG stopping (mounted disks stay mounted)"
}

main "$@"
