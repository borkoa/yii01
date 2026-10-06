# diskwarden

A systemd daemon for AlmaLinux 10 that waits for specific disks to be connected,
mounts them, and unmounts them when the user deletes a flag file. It is meant
for users who only see the server through a file share and cannot run
commands.

## How it works

For every disk configured in `/etc/diskwarden/diskwarden.conf`:

1. **Disk connected.** The disk appears as `/dev/disk/by-uuid/<UUID>`. If
   `FSCK=yes`, diskwarden checks the filesystem first. It then mounts the disk
   at `MOUNT_POINT` and creates the **mounted flag**
   `MOUNTED_FLAG_DIR/MOUNTED_FLAG_NAME`.
2. **User deletes the mounted flag** (or an admin runs
   `diskwarden --unmount NAME`). diskwarden syncs and unmounts the disk, then
   creates the **safe flag** `SAFE_FLAG_DIR/SAFE_FLAG_NAME`. The `%TS%` part of
   the name is the creation time, for example
   `backup1_SAFE_TO_DISCONNECT_2026-10-06_14-25-30`. The status words in flag
   names (`MOUNTED`, `SAFE_TO_DISCONNECT`, `WARNING`) are configurable.
3. **Safe flag expires.** The safe flag is deleted `SAFE_FLAG_TTL` seconds
   after it was created (default 300 s, or 5 minutes).
4. **Disk disconnected.** The next time it is connected, it is mounted again.
   To mount it again *without* reconnecting it, run `diskwarden --mount NAME`.

If the disk **cannot be checked or mounted**, diskwarden creates a **warning
flag** `WARNING_FLAG_DIR/WARNING_FLAG_NAME` that explains why, and logs a
warning. This happens when:

| Problem | Result |
|---------|--------|
| No recognisable filesystem (empty, encrypted or damaged disk) | not mounted |
| Filesystem type not supported (no kernel driver or `mount.<type>` helper, or `mount` reports "unknown filesystem type") | not mounted |
| `FSCK=yes` but no `fsck.<type>` tool installed | mounted anyway (`FSCK_UNSUPPORTED_ACTION=mount`) or not mounted (`skip`) |
| fsck found errors it could not fix (exit code 2 or higher) | not mounted |
| Any other mount error | not mounted |

The warning flag is removed when the disk is disconnected or mounted
successfully, or after `WARNING_FLAG_TTL` seconds if that is not 0.

Other behaviour:

* **Disk is busy when unmounting.** diskwarden retries `UMOUNT_RETRIES` times. If
  every attempt fails, it re-creates the mounted flag with the error and the list
  of processes using the disk written inside. Delete the flag again to retry.
* **Disk unplugged while mounted.** The mount is detached lazily and the
  mounted flag is removed.
* **Disk unmounted or mounted by hand.** diskwarden notices and updates the
  flags to match.
* **Service stops or restarts.** Mounted disks stay mounted. On start,
  diskwarden takes over disks that are already mounted on their mount point.
* **Configuration reload.** `systemctl reload diskwarden` re-reads the
  configuration. If the new file is invalid, the old configuration stays active.

## What the flag files contain

Every flag file is a short report for the person who finds it on the share:

* **Headline.** For example `DISK "backup1" IS MOUNTED - do not unplug it now`.
* **What to do.** Plain instructions, including the exact name of the file to
  wait for.
* **Disk.** Name, UUID, device, filesystem type and label, size, model, mount
  point and mount options.
* **Space.** Total, used, free and inodes, from `df`, with a usage bar. The
  mounted flag shows the space at mount time; the safe flag shows it just
  before unmounting.
* **What diskwarden did.** Every step with its time, command, exit code and
  meaning (for example `fsck ... -> exit 1 (errors corrected)`) and the first
  lines of its output. After a failed unmount, this also includes the
  `fuser` list of processes still using the disk.
* **Unmount requested by** (safe flag only). The user, IP address and
  computer that deleted the flag (see below), or the admin who ran
  `diskwarden --unmount` (taken from `sudo`).

