"""Unit tests for the talos_maintenance_facts module.

The fixtures are shaped like real `talosctl get -o json` output, including the
details that broke this code when it was written by inspection rather than
against captured data: documents are concatenated rather than newline-delimited,
there is no `physical` field to read, and `kind` is absent on physical links
rather than empty.
"""

import importlib.util
import pathlib

import pytest

MODULE_PATH = (
    pathlib.Path(__file__).parents[4] / "plugins" / "modules" / "talos_maintenance_facts.py"
)
spec = importlib.util.spec_from_file_location("talos_maintenance_facts", MODULE_PATH)
facts = importlib.util.module_from_spec(spec)
spec.loader.exec_module(facts)


LINKS = """
{"metadata": {"id": "bond0"}, "spec": {"type": "ether", "kind": "bond", "hardwareAddr": "aa:00:00:00:00:09"}}
{"metadata": {"id": "ens2"}, "spec": {"type": "ether", "hardwareAddr": "52:54:00:4d:2c:83",
 "permanentAddr": "52:54:00:4d:2c:83", "linkState": true}}
{"metadata": {"id": "ens3"}, "spec": {"type": "ether", "hardwareAddr": "52:54:00:01:b6:58",
 "permanentAddr": "52:54:00:01:b6:58", "linkState": true}}
{"metadata": {"id": "lo"}, "spec": {"type": "loopback"}}
{"metadata": {"id": "flannel.1"}, "spec": {"type": "ether", "kind": "vxlan"}}
{"metadata": {"id": "teql0"}, "spec": {"type": "void"}}
"""

ADDRESSES = """
{"metadata": {"id": "ens2/172.16.31.106/24"}, "spec": {"address": "172.16.31.106/24", "linkName": "ens2"}}
{"metadata": {"id": "ens3/172.16.31.145/24"}, "spec": {"address": "172.16.31.145/24", "linkName": "ens3"}}
{"metadata": {"id": "ens2/fe80::1/64"}, "spec": {"address": "fe80::1/64", "linkName": "ens2"}}
{"metadata": {"id": "orphan"}, "spec": {"address": "10.0.0.1/24", "linkName": "gone"}}
"""

DISKS = """
{"metadata": {"id": "vda"}, "spec": {"dev_path": "/dev/vda", "size": 21474836480,
 "pretty_size": "21 GB", "rotational": true, "bus_path": "/pci0000:00/0000:00:04.0/virtio2"}}
{"metadata": {"id": "vdb"}, "spec": {"dev_path": "/dev/vdb", "size": 42949672960,
 "pretty_size": "42 GB", "rotational": true}}
{"metadata": {"id": "sr0"}, "spec": {"dev_path": "/dev/sr0", "size": 1073741824, "cdrom": true}}
{"metadata": {"id": "sdc"}, "spec": {"dev_path": "/dev/sdc", "size": 8000000000,
 "transport": "usb", "wwid": "usb-0001"}}
"""


def read(kind):
    return facts.decode_documents({"links": LINKS, "addresses": ADDRESSES, "disks": DISKS}[kind])


class TestDecodeDocuments:
    def test_reads_concatenated_documents(self):
        assert len(facts.decode_documents(LINKS)) == 6

    def test_handles_empty_output(self):
        assert facts.decode_documents("") == []
        assert facts.decode_documents(None) == []

    def test_reads_documents_spanning_several_lines(self):
        # talosctl pretty-prints, so a document is not a line.
        assert len(facts.decode_documents('{\n  "a": 1\n}\n{\n  "a": 2\n}')) == 2


class TestLinkFacts:
    def test_identifies_physical_links(self):
        links = facts.link_facts(read("links"))
        assert [n for n, l in links.items() if l["physical"]] == ["ens2", "ens3"]

    def test_excludes_bonds_tunnels_and_loopback(self):
        links = facts.link_facts(read("links"))
        for name in ("bond0", "lo", "flannel.1", "teql0"):
            assert links[name]["physical"] is False

    def test_falls_back_to_hardware_address(self):
        # A link with no permanentAddr still has to be selectable.
        links = facts.link_facts(read("links"))
        assert links["bond0"]["permanentAddr"] == "aa:00:00:00:00:09"


class TestAddresses:
    def test_attaches_addresses_to_their_link(self):
        links = facts.attach_addresses(facts.link_facts(read("links")), read("addresses"))
        assert [a["ip"] for a in links["ens2"]["addresses"]] == ["172.16.31.106", "fe80::1"]
        assert [a["ip"] for a in links["ens3"]["addresses"]] == ["172.16.31.145"]

    def test_ignores_addresses_on_unknown_links(self):
        links = facts.attach_addresses(facts.link_facts(read("links")), read("addresses"))
        assert all("10.0.0.1" not in str(l["addresses"]) for l in links.values())


class TestDiskFacts:
    def test_reports_every_disk_without_judgement(self):
        # Selection is the caller's business; the module must not pre-filter.
        assert {d["devPath"] for d in facts.disk_facts(read("disks"))} == {
            "/dev/vda", "/dev/vdb", "/dev/sr0", "/dev/sdc"
        }

    def test_exposes_the_attributes_selection_needs(self):
        disks = {d["devPath"]: d for d in facts.disk_facts(read("disks"))}
        assert disks["/dev/sr0"]["cdrom"] is True
        assert disks["/dev/sdc"]["transport"] == "usb"
        assert disks["/dev/vda"]["rotational"] is True
        assert disks["/dev/vda"]["size"] == 21474836480


class TestDescribe:
    def test_assembles_a_machine(self):
        machine = facts.describe("172.16.31.106", read)
        assert machine["address"] == "172.16.31.106"
        assert [l["name"] for l in machine["links"]] == [
            "bond0", "ens2", "ens3", "flannel.1", "lo", "teql0"
        ]
        assert len(machine["disks"]) == 4


class TestDeduplicate:
    def test_collapses_one_machine_answering_on_several_addresses(self):
        a = facts.describe("172.16.31.106", read)
        b = facts.describe("172.16.31.145", read)
        assert len(facts.deduplicate([a, b])) == 1

    def test_keeps_distinct_machines(self):
        a = facts.describe("172.16.31.106", read)
        b = facts.describe("172.16.31.107", read)
        b["links"] = [dict(l, permanentAddr="aa:bb:cc:dd:ee:ff") for l in b["links"]]
        assert len(facts.deduplicate([a, b])) == 2

    def test_drops_machines_that_reported_nothing(self):
        # A failed talosctl call yields no links; such an entry identifies nothing
        # and must not be mistaken for a machine.
        assert facts.deduplicate([{"address": "10.0.0.1", "links": [], "disks": []}]) == []


@pytest.mark.parametrize("network", ["not-a-network", "172.16.31.0/99"])
def test_scan_rejects_invalid_networks(network):
    with pytest.raises(ValueError):
        facts.scan(network, 50000, 0.01, 4)
