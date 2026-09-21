# Ansible Collection - pokerops.baremetal

Provisions bare metal over Redfish and installs an operating system onto it. The
only thing you need to know about a machine in advance is how to reach its BMC:
everything else -- which of its links are on the provisioning network, which disk
to install to -- is discovered from the machine itself.

Today the collection ships one OS profile, Talos Linux, which it takes from bare
metal to a working Kubernetes cluster.

`DESIGN.md` explains how it works and why. `TODO.md` records what is not done yet.

## What a run does

1. **Classify.** Machines that already answer on their inventory address are
   members; the rest are installed. Re-running against a built cluster is safe.
2. **Publish media.** One boot image for the fleet, built by the Talos Image
   Factory and served over HTTP.
3. **Boot.** Each BMC is pointed at that image over Redfish and powered on.
4. **Discover.** Machines reach Talos maintenance mode and report their links and
   disks; the collection decides which links are the provisioning ones and which
   disk to install to.
5. **Seed.** Cluster credentials are generated once, a machine configuration is
   rendered per node and pushed.
6. **Bootstrap.** etcd comes up once, and the cluster is waited on until healthy.

## Requirements

- A controller with `talosctl`, `tofu` and Docker available -- the devbox
  environment in this repository provides them.
- Redfish-capable BMCs reachable over HTTPS.
- A provisioning network the machines and the controller share, with DHCP for
  maintenance mode and switch ports that forward while a machine speaks no LACP.

## Usage

Point the collection at an inventory that describes the machines and run the
profile playbook:

```yaml
- name: Build a Talos cluster
  ansible.builtin.import_playbook: pokerops.baremetal.talos.deploy
```

Individual steps are addressable too, which is what the day-2 operations use:

| Playbook                             | Purpose                                                |
| ------------------------------------ | ------------------------------------------------------ |
| `pokerops.baremetal.talos.deploy`    | the whole sequence                                     |
| `pokerops.baremetal.talos.groups`    | classify the fleet into install and member groups      |
| `pokerops.baremetal.talos.media`     | build and publish the boot image                       |
| `pokerops.baremetal.talos.discover`  | find machines in maintenance mode                      |
| `pokerops.baremetal.talos.seed`      | generate and apply machine configuration               |
| `pokerops.baremetal.talos.bootstrap` | bootstrap etcd and wait for health                     |
| `pokerops.baremetal.talos.network`   | converge resolvers and time servers on a built cluster |
| `pokerops.baremetal.talos.upgrade`   | roll a new Talos release through the fleet             |

`pokerops.baremetal.boot`, `.validate` and `.media.start` / `.media.stop` are
OS-agnostic and shared by every profile.

## Configuration

Every variable is declared in `roles/baremetal/defaults/main.yml`. The ones you
have to set:

| Variable                               | Scope     | Meaning                            |
| -------------------------------------- | --------- | ---------------------------------- |
| `baremetal_bmc_address`                | per node  | how the BMC is reached             |
| `baremetal_bmc_username` / `_password` | per node  | BMC credentials                    |
| `baremetal_network_gateway`            | per fleet | provisioning network gateway       |
| `baremetal_network_prefix`             | per fleet | provisioning network prefix length |

The ones you most often want to change:

| Variable                             | Default | Meaning                                                                       |
| ------------------------------------ | ------- | ----------------------------------------------------------------------------- |
| `baremetal_talos_api_address`        | `""`    | shared control plane address; also the cluster endpoint and a certificate SAN |
| `baremetal_talos_api_fqdn`           | `""`    | name administrators use, added to the certificate                             |
| `baremetal_dns_servers`              | `[]`    | resolvers; empty defers to Talos                                              |
| `baremetal_ntp_servers`              | `[]`    | time servers; empty defers to Talos                                           |
| `baremetal_talos_release`            | `""`    | the release the fleet runs; empty tracks the local `talosctl`                 |
| `baremetal_install_disk_require_ssd` | `true`  | restrict the install disk to solid state                                      |
| `baremetal_reinstall`                | `false` | force built machines back onto the install path                               |
| `baremetal_talos_teardown_enable`    | `false` | take cluster members the inventory no longer carries out                      |
| `baremetal_talos_annotate_enable`    | `true`  | record each member's BMC on its node, so it outlives the machine              |
| `baremetal_talos_k8s_version`        | `""`    | Kubernetes version; empty tracks the toolchain                                |
| `baremetal_talos_boot`               | `true`  | boot the machines from virtual media                                          |
| `baremetal_talos_configure`          | `true`  | discover, configure, bootstrap and converge the machines                      |

