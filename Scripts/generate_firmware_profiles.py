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
_HEX_BASE_RE = re.compile(r"^0x[0-9A-Fa-f]{8,16}$")
_HEX_SIZE_RE = re.compile(r"^0x[0-9A-Fa-f]{2,5}$")
_HEX_OFFSET_RE = re.compile(r"^0x[0-9A-Fa-f]{1,4}$")
_IT8227_V0_OFFSETS = {
    "curve_point": 0x134,
    "curve_size": 0x135,
    "cpu_temp": 0x138,
    "gpu_temp": 0x139,
    "fan1_curve": 0x140,
    "fan2_curve": 0x150,
    "fan1_rpm": 0x1E0,
    "fan2_rpm": 0x1E2,
    "update_counter1": 0x1FE,
    "update_counter2": 0x1FF,
    "internal_cpu_level": 0x234,
    "internal_gpu_level": 0x235,
    "internal_sensor_level": 0x236,
}


def _parse_mmio(profile, profile_id):
    ec_base_raw = profile.get("ec_base")
    ec_size_raw = profile.get("ec_size")
    if (ec_base_raw is None) != (ec_size_raw is None):
        raise ValueError(f"{profile_id}: ec_base and ec_size must be provided together")
    if ec_base_raw is None:
        return 0, 0
    if not isinstance(ec_base_raw, str) or not _HEX_BASE_RE.fullmatch(ec_base_raw):
        raise ValueError(f"{profile_id}: invalid ec_base")
    if not isinstance(ec_size_raw, str) or not _HEX_SIZE_RE.fullmatch(ec_size_raw):
        raise ValueError(f"{profile_id}: invalid ec_size")
    ec_base = int(ec_base_raw, 16)
    ec_size = int(ec_size_raw, 16)
    if ec_base == 0 or (ec_base & 0xFF) != 0:
        raise ValueError(f"{profile_id}: ec_base must be non-zero and 256-byte aligned")
    if ec_size < 0x100 or ec_size > 0x10000:
        raise ValueError(f"{profile_id}: ec_size out of range [0x100, 0x10000]")
    return ec_base, ec_size


