"""Generate the read-only kernel profile table from reviewed hardware profiles."""
import argparse
import json
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "ReYogaSMC/ReYogaFirmwareProfiles.hpp"

_FIELD_ORDER = ("FANS", "FA2S", "CPUT", "GPUT")
_IDENTITY_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{1,63}$")
_MACHINE_RE = re.compile(r"^[0-9A-Z]{4}$")
_BIOS_RE = re.compile(r"^[0-9A-Z]{4}$")
_OEM_RE = re.compile(r"^[ -~]{1,8}$")
_EC_PATH_RE = re.compile(r"^\\_SB(?:\.[A-Z_][A-Z0-9_]{0,3})+$")
_PCI_RE = re.compile(r"^17aa:[0-9a-f]{4}$")
_HASH_RE = re.compile(r"^[a-f0-9]{64}$")


def _require_string(profile, key):
    value = profile.get(key)
    if not isinstance(value, str) or not value:
        raise ValueError(f"{profile.get('id', '<profile>')}: {key} must be non-empty text")
    return value


def _validate_identity(profile):
    profile_id = _require_string(profile, "id")
    name = _require_string(profile, "name")
    if len(name) > 128 or any(ord(character) < 32 for character in name):
        raise ValueError(f"{profile_id}: invalid model name")
    if not _IDENTITY_RE.fullmatch(profile_id):
        raise ValueError(f"{profile_id}: invalid profile id")
    machine_types = profile.get("machine_types")
    bios_families = profile.get("bios_families")
    oem_ids = profile.get("oem_table_ids")
    if not isinstance(machine_types, list) or not machine_types:
        raise ValueError(f"{profile_id}: machine_types is required")
    if not all(isinstance(value, str) and _MACHINE_RE.fullmatch(value) for value in machine_types):
        raise ValueError(f"{profile_id}: invalid machine type")
    if not isinstance(bios_families, list) or not bios_families:
        raise ValueError(f"{profile_id}: bios_families is required")
    if not all(isinstance(value, str) and _BIOS_RE.fullmatch(value) for value in bios_families):
        raise ValueError(f"{profile_id}: invalid BIOS family")
    if not isinstance(oem_ids, list) or len(oem_ids) != 1 or not isinstance(oem_ids[0], str) or not _OEM_RE.fullmatch(oem_ids[0]):
        raise ValueError(f"{profile_id}: exactly one valid oem_table_ids value is required")
    namespace = profile.get("ec_path")
    if not isinstance(namespace, str) or not _EC_PATH_RE.fullmatch(namespace):
        raise ValueError(f"{profile_id}: ec_path must be an absolute ACPI namespace path")
    return profile_id, machine_types, bios_families, oem_ids[0], namespace