```
======================================================================
  DISK "backup1" IS UNMOUNTED - SAFE TO DISCONNECT
======================================================================

--- WHAT TO DO -------------------------------------------------------
  You can unplug the disk now.
  To use it again, plug it in again; it is mounted automatically.

  This notice is removed at 2026-10-06 14:30:36 (after 300s).

--- UNMOUNT REQUESTED BY ---------------------------------------------
  user "alice" from 192.168.1.20 (computer pc-alice), share "disks" - deleted the mounted flag

--- DISK -------------------------------------------------------------
  Name           backup1
  UUID           aaaaaaaa-0000-0000-0000-00000000000a
  Device         /dev/sdb1
  Filesystem     ext4, label "Backup Office"
  Size           931.5G
  Model          WD Elements 25A3
  Mount point    /mnt/backup1
  Options        defaults

--- SPACE (just before unmounting) -----------------------------------
  Total          916G
  Used           275G (30%)
  Free           595G
  Files/dirs     81234 inodes used (1%)
  [############............................] 30% used

--- WHAT DISKWARDEN DID TO UNMOUNT IT --------------------------------
  14:25:36  mounted flag /srv/diskwarden/backup1_MOUNTED was deleted
  14:25:36  sync -f /mnt/backup1 (write cached data to the disk)
            -> exit 0
  14:25:36  umount /mnt/backup1 (attempt 1 of 4)
            -> exit 0  (unmounted)

----------------------------------------------------------------------
  diskwarden 2.1.0 on fileserver, file written 2026-10-06 14:25:36 CEST
```

## Who deleted the flag (optional)

When the flag directory is shared with Samba, diskwarden can name the person
who deleted the mounted flag. It reads the records of Samba's `full_audit`
module. Add this to the share in `/etc/samba/smb.conf`:

```
[disks]
    path = /srv/diskwarden
    vfs objects = full_audit
    full_audit:prefix = %u|%I|%m|%S
    full_audit:success = unlinkat renameat
    full_audit:failure = none
    full_audit:facility = local5
    full_audit:priority = notice
```

Then set `AUDIT_LOG=journal` in `diskwarden.conf`. Samba logs these records
through syslog with the identifier `smbd_audit`, and on AlmaLinux they end up
in the journal. If rsyslog writes them to a file instead, set `AUDIT_LOG` to
that file's path.

* **Where the name appears.** In the safe flag, in the journal, in
  `diskwarden --status`, and in the `ON_UNMOUNT` hook as
  `DISKWARDEN_REQUESTED_BY`.
* **No matching record.** For example, if the flag was deleted locally on the
  server, the safe flag says "unknown".
* **Prefix format.** With the prefix shown above, the output is formatted as
  user, IP address, computer and share. With a different prefix, the raw
  prefix fields are shown instead.

## Commands

```
diskwarden --status          # state of every disk and the last event
diskwarden --mount NAME      # mount again without reconnecting the disk
diskwarden --unmount NAME    # unmount (same as deleting the mounted flag)
diskwarden --check           # validate and print the configuration
```

`--mount` and `--unmount` send a request to the running daemon and wait for
the result. All commands except `--check` need root.

```
diskwarden daemon: running

NAME         STATE                                  MOUNT POINT              SINCE               LAST EVENT
backup1      mounted                                /mnt/backup1             2026-10-06 14:20:03 mounted (ext4)
archive      unmounted, safe to disconnect          /mnt/archive             2026-10-06 14:25:30 unmounted
usbstick     connected, NOT mounted (see warning)   /mnt/usbstick            2026-10-06 14:26:11 Filesystem type 'ntfs' is not supported ...
```

## Files

| Path | Purpose |
|------|---------|
| `PROGRAM_DIR/diskwarden.sh` (default `/usr/libexec/diskwarden/`) | the daemon and admin command |
| `COMMAND_LINK` (default `/usr/sbin/diskwarden`) | symlink to the program |
| `/etc/diskwarden/diskwarden.conf` | configuration |
| `/etc/systemd/system/diskwarden.service` | systemd unit, generated by `install.sh` |
| `/usr/share/doc/diskwarden/README.md` | this file |
| `CONTROL_DIR` (default `/run/diskwarden/control`) | status file and requests (root only) |

`PROGRAM_DIR` and `COMMAND_LINK` are set in the `[global]` section of the
config. `install.sh` reads them from there. After changing them, run
`./install.sh` again: it installs to the new place and removes the old copy.

## Install

```bash
sudo ./install.sh
lsblk -o NAME,SIZE,FSTYPE,UUID,LABEL      # find your disk UUIDs
sudo vi /etc/diskwarden/diskwarden.conf
sudo diskwarden --check
sudo systemctl enable --now diskwarden
sudo diskwarden --status
journalctl -u diskwarden -f
```

`install.sh` is **idempotent**: running it again changes nothing if nothing
changed, and says so.

**Upgrading.** Unpack the new version and run `sudo ./install.sh` again.

* **Config.** Your config is never modified. It is validated with the *new*
  program first; if it is not valid, the installer stops before changing
  anything. The new example config is written next to yours as
  `diskwarden.conf.new` (only when it differs), and settings new in this
  version are listed. They use built-in defaults until you set them.
* **Files.** A file is replaced only when its content changes. The service is
  restarted only if it is running and its program or unit changed.
