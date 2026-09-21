# Design

How this collection provisions bare metal, and why it is built the way it is. The
code carries no rationale of its own -- this file is where it lives, so that an
explanation is written once rather than beside each of the places it applies.

`TODO.md` is the companion to this file: it records work not yet done.

## Provisioning model

A machine arrives with nothing on it. It is not declared anywhere, it has no
configuration, and nothing about its interfaces or disks is known in advance. The
only fact available before it boots is how to reach its BMC.

From there the sequence is:

1. **Classify.** Decide, per machine, whether it needs installing or is already a
   cluster member.
2. **Publish media.** Build one boot image for the fleet and put it on an HTTP
   server the machines can reach.
3. **Boot.** Point each BMC at that image over Redfish and power the machine on.
4. **Discover.** The machine reaches Talos maintenance mode, DHCPs on every link,
   and answers an API that exists before any configuration does. Ask it what it is
   made of.
5. **Seed.** Generate the cluster's credentials once, render a machine
   configuration per node, and push it to the machine at its maintenance address.
6. **Install.** The machine writes itself to disk, reboots, and comes up at the
   static address the configuration gave it.
7. **Bootstrap.** Bring up etcd once, from a single control plane node, and wait
   for the cluster to become healthy.

Everything before step 7 is per machine and independent. Step 7 is the first thing
that is true of the fleet rather than of a machine.

## The collection interface

`roles/baremetal/defaults/main.yml` is the interface. Every knob any playbook reads
is declared there, so that one file documents what can be set and what it defaults
to.

Nothing is referenced without a default. Kubernetes settings are named
`baremetal_talos_k8s_*`, so that the knobs belonging to the cluster running on
Talos are distinguishable at a glance from the knobs belonging to Talos itself. An undefined name in `hosts:` is not an
empty match that skips a play quietly -- it aborts the run with "Error processing
keyword 'hosts'".

Required parameters have no sensible default and are listed in that file as
commented names rather than empty values: the BMC address, username and password per
node, and the provisioning gateway and prefix per fleet. A wrong gateway or prefix
produces a machine that boots, configures itself and reaches nothing, which reads as
a hardware fault rather than as a typo.

## Classification: install or member

`playbooks/talos/groups.yml` runs before anything powers off and sorts the fleet
into dynamic groups. A machine that answers on port 50000 at its `ansible_host` is
already provisioned and joins `_baremetal_talos_member`; everything else joins
`_baremetal_talos_install`. Control plane and worker groups are derived the same way,
so each play targets the exact set it applies to.

This matters because booting installer media at a machine that already has Talos on
disk halts it rather than reinstalling it -- `talos.halt_if_installed=1` -- which
took a live six-node cluster down once. Every install-path play targets the install
group, so a re-run against a built cluster finds no hosts for them.

`baremetal_reinstall=true` forces machines back onto the install path.

The classification tasks are marked `changed_when: false`. `group_by` reports changed
unconditionally, but it only binds hosts to groups and touches nothing on a managed
node, so counting it as a change would mean the collection could never report a
converged fleet as unchanged.

An earlier design used a guard play that refused to run at all when it found an
installed machine. Classification does the same job without the veto, and a mixed
fleet -- some machines built, some not -- splits automatically rather than having to
be separated by hand or rebuilt wholesale.

The same playbook asks the question from the cluster's side: which members does the
cluster carry that the inventory does not? Those cannot be a group, because a group
holds inventory hosts and these are exactly the machines no longer in the inventory,
so they are published as facts on localhost -- the way discovery publishes what it
scanned. `_baremetal_talos_orphans` holds all of them, and they are split by role
into `_baremetal_talos_orphan_control` and `_baremetal_talos_orphan_worker`, which is
what lets teardown refuse one kind and act on the other without deciding anything
itself.

Which role a member holds comes from the cluster rather than from the inventory,
which by definition no longer describes it: the label kubelet registered with, rather
than the group the host used to sit in. `_baremetal_cluster_readable` records whether
the cluster answered at all, because an empty orphan list otherwise means either that
there are none or that nothing could be read. The read is tolerated rather than
fatal, so a fleet with no cluster yet classifies normally.

That set is compared against the inventory groups rather than against the groups
above, because those honour `--limit`. A run limited to one machine would otherwise
be indistinguishable from an inventory every other member had been taken out of, and
teardown would eat the cluster.

## Boot media

