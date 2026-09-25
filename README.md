# Ansible Collection - pokerops.baremetal

Provisions bare metal over Redfish and installs an operating system onto it. The
only thing you need to know about a machine in advance is how to reach its BMC:
everything else -- which of its links are on the provisioning network, which disk
to install to -- is discovered from the machine itself.

Today the collection ships one OS profile, Talos Linux, which it takes from bare
metal to a working Kubernetes cluster.

`DESIGN.md` explains how it works and why. `TODO.md` records what is not done yet.

## Requirements

- A controller with `talosctl`, `tofu` and Docker available -- the devbox
  environment in this repository provides them.
- Redfish-capable BMCs reachable over HTTPS.
- A provisioning network the machines and the controller share, with DHCP for
  maintenance mode and switch ports that forward while a machine speaks no LACP.

## Global Configuration

Every variable is declared in `roles/baremetal/defaults/main.yml`.

Required global variables

| Variable                               | Scope     | Meaning                            |
| -------------------------------------- | --------- | ---------------------------------- |
| `baremetal_bmc_address`                | per node  | how the BMC is reached             |
| `baremetal_bmc_username` / `_password` | per fleet | BMC credentials                    |
| `baremetal_network_gateway`            | per fleet | provisioning network gateway       |
| `baremetal_network_prefix`             | per fleet | provisioning network prefix length |

BMC credentials have to resolve for the controller, not only for each machine. A
machine being reclaimed has already left the inventory, so the run reaches its BMC
with what the fleet configuration holds; per-host credentials are not enough.

Common global variables

| Variable                             | Default                | Meaning                                         |
| ------------------------------------ | ---------------------- | ----------------------------------------------- |
| `baremetal_bmc_system_id`            | `"System.Embedded.1"`  | per node; the Redfish system to act on          |
| `baremetal_dns_servers`              | `[]`                   | resolvers; empty defers to Talos                |
| `baremetal_ntp_servers`              | `[]`                   | time servers; empty defers to Talos             |
| `baremetal_install_disk_require_ssd` | `true`                 | restrict the install disk to solid state        |
| `baremetal_reinstall`                | `false`                | force built machines back onto the install path |

## Talos

Takes the fleet from bare metal to one Kubernetes cluster, and keeps it there: the
same deploy installs new machines, converges releases, and removes members the
inventory no longer carries.

### Configuration

| Variable                          | Default | Meaning                                                                       |
| --------------------------------- | ------- | ----------------------------------------------------------------------------- |
| `baremetal_talos_release`         | `""`    | the release the fleet runs; empty tracks the local `talosctl`                 |
| `baremetal_talos_api_address`     | `""`    | shared control plane address; also the cluster endpoint and a certificate SAN |
| `baremetal_talos_api_fqdn`        | `""`    | name administrators use, added to the certificate                             |
| `baremetal_talos_teardown_enable` | `false` | take cluster members the inventory no longer carries out                      |
| `baremetal_talos_annotate_enable` | `true`  | record each member's BMC on its node, so it outlives the machine              |
| `baremetal_talos_reclaim_enable`  | `false` | power an unreachable member on over its BMC before giving up on wiping it     |
| `baremetal_talos_unregister`      | `false` | delete a member that could not be wiped, accepting the machine is gone        |
| `baremetal_talos_k8s_version`     | `""`    | Kubernetes version; empty tracks the toolchain                                |
| `baremetal_talos_boot`            | `true`  | boot the machines from virtual media                                          |
| `baremetal_talos_configure`       | `true`  | discover, configure, bootstrap and converge the machines                      |

### What a run does

1. **Classify.** Machines that already answer on their inventory address are
   members; the rest are installed.
2. **Publish media.** One boot image for the fleet, built by the Talos Image
   Factory and served over HTTP.
3. **Boot.** Each BMC is pointed at that image over Redfish and powered on.
4. **Discover.** Machines reach Talos maintenance mode and report their links and
   disks; the collection decides which links are the provisioning ones and which
   disk to install to.
5. **Seed.** Cluster credentials are generated once, a machine configuration is
   rendered per node and pushed.
6. **Bootstrap.** etcd comes up once, and the cluster is waited on until healthy.

### Usage

Every operation below is a change to the inventory followed by the same deploy. What
differs is which flag, if any, gives the run permission to destroy something.

#### Cluster install

- Put every machine in `talos_controlplane` or `talos_worker`, each with
  `ansible_host` set to the address it will hold on the provisioning network and
  `baremetal_bmc_address` set to its BMC. Add `baremetal_bmc_system_id` if it is not
  `System.Embedded.1`. Set `baremetal_network_gateway`, `baremetal_network_prefix` and
  the BMC credentials for the fleet.
