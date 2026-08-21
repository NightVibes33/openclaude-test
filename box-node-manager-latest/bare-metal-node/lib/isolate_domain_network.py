#!/usr/bin/env python3
"""Atomically isolate the two expected libvirt domain network interfaces."""

import argparse
from collections import Counter
import os
from pathlib import Path
import tempfile
import xml.etree.ElementTree as ET


class IsolationError(ValueError):
    pass


def _expected_interfaces(root, expected_networks):
    if len(expected_networks) != 2:
        raise IsolationError("exactly two expected networks are required")

    interfaces = root.findall("./devices/interface")
    if len(interfaces) != 2:
        raise IsolationError(
            f"expected exactly 2 domain network interfaces, found {len(interfaces)}"
        )

    actual_networks = []
    for interface in interfaces:
        if interface.get("type") != "network":
            raise IsolationError("both domain interfaces must have type='network'")

        sources = interface.findall("source")
        if len(sources) != 1 or not sources[0].get("network"):
            raise IsolationError("each domain interface must have one network source")
        actual_networks.append(sources[0].get("network"))

        if len(interface.findall("port")) > 1:
            raise IsolationError("a domain interface has multiple port elements")

    if Counter(actual_networks) != Counter(expected_networks):
        raise IsolationError(
            f"expected network interfaces {expected_networks}, found {actual_networks}"
        )

    return interfaces


def isolate_tree(tree, expected_networks):
    interfaces = _expected_interfaces(tree.getroot(), expected_networks)
    for interface in interfaces:
        port = interface.find("port")
        if port is None:
            port = ET.SubElement(interface, "port")
        port.set("isolated", "yes")

    isolated = sum(
        interface.find("port") is not None
        and interface.find("port").get("isolated") == "yes"
        for interface in _expected_interfaces(tree.getroot(), expected_networks)
    )
    if isolated != 2:
        raise IsolationError(
            f"expected 2 isolated network interfaces, found {isolated}"
        )


def isolate_domain_xml(xml_path, expected_networks):
    path = Path(xml_path)
    try:
        tree = ET.parse(path)
    except (ET.ParseError, OSError) as error:
        raise IsolationError(f"cannot parse domain XML {path}: {error}") from error

    isolate_tree(tree, expected_networks)

    file_descriptor, temporary_name = tempfile.mkstemp(
        dir=path.parent, prefix=f".{path.name}.", suffix=".tmp"
    )
    try:
        with os.fdopen(file_descriptor, "wb") as temporary_file:
            tree.write(temporary_file, encoding="utf-8", xml_declaration=True)
            temporary_file.flush()
            os.fsync(temporary_file.fileno())
        os.chmod(temporary_name, path.stat().st_mode & 0o777)

        written_tree = ET.parse(temporary_name)
        interfaces = _expected_interfaces(written_tree.getroot(), expected_networks)
        if any(
            interface.find("port") is None
            or interface.find("port").get("isolated") != "yes"
            for interface in interfaces
        ):
            raise IsolationError(
                "atomic output validation found an unisolated interface"
            )

        os.replace(temporary_name, path)
        temporary_name = None
    finally:
        if temporary_name is not None:
            Path(temporary_name).unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("xml_path", help="rendered libvirt domain XML to update")
    parser.add_argument(
        "--expected-network",
        action="append",
        required=True,
        help="expected libvirt network name; pass exactly twice",
    )
    args = parser.parse_args()

    try:
        isolate_domain_xml(args.xml_path, args.expected_network)
    except IsolationError as error:
        parser.exit(1, f"network isolation validation failed: {error}\n")


if __name__ == "__main__":
    main()