def _fan_curve_metadata(profile, profile_id):
    ec_base, ec_size = _parse_mmio(profile, profile_id)
    curve_points_max = profile.get("curve_points_max", 0)
    if "curve_points_max" in profile and (type(curve_points_max) is not int or not 1 <= curve_points_max <= 10):
        raise ValueError(f"{profile_id}: curve_points_max must be integer 1..10")
    offsets = profile.get("offsets")
    it8227_v0 = False
    if offsets is not None:
        if not isinstance(offsets, dict) or ec_size < 0x300:
            raise ValueError(f"{profile_id}: offsets require valid ec_base and ec_size >= 0x300")
        parsed = {}
        for key, raw in offsets.items():
            if not isinstance(raw, str) or not _HEX_OFFSET_RE.fullmatch(raw):
                raise ValueError(f"{profile_id}: invalid offset {key}")
            val = int(raw, 16)
            if val >= ec_size:
                raise ValueError(f"{profile_id}: offset {key} exceeds ec_size")
            parsed[key] = val
        it8227_v0 = all(parsed.get(k) == v for k, v in _IT8227_V0_OFFSETS.items())
    sensors = profile.get("native_telemetry") or []
    has_dual_fans = {item.get("field") for item in sensors if isinstance(item, dict)} >= {"FANS", "FA2S"}
    verified_writes = profile.get("verified_writes", 0)
    if type(verified_writes) is not int or verified_writes not in (0, 1):
        raise ValueError(f"{profile_id}: verified_writes must be integer 0 or 1")
    bridge_kind = profile.get("bridge_kind")
    if not bridge_kind:
        bridge_kind = "named-fields-readonly" if profile.get("native_telemetry") and verified_writes == 0 else "raw-offsets"
    is_readonly = bridge_kind == "named-fields-readonly"
    if verified_writes == 1:
        if is_readonly or ec_base == 0 or ec_size < 0x300 or curve_points_max < 1 or not it8227_v0 or not has_dual_fans:
            raise ValueError(f"{profile_id}: verified_writes requires raw-offsets bridge and complete curve/MMIO metadata")
    return ec_base, ec_size, curve_points_max, 0 if is_readonly else verified_writes


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
    machine_owners = {}
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
            if machine in machine_owners and machine_owners[machine] != profile["name"]:
                raise ValueError(f"ambiguous machine type: {machine}")
            machine_owners[machine] = profile["name"]
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
        verified_writes = profile.get("verified_writes", 0)
        if type(verified_writes) is not int or verified_writes not in (0, 1):
            raise ValueError(f"{profile_id}: verified_writes must be integer 0 or 1")
        bridge_kind = profile.get("bridge_kind")
        if not bridge_kind:
            bridge_kind = "named-fields-readonly" if profile.get("native_telemetry") and profile.get("verified_writes", 0) == 0 else "raw-offsets"
        if bridge_kind not in ("raw-offsets", "named-fields-readonly"):
            raise ValueError(f"{profile_id}: unsupported bridge kind")
        if bridge_kind == "named-fields-readonly" and verified_writes:
            raise ValueError(f"{profile_id}: read-only bridge cannot validate writes")
        sensors = profile.get("native_telemetry")
        _fan_curve_metadata(profile, profile_id)
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
        is_readonly = (profile.get("bridge_kind") == "named-fields-readonly" or
                       (profile.get("native_telemetry") and profile.get("verified_writes", 0) == 0))
        ec_base, ec_size, curve_points_max, verified_writes = _fan_curve_metadata(profile, profile_id)
        ec_base_lit = f"0x{ec_base:08X}ULL" if ec_base else "0ULL"
        ec_size_lit = f"0x{ec_size:X}U" if ec_size else "0U"
        for machine in machine_types:
            for bios in bios_families:
                rows.append(
                    f'    {{"{profile_id}", {json.dumps(profile["name"])}, '
                    f'{json.dumps(oem_id)}, {json.dumps(machine)}, {json.dumps(bios)}, '
                    f'{{{fields}}}, {{{scales}}}, {json.dumps("|".join(profile.get("pci_subsystem_ids", [])))}, '
                    f'{1 if is_readonly else 2}, {ec_base_lit}, {ec_size_lit}, {curve_points_max}U, {verified_writes}U}},'
                )
    if not rows:
        raise ValueError("No native telemetry profiles found")
    return """// Generated by Scripts/generate_firmware_profiles.py; edit HardwareProfiles instead.
#ifndef ReYogaFirmwareProfiles_hpp
#define ReYogaFirmwareProfiles_hpp

#include <stdint.h>

struct ReYogaNativeProfile {
    const char *id;
    const char *name;
    const char *oemTableID;
    const char *machineType;
    const char *biosFamily;
    const char *fields[4]; // Absolute ACPI paths: fan 1/2 RPM, CPU/GPU Celsius.
    unsigned scales[4];
    const char *pciSubsystemIDs; // Model-specific Lenovo subsystem IDs separated by |.
    unsigned bridgeVersion; // Maximum reviewed bridge interface (1: named reads, 2: raw offsets).
    uint64_t ecBase; // Verified SystemMemory EC MMIO base address, or 0 if unavailable.
    uint32_t ecSize; // Verified EC MMIO window size in bytes, or 0 if unavailable.
    uint8_t curvePointsMax; // Maximum fan curve trip points (1..10), or 0 if unavailable.
    uint8_t verifiedWrites; // 1 only when writes and recovery are verified on hardware; 0 otherwise.
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
    OUTPUT.write_text(result, encoding="utf-8", newline="\n")
    print(f"Generated {OUTPUT}")


if __name__ == "__main__":
    main()
