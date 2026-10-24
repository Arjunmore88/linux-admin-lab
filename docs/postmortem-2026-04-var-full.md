# Postmortem: `/var` filled on app-prod-03 after debug logging was left enabled

| | |
|---|---|
| **Incident ID** | INC-2026-0412 |
| **Date** | 2026-04-14 |
| **Duration** | 02:10 to 03:05 IST (55 minutes of degraded service) |
| **Severity** | SEV-2: one of three API nodes out of the load balancer pool; no data loss |
| **Status** | Resolved. Action items tracked below |
| **Format** | Blameless. This document looks at systems and process, not individuals |

## Summary

Debug-level logging was enabled on the order API service during an
investigation on 13 April and was not turned off afterwards. The service
then wrote about 1.6 GB of logs per hour to `/var/log/myapp/app.log`. Its
logrotate policy rotated daily only, and `delaycompress` left the 12 GB
rotated file uncompressed on disk, so log growth continued until the 25 GB
`/var` filesystem reached 100 %. The application then failed to
write its PID and session files, its health endpoint returned HTTP 500, and
the load balancer removed the node. The other two nodes absorbed the
traffic, with p95 latency rising from 180 ms to 640 ms.

## Impact

- app-prod-03 out of service for 55 minutes.
- p95 API latency elevated on the remaining nodes for the same period.
- About 0.4 % of requests during the window returned 502 before the load
  balancer health check marked the node unhealthy.
- journald on the host stopped persisting logs from 02:04 to 02:41, which
  left a gap in the audit trail.
- No data loss. The database is on separate hosts.

## Timeline (IST)

| Time | Event |
|---|---|
| 04-13 16:30 | Debug logging enabled on app-prod-03 (`LOG_LEVEL=debug` in the unit drop-in) to investigate a payment-callback bug. |
| 04-13 17:45 | Investigation concluded and the bug-fix ticket closed. The log level change was not reverted; nothing on the ticket checklist asked for it. |
| 04-13 23:10 | `/var` passes 80 %. No page: this host still used the old cron-based disk check, which only emailed a shared mailbox. |
| 04-14 00:00 | Nightly logrotate run. The 12 GB `app.log` is renamed to `app.log.1`. Because of `delaycompress` it stays uncompressed until the next run, so no space is freed. |
| 04-14 02:04 | `/var` reaches 100 %. journald reports `No space left on device`. |
| 04-14 02:10 | App health endpoint starts returning 500. Load balancer marks the target unhealthy. PagerDuty alert for "target unhealthy" pages the on-call engineer. |
| 02:18 | On-call acknowledges and SSHes in. `df -h` shows `/var` 100 %. |
| 02:24 | `du -xh --max-depth=2 /var` identifies `/var/log/myapp` at 15.3 GB (`app.log.1` 12 GB, live `app.log` 3.3 GB). |
| 02:27 | `rm` of the live `app.log` is considered and rejected: the process would keep the deleted file open and no space would be freed (runbook step 4). The last 100k lines are saved, the live file is truncated, and `app.log.1` is compressed to the backup volume and removed. `/var` drops to 39 %. |
| 02:31 | Service restarted. Health endpoint returns 200. |
| 02:41 | journald is writing again (`systemctl restart systemd-journald`). |
| 02:45 | Root cause found: `systemctl cat myapp` shows the `LOG_LEVEL=debug` drop-in. It is removed and the service restarted at the normal log level. |
| 03:05 | Node back in the load balancer pool and latency back to baseline. Incident resolved. |

## Root cause

Several contributing factors combined. No single one of them would have
caused an outage.

1. **A temporary change with no expiry.** Debug logging was enabled with no
   mechanism or checklist step to revert it.
2. **Rotation was time-based only.** `daily` without `maxsize` assumes log
   volume is roughly constant. Debug mode raised it about 40 times, and
   `delaycompress` meant the first rotation freed no space at all.
3. **Logs shared a filesystem with application state.** `/var/log` was not
   a separate LV, so log growth affected PID files, sessions and journald.
4. **The disk alert did not reach a person.** This host had not yet been
   moved to the health-check timer. Its legacy cron check emailed a shared
   inbox that nobody watches overnight. The first page came from the load
   balancer, after customers were already affected.

## What went well

- The load balancer health check removed the bad node automatically and
  the remaining capacity absorbed the traffic.
- The disk-full runbook steered the on-call engineer away from `rm` on an
  open file, which would have wasted time.
- The root cause was identified within 30 minutes of the page.

## What went poorly

- The 80 % warning fired three hours before the outage and nobody saw it.
- The journald gap made it harder to reconstruct events afterwards.

## Action items

| # | Action | Type | Owner | Status |
|---|---|---|---|---|
| 1 | Add `maxsize 500M` to all application logrotate policies (`configs/logrotate-linux-admin-lab`) | Prevent | Cloud Ops | Done |
| 2 | Move every host to `health-check.timer` and route WARNING/CRITICAL to the on-call alerting channel instead of email | Detect | Cloud Ops | Done |
| 3 | Cap journald with `SystemMaxUse=1G` fleet-wide | Mitigate | Cloud Ops | Done |
| 4 | Move `/var/log` to its own LV on the next image build | Mitigate | Platform | In progress |
| 5 | Add "revert temporary debug/log-level changes" to the incident and bug-ticket close checklist | Process | Eng Managers | Done |
| 6 | Support a time-limited debug mode in the app (auto-revert after N hours) | Prevent | App team | Backlog |

## Lessons learned

- Plan rotation around the worst-case log volume, not the average. A size
  cap is cheap insurance.
- An alert that nobody acts on does not protect anything. Alerts are only
  useful if they are routed to someone on call.
- Temporary changes need an owner and an end date.