**One image for the whole fleet.** Nothing in the image is per node -- no address,
no configuration URL -- so every machine boots the same URL. Talos fetches its own
configuration over HTTP keyed by MAC, so nothing has to be attached per machine.

**The image comes from the Talos Image Factory**, which builds from a schematic:
the kernel arguments and system extensions the machines need. Schematics are
content-addressed, so the cached image is keyed by schematic id and version -- both
change the image, and a name encoding neither would let the cache check serve a
stale build forever.

**The installer image must be the Factory installer for the same schematic.** The
installed system is built from `machine.install.image`, not from the ISO it booted.
Pointing that at the stock installer silently drops everything the schematic added,
kernel arguments and extensions alike. Confirmed on an installed machine:
`/proc/cmdline` came back without `console=ttyS0`, so the serial console -- the only
channel into a machine that will not boot -- was gone.

**The Talos version tracks the local toolchain.** `talosctl gen config` bakes in the
Kubernetes version its own binary defaults to, and a node refuses a Kubernetes newer
than its Talos supports, so the image has to follow `talosctl` rather than a moving
upstream pointer. `baremetal_talos_release` is empty by default to mean exactly that;
an explicit override needs a `talosctl` pinned to the same minor, which
`playbooks/talos/media.yml` asserts rather than assumes. Nothing else catches this:
the Kubernetes version comes from talosctl and the Talos version from the image, and
`talosctl validate` reads only the former, so it passes on a configuration no node in
the fleet will accept.

**Publishing is a server-side copy.** dufs implements WebDAV COPY, so promoting a
cached image to the boot URL is a file operation on the server whatever the image
size. The cache name carries the schematic and version; the boot URL stays stable so
`boot.yml` can insert it.

**The media server is dufs on host networking.** A single flag gives GET, PUT and
DELETE, so it needs no configuration file and no init hook to prepare its storage.
Host networking rather than a published port: a published port reaches the container
through Docker's DNAT and forward chains, which traffic arriving from a libvirt guest
bridge does not survive. Binding directly on the host puts the server on the
provisioning network with no NAT hop, and `--bind` keeps it off every other
interface, including loopback where something else may already hold port 80. Its
storage is a named volume so images already fetched survive a run and the cache check
has something to hit.

The first request for a schematic the Factory has not served before triggers a build
rather than a download, which is what `baremetal_boot_image_timeout` waits on.

## Discovery

`playbooks/talos/discover.yml` finds the machines and decides which of their links
and disks to use.

**Facts and judgement are separated.** `pokerops.baremetal.talos_maintenance_facts`
finds the machines and reports what they are made of, and knows nothing about what
any of it is for. Every judgement -- which links are the provisioning ones, which
disk gets installed to, what counts as a machine that is not ready -- is made in the
playbook, in the open, where it can be read and overridden.

**The scan counts against the play's own hosts.** This play installs exactly those
machines, so that is how many have to appear before the scan is complete. Naming a
group here is what broke it once: `baremetal_node_group` outlived the inventory that
defined it.

**The scan result is delegated to localhost.** The scan is `run_once`, so its fact
would otherwise land on whichever install host Ansible happened to pick, and that
host is not knowable from a later play. localhost is the one host every machine can
read from. Without the delegation the per-machine loop finds nothing and fails with
`'item' is undefined`.

**Identity comes from the BMC, composition from the machine.** The BMC is the only
thing known before a machine boots, so the BMC's MAC addresses are what tie an
inventory host to a discovered machine. Each Redfish member is fetched rather than
having its address read off the collection URL: under sushy the member id happens to
be the MAC, so parsing the URL appears to work, while a real iDRAC names them
`NIC.Integrated.1-1-1` and reports the address in the document. Both `MACAddress` and
`PermanentMACAddress` are collected, because matching is by intersection -- an extra
address costs nothing and a missing one would lose the machine.

Machines are matched on any shared MAC rather than on address: a machine with several
links on this network holds several addresses, and which one answered the scan is an
accident of timing.

**Provisioning links are the ones holding an address inside the provisioning
subnet.** This is the discrimination step, and the reason none of this needs prior
knowledge. Links are annotated first rather than accumulated, because
`baremetal_bond_members` is persisted to host_vars and appending to it would double
the list on a second run.

