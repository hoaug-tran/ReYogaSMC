"""Replay production control envelopes/results with owned-reference and fault stubs."""
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest
try:
    from .source_tools import function
except ImportError:
    from source_tools import function

ROOT = pathlib.Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which('g++') or shutil.which('clang++'), 'C++ compiler required')
class ControlRequestTests(unittest.TestCase):
    def test_envelope_readback_and_failure_ownership(self):
        header = (ROOT / 'ReYogaSMC/ControlRequest.hpp').read_text(encoding='utf-8')
        common = (ROOT / 'ReYogaSMC/common.h').read_text(encoding='utf-8')
        helpers = '\n'.join('template <typename ' + parameters + '>\n' + function(common, signature)
                            for parameters, signature in (
                                ('Value, typename Key', 'inline Value *get('),
                                ('Key', 'inline bool setOwned('),
                                ('Key', 'inline bool setBoolean('),
                                ('Key', 'inline bool setNumber(')))
        production = '\n'.join(function(header, signature) for signature in (
            'struct ControlEnvelope', 'inline bool parseControlEnvelope(', 'inline OSDictionary *makeControlResult('))
        # source_tools.function returns the braced definition; a struct also needs its semicolon.
        production = production.replace('\ninline bool parseControlEnvelope', ';\ninline bool parseControlEnvelope', 1)
        fixture = r'''
#include "ReYogaSMC/ControlValidation.hpp"
#include <cassert>
#include <cstdint>
#include <map>
#include <string>
using UInt64 = std::uint64_t;
using IOReturn = std::int32_t;
constexpr IOReturn kIOReturnSuccess = 0;
constexpr IOReturn kIOReturnIOError = static_cast<IOReturn>(0xe00002caU);
constexpr IOReturn commandError = static_cast<IOReturn>(0xe00002d8U);
#define OSDynamicCast(type, value) dynamic_cast<type *>(value)

struct OSObject {
    static int live;
    int references = 1;
    OSObject() { ++live; }
    OSObject(const OSObject &) = delete;
    virtual ~OSObject() { assert(references == 0); --live; }
    void retain() { assert(references > 0); ++references; }
    void release() { assert(references > 0); if (--references == 0) delete this; }
    virtual bool isEqualTo(const OSObject *other) const { return this == other; }
};
int OSObject::live = 0;
struct OSString : OSObject {
    std::string value;
    explicit OSString(std::string text) : value(text) {}
    unsigned getLength() const { return static_cast<unsigned>(value.size()); }
};
struct OSNumber : OSObject {
    static int allocations, failAllocation;
    UInt64 value;
    unsigned bits;
    OSNumber(UInt64 number, unsigned width) : value(width == 32 ? number & 0xffffffffULL : number), bits(width) {}
    static OSNumber *withNumber(UInt64 number, unsigned width) {
        if (++allocations == failAllocation) return nullptr;
        return new OSNumber(number, width);
    }
    bool isEqualTo(const OSObject *other) const override {
        auto number = dynamic_cast<const OSNumber *>(other);
        return number && value == number->value;
    }
};
int OSNumber::allocations = 0;
int OSNumber::failAllocation = -1;
struct OSBoolean : OSObject { bool value; explicit OSBoolean(bool flag) : value(flag) {} };
OSBoolean *kOSBooleanTrue = new OSBoolean(true), *kOSBooleanFalse = new OSBoolean(false);
struct OSDictionary : OSObject {
    static bool failAllocation;
    static std::string failKey;
    std::map<std::string, OSObject *> objects;
    static OSDictionary *withCapacity(unsigned) { return failAllocation ? nullptr : new OSDictionary; }
    ~OSDictionary() override { for (const auto &entry : objects) entry.second->release(); }
    OSObject *getObject(const char *key) const {
        auto found = objects.find(key);
        return found == objects.end() ? nullptr : found->second;
    }
    bool setObject(const char *key, OSObject *object) {
        if (!object || failKey == key) return false;
        object->retain();
        auto previous = getObject(key);
        objects[key] = object;
        if (previous) previous->release();
        return true;
    }
    void removeObject(const char *key) {
        auto object = getObject(key);
        if (object) { objects.erase(key); object->release(); }
    }
};
bool OSDictionary::failAllocation = false;
std::string OSDictionary::failKey;
namespace ReYogaProperty {
// PROPERTY_HELPERS
}
namespace ReYogaControl {
// CONTROL_FUNCTIONS
}
using namespace ReYogaControl;

OSDictionary *request(unsigned propertyLength = 8, unsigned requestIDLength = 4) {
    auto dictionary = new OSDictionary;
    assert(ReYogaProperty::setOwned(dictionary, "Property", new OSString(std::string(propertyLength, 'p'))));
    assert(ReYogaProperty::setOwned(dictionary, "RequestID", new OSString(std::string(requestIDLength, 'r'))));
    assert(ReYogaProperty::setOwned(dictionary, "Value", new OSNumber(4, 32)));
    return dictionary;
}
void resetFaults() {
    OSDictionary::failAllocation = false;
    OSDictionary::failKey.clear();
    OSNumber::allocations = 0;
    OSNumber::failAllocation = -1;
}
void assertEmpty(const ControlEnvelope &envelope) {
    assert(!envelope.property && !envelope.requestID && !envelope.value);
}
void assertStatus(OSDictionary *result, const char *key, IOReturn status) {
    auto number = ReYogaProperty::get<OSNumber>(result, key);
    assert(number && number->bits == 32 && number->value == static_cast<std::uint32_t>(status));
}
void testParsing() {
    auto valid = request();
    ControlEnvelope envelope;
    assert(parseControlEnvelope(valid, envelope));
    assert(envelope.property == valid->getObject("Property") && envelope.requestID == valid->getObject("RequestID"));
    assert(envelope.value == valid->getObject("Value"));
    assert(envelope.property->references == 1 && envelope.requestID->references == 1 && envelope.value->references == 1);
    assert(!parseControlEnvelope(nullptr, envelope));
    assertEmpty(envelope);
    valid->release();
    for (const char *key : {"Property", "RequestID", "Value"}) {
        auto missing = request();
        assert(parseControlEnvelope(missing, envelope));
        missing->removeObject(key);
        assert(!parseControlEnvelope(missing, envelope));
        assertEmpty(envelope);
        missing->release();
    }
    for (const char *key : {"Property", "RequestID"}) {
        auto wrong = request();
        assert(parseControlEnvelope(wrong, envelope));
        assert(ReYogaProperty::setOwned(wrong, key, new OSNumber(1, 32)));
        assert(!parseControlEnvelope(wrong, envelope));
        assertEmpty(envelope);
        wrong->release();
    }
    for (unsigned length : {0U, 64U, 65U}) {
        for (bool property : {false, true}) {
            auto bounded = request(property ? length : 8, property ? 4 : length);
            bool parsed = parseControlEnvelope(bounded, envelope);
            assert(parsed == (length <= 64));
            if (!parsed) assertEmpty(envelope);
            bounded->release();
        }
    }
}
void testResults() {
    for (IOReturn command : {kIOReturnSuccess, commandError}) {
        for (int readback : {0, 1, 2}) {
            auto input = request();
            ControlEnvelope envelope;
            assert(parseControlEnvelope(input, envelope));
            auto actual = readback == 0 ? nullptr : new OSNumber(readback == 1 ? 4 : 5, 32);
            IOReturn status = 123;
            auto result = makeControlResult(envelope, actual, command, status);
            auto expected = command != kIOReturnSuccess ? command : readback == 1 ? kIOReturnSuccess : kIOReturnIOError;
            assert(result && result->references == 1 && status == expected);
            assertStatus(result, "Status", expected);
            assertStatus(result, "CommandStatus", command);
            assert(result->getObject("ReadbackPending") ==
                (command == kIOReturnSuccess && expected != kIOReturnSuccess ? kOSBooleanTrue : kOSBooleanFalse));
            assert(result->getObject("Requested") == envelope.value && result->getObject("Actual") == actual);
            assert(envelope.value->references == 2 && envelope.property->references == 2 && envelope.requestID->references == 2);
            assert(result->getObject("Property") == envelope.property && result->getObject("RequestID") == envelope.requestID);
            if (actual) { assert(actual->references == 2); actual->release(); }
            input->release();
            assert(ReYogaProperty::get<OSString>(result, "Property")->getLength() == 8);
            assert(ReYogaProperty::get<OSNumber>(result, "Requested")->value == 4);
            result->release();
        }
    }
}
void testFailureCleanup() {
    // Each injection runs after request setup, so only result construction can fail.
    for (int fault = 0; fault < 10; ++fault) {
        for (IOReturn command : {kIOReturnSuccess, commandError}) {
            for (bool matched : {false, true}) {
                auto input = request();
                ControlEnvelope envelope;
                assert(parseControlEnvelope(input, envelope));
                auto actual = new OSNumber(matched ? 4 : 5, 32);
                const int liveBefore = OSObject::live;
                resetFaults();
                if (fault == 0) OSDictionary::failAllocation = true;
                else if (fault <= 2) OSNumber::failAllocation = fault;
                else {
                    const char *keys[] = {"RequestID", "Property", "Requested", "Actual", "Status", "CommandStatus", "ReadbackPending"};
                    OSDictionary::failKey = keys[fault - 3];
                }
                IOReturn status = 123;
                auto result = makeControlResult(envelope, actual, command, status);
                assert(!result);
                assert(status == (command != kIOReturnSuccess ? command : matched ? kIOReturnSuccess : kIOReturnIOError));
                assert(OSObject::live == liveBefore);
                assert(envelope.property->references == 1 && envelope.requestID->references == 1 && envelope.value->references == 1);
                assert(actual->references == 1 && kOSBooleanTrue->references == 1 && kOSBooleanFalse->references == 1);
                resetFaults();
                actual->release();
                input->release();
            }
        }
    }
    auto input = request();
    ControlEnvelope envelope;
    assert(parseControlEnvelope(input, envelope));
    OSDictionary::failAllocation = true;
    IOReturn status = kIOReturnSuccess;
    assert(!makeControlResult(envelope, nullptr, kIOReturnSuccess, status));
    assert(status == kIOReturnIOError);
    resetFaults();
    input->release();
}
int main() {
    const int baseline = OSObject::live;
    testParsing();
    assert(OSObject::live == baseline);
    testResults();
    assert(OSObject::live == baseline);
    testFailureCleanup();
    assert(OSObject::live == baseline);
    kOSBooleanTrue->release();
    kOSBooleanFalse->release();
    assert(OSObject::live == 0);
}
'''
        fixture = fixture.replace('// PROPERTY_HELPERS', helpers).replace('// CONTROL_FUNCTIONS', production)
        with tempfile.TemporaryDirectory() as folder:
            folder = pathlib.Path(folder)
            source = folder / 'control-request.cpp'
            source.write_text(fixture, encoding='utf-8')
            executable = folder / 'control-request.exe'
            sanitizers = ['-fsanitize=address,undefined', '-fno-omit-frame-pointer'] if sys.platform != 'win32' else []
            build = subprocess.run([shutil.which('g++') or shutil.which('clang++'), '-std=c++14',
                                    '-Wall', '-Wextra', '-Werror', *sanitizers, '-I', str(ROOT),
                                    str(source), '-o', str(executable)], capture_output=True, text=True, timeout=60)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
