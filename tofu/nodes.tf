# Node boot disks live in a pool of their own. There is no `default` pool to lean
# on, and giving the project its own keeps teardown from touching anything else.
resource "libvirt_pool" "talos" {
  name = var.pool_name
  type = "dir"

  target = {
    path = var.pool_path

    permissions = {
      mode  = var.pool_mode
      owner = var.pool_owner
      group = var.pool_group
    }
  }
}

resource "libvirt_volume" "boot" {
  for_each = var.nodes

  name = "${each.key}.qcow2"
  pool = libvirt_pool.talos.name

  capacity      = each.value.disk
  capacity_unit = "B"

  target = {
    format = {
      type = "qcow2"
    }

    permissions = {
      mode  = var.volume_mode
      owner = var.pool_owner
      group = var.pool_group
    }
  }
}

# A second, larger disk. Disk selection picks the smallest candidate, and with one
# disk per machine that rule is untested -- any rule would pick the same device.
# With two, choosing wrongly is visible: the installer lands on the wrong disk and
# the machine never comes back.
resource "libvirt_volume" "spare" {
  for_each = var.nodes

  name = "${each.key}-spare.qcow2"
  pool = libvirt_pool.talos.name

  capacity      = each.value.disk * 2
  capacity_unit = "B"

  target = {
    format = {
      type = "qcow2"
    }

    permissions = {
      mode  = var.volume_mode
      owner = var.pool_owner
      group = var.pool_group
    }
  }
}

resource "libvirt_domain" "node" {
  for_each = var.nodes

  name = each.key
  type = "kvm"

  # No identity is set here. The domain uuid -- what sushy serves as the Redfish
  # system id -- is assigned by libvirt and readable only after apply, so it is
  # published as an output and written back into host_vars. Pinning the SMBIOS
  # uuid via `hwuuid` is rejected on read-back by provider 0.9.8, so machines
  # carry a generated one; nothing in the Talos path depends on it.

  # Talos requires the x86-64-v2 microarchitecture and refuses to start without
  # it: init exits immediately with "can only be run on AMD64 processors with v2
  # microarchitecture support" and the kernel panics. QEMU's default model
  # predates those instructions, so the host's own CPU is passed through.
  cpu = {
    mode = var.cpu_mode
  }

  memory      = each.value.memory
  memory_unit = "MiB"
  vcpu        = each.value.vcpu

  # Left powered off: bringing a machine up is the BMC's job, driven over Redfish
  # exactly as it will be against iDRAC.
  running   = false
  autostart = false

  # libvirt refuses a UEFI domain without ACPI on x86_64.
  features = {
    acpi = true
    apic = {}
  }

  os = {
    type = "hvm"

    # Talos wants UEFI, and it is what the bare metal fleet will boot.
    firmware = "efi"

    # Removable media first so an inserted ISO wins, falling back to the disk
    # once the installer has written it.
    boot_devices = [
      { dev = "cdrom" },
      { dev = "hd" },
    ]
  }

  devices = {
    disks = [
      {
        device = "disk"

        # Referenced by path, not as pool/volume. virt-aa-helper cannot resolve a
        # <disk type='volume'> back to a file, so it generates no per-domain
        # AppArmor profile and qemu is denied the disk at start -- the domain
        # dies with "Could not open ...: Permission denied" no matter what the
        # file mode says. Identical domains start fine referenced this way.
        source = {
          file = {
            file = libvirt_volume.boot[each.key].path
          }
        }

        # With a file source there is no pool metadata to infer the format from,
        # and letting qemu probe it is both slower and a known hazard.
        driver = {
          name = "qemu"
          type = "qcow2"
        }

        target = {
          dev = "vda"
          bus = "virtio"
        }
      },
      {
        device = "disk"

        source = {
          file = {
            file = libvirt_volume.spare[each.key].path
          }
        }

        driver = {
          name = "qemu"
          type = "qcow2"
        }

        target = {
          dev = "vdb"
          bus = "virtio"
        }
      },
    ]

    # A serial port and a console on it, so `virsh console <name>` shows the
    # guest's boot output. Without one a machine that fails to boot is opaque
    # from the outside -- and an installer that cannot find its config fails in
    # exactly that way, looking indistinguishable from a network problem.
    #
    # `serials[].log.file` can additionally tee this to a file for scripted
    # capture, at the cost of a directory libvirtd writes into as root.
    # No source declared on purpose: libvirt then defaults to a pty and assigns
    # the path itself. Naming a pty explicitly means supplying the path, which is
    # libvirt's to hand out, not ours to choose.
    serials = [
      {},
    ]

    consoles = [
      {
        target = {
          type = "serial"
        }
      },
    ]

    # Two interfaces, both on the provisioning network. One would exercise the
    # pipeline but not the thing that makes bare metal hard: a machine reports
    # several links and the provisioning ones have to be told apart from the
    # rest. With two, discovery has to select by subnet membership rather than
    # by "the only link there is", and the bond has more than one member.
    #
    # A libvirt bridge speaks no LACP, so 802.3ad would never aggregate here --
    # the scenario sets baremetal_bond_mode to active-backup. Negotiation and
    # switch fallback stay bare-metal-only.
    interfaces = [
      for i in range(var.interface_count) : {
        source = {
          network = {
            network = libvirt_network.talos.name
          }
        }
        model = {
          type = "virtio"
        }
      }
    ]
  }
}
