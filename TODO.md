# TODO

Deferred work, recorded with the findings behind each decision so they do not need
rediscovering.

## Ubuntu support

Deferred in favour of getting Talos working first. Ubuntu is a second OS profile rather
than a rewrite: both are "boot installer media, install to disk, reboot into the
installed system", and the Redfish layer is already OS-agnostic.

### Mechanism

Use pokerops.ubuntu_installer to build custom per-device isos that assign static
addressing and bootstrap required OS parameters. We will accept subiquity reaching out
to external repositories to update the OS on first install

## Bare-metal scenario

A second molecule scenario driving real iDRAC instead of sushy, sharing the Redfish
steps. From the design discussion:

- Optionally move to `dellemc.openmanage.idrac_virtual_media` and `idrac_boot` over
  `community.general.redfish_command`; narrowing to iDRAC is what buys escape from
  vendor one-time-boot quirks. Skip `idrac_os_deployment` -- it is CIFS/NFS only, which
  would force a Samba or NFS share in place of a throwaway HTTP server.

## Re-running against an installed fleet

`pokerops.baremetal.talos` is not safe to re-run over a live cluster, and the talos
scenario omits the `idempotence` stage for that reason.

Two separate causes:

- Factory ISOs carry `talos.config=metal-iso talos.halt_if_installed=1`. Booting the
  installer on a machine that already has Talos on disk halts it rather than
  reinstalling -- correct and protective, but it means `boot.yml` powers a healthy
  node off and leaves it there.
- `seed/talos.yml` regenerates the per-node configs each run. Harmless today because
  `gen config` is guarded by `creates`, so the CA is stable, but the configs are
  re-published and the machines never re-read them.

This now fails loudly rather than quietly: discovery looks for machines in
maintenance mode, and an installed machine never returns there, so the scan times
out naming the machines it could not find instead of silently reconfiguring a live
cluster. That is an improvement, not a fix -- `boot.yml` has already power-cycled
the fleet into the installer by the time discovery runs.

The fix is a guard before boot: skip machines already answering on 50000 with a
configuration that matches, or require an explicit reinstall variable. Until then,
reinstalling means `destroy` first.

## What the harness cannot reach

The scenario exercises discovery, subnet filtering, member selection, the
connected-interface assertion and a real bond carrying the node's address. Three
things it cannot exercise, all bare-metal only:

- **LACP negotiation.** A libvirt bridge speaks no LACP, so `baremetal_bond_mode`
  is overridden to `active-backup` in the scenario. 802.3ad is untested here.
- **LACP fallback.** The entire design depends on ports forwarding while a machine
  in maintenance mode speaks no LACP. Nothing in the harness can simulate a switch
  suspending or releasing a port, and a switch without fallback fails discovery
  outright rather than subtly.
- **`LinkStatus` and OEM switch data.** sushy advertises `EthernetInterface.v1_0_2`
  and returns only MACs, so anything richer from a real BMC is unverified.
- **The solid-state half of the install-disk rule.** A virtio disk reports itself
  as rotational, so `baremetal_install_disk_require_ssd` is off in the scenario.
  The rest of the rule is exercised: each machine has two disks and picking the
  larger one would leave it unable to boot.
- **Pinning the install disk by a stable identifier.** virtio disks report no
  wwid, serial or uuid, so only the `busPath` fallback is reached here. Real NVMe
  and SAS disks report a wwid, which is the branch that would actually be used.

## LLDP

No longer needed to bootstrap. Discovery identifies the provisioning interfaces
from DHCP -- the links holding an address inside the provisioning subnet are the
ones on that network -- so nothing has to be told which port faces which switch.

It remains useful for two things neither of which blocks anything: confirming that
the links found really are cabled to the expected switch pair, and disambiguating
a topology where several networks share a subnet. Talos ships no LLDP in the base
image (checked at v1.13.8: `pkg/machinery/config/types/network` defines bond,
bridge, dhcp4/6, ethernet, hostname, kubespan, link, resolver, vlan, vrf,
wireguard and others, nothing for LLDP); it exists as the official
`siderolabs/lldpd` extension, and Dell iDRAC exposes switch-connection data from
the BMC without needing the OS at all. The BMC route is the one to try first.

Note that an extension only survives installation if `machine.install.image`
points at the Factory installer for the same schematic. It does not today.

## Media server teardown

`media/stop.yml` exists but nothing calls it. It was left out until the full boot
procedure worked end to end, which it now does. Deciding where it belongs is the
remaining work: the server holds the image cache, so tearing it down with each run
throws away the images that make a re-run cheap.

## Smaller items

- **`ansible-test sanity` is not wired up.** `just units` runs the module's unit
  tests, but the collection-standard gate -- which validates the DOCUMENTATION and
  RETURN blocks against the argument spec, and runs pep8 and import checks -- does
  not. It needs the repository to sit at `ansible_collections/nephelaiio/baremetal`,
  which this checkout does not, so it wants a symlinked working directory in the
  recipe rather than a plain invocation.

- **The virtual media eject is not retried.** Every other Redfish call in `boot.yml`
  reads its result back and repeats, after sushy answered 500 "database is locked"
  under six concurrent machines. The eject is deliberately left tolerant instead:
  `failed_when: false`, on the grounds that the insert following it is what actually
  needs a free slot and reports plainly when there is none. If a locked eject ever
  does strand a slot, that reasoning is what to revisit.