**Every interface is expected to reach the provisioning network.** A bond quietly
built from fewer members than the machine has is the failure this guards against: it
comes up, passes every health check, and has silently lost the redundancy it was
built for. The causes are a cable in the wrong switch, a port still inside the
fallback timer, or a switch that falls back to one member rather than all of them.
Set `_baremetal_require_all_interfaces=false` where interfaces are deliberately on
other networks.

**What is discovered is persisted to host_vars**, because a machine only answers in
maintenance mode once. After installation it boots from disk and never returns
there, so a later run cannot rediscover what it is made of, and the generated
configuration would stop being reproducible from the inventory. It is written as
`host_vars/<host>/` rather than `host_vars/<host>.yml` because Ansible loads one or
the other and never both, and the scenario's create playbook owns a file of its own
in that directory for the Redfish system ids.

## Install disk selection

The rule, stated once: **anything removable, read-only, a CD-ROM, or on a USB or MMC
transport is out; of what remains, the smallest wins.** Smallest because a machine's
system disk is routinely its least interesting one, and installing over the large
disks is the expensive mistake.

**Solid state is a separable half of the rule** (`baremetal_install_disk_require_ssd`)
because a virtio disk reports itself as rotational, and the molecule scenario would
otherwise have no eligible disk at all. It stays true against real hardware, where
installing the system onto a spinning disk beside available flash is a mistake worth
failing on.

**The chosen disk is pinned by the most stable identifier it reports** -- wwid,
then serial, then uuid, then bus path. A device path is not a stable identifier:
`/dev/sda` and `/dev/sdb` swap between boots on the same machine, and the installer
would land wherever the kernel enumerated first.

## Machine configuration

**Cluster credentials are generated once, not once per node.** `talosctl gen config`
mints the cluster CA, the admin certificate and the join tokens; per-node runs would
produce machines holding different credentials and no cluster at all. The task is
guarded with `creates` rather than run with `--force`, because re-running against a
live cluster must not mint a second CA -- that produces configurations the installed
machines reject and a talosconfig that can no longer reach them. Losing
`baremetal_talos_config_directory` loses administrative access to the fleet, which is
why it defaults to a persistent location.

**Endpoints are baked into the talosconfig**, so talosctl works against the cluster
without `-e` on every call; `gen config` leaves them empty, which makes even
`talosctl version` need two flags to reach anything. Endpoints only, deliberately not
`talosctl config node`: that sets the default target for every command including the
destructive ones, so a bare `talosctl reset` would take the whole fleet. Which
machine to act on stays something you have to say.

**The hostname is set through `HostnameConfig` with `auto` turned off.** `auto` and
`hostname` are mutually exclusive there, and `gen config` emits `auto: stable`, so
setting `machine.network.hostname` on top of it is rejected outright.

**Configurations are validated before they are applied**, which catches a malformed
document here rather than as a node that boots, fetches it, rejects it and loops --
which from the outside looks like a network fault.

**The configuration is pushed, not published for collection.** The machine is in
maintenance mode at an address DHCP gave it, and this is the last thing that uses
that address: applying the configuration brings up the bond, moves the machine to its
static address and takes the DHCP one away.

## Resolvers and time servers

`baremetal_dns_servers`, `baremetal_search_domains` and `baremetal_ntp_servers` are
empty by default, and each stanza is emitted only when its list is non-empty. Empty
means "defer to Talos", which ships its own defaults -- `1.1.1.1` and `8.8.8.8` for
resolvers, `time.cloudflare.com` for time -- so writing an empty list would replace
working defaults with nothing. They carry no `talos_` prefix because neither setting
is Talos-specific and a second OS profile needs the same two knobs.

The settings reach a machine by two different routes, because a machine that is
being installed and a machine already running a cluster cannot be treated alike.

**At install time** they are part of the generated machine configuration, emitted by
`seed/talos.yml` into the same patch that carries the bond and the install disk.
Nothing extra happens: the node comes up already holding them.

**On a running cluster** `network/talos.yml` converges them. It targets
`_baremetal_talos_member`, so on a first install it matches nothing and on a re-run
it matches the whole fleet. It reads what each node actually reports through
`talosctl get resolvers` and `talosctl get timeservers`, compares that against what
is configured, and patches only the nodes that differ -- which is what keeps a
re-run a no-op rather than an unconditional write. The patch is applied with
`--mode no-reboot`, so a setting that would require a reboot fails loudly instead of
restarting a production node as a side effect of a configuration run.

