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
- Create playbooks per switch OS family to read the
  neighbour table using LLPD and configure ports from it.

## Smaller items

- **The virtual media eject is not retried.** Every other Redfish call in `boot.yml`
  reads its result back and repeats, after sushy answered 500 "database is locked"
  under six concurrent machines. The eject is deliberately left tolerant instead:
  `failed_when: false`, on the grounds that the insert following it is what actually
  needs a free slot and reports plainly when there is none. If a locked eject ever
  does strand a slot, that reasoning is what to revisit.

## BGP configuration

## Upgrade coverage

`pokerops.baremetal.talos.upgrade` rolls a release through the fleet and the
`upgrade` molecule scenario exercises it between the two most recent releases on
the toolchain's minor line. What is not covered yet:

- **The minor-jump refusal is guarded but not exercised by a scenario.** A target
  more than one minor ahead of any member is refused and single-minor jumps are
  allowed, but the scenario only runs a patch hop: staging a minor jump means
  bumping the toolchain in the same change, since `media/talos.yml` asserts the
  image minor matches the local `talosctl`. The downgrade refusal is exercised --
  the scenario runs the upgrade pinned to an older release, requires it to fail at
  the guard, and asserts the fleet did not move.
- **Kubernetes version upgrades.** `talosctl upgrade-k8s` is a separate operation
  from the Talos upgrade and is not wired up.

## Cluster add worker support/scenario

## Cluster delete worker support/scenario

## Cluster reinstall worker support/scenario

## Cluster renstall control support/scenario
