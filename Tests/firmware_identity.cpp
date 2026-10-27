// SPDX-License-Identifier: GPL-2.0-only
#include "../ReYogaSMC/FirmwareIdentity.hpp"
#include "../ReYogaSMC/ControlValidation.hpp"
#include <assert.h>
#include <stdio.h>
#include <vector>
using namespace ReYogaFirmware;

struct FanEC {
    unsigned calls {0}, failure {0}, selectorReads {0}, selectorWrites {0}, controlWrites {0};
    bool hasSelector {true}, mutateBeforeFailure {true}, ignoreSelectorWrite {false}, ignoreControlWrite {false};
    bool failRestore {false}, changeOtherBits {false};
    bool tachometerUnavailable {false};
    unsigned char selector {0xa0}, levels[2] {0x84, 0x84};
    bool read(unsigned offset, unsigned char &value) {
        if (offset == 0x31) ++selectorReads;
        if (++calls == failure) return false;
        value = offset == 0x31 ? selector : offset == 0x2f ? levels[hasSelector ? selector & 1 : 0] : offset == 0x84 ? 0x88 : 0x13;
        if (tachometerUnavailable && (offset == 0x84 || offset == 0x85)) value = 0xff;
        if (offset == 0x2f && changeOtherBits) { selector ^= 0x80; changeOtherBits = false; }
        return true;
    }
    bool write(unsigned offset, unsigned char value) {
        const bool failed = ++calls == failure || (failRestore && offset == 0x31 && !(value & 1));
        if (offset == 0x31) ++selectorWrites;
        else ++controlWrites;
        if (!failed || mutateBeforeFailure) {
            if (offset == 0x31) { if (!ignoreSelectorWrite) selector = value; }
            else if (!ignoreControlWrite) levels[hasSelector ? selector & 1 : 0] = value;
        }
        return !failed;
    }
    ReYogaControl::ThinkFanResult access(unsigned fan, unsigned target, unsigned char output[3], ReYogaControl::ThinkFanState &state) {
        return ReYogaControl::transactThinkFan(fan, target, output, hasSelector, state,
            [&](unsigned offset, unsigned char &value) { return read(offset, value); },
            [&](unsigned offset, unsigned char value) { return write(offset, value); });
    }
};

static void checkThinkFans() {
    using namespace ReYogaControl;
    FanEC modes;
    ThinkFanState modeState;
    unsigned char modeSample[3] {};
    assert(modes.access(0, 7, modeSample, modeState) == ThinkFanResult::ok && modeSample[2] == 0x07);
    assert(modes.access(0, 0x47, modeSample, modeState) == ThinkFanResult::ok && (modeSample[2] & 0x40));
    assert(modes.access(0, 0x84, modeSample, modeState) == ThinkFanResult::ok && (modeSample[2] & 0x80));
    ThinkFanState logging;
    assert(!logging.pollStatusChanged(0, 0));
    assert(logging.pollStatusChanged(0, 1));
    assert(!logging.pollStatusChanged(0, 1));
    assert(logging.pollStatusChanged(1, 1));
    assert(logging.pollStatusChanged(0, 0));
    assert(!logging.pollStatusChanged(0, 0));
    assert(!logging.pollStatusChanged(2, 1));
    unsigned char output[3] {};
    ThinkFanState singleState;
    FanEC single;
    single.hasSelector = false;
    single.selector = 3;
    assert(single.access(0, 0x100, output, singleState) == ThinkFanResult::ok);
    assert(single.selectorReads == 0 && single.selectorWrites == 0 && single.controlWrites == 0);
    const unsigned calls = single.calls;
    assert(single.access(1, 4, output, singleState) == ThinkFanResult::invalid && single.calls == calls);

    // Missing tachometer data must not turn a confirmed Auto command into a failure.
    single.tachometerUnavailable = true;
    assert(single.access(0, 0x84, output, singleState) == ThinkFanResult::ok);
    assert(output[0] == 0xff && output[1] == 0xff && output[2] == 0x84);
    assert(singleState.modifiedMask == 0);
    assert(single.access(0, 0x100, output, singleState) == ThinkFanResult::ok);
    assert(single.selectorReads == 0 && single.selectorWrites == 0);

    // Readback still has to confirm Auto even when the tachometer is unavailable.
    single.ignoreControlWrite = true;
    single.levels[0] = 4;
    assert(single.access(0, 0x84, output, singleState) == ThinkFanResult::readbackMismatch);
    assert(singleState.modifiedMask == 1);
    single.levels[0] = 0xc4;
    assert(single.access(0, 0x100, output, singleState) == ThinkFanResult::readbackMismatch);

    ThinkFanState mainReadState;
    FanEC mainRead;
    mainRead.selector = 0xa1;
    assert(mainRead.access(0, 0x100, output, mainReadState) == ThinkFanResult::ok);
    assert(mainRead.selector == 0xa1 && mainRead.controlWrites == 0 && mainReadState.modifiedMask == 0);

    ThinkFanState initial;
    FanEC successful;
    assert(successful.access(1, 4, output, initial) == ThinkFanResult::ok);
    assert(initial.modifiedMask == 2 && successful.selector == 0xa0);
    const unsigned steps = successful.calls;
    for (bool mutate : {false, true}) {
        for (unsigned failure = 1; failure <= steps; ++failure) {
            ThinkFanState state;
            FanEC ec;
            ec.failure = failure; ec.mutateBeforeFailure = mutate;
            unsigned char sample[3] = {0xee, 0xee, 0xee};
            assert(ec.access(1, 4, sample, state) != ThinkFanResult::ok);
            assert(sample[0] == 0xee && sample[1] == 0xee && sample[2] == 0xee);
            if (state.modifiedMask || state.selectorRestorePending) {
                assert(ec.access(1, 0x84, sample, state) == ThinkFanResult::ok);
                assert(!state.selectorRestorePending && state.modifiedMask == 0);
                assert(ec.levels[1] == 0x84 && (ec.selector & 1) == 0);
            }
        }
    }
    ThinkFanState blocked;
    FanEC ec;
    ec.failRestore = true; ec.mutateBeforeFailure = false;
    assert(ec.access(1, 1, output, blocked) == ThinkFanResult::restoreFailed);
    assert(blocked.selectorRestorePending && blocked.modifiedMask == 2 && ec.levels[1] == 1);
    const unsigned writes = ec.controlWrites;
    assert(ec.access(1, 4, output, blocked) == ThinkFanResult::restoreFailed && ec.controlWrites == writes);
    assert(ec.access(1, 0x84, output, blocked) == ThinkFanResult::restoreFailed && blocked.modifiedMask == 2);
    ec.failRestore = false;
    assert(ec.access(1, 0x84, output, blocked) == ThinkFanResult::ok);
    assert(!blocked.selectorRestorePending && blocked.modifiedMask == 0 && ec.levels[1] == 0x84);

    ThinkFanState ignored;
    FanEC wrongBank;
    wrongBank.ignoreSelectorWrite = true;
    assert(wrongBank.access(1, 4, output, ignored) == ThinkFanResult::transportFailed);
    assert(wrongBank.controlWrites == 0 && ignored.modifiedMask == 0);

    ThinkFanState unconfirmed;
    FanEC rejectedAuto;
    assert(rejectedAuto.access(1, 1, output, unconfirmed) == ThinkFanResult::ok);
    rejectedAuto.ignoreControlWrite = true;
    assert(rejectedAuto.access(1, 0x84, output, unconfirmed) == ThinkFanResult::readbackMismatch);
    assert(unconfirmed.modifiedMask == 2);

    ThinkFanState changed;
    FanEC otherBits;
    otherBits.changeOtherBits = true;
    assert(otherBits.access(1, 4, output, changed) == ThinkFanResult::ok && otherBits.selector == 0x20);
}

