# Runbooks

On-call runbooks for the Linux fleet. Each follows the same shape so you can
skim under pressure: **Symptoms -> Triage -> Resolution -> Prevention**.

| Runbook | Typical alert |
|---|---|
| [disk-full.md](disk-full.md) | `health-check: CRITICAL - /var 96% used` |
| [high-cpu-load.md](high-cpu-load.md) | `health-check: WARNING - load 2.10/core` |
| [service-down.md](service-down.md) | `health-check: CRITICAL - nginx.service failed` |
| [ssh-lockout.md](ssh-lockout.md) | "I can't SSH to the box" ticket |
| [lvm-extend-filesystem.md](lvm-extend-filesystem.md) | Planned change after a disk alert |

Ground rules:

- Record what you ran and when in the incident channel or ticket. The
  postmortem is written from that timeline.
- Prefer reversible actions. Take a backup or snapshot before anything that
  is not.
- If a step here is wrong or missing, fix the runbook as part of closing the
  incident.
