// SPDX-License-Identifier: GPL-2.0-only
#include "../ReYogaSMC/FirmwareIdentity.hpp"
#include "../ReYogaSMC/ControlValidation.hpp"
#include <assert.h>
#include <stdio.h>
#include <vector>
using namespace ReYogaFirmware;

static Identity identity(const char *machine, const char *bios) {
    Identity result;
    result.add(machine, strlen(machine), false);
    result.add(bios, strlen(bios), true);
    return result;
}

int main() {
    constexpr size_t count = sizeof(ReYogaNativeProfiles) / sizeof(ReYogaNativeProfiles[0]);
    for (const auto &profile : ReYogaNativeProfiles) {
        char version[16] {};
        snprintf(version, sizeof(version), "%s99WW", profile.biosFamily);
        auto evidence = identity(profile.machineType, version);
        auto match = select(ReYogaNativeProfiles, count, evidence, profile.oemTableID, "");
        assert(match.profile && !strcmp(match.profile->id, profile.id));
        assert(match.state == MatchState::matched);
    }
    Identity pciOnly;
    pciOnly.addPCI(0x17aa, 0x3a58);
    auto pciMatch = select(ReYogaNativeProfiles, count, pciOnly, "CB-01", "");
    assert(pciMatch.profile && !strcmp(pciMatch.profile->id, "legion7-16achg6-gkcn"));
    assert(pciMatch.pciMatched && !pciMatch.exact);
    assert(select(ReYogaNativeProfiles, count, pciOnly, "OTHER", "").profile == nullptr);
    auto changedBIOS = identity("82N6", "GKCN99WW");
    assert(select(ReYogaNativeProfiles, count, changedBIOS, "CB-01", "").profile);
    auto machineOnly = identity("82N6", "");
    assert(select(ReYogaNativeProfiles, count, machineOnly, "CB-01", "").profile);
    auto contradictoryPCI = identity("82JQ", "");
    contradictoryPCI.addPCI(0x17aa, 0x3a58);
    assert(select(ReYogaNativeProfiles, count, contradictoryPCI, "CB-01", "").state == MatchState::conflict);
    auto unknownPCI = Identity {};
    unknownPCI.addPCI(0x17aa, 0x0001);
    assert(!select(ReYogaNativeProfiles, count, unknownPCI, "CB-01", "").profile);
    auto legion = identity("82N6CTO1WW", "GKCN65WW");
    auto empty = Identity {};
    assert(!select(ReYogaNativeProfiles, count, empty, "CB-01", "").profile);
    assert(select(ReYogaNativeProfiles, count, empty, "CB-01", "").state == MatchState::missingIdentity);
    assert(!select(ReYogaNativeProfiles, count, identity("82N6", "ZZZZ99WW"), "CB-01", "").profile);
    assert(!select(ReYogaNativeProfiles, count, legion, "OTHER", "").profile);
    auto apple = identity("MacBookPro16,3", "MBP161.999");
    assert(!apple.machine[0] && !select(ReYogaNativeProfiles, count, apple, "CB-01", "").profile);
    legion.add("82JQ", 4, false);
    assert(legion.conflict && select(ReYogaNativeProfiles, count, legion, "CB-01", "").state == MatchState::conflict);

    const char *hash = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    auto row = ReYogaNativeProfiles[0];
    row.amlHashes = hash;
    auto exact = select(&row, 1, empty, row.oemTableID, hash);
    assert(exact.profile && exact.exact);
    assert(select(&row, 1, identity("9999", "ZZZZ99WW"), row.oemTableID, hash).state == MatchState::conflict);
    assert(!hashMatches("short", hash));
    assert(!hashMatches(hash, "short"));
    ReYogaNativeProfile duplicates[] = {row, row};
    assert(select(duplicates, 2, empty, row.oemTableID, hash).profile);
    duplicates[1].id = "conflicting-profile";
    assert(select(duplicates, 2, empty, row.oemTableID, hash).state == MatchState::ambiguous);

    uint32_t value = 0;
    assert(validSample(0, 0, 100, value) && value == 0);
    assert(validSample(0, 50, 100, value) && value == 5000);
    assert(!validSample(0, 0xffff, 100, value));
    assert(!validSample(0, UINT32_MAX, 100, value));
    assert(!validSample(2, 0, 1, value));
    assert(!validSample(2, 125, 1, value));
    assert(validSample(3, 45, 1, value));
    assert(!validSample(2, 45, 0, value));
    for (unsigned level = 0; level <= 0x100; ++level)
        assert(ReYogaControl::validThinkFanLevel(level) ==
            (level <= 7 || level == 0x47 || level == 0x80 || level == 0x84));

    // Inject a failure at every transaction step. A changed selector is always
    // restored; failed transactions never publish a partial measurement.
    for (unsigned failure = 0; failure <= 7; ++failure) {
        unsigned calls = 0;
        unsigned char selector = 0xa0, level = 0x84, output[3] = {0xee, 0xee, 0xee};
        const auto result = ReYogaControl::transactThinkFan(1, 4, output,
            [&](unsigned offset, unsigned char &value) {
                if (++calls == failure) return false;
                value = offset == 0x31 ? selector : offset == 0x2f ? level : offset == 0x84 ? 0x88 : 0x13;
                return true;
            },
            [&](unsigned offset, unsigned char value) {
                // Model firmware that changes the selector before reporting
                // a transport failure, so restoration is still necessary.
                if (offset == 0x31) selector = value;
                else level = value;
                return ++calls != failure;
            });
        if (!failure) {
            assert(result == ReYogaControl::ThinkFanResult::ok && output[2] == 4);
        } else {
            assert(result != ReYogaControl::ThinkFanResult::ok && output[0] == 0xee);
        }
        assert(selector == 0xa0);
    }
    std::vector<uint8_t> table = {0, 6, 0, 0, 1, 2};
    const char bios[] = "LENOVO\0GKCN65WW\0";
    table.insert(table.end(), bios, bios + sizeof(bios));
    const uint8_t product[] = {1, 6, 0, 0, 1, 2, 'L', 'E', 'N', 'O', 'V', 'O', 0, '8', '2', 'N', '6', 0, 0};
    table.insert(table.end(), product, product + sizeof(product));
    Identity decoded;
    assert(readSMBIOS(table.data(), table.size(), decoded));
    assert(!strcmp(decoded.machine, "82N6") && !strcmp(decoded.bios, "GKCN"));
    for (size_t size = 1; size < 6; ++size) {
        Identity rejected;
        assert(!readSMBIOS(table.data(), size, rejected));
        assert(!rejected.machine[0] && !rejected.bios[0]);
    }
    // Exercise untrusted lengths and string indexes under ASan/UBSan.
    uint32_t random = 0x12345678;
    for (unsigned iteration = 0; iteration < 10000; ++iteration) {
        uint8_t bytes[128];
        for (auto &byte : bytes) { random = random * 1664525U + 1013904223U; byte = random >> 24; }
        Identity fuzzed;
        readSMBIOS(bytes, iteration % sizeof(bytes), fuzzed);
    }
    puts("PASS all declared firmware identities, ambiguous/conflicting/missing evidence, sensor bounds and SMBIOS parser");
}
