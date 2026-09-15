locals {
  # The host sits on the first usable address of the subnet, so 172.16.31.0/24
  # puts the bridge interface on 172.16.31.1.
  host_address   = cidrhost(var.network_cidr, 1)
  network_prefix = tonumber(split("/", var.network_cidr)[1])
}

resource "libvirt_network" "talos" {
  name      = var.network_name
  autostart = var.network_autostart

  forward = {
    mode = var.network_mode
  }

  # A lease is how a node reaches the media server to fetch its own machine
  # configuration; the configuration it fetches then pins the permanent static
  # address. The range is deliberately outside the static block so the two cannot
  # collide, and nothing depends on which lease a node gets -- it identifies
  # itself by MAC, not by address.
  ips = [
    {
      family  = "ipv4"
      address = local.host_address
      prefix  = local.network_prefix

      dhcp = {
        ranges = [
          {
            start = cidrhost(var.network_cidr, 100)
            end   = cidrhost(var.network_cidr, 199)
          },
        ]
      }
    }
  ]
}
