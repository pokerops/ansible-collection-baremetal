variable "libvirt_uri" {
  description = "libvirt connection URI"
  type        = string
  default     = "qemu:///system"
}

variable "network_name" {
  description = "Name of the libvirt network"
  type        = string
  default     = "talos"
}

variable "network_cidr" {
  description = "IPv4 subnet for the network. The host takes the first usable address."
  type        = string
  default     = "172.16.31.0/24"

  validation {
    condition     = can(cidrhost(var.network_cidr, 1))
    error_message = "network_cidr must be a valid IPv4 CIDR block."
  }
}

variable "network_mode" {
  description = "Forwarding mode for the network"
  type        = string
  default     = "nat"

  validation {
    condition     = contains(["nat", "route", "open", "none"], var.network_mode)
    error_message = "network_mode must be one of nat, route, open or none."
  }
}

variable "network_autostart" {
  description = "Start the network on host boot"
  type        = bool
  default     = true
}

variable "pool_name" {
  description = "Name of the libvirt storage pool holding node boot disks"
  type        = string
  default     = "talos"
}

variable "pool_path" {
  description = "Host directory backing the storage pool"
  type        = string
  default     = "/var/lib/libvirt/images/talos"
}

# libvirt creates a pool directory 0711 root:root by default, which leaves qemu
# unable to open the volumes inside it -- domains fail to start with "Permission
# denied". Ownership is passed in from the caller so the pool belongs to whoever
# is driving it rather than to a uid hardcoded here.
variable "pool_owner" {
  description = "uid owning the storage pool directory"
  type        = string
  default     = ""
}

variable "pool_group" {
  description = "gid owning the storage pool directory"
  type        = string
  default     = ""
}

variable "pool_mode" {
  description = "Mode of the storage pool directory"
  type        = string
  default     = "0755"
}

# qemu runs as its own user, so a boot disk left at the default 0600 root:root
# cannot be opened and the domain dies at start with "Permission denied".
# libvirt fixes up the group at domain start but not the mode.
variable "volume_mode" {
  description = "Mode of node boot disks"
  type        = string
  default     = "0666"
}

# Rendered from the Ansible inventory rather than authored here: the inventory is
# the source of truth for what machines exist, and bare metal has no tofu at all.
# Only sizing lives here -- identity is not an input, because libvirt assigns the
# domain uuid and this provider will not round-trip a pinned SMBIOS uuid.
variable "nodes" {
  description = "Machines to create, keyed by inventory hostname"
  type = map(object({
    memory = optional(number, 4096)
    vcpu   = optional(number, 2)
    disk   = optional(number, 21474836480)
  }))
  default = {}
}

variable "cpu_mode" {
  description = "libvirt CPU mode for nodes. Must expose x86-64-v2 or Talos will not boot."
  type        = string
  default     = "host-passthrough"
}

# How many interfaces each machine gets, all on the provisioning network. Two by
# default so the harness exercises multi-link discovery and a real bond; one
# would silently pass a pipeline that cannot tell links apart.
variable "interface_count" {
  type    = number
  default = 2
}
