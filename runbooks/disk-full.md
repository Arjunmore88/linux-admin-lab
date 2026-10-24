# Runbook: Filesystem full or nearly full

**Severity guide:** WARNING at 80 %, CRITICAL at 90 % (health-check defaults).
A full `/` or `/var` stops logging and package installs, and can crash
databases. Treat 95 %+ as urgent.

## Symptoms

- `health-check.sh` reports `CRITICAL - /var 96% used`
- Applications fail with `No space left on device` (ENOSPC)
- `journald` or `rsyslog` stops writing; `apt`/`dnf` fail mid-transaction
- Disk looks full but `du` does not add up (deleted-but-open files)
- Disk has free space but writes still fail (inode exhaustion)

## Triage

```bash
# Which filesystem, and is it blocks or inodes?
df -hT -x tmpfs -x devtmpfs
df -i  -x tmpfs -x devtmpfs

# Largest directories on that filesystem only (-x stays on one fs)
sudo du -xh --max-depth=2 /var 2>/dev/null | sort -rh | head -20

# Largest individual files
sudo find /var -xdev -type f -size +200M -printf '%s\t%p\n' 2>/dev/null | sort -rn | head -20 | numfmt --to=iec --field=1

# Space held by deleted files that a process still has open
sudo lsof -nP +L1 2>/dev/null | awk 'NR==1 || $7 > 100000000'

# Journal size
journalctl --disk-usage

# Inode hog: directories with the most files
sudo find /var -xdev -type f 2>/dev/null | cut -d/ -f2-4 | sort | uniq -c | sort -rn | head
```

## Resolution

Work from the safest action to the riskiest. Stop as soon as usage is back
under the warning threshold, then fix the root cause.

1. **Journal:** `sudo journalctl --vacuum-size=500M`
2. **Package cache:** `sudo apt-get clean` (Ubuntu) / `sudo dnf clean all` (RHEL)
3. **Rotated logs:** delete old compressed rotations, not live files:
   `sudo find /var/log -name '*.gz' -mtime +7 -delete`
4. **A runaway live log file:** truncate, do not `rm`, so the writing
   process keeps a valid handle and space is actually freed:
   `sudo truncate -s 0 /var/log/myapp/app.log`
   Copy the tail first if it may be needed for diagnosis:
   `sudo tail -n 100000 /var/log/myapp/app.log > /root/app.log.tail`
5. **Deleted-but-open files** (from `lsof +L1`): restart the owning service
   (`sudo systemctl restart <unit>`). If a restart is not acceptable, truncate
   through procfs: `sudo truncate -s 0 /proc/<PID>/fd/<FD>`.
6. **Old core dumps / temp files:** `coredumpctl list`, `/var/crash`, `/var/tmp`.
7. **Still not enough:** extend the volume online, see
   [lvm-extend-filesystem.md](lvm-extend-filesystem.md).

Confirm: `df -h /var` and re-run `/opt/linux-admin-lab/scripts/health-check.sh`.

## Prevention

- Every application log has a logrotate policy with `maxsize`, not only a
  time-based schedule (see `configs/logrotate-linux-admin-lab`).
- Cap the journal: `SystemMaxUse=1G` in `/etc/systemd/journald.conf`.
- `/var/log` on its own LV so a log flood cannot fill `/`.
- health-check timer alerts at 80 %, giving time to act before 100 %.
- Check debug logging is turned off after troubleshooting; add it to the
  change-close checklist.
