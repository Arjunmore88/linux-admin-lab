# Runbook: Service down or failing to start

## Symptoms

- `health-check.sh` reports `CRITICAL - nginx.service failed`
- `systemctl --failed` lists the unit
- Load balancer health checks failing, HTTP 502/503 from upstream
- Unit is "activating (auto-restart)" in a loop

## Triage

```bash
systemctl status <unit> --no-pager -l          # state, last exit code, last log lines
journalctl -u <unit> -b --no-pager -n 100      # full logs since boot
journalctl -u <unit> --since "15 min ago" -p warning

systemctl cat <unit>                           # the unit as systemd sees it, incl. drop-ins
systemctl show <unit> -p ExecMainStatus -p Result -p NRestarts

# Did something change?
grep -E " (install|upgrade) " /var/log/dpkg.log | tail      # Ubuntu
sudo dnf history list | head                               # RHEL
sudo find /etc -newer /proc/1 -type f -mmin -120 2>/dev/null | head
```

Common causes and how they show up:

| Log / status says | Cause | Check |
|---|---|---|
| `status=203/EXEC` | binary missing or not executable | `ls -l` the `ExecStart` path |
| `status=217/USER` | `User=` does not exist | `getent passwd <user>` |
| `Address already in use` | port taken by another process | `sudo ss -ltnp 'sport = :80'` |
| `Permission denied` on a path | ownership, mode, or SELinux | `ls -lZ`, `sudo ausearch -m avc -ts recent` |
| config syntax error | bad edit | app's own test: `nginx -t`, `apachectl configtest`, `sshd -t` |
| `start request repeated too quickly` | crash loop hit `StartLimitBurst` | fix the cause, then `systemctl reset-failed <unit>` |
| killed with `status=9/KILL` | OOM killer | `journalctl -k | grep -i oom` |
| `No space left on device` | disk full | [disk-full.md](disk-full.md) |

## Resolution

1. Fix the underlying cause from the table above. Restarting a unit that
   fails for a config reason will only fail again.
2. Validate the config with the service's own checker before restarting.
3. Restart and watch:
   ```bash
   sudo systemctl reset-failed <unit>
   sudo systemctl restart <unit>
   journalctl -u <unit> -f
   ```
4. If a recent change caused it, roll back the change (restore the config
   from backup, or `dnf history undo <id>` / `apt install pkg=<old-version>`)
   rather than patching forward under pressure.
5. SELinux denial on RHEL: restore contexts (`sudo restorecon -Rv <path>`).
   Do **not** `setenforce 0` as a fix.

Confirm the service is healthy from the client side (curl the endpoint,
check the load balancer target), not only via `systemctl is-active`.

## Prevention

- Add `Restart=on-failure` with sensible `RestartSec=` to long-running units.
- Validate configs in CI or in a pre-reload step (`ExecReload=` with a
  test command first, as `harden-ssh.sh` does with `sshd -t`).
- Add every business-critical unit to `HEALTH_CHECK_ARGS` in
  `/etc/default/health-check`.