static Identity identity(const char *machine, const char *bios) {
    Identity result;
    result.add(machine, strlen(machine), false);
    result.add(bios, strlen(bios), true);
    return result;
}

int main() {
    assert(ReYogaControl::thinkFanRPM(0x28, 0x1a) == 6696);
    assert(ReYogaControl::thinkFanRPM(0x19, 0x1a) == 6681);
    assert(ReYogaControl::thinkFanRPM(0x00, 0x1b) == 6912);
    assert(ReYogaControl::thinkFanRPM(0xff, 0xff) == 65535);
    for (unsigned rpm = 0; rpm <= 0xffff; ++rpm)
        assert(ReYogaControl::thinkFanRPM(rpm & 0xff, rpm >> 8) == rpm);
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

    for (unsigned status : {3U, 4U, 5U, 6U, 7U, 12U, 13U, 14U, 16U, 20U, 23U})
        assert(!ReYogaControl::validHPSensorStatus(status));
    for (unsigned status : {0U, 1U, 2U, 17U, 19U})
        assert(ReYogaControl::validHPSensorStatus(status));
    unsigned hpValue = 0;
    assert(ReYogaControl::decodeHPSensor(420, -1, 2, 2, hpValue) && hpValue == 42000);
    assert(ReYogaControl::decodeHPSensor(555, -1, 2, 2, hpValue) && hpValue == 55500);
    assert(ReYogaControl::decodeHPSensor(104, 0, 2, 3, hpValue) && hpValue == 40000);
    assert(ReYogaControl::decodeHPSensor(31315, -2, 2, 4, hpValue) && hpValue == 40000);
    assert(ReYogaControl::decodeHPSensor(32, 2, 12, 19, hpValue) && hpValue == 3200);
    assert(ReYogaControl::decodeHPSensor(0, 0, 12, 19, hpValue) && hpValue == 0);
    assert(!ReYogaControl::decodeHPSensor(42, 0, 2, 19, hpValue));
    assert(!ReYogaControl::decodeHPSensor(42, -2147483647 - 1, 2, 2, hpValue));
    assert(!ReYogaControl::decodeHPSensor(0xffffffffU, 9, 12, 19, hpValue));
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

    checkThinkFans();
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
    puts("PASS firmware identities, sensor bounds, SMBIOS parser, fan topology and transaction recovery");
}