* **Cleanup.** Files and directories of the previous installation that are no
  longer needed are removed. This covers an old `PROGRAM_DIR` or
  `COMMAND_LINK`, and the version 1 layout in `/etc/diskwarden`. The
  installer records what it installed in
  `/var/lib/diskwarden/installed-files`.
* **Concurrency.** Only one installer can run at a time.

**Uninstalling.** Run `sudo ./install.sh --uninstall`. This removes exactly
what the installer created, including directories it created if they are
empty, and keeps `/etc/diskwarden`. Running it again does nothing.

## Configuration

The file has a `[global]` section and one `[mount NAME]` section per disk.
Every per-mount setting can go in `[global]` as a default and be overridden in
a mount section. **Directories (`*_DIR`) and file names (`*_NAME`) are always
separate settings.**

### Global only

| Key | Default | Description |
|-----|---------|-------------|
| `POLL_INTERVAL` | `2` | Seconds between checks. |
| `PROGRAM_DIR` | `/usr/libexec/diskwarden` | Install location of the program (used by `install.sh`). |
| `COMMAND_LINK` | `/usr/sbin/diskwarden` | Symlink to the program. Leave empty for none. |
| `CONTROL_DIR` | `/run/diskwarden/control` | Private directory for status and requests. |

### Per mount

| Key | Default | Description |
|-----|---------|-------------|
| `UUID` | – (required) | Filesystem UUID of the disk. |
| `MOUNT_POINT` | – (required) | Absolute path to mount the disk on. |
| `FS_TYPE` | `auto` | `mount -t` value. Set to `auto` to detect the type. |
| `MOUNT_OPTIONS` | `defaults` | `mount -o` value. |
| `CREATE_MOUNT_POINT` | `yes` | Create `MOUNT_POINT` if it is missing. |
| `UMOUNT_RETRIES` | `3` | Number of extra unmount attempts when the disk is busy. |
| `FSCK` | `no` | Run fsck before mounting. |
| `FSCK_OPTIONS` | `-p` | Options passed to fsck. `-p` repairs only what is safe automatically. |
| `FSCK_UNSUPPORTED_ACTION` | `mount` | `mount` or `skip` when `fsck.<type>` is missing. A warning is written either way. |
| `MOUNTED_WORD` | `MOUNTED` | Status word for `%STATUS%` in `MOUNTED_FLAG_NAME`. |
| `SAFE_WORD` | `SAFE_TO_DISCONNECT` | Status word for `%STATUS%` in `SAFE_FLAG_NAME`. |
| `WARNING_WORD` | `WARNING` | Status word for `%STATUS%` in `WARNING_FLAG_NAME`. |
| `MOUNTED_FLAG_DIR` / `_NAME` | `/run/diskwarden/flags` / `%NAME%.%STATUS%` | Mounted flag. |
| `SAFE_FLAG_DIR` / `_NAME` | `/run/diskwarden/flags` / `%NAME%.%STATUS%.%TS%` | Safe flag. The name must contain `%TS%`. |
| `SAFE_FLAG_TTL` | `300` | Lifetime of the safe flag, in seconds. |
| `WARNING_FLAG_DIR` / `_NAME` | `/run/diskwarden/flags` / `%NAME%.%STATUS%` | Warning flag. `%TS%` is optional in the name. |
| `WARNING_FLAG_TTL` | `0` | Lifetime of the warning flag, in seconds. `0` keeps it until the disk is disconnected or mounted. |
| `TIMESTAMP_FORMAT` | `%Y-%m-%d_%H-%M-%S` | strftime format used for `%TS%`. |
| `FLAG_OWNER` | *(root)* | `user` or `user:group` that owns the flag files. |
| `FLAG_MODE` | `0664` | Mode of the flag files. Execute bits are not allowed. |
| `FLAG_DIR_MODE` | `0775` | Mode applied to flag directories that diskwarden creates. |
| `ON_MOUNT`, `ON_UNMOUNT`, `ON_DISCONNECT`, `ON_WARNING`, `ON_ERROR` | *(empty)* | Hook commands, described below. |
| `HOOK_TIMEOUT` | `60` | Seconds before a hook is killed. |
| `AUDIT_LOG` | *(empty)* | Where to find Samba audit records: empty (off), `journal`, or a file path. |
| `AUDIT_JOURNAL_IDENTIFIER` | `smbd_audit` | Syslog identifier of the audit records when `AUDIT_LOG=journal`. |

