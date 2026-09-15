# TODO

Work not yet done. How the collection works and why it is built that way is in
`DESIGN.md`; this file records only what is outstanding, with enough of the finding
behind each item that it does not need rediscovering.

## Ubuntu support

Deferred in favour of getting Talos working first. Ubuntu is a second OS profile
rather than a rewrite: both are "boot installer media, install to disk, reboot into
the installed system", and the Redfish layer is already OS-agnostic.

Use `pokerops.ubuntu_installer` to build custom per-device ISOs that assign static
addressing and bootstrap required OS parameters. Accept subiquity reaching out to
external repositories to update the OS on first install.

A second profile also needs its own notion of "already provisioned". The current
probe is Talos-shaped: reachability on port 50000 at `ansible_host`.

## Bare-metal scenario

A second molecule scenario driving real iDRAC instead of sushy, sharing the Redfish
steps.

- Optionally move to `dellemc.openmanage.idrac_virtual_media` and `idrac_boot` over
  `community.general.redfish_command`; narrowing to iDRAC is what buys escape from
  vendor one-time-boot quirks. Skip `idrac_os_deployment` -- it is CIFS/NFS only,
  which would force a Samba or NFS share in place of a throwaway HTTP server.
- This scenario is where everything listed under "What the harness cannot exercise"
  in `DESIGN.md` first gets tested: LACP negotiation and fallback, richer
  `LinkStatus` data, the solid-state half of the install-disk rule, and pinning the
  install disk by wwid.
- Verify the switch-ordering failure mode on one machine before trusting it across a
  fleet: applying an 802.3ad bond to a host whose ports are not yet in a
  port-channel should leave it with no aggregator and no connectivity.

## LLDP: the switch side

`siderolabs/lldpd` is in the schematic and running, so the machines already
advertise themselves. What is left is a playbook per switch OS family to read the
neighbour table and configure ports from it.

Deliberately deferred to the bare-metal tests: nothing here can be written against a
libvirt bridge, which speaks no LLDP and has no neighbour table to read. The switch
side also needs `configure lldp portidsubtype ifname`, without which the neighbour
table repeats MAC addresses instead of naming interfaces.

## Smaller items

- **The virtual media eject is not retried.** Every other Redfish call in `boot.yml`
  reads its result back and repeats, after sushy answered 500 "database is locked"
  under six concurrent machines. The eject is deliberately left tolerant instead:
  `failed_when: false`, on the grounds that the insert following it is what actually
  needs a free slot and reports plainly when there is none. If a locked eject ever
  does strand a slot, that reasoning is what to revisit.

## NTP configuration

## BGP configuration

## Upgrade scenario

## Cluster add worker support/scenario

## Cluster delete worker support/scenario

## Cluster reinstall worker support/scenario

## Cluster renstall control support/scenario
