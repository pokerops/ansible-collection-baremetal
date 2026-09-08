#!/usr/bin/python
# -*- coding: utf-8 -*-
# GNU General Public License v3.0+ (see LICENSES/GPL-3.0-or-later.txt)

from __future__ import absolute_import, division, print_function

__metaclass__ = type

DOCUMENTATION = r"""
---
module: talos_maintenance_facts
short_description: Report Talos machines reachable in maintenance mode
version_added: "1.0.0"
description:
  - Scans a network for Talos machines that have booted without a configuration
    and are serving the maintenance API, then reports what each one is made of.
  - Returns facts only. Which links count as the provisioning ones, and which disk
    should be installed to, are decisions left to the caller - this module reports
    every physical link with the addresses it holds and every disk with the
    attributes needed to choose between them.
options:
  network:
    description: Network to scan, in CIDR notation.
    required: true
    type: str
  port:
    description: Port the Talos API listens on.
    type: int
    default: 50000
  connect_timeout:
    description: Seconds to wait for a machine to accept a connection.
    type: float
    default: 1.0
  concurrency:
    description: How many addresses to probe at once.
    type: int
    default: 64
  command_timeout:
    description: Seconds to wait for a single talosctl call.
    type: int
    default: 60
  talosctl:
    description: Path to the talosctl binary.
    type: str
    default: talosctl
author:
  - nephelaiio
"""

EXAMPLES = r"""
- name: Find machines waiting to be configured
  pokerops.baremetal.talos_maintenance_facts:
    network: 172.16.31.0/24
  register: discovered
"""

RETURN = r"""
machines:
  description:
    - One entry per machine found, deduplicated - a machine with several links on
      the scanned network answers on each of its addresses.
  returned: always
  type: list
  elements: dict
  sample:
    - address: 172.16.31.106
      links:
        - name: ens2
          physical: true
          hardwareAddr: "52:54:00:4d:2c:83"
          permanentAddr: "52:54:00:4d:2c:83"
          linkState: true
          addresses:
            - address: 172.16.31.106/24
              ip: 172.16.31.106
      disks:
        - devPath: /dev/vda
          size: 21474836480
          rotational: true
"""

import concurrent.futures
import ipaddress
import json
import socket
import subprocess

from ansible.module_utils.basic import AnsibleModule


def decode_documents(text):
    """Decode the concatenated JSON documents `talosctl get -o json` emits.

    It does not emit one document per line, nor a JSON array, so neither
    splitlines() nor json.loads() reads it.
    """
    decoder, found, index = json.JSONDecoder(), [], 0
    text = (text or "").strip()
    while index < len(text):
        document, index = decoder.raw_decode(text, index)
        found.append(document)
        while index < len(text) and text[index] in " \t\r\n":
            index += 1
    return found


def link_facts(documents):
    """Normalise LinkStatus documents, keyed by link name."""
    links = {}
    for document in documents:
        spec = document.get("spec", {})
        name = document.get("metadata", {}).get("id")
        if not name:
            continue
        links[name] = {
            "name": name,
            # Talos's own definition, from LinkStatusSpec.Physical():
            # `Type == ether && Kind == ""`. There is no `physical` field in the
            # JSON to read instead, and without this a bond would be offered lo,
            # bond0 and every tunnel the kernel creates.
            "physical": spec.get("type") == "ether" and not spec.get("kind"),
            "hardwareAddr": spec.get("hardwareAddr", ""),
            # The address that survives being enslaved to a bond, which is what a
            # bond member has to be selected by.
            "permanentAddr": spec.get("permanentAddr") or spec.get("hardwareAddr", ""),
            "linkState": bool(spec.get("linkState")),
            "addresses": [],
        }
    return links


def attach_addresses(links, documents):
    """Attach AddressStatus documents to the links that hold them."""
    for document in documents:
        spec = document.get("spec", {})
        link = links.get(spec.get("linkName"))
        if link is None:
            continue
        cidr = spec.get("address", "")
        try:
            held = ipaddress.ip_interface(cidr)
        except ValueError:
            continue
        link["addresses"].append({"address": cidr, "ip": str(held.ip)})
    return links