- `ansible-playbook -i inventory.yml pokerops.baremetal.talos.deploy`

Nothing answers yet, so every machine is installed: booted from media, discovered,
seeded, and bootstrapped into one cluster. Running it again against the built fleet is
safe, and is how every operation below is applied.

#### Cluster upgrade

- Set `baremetal_talos_release` to the Talos release the fleet should run, and
  `baremetal_talos_k8s_version` to the Kubernetes version it should run, for the
  fleet.
- `ansible-playbook -i inventory.yml pokerops.baremetal.talos.deploy`

Machines are rolled one at a time, control planes first. Each is cordoned and drained
before it reboots, and the next is not touched until the current one reports the new
release, rejoins Ready, and its workloads have settled. Nodes already on the target
are skipped, so a re-run costs nothing.

Left empty, both track the toolchain the devbox lock provides -- pin them in
production, or a lockfile refresh decides when your cluster reboots. Downgrades are
refused before anything is touched, as are jumps of more than one Talos minor.

#### Cluster scale up

- Add the host to `talos_worker` (or `talos_controlplane`), with `ansible_host` set to
  the address it will hold on the provisioning network and `baremetal_bmc_address` set
  to its BMC. Add `baremetal_bmc_system_id` if it is not `System.Embedded.1`.
- `ansible-playbook -i inventory.yml pokerops.baremetal.talos.deploy`

The machine does not answer on its address yet, so it is installed. Existing members
are left alone.

#### Cluster scale down

- Delete the host from the inventory.
- `ansible-playbook -i inventory.yml -e baremetal_talos_teardown_enable=true pokerops.baremetal.talos.deploy`

Members the cluster carries that the inventory does not are drained, wiped and
deleted. Without the flag, deploy reports what it would remove and touches nothing --
an inventory that is merely incomplete looks exactly like one that has had machines
taken out. Control plane members are refused either way.

#### Node reclaim

For scaling down a machine that is switched off or not answering.

- Delete the host from the inventory.
- `ansible-playbook -i inventory.yml -e baremetal_talos_teardown_enable=true -e baremetal_talos_reclaim_enable=true pokerops.baremetal.talos.deploy`

The machine is powered on over the BMC recorded on its node, and wiped once it
answers. If it never does, its node is kept and the machine is reported on every run
until someone deals with it -- nothing is forgotten quietly.

#### Node unregister

For a machine that is never coming back -- destroyed, decommissioned, or written off.

- Delete the host from the inventory.
- `ansible-playbook -i inventory.yml -e baremetal_talos_teardown_enable=true -e baremetal_talos_unregister=true pokerops.baremetal.talos.deploy`

Members that cannot be wiped are deleted from the cluster anyway, and stop being
reported. This is the one operation that gives something up: the machine keeps its
disk, cluster credentials and all, and the node object that recorded its address and
its BMC goes with it -- so nothing here can find or reclaim that machine afterwards.
Try `baremetal_talos_reclaim_enable` first, and reach for this only once the answer to
"is anyone going to fix it?" is no.

Members that *can* be wiped are wiped as usual; the flag only decides what happens to
the ones that could not be.

#### Node crash

For putting a machine that died back into the cluster it left.

- Leave the host in the inventory.
- `ansible-playbook -i inventory.yml pokerops.baremetal.talos.deploy`

A machine that stopped answering is already treated as one to install, so an ordinary
deploy rebuilds it. Nothing else is needed.

#### Node reinstall

For rebuilding a machine that is healthy and still serving.

- Set `baremetal_reinstall: true` on that host, in its `host_vars`. Passing it with
  `-e` applies it to the whole fleet and rebuilds every machine, control planes
  included.
- `ansible-playbook -i inventory.yml pokerops.baremetal.talos.deploy`

The machine is powered off, booted from installer media, re-seeded, and rejoins.
**Its workloads are not moved off first**: the install path powers the machine off
where it stands, and only teardown drains. Cordon and drain the node yourself if what
runs on it cannot take an abrupt stop.

### Running in two phases

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

`MOLECULE_SCENARIO=talos just test` -- what `just talos` above is shorthand for --
runs the talos scenario, which builds a cluster and checks the provisioning path in
detail: the BMC is left powered on with the boot image attached, each node carries its
address on the bond discovery chose, resolvers and time servers match what was asked
for, the API certificate covers the cluster address, and the cluster is made of
exactly the machines in the inventory.

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

`MOLECULE_SCENARIO=reinstall just test` runs the reinstall scenario, which forces a
healthy member back onto the install path with `baremetal_reinstall`, then asserts it
came up on a different boot and rejoined the cluster it left.

CI runs the five scenarios from the same workflow matrix, one after the other.