Verification asks the node rather than the configuration. `talosctl get resolvers`
returns the effective state after Talos merges its configuration layers, so the
assertion catches a patch that was rejected or never applied, where comparing
against the rendered file would only echo the inventory back.

## Bonding and addressing

Bond members are selected by **permanent address**, the one that survives being
enslaved to a bond.

`802.3ad` with `layer3+4` hashing is the default for real switches. layer2 -- the
kernel default -- hashes on MAC, so every flow to a given target lands on one member
however wide the bond is; layer3+4 is what lets multiple connections spread across
members at all.

The molecule scenario overrides the mode to `active-backup`: a libvirt bridge speaks
no LACP, so an 802.3ad bond would never find a partner, never aggregate, and leave
the machine unreachable.

## The control plane address

`baremetal_talos_api_address` is empty by default. Set it, and three things follow from that
one value: the address becomes the cluster endpoint passed to `talosctl gen config`,
it is added to the API server certificate's subject alternative names, and it is
emitted as `vip.ip` on bond0 in every control plane's machine configuration.

The cluster endpoint matters more than it looks. `talosctl kubeconfig` takes the
server URL from `cluster.controlPlane.endpoint`, so without a virtual address the
generated kubeconfig names whichever control plane happened to render the
configuration -- administrative access then depends on that one machine being up,
even though the cluster survives losing it. Pointing the endpoint at the virtual
address fixes the kubeconfig and the nodes' own join address together.

Talos implements the address itself: the control planes elect a holder through etcd
and move it, with no external component and no switch configuration. The cost is
that it is a layer 2 mechanism, so every control plane has to share a broadcast
domain. A routed control plane needs BGP instead, and that is a different design --
one where whatever advertises the address has to exist before the API it fronts is
reachable.

Workers never carry it. The stanza is emitted only for control planes, because the
address is owned by the etcd quorum.

`baremetal_talos_api_fqdn` adds the name administrators type to the same
certificate. It is deliberately not the cluster endpoint: that endpoint is what
nodes use to reach the API when joining and when recovering, and resolving it
through DNS would make cluster formation depend on the thing most likely to be
broken during a recovery. Nodes use the address; the certificate covers both, so
people and tooling can use the name.

Both are baked at generation time: the certificate is minted once by
`talosctl gen config`, and the configuration directory is guarded by `creates`, so
changing either on a built cluster means reissuing rather than editing.

## Cluster bootstrap

etcd is bootstrapped exactly once, from a single control plane node. Running it on
several produces that many separate clusters, each convinced it is the real one,
rather than one shared quorum.

The bootstrap call is **not idempotent server-side**: a second attempt is refused
because etcd already holds data. That refusal is the state the task exists to reach,
so it counts as success -- but only that one refusal, since every other error means
the cluster is not up.

The health check is passed **both node lists explicitly**. Left to discover them, it
asks the cluster what it consists of, so a machine that never joined is simply not
looked for and the cluster is pronounced healthy without it.

Waiting on machines that are installing and rebooting cannot key on the API
answering, because Talos serves the API in maintenance mode too. Readiness is a call
made with the cluster's own credentials, retried while the machine installs and comes
back.

## Upgrades

`baremetal_talos_release` is the release the fleet runs, and `talos/upgrade.yml`
converges members onto it as part of deploy. An upgrade is therefore the same
gesture as any other change: declare the new value, run deploy. Nodes already on
the release are skipped, so the playbook is re-runnable and a partially completed
roll can be resumed.

Empty means "the release the project's toolchain provides". That is deliberately
the same rule the install path uses, so a machine added next month gets the
release its neighbours are already on rather than whatever is newest -- if the two
paths disagreed, a fleet would drift apart as machines were added. The cost is
that refreshing the devbox lock changes what the fleet converges to, which is why
production inventories should pin the release rather than track the toolchain.

**Unsupported jumps are refused before anything is touched.** Talos upgrades one
minor version at a time, so a target more than one minor ahead of any member is
rejected; patch jumps within a minor are unrestricted, because an install writes a
whole OS image rather than applying increments, so intermediate patches contribute
nothing.

**Downgrades are refused the same way.** The playbook reads every
member's release first and fails if any of them is newer than the target, naming
the offenders. Talos does not support downgrades. Both checks are pre-flight
rather than per node on purpose: refusing halfway through a roll would leave the
fleet split across releases, which is the state the whole design is trying to
avoid.

