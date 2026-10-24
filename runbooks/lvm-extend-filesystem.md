# Runbook: Extend an LVM-backed filesystem online

Both ext4 and XFS can be **grown** while mounted, with no downtime.
Neither should be shrunk online (XFS cannot be shrunk at all), so size
increases carefully: you cannot easily take space back.

## Symptoms / when to use

- Disk alert where cleanup alone is not enough (see [disk-full.md](disk-full.md))
- Planned capacity increase from a change ticket

## Triage: understand the stack first

```bash
lsblk -f                         # disk -> partition -> PV -> LV -> filesystem
df -hT /var                      # filesystem type matters (ext4 vs xfs)
sudo pvs; sudo vgs; sudo lvs     # is there free space (VFree) in the VG already?
```

Decide which case you are in:

- **A.** VG already has free extents -> go to step 3
- **B.** Cloud disk was (or will be) resized -> steps 1-3
- **C.** New disk attached -> step 2b, then 3

## Resolution

**0. Safety first.** Take a snapshot of the cloud volume (EBS snapshot / GCE
disk snapshot) or confirm a recent backup. Note the current sizes in the
ticket.

**1. Resize the cloud disk** in the console or CLI, for example:
```bash
aws ec2 modify-volume --volume-id vol-0abc123 --size 100
```
Then make the kernel see it:
```bash
lsblk                                        # confirm new disk size
sudo growpart /dev/nvme1n1 1                 # only if the PV is a partition (cloud-guest-utils / cloud-utils-growpart)
sudo pvresize /dev/nvme1n1p1                 # or /dev/nvme1n1 if the PV is the whole disk
sudo vgs                                     # VFree should now show the new space
```

**2b. Or add a new disk to the VG:**
```bash
sudo pvcreate /dev/nvme2n1
sudo vgextend vg_data /dev/nvme2n1
```

**3. Extend the LV and the filesystem in one step.** `-r` (`--resizefs`)
calls `resize2fs` or `xfs_growfs` for you:
```bash
sudo lvextend -r -L +20G /dev/vg_data/lv_var          # add 20 GiB
# or use all remaining free space in the VG:
sudo lvextend -r -l +100%FREE /dev/vg_data/lv_var
```

If the LV was extended without `-r`, grow the filesystem manually:
```bash
sudo resize2fs /dev/vg_data/lv_var      # ext4: takes the device
sudo xfs_growfs /var                    # XFS: takes the MOUNT POINT
```

**4. Verify.**
```bash
df -hT /var
sudo lvs vg_data
```

## Prevention

- Do not allocate 100 % of a VG at build time; keep 10-20 % free so an
  emergency extend needs no cloud-side change.
- Separate LVs for `/var`, `/var/log`, `/home` so one runaway consumer
  cannot fill `/`.
- Alert at 80 %, giving time for a planned change instead of a 3 a.m. one.
- Record every extend in the CMDB / ticket so growth trends are visible.