`%NAME%` (the mount's name) and `%UUID%` can be used in `MOUNT_POINT`, `*_DIR`,
`*_NAME` and `*_WORD`. `%STATUS%` can be used in `*_FLAG_NAME`.

Status words make it possible to change the wording, or the language, of all
flag names in one place. For example, `SAFE_WORD=MOZNO_ODPOJIT` with
`SAFE_FLAG_NAME=%NAME%_%STATUS%_%TS%.txt` produces
`backup1_MOZNO_ODPOJIT_2026-10-06_14-25-30.txt`. Words may contain any
characters except `/ % * ? [ ]`. The defaults in the shipped config file differ slightly from
the built-in defaults shown here; for example, it uses `/srv/diskwarden` for
the flags.

### Hooks

Each `ON_*` setting is a shell command run as root, in the background, so it
never blocks the daemon. Its output goes to the journal. Details are passed
**only as environment variables**, so a disk label or message can never inject
shell code:

| Variable | Contents |
|----------|----------|
| `DISKWARDEN_EVENT` | `MOUNT`, `UNMOUNT`, `DISCONNECT`, `WARNING` or `ERROR` |
| `DISKWARDEN_NAME` | name of the mount |
| `DISKWARDEN_UUID` | UUID of the disk |
| `DISKWARDEN_DEVICE` | device node, for example `/dev/sdb1` |
| `DISKWARDEN_MOUNT_POINT` | mount point |
| `DISKWARDEN_MOUNTED_FLAG` | path of the mounted flag |
| `DISKWARDEN_MESSAGE` | human-readable description of the event |
| `DISKWARDEN_REQUESTED_BY` | who asked for the unmount (`UNMOUNT` only; see "Who deleted the flag") |

`WARNING` covers an unsupported filesystem or a missing fsck tool. `ERROR`
covers fsck failures, mount failures and unmount failures.

```
ON_MOUNT=/usr/local/bin/start-backup "$DISKWARDEN_MOUNT_POINT"
ON_WARNING=echo "$DISKWARDEN_MESSAGE" | mail -s "disk $DISKWARDEN_NAME" admin@example.com
```

### Permissions and security

To delete the mounted flag, a user needs **write permission on
`MOUNTED_FLAG_DIR`**. Either point it at a directory the user can write to, or
let diskwarden create the directory with the right `FLAG_OWNER` and
`FLAG_DIR_MODE`. It applies these only to directories it creates.

Because users can write to the flag directories, diskwarden never writes
through an existing path:

* Each flag is written to a new file with a random name, created exclusively
  with the final mode. It is then renamed over the flag path.
* Ownership changes use `chown -h`.
* A flag directory that is a symbolic link is refused.

A symlink that a user plants at a flag path is therefore replaced, never
followed. `CONTROL_DIR` must be owned by root with mode 0700, and diskwarden
enforces this.

`MOUNTED_FLAG_DIR` can be inside the mount point, which puts the flag on the
disk itself. For FAT and exFAT disks, set `uid=`, `gid=` and `umask=` in
`MOUNT_OPTIONS` so the user can write to the disk. `SAFE_FLAG_DIR` and
`WARNING_FLAG_DIR` must never be on the disk.

## Notes for AlmaLinux 10

* **SELinux.** The unit starts the script with `/usr/bin/bash`, so it runs as
  `unconfined_service_t` whatever the SELinux label of `PROGRAM_DIR`. The
  installer runs `restorecon` on everything it installs.
* **Sandboxing.** Do not add sandboxing options to the unit, such as
  `PrivateTmp`, `ProtectSystem` or `ProtectHome`. They create a private mount
  namespace, which would hide the mounts from the rest of the system.
* **Filesystem support.** ext4, xfs, vfat and exfat work out of the box. NTFS
  needs `ntfs-3g` from EPEL; set `FS_TYPE=ntfs-3g` for such disks. Without it,
  diskwarden writes the "not supported" warning flag.
* **fsck for XFS.** `fsck.xfs` does nothing by design, so `FSCK=yes` gives no
  protection for XFS disks. Use `xfs_repair` manually if needed.
* **Desktop automounting.** On GNOME, udisks2 may also mount the disk under
  `/run/media/...`. diskwarden logs a warning when this happens. To stop it,
  add a udev rule that sets `UDISKS_IGNORE`, for example in
  `/etc/udev/rules.d/99-diskwarden.rules`:
  `ENV{ID_FS_UUID}=="<UUID>", ENV{UDISKS_IGNORE}="1"`
* **fstab.** Do not add these disks to `/etc/fstab`.
* **Dependencies.** The script only needs `util-linux`, `coreutils`, `kmod` and
  `systemd`, which are all part of a minimal install. `fuser` (from `psmisc`)
  is optional. If installed, the error report for a busy disk lists the
  processes that are using it.