The order is control planes first, one at a time, then workers, one at a time --
`serial: 1` on each play. etcd tolerates losing one member of three, and
`talosctl upgrade` cordons and drains a node before rebooting it, so its workloads
move before it goes away. Between nodes the playbook waits for the node to report
the target release, to rejoin Kubernetes as Ready, and for every pod to be back in
a healthy phase. The wait for workloads matters as much as the wait for the node:
a node can be Ready while the deployments that moved off it are still
rescheduling, and rebooting the next machine then is how a rolling upgrade becomes
an outage.

The image is the Factory installer for the target release built from the same
schematic the cluster was installed with, so kernel arguments and system
extensions survive the upgrade.

Two molecule scenarios cover this, named for the version axis each moves the fleet
along. The `patch` scenario builds a cluster with the release pinned to one version,
verifies it, re-runs deploy with the release pinned one version newer, and verifies
again -- the same gesture an operator makes, with health asserted on both releases.
The `minor` scenario does it a minor apart, which means installing the talosctl that
matches the older release, and requires the two minor jump to be refused first.

## Scaling

Scaling out needs no mechanism of its own. A machine the cluster has never met is an
inventory host that does not answer on its address, which is what classification
already calls an install: add the host, run deploy, and it is booted, discovered,
seeded and joined like any other. Cluster credentials are generated once and kept, so
a worker added a year later is issued the credentials of the cluster it is joining
rather than a new cluster's.

Scaling down is the same statement read the other way. `playbooks/talos/teardown.yml`
takes the machines classification put in `_baremetal_talos_orphan_worker` and drains,
wipes (`talosctl reset --graceful=false --reboot`), deletes and forgets each one --
refusing the whole run first if `_baremetal_talos_orphan_control` holds anything. The
machine ends with no cluster state on disk, which is what keeps the two directions
symmetric: a machine taken out is indistinguishable from one that was never
installed, so putting it back is scaling out rather than a path of its own.

The machine's address comes from the node's `InternalIP`, read back at teardown time
rather than carried from classification. A member that has already gone has no
address to find, or none that answers, and that is not an error: the wipe is skipped
and the node object kept. The node object is the only record an orphan leaves --
the inventory no longer carries it, so its address and anything else written onto the
node live nowhere else -- and deleting it after a wipe that did not happen would
leave a machine that still believes it is a member with nothing left to find it by.
Keeping it means the next run sees the same orphan and tries again, which is how a
machine that was merely powered off gets wiped without anyone intervening.

The member is cordoned first, whatever happens next. That is not the drain's doing
any more: it is what holds a machine out of service when the wipe does not happen and
the node object stays. One that was only rebooting comes back Ready, and nothing
should be scheduled onto a disk the next run means to erase. The cordon is marked
`baremetal.pokerops.io/cordoned-by: teardown`, because lifting it later has to be
able to tell it from one a person placed for their own reasons.

The workloads come off either way, and that is deliberate. A node that has stopped
answering holds its pods hostage: Kubernetes waits out a five minute toleration
before rescheduling them, and never reschedules a StatefulSet's at all while the node
object stands, because it cannot confirm the old pod is gone. A member that still
answers is drained, evicting politely and honouring disruption budgets. One that does
not is not drained at all -- eviction means nothing to a machine with no kubelet to
confirm it -- and its pods are deleted outright with no grace period, which is what
releases them from a node object this run is about to keep. Daemon set pods are left
alone, as a drain leaves them: deleting one only has its controller place another on
the same dead machine.

Putting the host back in the inventory is how the decision to remove it is taken
back, and teardown acts on that too, lifting the cordon on a member the inventory
carries again. That half is not gated on `baremetal_talos_teardown_enable`, because
the flag exists to hold back destruction and returning a machine to service is the
opposite of it. Only a cordon carrying the mark is lifted, and the mark is dropped on
the way out, so a cordon placed by hand afterwards is never mistaken for one of ours.

Out of reach, that is, over the Talos API. The BMC answers whatever the machine is
doing, which makes it the one handle that works on a machine that has stopped
listening -- and it is per-machine inventory data, so it is missing for exactly the
machines that need it most, the ones the inventory no longer carries.
`playbooks/talos/annotate.yml` closes that gap by writing the BMC address and system
id onto each node while the machine is still a member, under
`baremetal.pokerops.io/`. A node object lives in etcd rather than on the machine, so
what is recorded there outlives the machine going dark.

