# linux-admin-lab

[![CI](https://github.com/Arjunmore88/linux-admin-lab/actions/workflows/ci.yml/badge.svg)](https://github.com/Arjunmore88/linux-admin-lab/actions/workflows/ci.yml)
![Shell](https://img.shields.io/badge/shell-bash-4EAA25)
![Platforms](https://img.shields.io/badge/platforms-Ubuntu%20%7C%20RHEL%20%7C%20Rocky%20%7C%20Alma-blue)
[![License: MIT](https://img.shields.io/badge/license-MIT-lightgrey)](LICENSE)

Scripts, systemd units, configs and runbooks for bringing a mixed Ubuntu and
RHEL fleet to a standard operational baseline. Everything is linted with
ShellCheck and covered by bats tests in CI.

## Scenario

> You've joined a company's cloud ops team; an Ubuntu/RHEL fleet needs to be
> brought to a standard baseline.

The servers were built by different people over several years. Accounts
are created by hand and never removed, SSH accepts passwords on some hosts,
firewall state varies from host to host, and the only monitoring is a cron
job that emails a shared mailbox. A recent outage
([INC-2026-0412](docs/postmortem-2026-04-var-full.md)) happened when `/var`
filled with logs while the warning sat unread in that mailbox.

This repository is the team's toolkit for fixing that. It has to be safe
to run on production, it has to behave the same on both distro families,
and it has to be easy to hand over to whoever is on call.

## What's covered

| Area | Deliverable | Highlights |
|---|---|---|
| Identity and access | [`onboard-users.sh`](scripts/onboard-users.sh), [`offboard-user.sh`](scripts/offboard-user.sh) | CSV-driven; validates every row before changing anything; SSH key-only accounts; sudo via `/etc/sudoers.d` checked with `visudo -c`; account expiry for contractors; offboarding locks access *before* archiving the home directory |
| SSH hardening | [`harden-ssh.sh`](scripts/harden-ssh.sh) | Idempotent; timestamped backup; `sshd -t` before reload, with automatic rollback; uses a `00-` drop-in on modern distros so it overrides `50-cloud-init.conf`; refuses to disable passwords if you have no key |
| Network | [`firewall-baseline.sh`](scripts/firewall-baseline.sh) | Detects ufw or firewalld; default-deny inbound; SSH is allowed before deny is enabled; strips RHEL's default cockpit/dhcpv6 openings |
| Monitoring | [`health-check.sh`](scripts/health-check.sh) + [systemd timer](systemd/) | Disk, inode, memory (`MemAvailable`), per-core load, service state; Nagios exit codes 0/1/2/3; runs under a sandboxed `DynamicUser` |
| Backup | [`backup.sh`](scripts/backup.sh) | tar.gz + SHA-256, verified before old copies are pruned; atomic `.partial` rename; `flock` against overlapping runs; per-job retention |
| OS config | [`configs/`](configs/) | CIS-aligned sysctl hardening, logrotate with size caps, sample onboarding CSV |
| Operations | [`runbooks/`](runbooks/), [`docs/`](docs/) | Five on-call runbooks (symptoms, triage, resolution, prevention) and a blameless postmortem |
| Quality | [`tests/`](tests/), [CI](.github/workflows/ci.yml) | 49 bats tests; ShellCheck; matrix on Ubuntu 22.04/24.04 and a Rocky Linux 9 container |

## Repository layout

```
linux-admin-lab/
├── scripts/
│   ├── lib/common.sh          # logging, dry-run wrapper, root check, distro detection
│   ├── onboard-users.sh       # create/update users from CSV
│   ├── offboard-user.sh       # lock, revoke, archive home
│   ├── harden-ssh.sh          # sshd baseline with validation and rollback
│   ├── firewall-baseline.sh   # ufw / firewalld default-deny
│   ├── health-check.sh        # Nagios-style host health check
│   └── backup.sh              # checksummed backups with retention
├── systemd/
│   ├── health-check.service   # sandboxed oneshot unit
│   ├── health-check.timer     # every 5 min, replaces cron
│   └── health-check.default   # per-host args -> /etc/default/health-check
├── configs/
│   ├── users.csv                  # sample onboarding batch
│   ├── logrotate-linux-admin-lab  # -> /etc/logrotate.d/
│   └── 99-sysctl-hardening.conf   # -> /etc/sysctl.d/
├── runbooks/                  # disk full, high load, service down, SSH lockout, LVM extend
├── docs/
│   └── postmortem-2026-04-var-full.md
├── tests/                     # bats suites + fixtures (fake /proc, os-release)
├── .github/workflows/ci.yml   # ShellCheck + bats (Ubuntu matrix + Rocky 9)
├── .shellcheckrc
├── Makefile                   # make lint | test | check | install-timer
└── LICENSE
```

## Design conventions

Every script follows the same conventions, so a reviewer who has read one
can read the rest:

- `set -euo pipefail`, `--help`, and the same exit codes everywhere:
  **0** success, **1** runtime failure, **2** usage or validation error.
  `health-check.sh` uses Nagios codes instead (0/1/2/3).
- **`--dry-run`** on everything that changes the system. All changes go
  through one `run` wrapper, so a dry run prints exactly the commands a real
  run would execute.
- **Validate first.** Input is fully validated (CSV rows, ports, thresholds,
  usernames) before the first change, and all errors are reported at once.
- **Root check after argument parsing**, so `--help`, `--validate-only`,
  `--print` and `--dry-run` work for unprivileged users.
- **Distro detection** parses `/etc/os-release` (it is not sourced) and maps
  `ID`/`ID_LIKE` to `debian` or `rhel` family. That decides `ssh` vs `sshd`,
  ufw vs firewalld, and which package hints to print.
- **Idempotent.** Re-running a script on a compliant host makes no changes
  and says so.
- Timestamped logging to stderr, plus an optional `LOG_FILE`.

## Quick start

```bash
git clone https://github.com/Arjunmore88/linux-admin-lab.git
cd linux-admin-lab

# Lint and test (needs shellcheck and bats-core)
make check

# Everything below is safe to try as a normal user
./scripts/onboard-users.sh --csv configs/users.csv --validate-only
./scripts/onboard-users.sh --csv configs/users.csv --dry-run
./scripts/harden-ssh.sh --print --allow-groups "cloudops"
./scripts/firewall-baseline.sh --allow 443/tcp --dry-run
./scripts/health-check.sh --service ssh.service; echo "exit=$?"
./scripts/backup.sh -s ~/projects -d /tmp/backups -N projects -r 7
```

Applying the baseline to a host (as root, after reviewing the dry runs):

```bash
sudo ./scripts/onboard-users.sh --csv /secure/path/users.csv
sudo ./scripts/harden-ssh.sh --allow-groups "cloudops sudo wheel"   # keep this session open; test a new login
sudo ./scripts/firewall-baseline.sh --allow 443/tcp
sudo install -m 0644 configs/99-sysctl-hardening.conf /etc/sysctl.d/ && sudo sysctl --system
sudo install -m 0644 configs/logrotate-linux-admin-lab /etc/logrotate.d/linux-admin-lab
sudo make install-timer                     # health check every 5 minutes via systemd
```

Check the timer:

```bash
systemctl list-timers health-check.timer
journalctl -u health-check.service -n 20
systemctl --failed                          # a WARNING/CRITICAL run shows up here
```

Offboarding a leaver:

```bash
sudo ./scripts/offboard-user.sh --user rkulkarni --dry-run
sudo ./scripts/offboard-user.sh --user rkulkarni     # archive in /var/backups/offboarded/
```

## Health check output

```
$ ./scripts/health-check.sh --service nginx.service
CRITICAL - /var 93% used; nginx.service failed
  disk / 41%
  disk /var 93%
  memory 62% used (1480 MiB available)
  load5 0.84 on 2 core(s) = 0.42/core
  service nginx.service failed
$ echo $?
2
```

The first line is the summary that Nagios, Icinga or an NRPE wrapper
displays. Under systemd, any non-zero exit puts the unit in a failed state,
which `OnFailure=` hooks or node_exporter's systemd collector can alert on.

## Testing

```
$ make check
shellcheck -x scripts/lib/common.sh scripts/backup.sh ... tests/test_helper.bash
lint OK
bats tests/
1..49
ok 1 --help prints usage and exits 0
ok 2 missing --dest is a usage error
...
ok 49 real run as non-root is refused after validation
```

The tests never need root and never change the host:

- CSV validation, argument parsing and `--help` for every script
- dry-run plans, e.g. checking that ufw allows SSH *before* `default deny`
- the sshd config renderer against temporary files, including idempotency
  and a real `sshd -t` syntax check with a throwaway host key
- health-check thresholds, using fake `/proc/meminfo` and `/proc/loadavg`
  fixtures
- real backups, checksum tamper detection and retention pruning inside a
  temporary directory

CI also runs the suite inside a Rocky Linux 9 container, as an unprivileged
user, to catch Ubuntu-only assumptions.

## Skills demonstrated

- **Linux administration:** users, groups, sudoers, `chage`, SSH, systemd
  units and timers, logrotate, sysctl, LVM, ufw and firewalld
- **Cross-distro support:** Ubuntu/Debian and RHEL/Rocky/Alma handled in
  one code path
- **Security hardening:** key-only SSH, least-privilege systemd sandboxing
  (`ProtectSystem=strict`, `DynamicUser`, syscall filtering), CIS-aligned
  kernel parameters, default-deny firewall
- **Defensive Bash:** strict mode, input validation, dry-run, idempotency,
  backup-validate-rollback, locking, atomic writes
- **Monitoring and operations:** Nagios-compatible checks, runbooks,
  blameless postmortems with action items
- **CI and testing:** GitHub Actions, ShellCheck, bats-core, a multi-distro
  test matrix

## Author

**Arjun More**: aspiring Associate Cloud Engineer / Linux administrator.

- GitHub: [@Arjunmore88](https://github.com/Arjunmore88)

## License

[MIT](LICENSE)
