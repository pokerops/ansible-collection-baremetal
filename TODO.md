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

## Upgrade coverage

`pokerops.baremetal.talos.upgrade` rolls a release through the fleet. The `patch`
scenario exercises a patch hop between the two most recent releases on the
toolchain's minor line, and the downgrade refusal with it. The `minor` scenario
builds the fleet one minor back -- installing the talosctl that matches, because
`media/talos.yml` requires the boot image and the toolchain to share a minor --
then refuses a two minor jump and takes the one minor step. What is not covered
yet:

- **No fleet is ever built more than one minor behind.** The machine configuration
  `seed.yml` renders carries a `HostnameConfig` document, which talosctl only
  registers from 1.12 onwards, so a fleet built two minors back dies at
  `talosctl validate` rather than reaching anything the upgrade path owns. The
  `minor` scenario therefore refuses a target two minors ahead of the fleet -- the
  minor after the toolchain's, which has no release yet -- exercising the guard's
  arithmetic without ever resolving an installer image for it. Reaching further
  back means rendering a configuration the older talosctl accepts.

## Cluster scaling

`pokerops.baremetal.talos.teardown` converges cluster membership down to the
inventory -- drain, wipe, delete the node, forget what discovery recorded -- under
`baremetal_talos_teardown_enable`, and the `scale` molecule scenario takes a worker
out of the inventory and puts it back. Scaling out needed no new code: a machine that
has been torn down is an inventory host that does not answer, which is what deploy
already installs. What is not covered yet:

- **Control plane members cannot be taken out.** Teardown refuses them. It means
  having the member leave etcd first -- `talosctl etcd leave`, or `etcd remove-member`
  from a survivor when it is already gone -- and then deciding what a cluster does
  when a removal would drop it below quorum. Neither is written.
- **A machine that is already unreachable is not reclaimed.** The wipe needs the
  Talos API, so a member that died before it left the inventory has its node object
  deleted and its disk left as it was. Whoever revives it gets a machine that still
  believes it is a member. Teardown reports the address it could not reach.
- **Only one machine is taken out at a time.** Teardown loops over the members it
  found, so several ought to work, but nothing asserts that a cluster losing two
  workers at once reschedules what was on them.
- **Nothing asserts the refusal to run on an unreadable cluster.** Teardown stops
  when `baremetal_talos_teardown_enable` is set and the cluster cannot be read, on
  the grounds that taking machines out on a partial answer is guesswork. That guard
  is exercised by hand, not by a scenario.

## Cluster reinstall worker support/scenario

Largely covered by the scaling path already: removal wipes the machine and the next
deploy installs it again. What is missing is the trigger, `baremetal_reinstall=true`,
which forces a machine that is still a healthy member back onto the install path
without going through removal first.

## Cluster reinstall control support/scenario