This is provenance rather than desired state: the cluster recording which BMC a node
was provisioned from, in the same spirit as the discovery facts written back to the
inventory. Nothing declares a fleet by annotating nodes, and the inventory remains
the only place membership is declared. Credentials are deliberately not written --
an address and a system id are identifiers, while the username and password are
fleet-wide secrets and a node annotation is readable by anything with cluster read
access.

Working out which machines those are belongs to classification rather than to
teardown, because it is the same question the install and member groups answer --
what is this fleet made of -- and splitting it would leave two places deciding. A
list of machines to destroy, supplied separately instead, would mean saying the same
thing twice (delete the host, then name it again) and would only reach machines still
in the inventory, which is the wrong set.

`baremetal_talos_teardown_enable` gates it and defaults to false. Deploy is otherwise
additive, and an inventory that is merely incomplete -- a file not yet written, a
group_vars typo, a host commented out for the afternoon -- looks exactly like one that
has had machines taken out of it. The two must not mean the same thing, so the
destructive reading has to be asked for. Left off, the drift is reported and nothing
is touched. This is the shape `baremetal_reinstall` already has: the fleet's desired
state is declared in one place, and a flag says how far deploy may go to reach it.

Teardown runs before deploy builds anything, so a refusal lands before a machine is
powered off rather than half way through. Control plane members are refused outright:
removing one means leaving etcd before the wipe, and a cluster dropping below quorum
needs more care than a worker does.

The `scale` molecule scenario builds the fleet, then points
`baremetal_talos_worker_group` at a subset -- the harness's way of saying machines
have left the inventory -- and asserts the cluster is exactly what the inventory kept
and every node Ready. Pointing it back and running deploy again brings them home.

## Verification

The BMC assertions read state back from the BMC rather than from anything the
converge left behind: the machine is on, it was pointed at removable media, and the
images are attached from the media server.

The bond assertion is the whole discovery path in one statement: the machine booted
knowing nothing, DHCPed, was found, was asked which of its links sat on the
provisioning network, and came back with those links bonded and carrying the address
the inventory asked for.

**Cluster membership is asked of the Kubernetes API, not of `talosctl get members`.**
That printed a human-readable table and the check was `hostname in stdout` -- a
substring search that would pass on a name appearing in any column or as a prefix of
a different node's name, and would break the moment the table gained a column. The
API returns objects, so membership becomes a set comparison against the inventory.

The comparison runs **both ways**: a missing machine is the obvious failure, and an
unexpected one means a machine joined that the inventory does not know about -- a
stale node from a previous cluster, or one built from the wrong configuration. It is
checked **by name**, which is what makes it more than a head count: the name comes
from the inventory, travels through a per-node machine configuration, and is only
visible here if that configuration reached the machine it was built for. Two machines
given each other's configuration would still total six.

Membership is not health, so every node is additionally asserted `Ready`: a node
registers before it is usable, and a cluster can be complete with nothing able to run
on it.

## Retries

Concurrent Redfish calls are not reliably served, so every state-changing one is
retried. sushy keeps emulator state in SQLite and answers `500 database is locked`
when six machines are driven at once; iDRAC rate-limits and returns transient 500s
under the same load.

The Image Factory and the media server are both reached over the network, and a
momentary failure on either aborts a converge minutes in. One run died on
`Errno 113 No route to host` from the controller's wireless leg, with the same
request succeeding seconds later, so those calls are retried for the same reason the
Redfish ones are.

## LLDP

`siderolabs/lldpd` is in the schematic and its service runs, so each machine
advertises itself and the switches learn which port every NIC is in.

**The extension is configured through an `ExtensionServiceConfig` document** emitted
by `seed/talos.yml`, and that document is not optional: without it the service sits
in "Waiting for extension service config", the node never leaves the booting stage,
and `talosctl health` fails for the entire cluster. It is harmless in maintenance
mode, where discovery and configuration complete normally.

**The node cannot be asked what it sees.** Talos exposes no LLDP resource -- there is
nothing in `pkg/machinery/resources/network` to query, and no shell to run `lldpcli`
in. The data flows outward only: nodes advertise, switches record. Anything that
needs to correlate ports to interfaces reads the switch.

**`configure lldp portidsubtype ifname`** on the switch is what makes the
advertisement useful. Without it a neighbour table repeats MAC addresses; with it
each node announces its interface names, so the switch can name the NIC.