def _validate_profiles(profiles):
    ids = set()
    identities = set()
    pci_owners = {}
    hash_owners = {}
    for profile in profiles:
        if not isinstance(profile, dict) or type(profile.get("schema_version")) is not int or profile.get("schema_version") != 1:
            raise ValueError("profile schema_version must be 1")
        if profile.get("kind") != "acpi":
            continue
        profile_id, machine_types, bios_families, oem_id, namespace = _validate_identity(profile)
        if profile_id in ids:
            raise ValueError(f"duplicate profile id: {profile_id}")
        ids.add(profile_id)
        for machine in machine_types:
            for bios in bios_families:
                identity = (machine, bios, oem_id)
                if identity in identities:
                    raise ValueError(f"ambiguous firmware identity: {identity}")
                identities.add(identity)
        pci_ids = profile.get("pci_subsystem_ids", [])
        if not isinstance(pci_ids, list) or not all(isinstance(value, str) and _PCI_RE.fullmatch(value) for value in pci_ids):
            raise ValueError(f"{profile_id}: invalid Lenovo PCI subsystem IDs")
        for value in pci_ids:
            if value in pci_owners and pci_owners[value] != profile["name"]:
                raise ValueError(f"ambiguous PCI subsystem ID: {value}")
            pci_owners[value] = profile["name"]
        for key in ("reviewed_aml_hashes", "reviewed_dsdt_hashes"):
            hashes = profile.get(key, [])
            if not isinstance(hashes, list) or len(hashes) > 128 or not all(isinstance(value, str) and _HASH_RE.fullmatch(value) for value in hashes):
                raise ValueError(f"{profile_id}: invalid {key}")
            for digest in hashes:
                identity = (key, digest)
                if identity in hash_owners and hash_owners[identity] != profile_id:
                    raise ValueError(f"ambiguous reviewed firmware fingerprint: {digest}")
                hash_owners[identity] = profile_id
        verified_writes = profile.get("verified_writes", 0)
        if type(verified_writes) is not int or verified_writes not in (0, 1):
            raise ValueError(f"{profile_id}: verified_writes must be integer 0 or 1")
        if verified_writes and not profile.get("reviewed_aml_hashes"):
            raise ValueError(f"{profile_id}: validated writes require reviewed AML fingerprints")
        sensors = profile.get("native_telemetry")
        if sensors is None:
            continue
        if not isinstance(sensors, list) or not all(isinstance(item, dict) for item in sensors) or [item.get("field") for item in sensors] != list(_FIELD_ORDER):
            raise ValueError(f"{profile_id}: native_telemetry must contain {_FIELD_ORDER} in order")
        for sensor in sensors:
            scale = sensor.get("scale")
            if type(scale) is not int or not 1 <= scale <= 1000:
                raise ValueError(f"{profile_id}: invalid sensor scale: {scale}")


def render(profiles):
    _validate_profiles(profiles)
    rows = []
    for profile in sorted(profiles, key=lambda item: item.get("id", "")):
        if profile.get("kind") != "acpi" or "native_telemetry" not in profile:
            continue
        profile_id, machine_types, bios_families, oem_id, namespace = _validate_identity(profile)
        fields = ", ".join(json.dumps(namespace + "." + field) for field in _FIELD_ORDER)
        scales = ", ".join(str(sensor["scale"]) for sensor in profile["native_telemetry"])
        for machine in machine_types:
            for bios in bios_families:
                rows.append(
                    f'    {{"{profile_id}", {json.dumps(profile["name"])}, '
                    f'{json.dumps(oem_id)}, {json.dumps(machine)}, {json.dumps(bios)}, '
                    f'{{{fields}}}, {{{scales}}}, {json.dumps("|".join(profile.get("reviewed_aml_hashes", [])))}, {json.dumps("|".join(profile.get("pci_subsystem_ids", [])))}}},'
                )
    if not rows:
        raise ValueError("No native telemetry profiles found")
    return """// Generated by Scripts/generate_firmware_profiles.py; edit HardwareProfiles instead.
#ifndef ReYogaFirmwareProfiles_hpp
#define ReYogaFirmwareProfiles_hpp

struct ReYogaNativeProfile {
    const char *id;
    const char *name;
    const char *oemTableID;
    const char *machineType;
    const char *biosFamily;
    const char *fields[4]; // Absolute ACPI paths: fan 1/2 RPM, CPU/GPU Celsius.
    unsigned scales[4];
    const char *amlHashes; // Reviewed AML SHA-256 digests separated by |.
    const char *pciSubsystemIDs; // Model-specific Lenovo subsystem IDs separated by |.
};

static constexpr ReYogaNativeProfile ReYogaNativeProfiles[] = {
""" + "\n".join(rows) + """
};

#endif
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    profiles = [json.loads(path.read_text(encoding="utf-8")) for path in sorted((ROOT / "HardwareProfiles").glob("*.json"))]
    result = render(profiles)
    if args.check:
        current = OUTPUT.read_text(encoding="utf-8") if OUTPUT.exists() else ""
        if current != result:
            raise SystemExit("ReYogaFirmwareProfiles.hpp is out of date. Run python3 Scripts/generate_firmware_profiles.py")
        print("Firmware profile table is up to date.")
        return
    OUTPUT.write_text(result, encoding="utf-8")
    print(f"Generated {OUTPUT}")


if __name__ == "__main__":
    main()
