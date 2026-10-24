# Runbook: High CPU usage or load average

Load average counts processes that are running **or waiting** (CPU run
queue plus uninterruptible I/O sleep, state `D`). High load with low CPU
usage almost always means storage or NFS trouble, not a CPU problem.
`health-check.sh` normalises load per core: 1.0/core means fully busy.

## Symptoms

- `health-check.sh` reports `WARNING - load 2.10/core`
- Slow SSH logins, slow API responses, timeouts at the load balancer
- Cloud console shows CPU at 100 % or CPU credit balance at zero (burstable
  instance types such as AWS t3 / GCP e2-micro)

## Triage

```bash
uptime                          # 1/5/15-min trend: rising or recovering?
nproc                           # compare load to core count

# CPU time breakdown: us=user, sy=kernel, wa=I/O wait, st=steal
vmstat 1 5
mpstat -P ALL 1 3               # sysstat package; one hot core = single-threaded process

# Top consumers
ps -eo pid,ppid,user,%cpu,%mem,stat,etime,cmd --sort=-%cpu | head -15

# Processes stuck in D state (waiting on I/O)
ps -eo pid,stat,wchan:32,cmd | awk '$2 ~ /D/'

# Disk latency and saturation
iostat -xz 1 3                  # look at await and %util

# Which unit owns the hot process?
systemd-cgtop -n 3
systemctl status <PID>

# History: was it like this yesterday? (if sysstat collection is enabled)
sar -u -f /var/log/sysstat/sa$(date -d yesterday +%d) 2>/dev/null | tail
```

How to read it:

| Pattern | Likely cause | Next step |
|---|---|---|
| high `us`, one process | runaway app, busy loop, bad deploy | check recent deploys, app logs |
| high `sy` | heavy syscalls, context switching | `pidstat -w 1`, `perf top` |
| high `wa`, `D` processes | slow disk / NFS hang | `iostat`, `dmesg -T`, check NFS mounts |
| high `st` | noisy neighbour or credit exhaustion | resize or move to non-burstable type |
| many short-lived processes | cron storm, fork loop | `execsnoop` (bcc), `journalctl -u cron` |

## Resolution

1. If a known non-critical job (backup, reindex, report) is responsible,
   deprioritise rather than kill it:
   `sudo renice -n 19 -p <PID>; sudo ionice -c3 -p <PID>`
2. For a runaway service, capture evidence first, then restart:
   ```bash
   sudo cat /proc/<PID>/status > /root/incident-<PID>.txt
   sudo timeout 10 strace -c -p <PID> 2>>/root/incident-<PID>.txt
   sudo systemctl restart <unit>
   ```
3. A process that ignores SIGTERM: `sudo kill -TERM <PID>`, wait 30 s, then
   `sudo kill -KILL <PID>`. Processes in `D` state cannot be killed; fix the
   I/O path underneath them.
4. Contain a service that keeps doing it while the owning team investigates:
   `sudo systemctl set-property <unit> CPUQuota=50%`
5. Sustained legitimate load: scale out or move to a larger instance type.

## Prevention

- Set `CPUQuota=` / `MemoryMax=` on batch and background units.
- Schedule heavy jobs off-peak with `RandomizedDelaySec=` on timers so a
  fleet does not run them in the same minute.
- Enable `sysstat` so there is history to compare against.
- Alert on CPU credit balance for burstable instance types.
