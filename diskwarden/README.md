# diskwarden

A systemd daemon for AlmaLinux 10 that waits for specific disks to be connected,
mounts them, and unmounts them when the user deletes a flag file.

## How it works

For every disk configured in `/etc/diskwarden/diskwarden.conf`:

1. **Disk connected.** The disk appears as `/dev/disk/by-uuid/<UUID>`. diskwarden
   mounts it at `MOUNT_POINT` and creates the **mounted flag**
   `MOUNTED_FLAG_DIR/MOUNTED_FLAG_NAME`.
2. **User deletes the mounted flag.** diskwarden syncs and unmounts the disk, then
   creates the **safe flag** `SAFE_FLAG_DIR/SAFE_FLAG_NAME`. The `%TS%` part of
   the name is the creation time, for example
   `BACKUP1_SAFE_TO_DISCONNECT_2026-10-06_14-25-30`.
3. **Safe flag expires.** The safe flag is deleted `SAFE_FLAG_TTL` seconds after
   it was created (default 300 s, or 5 minutes).
4. **Disk disconnected.** The next time it is connected, it is mounted again.

Other behaviour:

* **Disk is busy when unmounting.** diskwarden retries `UMOUNT_RETRIES` times. If
  every attempt fails, it re-creates the mounted flag with the error and the list
  of processes using the disk written inside. Delete the flag again to retry.
* **Disk not reconnected yet.** An unmounted disk that is still connected is not
  mounted again until it has been disconnected and reconnected, or the service
  is restarted.
* **Disk unplugged while mounted.** The mount is detached lazily and the
  mounted flag is removed.
* **Disk unmounted or mounted by hand.** diskwarden notices and updates the
  flags to match.
* **Service stops or restarts.** Mounted disks stay mounted. On start,
  diskwarden takes over disks that are already mounted on their mount point and
  re-creates any missing mounted flags.
* **Configuration reload.** `systemctl reload diskwarden` re-reads the
  configuration. If the new file is invalid, the old configuration stays active.

## Files

| Path | Purpose |
|------|---------|
| `/etc/diskwarden/diskwarden.sh`   | the daemon script |
| `/etc/diskwarden/diskwarden.conf` | configuration |
| `/etc/diskwarden/README.md`       | this file |
| `/etc/systemd/system/diskwarden.service` | systemd unit |

## Install

```bash
sudo ./install.sh
lsblk -o NAME,SIZE,FSTYPE,UUID,LABEL      # find your disk UUIDs
sudo vi /etc/diskwarden/diskwarden.conf
sudo /etc/diskwarden/diskwarden.sh --check
sudo systemctl enable --now diskwarden
journalctl -u diskwarden -f
```

To uninstall, run `sudo ./install.sh --uninstall`. This keeps `/etc/diskwarden`.

## Configuration

The file has a `[global]` section and one `[mount NAME]` section per disk. Any
setting other than `POLL_INTERVAL` can go in `[global]` as a default and be
overridden in a mount section. **Directories (`*_DIR`) and file names (`*_NAME`)
are always separate settings.**

| Key | Default | Description |
|-----|---------|-------------|
| `POLL_INTERVAL` (global only) | `2` | Seconds between checks. |
| `UUID` | – (required) | Filesystem UUID of the disk. |
| `MOUNT_POINT` | – (required) | Absolute path to mount the disk on. |
| `FS_TYPE` | `auto` | `mount -t` value. Set to `auto` to let `mount` detect the type. |
| `MOUNT_OPTIONS` | `defaults` | `mount -o` value. |
| `CREATE_MOUNT_POINT` | `yes` | Create `MOUNT_POINT` if it is missing. |
| `MOUNTED_FLAG_DIR` | `/run/diskwarden` | Directory of the mounted flag. |
| `MOUNTED_FLAG_NAME` | `%NAME%.MOUNTED` | File name of the mounted flag. |
| `SAFE_FLAG_DIR` | `/run/diskwarden` | Directory of the safe flag. Must not be on the disk. |
| `SAFE_FLAG_NAME` | `%NAME%.SAFE_TO_DISCONNECT.%TS%` | File name of the safe flag. Must contain `%TS%` exactly once. |
| `SAFE_FLAG_TTL` | `300` | Lifetime of the safe flag, in seconds. |
| `TIMESTAMP_FORMAT` | `%Y-%m-%d_%H-%M-%S` | strftime format used for `%TS%`. |
| `FLAG_OWNER` | *(root)* | `user` or `user:group` that owns the flag files. |
| `FLAG_MODE` | `0664` | Mode of the flag files. |
| `FLAG_DIR_MODE` | `0775` | Mode applied to flag directories that diskwarden creates. |
| `UMOUNT_RETRIES` | `3` | Number of extra unmount attempts when the disk is busy. |

`%NAME%` (the mount's name) and `%UUID%` can be used in `MOUNT_POINT`, `*_DIR`
and `*_NAME`.

### Permissions

To delete the mounted flag, a user needs **write permission on
`MOUNTED_FLAG_DIR`**. Either point it at a directory the user can write to, or
let diskwarden create the directory with the right `FLAG_OWNER` and
`FLAG_DIR_MODE`. It applies these only to directories it creates.

`MOUNTED_FLAG_DIR` can be inside the mount point, which puts the flag on the
disk itself. For FAT and exFAT disks, set `uid=`, `gid=` and `umask=` in
`MOUNT_OPTIONS` so the user can write to the disk. `SAFE_FLAG_DIR` must never
be on the disk.

## Notes for AlmaLinux 10

* **SELinux.** The unit starts the script with `/usr/bin/bash`, so the script
  runs as `unconfined_service_t` even though it lives under `/etc`. The
  installer runs `restorecon` on the installed files.
* **Sandboxing.** Do not add sandboxing options to the unit, such as
  `PrivateTmp`, `ProtectSystem` or `ProtectHome`. They create a private mount
  namespace, which would hide the mounts from the rest of the system.
* **Desktop automounting.** On GNOME, udisks2 may also mount the disk under
  `/run/media/...`. diskwarden logs a warning when this happens. To stop it,
  add a udev rule that sets `UDISKS_IGNORE`, for example in
  `/etc/udev/rules.d/99-diskwarden.rules`:
  `ENV{ID_FS_UUID}=="<UUID>", ENV{UDISKS_IGNORE}="1"`
* **fstab.** Do not add these disks to `/etc/fstab`.
* **Dependencies.** The script only needs `util-linux`, `coreutils`,
  `findutils` and `systemd`, which are all part of a minimal install. `fuser`
  (from `psmisc`) is optional. If installed, the error report for a busy disk
  lists the processes that are using it.
