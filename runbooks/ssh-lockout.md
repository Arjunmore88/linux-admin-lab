# Runbook: Locked out of SSH

**Golden rule for anyone changing SSH or firewall config:** keep your current
session open and test a *new* connection before you log out.
`harden-ssh.sh` uses `reload` for exactly this reason.

## Symptoms

- `Permission denied (publickey)`
- `Connection refused` (sshd not listening, or wrong port)
- `Connection timed out` (firewall, security group, or host down)
- One user cannot log in, others can

## Triage (from your workstation)

```bash
# Verbose client output shows which keys were offered and where it stops
ssh -vvv -i ~/.ssh/id_ed25519 user@host

# Is the port reachable at all?
nc -vz -w 5 host 22
```

| Client sees | Meaning | Look at |
|---|---|---|
| timed out | packets dropped | cloud security group / NACL, host firewall, instance state |
| refused | host up, nothing on that port | sshd stopped, or listening on another `Port` |
| `Permission denied (publickey)` | sshd up, auth rejected | key, permissions, `AllowGroups`, account locked/expired |
| `Too many authentication failures` | agent offered too many keys | `ssh -o IdentitiesOnly=yes -i key ...` |

## Getting back in (out-of-band)

Use whichever the platform provides. None of these depend on sshd:

- **AWS:** EC2 Instance Connect, SSM Session Manager
  (`aws ssm start-session --target i-xxxx`), or EC2 Serial Console
- **GCP:** serial console (`gcloud compute connect-to-serial-port`), or
  OS Login via the console
- **Azure:** Serial Console, or Run Command
- **VMware / bare metal:** hypervisor console, iLO / iDRAC
- **Last resort:** stop the instance, attach its root volume to a rescue
  instance, fix files, reattach

## Resolution (once on the console)

```bash
sudo systemctl status sshd        # 'ssh' on Ubuntu
sudo sshd -t                      # config syntax errors are printed here
sudo journalctl -u sshd -n 50     # look for 'Authentication refused', 'not allowed because'

# Restore the last known-good config written by harden-ssh.sh
ls -lt /etc/ssh/sshd_config*.bak.* /etc/ssh/sshd_config.d/*.bak.* 2>/dev/null
sudo cp -p /etc/ssh/sshd_config.bak.<timestamp> /etc/ssh/sshd_config
sudo sshd -t && sudo systemctl reload sshd

# Key and permission problems (sshd StrictModes rejects loose permissions)
sudo chmod 700 /home/<user>/.ssh
sudo chmod 600 /home/<user>/.ssh/authorized_keys
sudo chown -R <user>:<user> /home/<user>/.ssh
sudo restorecon -Rv /home/<user>/.ssh          # RHEL: wrong SELinux label is a classic

# Account locked or expired?
sudo chage -l <user>
sudo passwd -S <user>

# Host firewall
sudo ufw status numbered          # Ubuntu
sudo firewall-cmd --list-all      # RHEL
```

## Prevention

- Change SSH and firewall settings only through `harden-ssh.sh` and
  `firewall-baseline.sh`: they validate, back up, and keep SSH allowed.
- Make sure SSM Agent / serial console access is enabled on every instance
  *before* you need it.
- Keep at least two admin keys enrolled (person + break-glass) and test the
  break-glass path quarterly.
