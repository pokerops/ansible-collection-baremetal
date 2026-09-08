# talos libvirt network

OpenTofu manifests for the `talos` libvirt network.

| setting  | value            |
| -------- | ---------------- |
| name     | `talos`          |
| subnet   | `172.16.31.0/24` |
| host     | `172.16.31.1`    |
| forward  | `nat`            |
| dhcp     | disabled         |

Nodes on this network are addressed statically; libvirt runs no DHCP server on it.

## usage

These manifests are one layer of the molecule `default` scenario rather than a
standalone stack, so drive them through molecule:

```sh
devbox run -- just create   # tofu apply, then the sushy BMC emulator
devbox run -- just destroy  # emulator down, then tofu destroy
```

`create.yml` applies this directory and writes molecule's instance config from the
`instances` output. `destroy.yml` stops the emulator before destroying what tofu made.

Running tofu by hand is for inspection:

```sh
devbox run -- tofu -chdir=tofu plan
devbox run -- tofu -chdir=tofu show
```

Avoid a direct `tofu apply` or `tofu destroy`. sushy-tools is a container managed by the
molecule playbooks, not a tofu resource, so applying leaves you with domains and no BMC
in front of them, and destroying orphans a container pointed at domains that are gone.

The provider talks to `qemu:///system` by default; override with `-var libvirt_uri=...`.
State is local (`tofu/terraform.tfstate`) and is not tracked by git. molecule and any
manual command share that one state file, so there is a single `talos` network on the
host rather than one per scenario.

## instance config

`instances` is empty while the manifests describe only the network. Appending node
resources to that output is all molecule needs to pick them up; the element shape is
still being settled, but it carries BMC coordinates rather than SSH details — Talos has
no SSH, and the out-of-band path is what the bare-metal scenario will share.

## variables

Variables reach tofu through the environment, which molecule passes on:

```yaml
# molecule/default/molecule.yml
ansible:
  env:
    TF_VAR_network_name: talos-ci
```