Discovery does not depend on any of this. Provisioning interfaces are identified by
subnet membership, so LLDP is for validating cabling and for the cases subnet
membership cannot separate -- several networks sharing a subnet, or LACP fallback
bringing up one member and hiding the rest.

## Switch prerequisites

Not code, but the design depends on both and nothing in the repository can check
them.

**LACP fallback must be configured**, so ports forward while a machine sits in
maintenance mode speaking no LACP. Without it the machines never get a DHCP lease,
never appear to discovery, and the run fails at the scan having found nothing.
Whether fallback brings up every member or only one also decides whether the full
bond membership can be discovered, or only the first link.

**Switches must be configured before servers.** Applying an 802.3ad bond to a host
whose ports are not yet in a port-channel leaves it with no aggregator and no
connectivity.

## Test harness

**Scenario layout.** Molecule inherits nothing between scenarios -- each
`molecule.yml` is standalone -- but it does look for a base config and deep merge
each scenario's file on top of it. `extensions/molecule/config.yml` is that base, and
the only place shared settings can live without being copied into each scenario and
drifting.

The talos scenario's sequence runs `idempotence` after `converge`: a second converge
against a built fleet takes the member path and must report no changes at all. The
`side_effect` stage then re-runs the whole playbook for the same reason from the other
direction, asserting that the install-path plays find no hosts.

The `default` scenario stands the environment up and tears it down; the profile
scenarios reuse its create, destroy and inventory and differ only in what they
converge and verify. `default` declares only the stages it has playbooks for --
`syntax` is absent because it is hardcoded to syntax-check the converge playbook,
which that scenario does not have.

Paths in the shared config are absolute on purpose. Molecule runs `ansible-playbook`
with cwd set to the scenario directory but shells out to `ansible-inventory` with its
own cwd, so no relative path satisfies both callers. There is one inventory for every
scenario rather than a copy each, because `create.yml` writes discovered Redfish
system ids into host_vars beside it and a scenario reading anywhere else would not see
the ids the machines were created with.

**The inventory is the source of truth.** It describes what machines exist; tofu
consumes it rather than producing it. Machines sit under a role group, role groups
under a profile group, and profile groups under `nodes`: `nodes` is what the
collection targets, the profile group selects the profile, and the role groups are how
configuration generation tells a control plane from a worker. `machine` is how to
fabricate a machine in the test environment, so it has no counterpart on bare metal --
you do not fabricate a chassis. localhost is declared explicitly, because Ansible's
implicit localhost sits outside the inventory and picks up no group variables at all.

`baremetal_bmc_system_id` is deliberately absent from the inventory: on real hardware
iDRAC serves one system per endpoint as `System.Embedded.1`, while under sushy it is
the libvirt domain uuid, so `create.yml` discovers it and writes it into host_vars.
That id is persisted to disk rather than kept as a runtime fact so that
`molecule list` and `molecule login` can see it -- both shell out to
`ansible-inventory`, which re-parses the inventory in a fresh process.

**libvirt and sushy.** The storage pool is owned by the inventory rather than by tofu
so sushy and the manifests cannot disagree; there is no `default` pool to fall back
on, which is sushy's own default. The pool's parent directory is created before tofu
runs so it belongs to the invoking user -- libvirt makes the pool directory as root
and would otherwise create the parent too, leaving a root-owned directory nothing
else can write into, and pool directories default to `0711 root:root`, leaving qemu
unable to open the volumes inside.

sushy is served over TLS because `community.general.redfish_*` hardcodes an `https://`
root uri, and because real BMCs are https with a self-signed certificate -- so the
client code is exercised exactly as it will run against iDRAC. Virtual media is
downloaded to `<state dir>/vmedia` and attached to the domain by path, so libvirtd on
the host has to read it, which is why that directory is bind mounted at the same path
inside the container. Both libvirt sockets have to be reachable inside the container:
sushy opens a read-only connection to serve reads and a read-write one for writes, so
mounting only `libvirt-sock` makes every GET fail with a connection error. Its
credentials are throwaway -- they exist so the Redfish client authenticates here as it
must against a real iDRAC, not to protect anything.
`SUSHY_EMULATOR_ALLOWED_INSTANCES` is left unset on purpose: omitting the key serves
every domain on the host, while defining it at all -- even as an empty list -- denies
everything not listed.