def disk_facts(documents):
    """Normalise Disk documents, every disk, with no judgement applied."""
    disks = []
    for document in documents:
        spec = document.get("spec", {})
        disks.append(
            {
                "devPath": spec.get("dev_path", ""),
                "size": int(spec.get("size") or 0),
                "prettySize": spec.get("pretty_size", ""),
                "model": spec.get("model", ""),
                "serial": spec.get("serial", ""),
                "wwid": spec.get("wwid", ""),
                "uuid": spec.get("uuid", ""),
                "busPath": spec.get("bus_path", ""),
                "transport": spec.get("transport", ""),
                "rotational": bool(spec.get("rotational")),
                "readonly": bool(spec.get("readonly")),
                "cdrom": bool(spec.get("cdrom")),
            }
        )
    return sorted(disks, key=lambda disk: disk["devPath"])


def describe(address, read):
    """Assemble one machine from three resource reads.

    `read` is a callable taking a resource kind, so the assembly is testable
    without talosctl or a network.
    """
    links = link_facts(read("links"))
    attach_addresses(links, read("addresses"))
    return {
        "address": address,
        "links": sorted(links.values(), key=lambda link: link["name"]),
        "disks": disk_facts(read("disks")),
    }


def fingerprint(machine):
    """What makes two addresses the same machine: the set of links it reports."""
    return tuple(
        sorted(
            link["permanentAddr"] for link in machine["links"] if link["permanentAddr"]
        )
    )


def deduplicate(machines):
    """Keep one entry per machine, in the order found."""
    seen, unique = set(), []
    for machine in machines:
        mark = fingerprint(machine)
        if not mark or mark in seen:
            continue
        seen.add(mark)
        unique.append(machine)
    return unique


def responds(address, port, timeout):
    """True when something accepts a connection on the API port."""
    with socket.socket() as probe:
        probe.settimeout(timeout)
        return probe.connect_ex((address, port)) == 0


def scan(network, port, timeout, concurrency):
    """Every address in the network that accepts a connection."""
    candidates = [str(host) for host in ipaddress.ip_network(network).hosts()]
    with concurrent.futures.ThreadPoolExecutor(max_workers=concurrency) as pool:
        results = pool.map(lambda a: responds(a, port, timeout), candidates)
        return [address for address, ok in zip(candidates, results) if ok]


def reader(module):
    """A `read` callable backed by talosctl."""

    def read(address, kind):
        # --insecure belongs to the subcommand, not to talosctl. As a global flag
        # it is parsed as a command name and every call dies with
        # `unknown command "<address>"`.
        result = subprocess.run(
            [
                module.params["talosctl"],
                "--nodes",
                address,
                "get",
                kind,
                "--insecure",
                "--output",
                "json",
            ],
            capture_output=True,
            text=True,
            timeout=module.params["command_timeout"],
            check=False,
        )
        if result.returncode != 0:
            return []
        return decode_documents(result.stdout)

    return read


def main():
    module = AnsibleModule(
        argument_spec=dict(
            network=dict(type="str", required=True),
            port=dict(type="int", default=50000),
            connect_timeout=dict(type="float", default=1.0),
            concurrency=dict(type="int", default=64),
            command_timeout=dict(type="int", default=60),
            talosctl=dict(type="str", default="talosctl"),
        ),
        supports_check_mode=True,
    )

    try:
        reachable = scan(
            module.params["network"],
            module.params["port"],
            module.params["connect_timeout"],
            module.params["concurrency"],
        )
    except ValueError as error:
        module.fail_json(
            msg="invalid network %s: %s" % (module.params["network"], error)
        )

    read = reader(module)
    machines = [
        describe(address, lambda kind, a=address: read(a, kind))
        for address in reachable
    ]
    module.exit_json(changed=False, machines=deduplicate(machines))


if __name__ == "__main__":
    main()