## Upgrades

`baremetal_talos_release` is the release the fleet runs, and deploy converges the
fleet onto it -- so an upgrade is "pin the new release, run deploy again". Nodes
already on it are skipped. Left empty it tracks the `talosctl` the project's
devbox lock provides, which keeps installs and existing members on one release
rather than letting the fleet drift apart as machines are added over time; pin it
in production so a lockfile refresh cannot decide when your cluster reboots.

Machines are rolled one at a time, control planes first, using the Factory
installer for the same schematic the cluster was built from. `talosctl upgrade`
cordons and drains each node before rebooting it, and the next machine is not
touched until the current one reports the new release, rejoins as Ready, and
every workload has settled.

Talos does not support downgrades, so the run refuses before touching anything if
any member is already newer than the target.

## Scaling

The inventory is the fleet, in both directions. Adding a machine is adding it to the
inventory and running deploy: a host that does not answer on its address is one to
install, so it is booted, discovered, seeded and joined like any other. Existing
members are left alone.

Taking one out is deleting it from the inventory and running deploy with teardown
enabled:

```bash
ansible-playbook --inventory inventory.yml \
  --extra-vars baremetal_talos_teardown_enable=true \
  pokerops.baremetal.talos.deploy
```

Members the cluster carries that the inventory does not are drained, wiped and
deleted. `baremetal_talos_teardown_enable` defaults to false, because an inventory
that is merely incomplete -- a file not yet written, a group_vars typo, a host
commented out for the afternoon -- looks exactly like one that has had machines taken
out of it. Left off, deploy reports the drift and touches nothing.

Control plane members are refused: taking one out means leaving etcd first, which
this does not do yet. A machine that has been torn down keeps no cluster state, so
putting it back in the inventory is all it takes for the next deploy to install it
again.

## Running in two phases

A fleet whose switches are not configured yet cannot be discovered: the machines
reach maintenance mode, but their ports stay suspended until LACP fallback is in
place, so nothing answers on the provisioning network. The two gates let a run
stop between those points.

```bash
# boot the machines, then stop
just talos converge -e baremetal_talos_configure=false

# ... read the switches' LLDP neighbour tables, configure the port-channels ...

# resume: the machines are already in maintenance mode, so do not boot them again
just talos converge -e baremetal_talos_boot=false
```

`baremetal_talos_configure` covers everything that needs the machines reachable --
discovery, configuration, bootstrap, and the resolver, release and Kubernetes
convergence steps. A boot-only run therefore converges nothing, including on
machines that are already built.

Publishing the boot image stays outside both gates, because the installer image it
resolves is what the machine configuration installs from.

## Testing

The molecule scenarios stand real machines up with libvirt and a sushy Redfish
emulator, so the Redfish path is exercised the same way it will run against iDRAC.

```bash
just talos converge     # build a cluster
just talos verify       # assert it is what was asked for
just talos test         # the full sequence, including teardown
just lint               # yamllint and ansible-lint
just pytest             # module unit tests
just sanity             # ansible-test sanity
```

`MOLECULE_SCENARIO=patch just test` runs the patch scenario, which builds a cluster
on one release, verifies it, upgrades the fleet, and verifies it again. It carries
the downgrade refusal and the Kubernetes convergence with it: the cluster starts a
Kubernetes release behind the toolchain and has to end up on it. The two Talos
releases it pins are the newest pair on the toolchain's minor line; `just update`
refreshes the devbox lock and repins them to match the toolchain it resolved.

`MOLECULE_SCENARIO=minor just test` runs the same shape a minor apart: it installs
the talosctl one minor behind the locked one -- `media/talos.yml` requires the boot
image and the toolchain to share a minor -- builds the fleet on that release, then
requires a two minor jump to be refused before stepping the fleet one minor forward.
The scenario puts the locked toolchain back when it destroys, including after a
failed run, so `devbox.json` and `devbox.lock` end where they started.

`MOLECULE_SCENARIO=scale just test` runs the scale scenario, which builds the fleet,
takes the last worker out of the cluster, asserts what is left is whole and healthy,
then runs deploy again and asserts the worker rejoined.

CI runs the four scenarios from the same workflow matrix, one after the other.