**CI needs the libvirt socket opened to it.** The prepare play adds the invoking
user to the `libvirt` group, but supplementary groups are fixed when a process is
created, and a CI runner's service started long before that group existed -- so
every process in the job, ansible and tofu alike, carries the old credentials and
`/var/run/libvirt/libvirt-sock` (root:libvirt 0770) refuses them. The socket's mode
is therefore relaxed directly for the run. Changing it through the systemd unit
would be more durable but needs the socket restarted, and systemd refuses to
restart a socket unit while its service holds it. This is gated on `CI`: a
workstation keeps the normal mode, where the developer's login already carries the
group. The prepare play then proves access with an unprivileged `virsh ... uri`,
because that is the identity tofu will use -- a check that fails loudly at prepare
time instead of surfacing later as an opaque provider error.

**Domains are referenced by `source.file`** rather than `type='volume'`, because
virt-aa-helper cannot resolve a volume reference.

**The media server address is overridden in the scenario.** The role derives it from
`ansible_default_ipv4`, which on a multi-homed controller picks the leg carrying the
default route -- a wireless LAN a machine on the provisioning subnet cannot reach.
The provisioning gateway is the controller's own leg on that network, so it is both
routable from the machines and bindable locally.

**Teardown removes the host_vars directory and the Talos configuration directory.**
The first holds the Redfish system ids create wrote and the interfaces discovery
found, neither of which outlives the machines they describe. The second holds the CA
and join tokens, and `gen config` only regenerates when the directory is gone, so
leaving it would silently reuse an endpoint and a CA belonging to a cluster that no
longer exists.

### The sanity gate

`just sanity` runs `ansible-test sanity`, the collection-standard gate: it validates
the module's DOCUMENTATION and RETURN blocks against its argument spec and runs the
pep8, pylint and import checks. `just pytest` covers the module's own unit tests and
is the faster loop; sanity is the one that checks the collection is shaped the way
Galaxy and ansible-core expect.

ansible-test insists on running from `.../ansible_collections/<namespace>/<name>/`,
which this checkout is not, so the recipe builds that layout in `$TMPDIR` first.
Three things about how it does it are load-bearing:

- **The tree is copied, not symlinked.** ansible-test resolves the physical working
  directory, so a symlink pointing back at the checkout still reports the checkout's
  real path and aborts with "No `ansible_collections` parent directory was found".
- **The copy is driven by `git ls-files --cached --others --exclude-standard`**, which
  is the source tree and nothing else -- 53 files. A plain recursive copy takes 6G,
  because `.ansible` holds the installed collections and the cached Talos images.
- **The copy is `git init`'d.** ansible-test enumerates the collection with its own
  `git ls-files` call; a tree that is not a repository makes it walk up to whatever
  ancestor is, which fails outright if git rejects that directory's ownership.

The gate runs with no ignore file. pylint's `ansible-bad-function` rejects
`subprocess` in a module, and ansible-lint's own `sanity[cannot-ignore]` rule refuses
to let that particular check be ignored, so the module calls `module.run_command()`
instead. `run_command` takes no timeout, and an unbounded call would let a talosctl
hung against an unresponsive machine stall the whole scan, so the bound comes from
wrapping the command in coreutils `timeout`. An expiry then arrives as a non-zero
return code and reads as "this machine offered nothing", where the previous
`subprocess.run(timeout=...)` would have raised `TimeoutExpired` and killed the module
outright.

### What the harness cannot exercise

The scenario covers discovery, subnet filtering, member selection, the
connected-interface assertion and a real bond carrying the node's address. These are
bare-metal only:

- **LACP negotiation.** A libvirt bridge speaks no LACP, so the scenario overrides
  the bond mode to `active-backup`. 802.3ad is untested here.
- **LACP fallback.** Nothing in the harness can simulate a switch suspending or
  releasing a port. A switch without fallback fails discovery outright rather than
  subtly.
- **`LinkStatus` and OEM switch data.** sushy advertises `EthernetInterface.v1_0_2`
  and returns only MACs, so anything richer from a real BMC is unverified.
- **The solid-state half of the install-disk rule.** virtio disks report as
  rotational, so `baremetal_install_disk_require_ssd` is off in the scenario. The
  rest of the rule is exercised: each machine has two disks and picking the larger
  would leave it unable to boot.
- **Pinning the install disk by wwid.** virtio disks report no wwid, serial or uuid,
  so only the `busPath` fallback is reached here. Real NVMe and SAS disks report a
  wwid, which is the branch that would actually be used.
