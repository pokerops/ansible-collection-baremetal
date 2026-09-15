output "network_id" {
  description = "libvirt UUID of the network"
  value       = libvirt_network.talos.id
}

output "network_name" {
  description = "Name of the libvirt network"
  value       = libvirt_network.talos.name
}

output "network_cidr" {
  description = "IPv4 subnet of the network"
  value       = var.network_cidr
}

output "host_address" {
  description = "Address of the host on the network bridge"
  value       = local.host_address
}

output "pool_name" {
  description = "Name of the storage pool holding node boot disks"
  value       = libvirt_pool.talos.name
}

# libvirt assigns the domain uuid, and sushy serves each domain under it as the
# Redfish system id. It cannot be known before apply, so create.yml persists this
# map into inventory host_vars -- the ansible-native pattern for runtime facts
# that later `molecule login` and `molecule list` invocations have to re-read.
output "system_ids" {
  description = "Redfish system id per node, keyed by inventory hostname"
  value       = { for name, domain in libvirt_domain.node : name => domain.uuid }
}
