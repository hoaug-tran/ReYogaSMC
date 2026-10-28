"""Replay production lease entry and expiry methods with a controllable clock/EC."""
import pathlib
import shutil
import subprocess
import tempfile
import unittest
try:
    from .source_tools import kernel_sources, function
except ImportError:
    from source_tools import kernel_sources, function

ROOT = pathlib.Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which('g++') or shutil.which('clang++'), 'C++ compiler required')
class CurveWatchdogTests(unittest.TestCase):
    def test_expiry_failure_retry_and_independent_fans(self):
        production = kernel_sources('ThinkVPC')
        bodies = []
        for signature in ('IOReturn ThinkVPC::accessPlatformFanCurve(', 'void ThinkVPC::expireThinkFanCurve('):
            bodies.append(function(production, signature))
        base = kernel_sources('ReYogaVPC')
        bodies.extend(function(base, signature) for signature in (
            'IOReturn ReYogaVPC::accessThinkFanCurve(', 'IOReturn ReYogaVPC::accessPlatformFanCurve('))
        fixture = r'''
#include "ReYogaSMC/ControlValidation.hpp"
#include <cassert>
#include <cstring>
using UInt32 = unsigned; using UInt8 = unsigned char; using IOReturn = int;
constexpr int kIOReturnSuccess=0, kIOReturnBadArgument=1, kIOReturnUnsupported=2, kIOReturnNotReady=3;
constexpr int kIOReturnNotAttached=4;
void *const kOSBooleanTrue = reinterpret_cast<void *>(1);
struct OSObject {};
struct IOTimerEventSource { unsigned arms=0; void setTimeoutMS(unsigned) { ++arms; } };
struct Gate {
    OSObject *owner;
    using Action = IOReturn (*)(OSObject *, void *, void *, void *, void *);
    IOReturn runAction(Action action, void *context=nullptr) { return action(owner, context, nullptr, nullptr, nullptr); }
};
static unsigned long long nowMS=0;
static unsigned long long thinkFanTimeMS() { return nowMS; }
struct ReYogaVPC {
    IOReturn accessThinkFanCurve(UInt32, UInt32, UInt8 *);
    virtual IOReturn accessPlatformFanCurve(UInt32, UInt32, UInt8 *);
};
struct ThinkVPC : OSObject {
    IOTimerEventSource timer; IOTimerEventSource *thinkFanWatchdog=&timer;
    Gate gate{this}; Gate *commandGate=&gate;
    ReYogaControl::ThinkFanLease thinkFanLease;
    bool safe=false, dual=true, inactive=false, fail=false, think=true, stopping=false;
    unsigned levels[2]{0x84,0x84}, writes=0, warnings=0;
    void *metaCast(const char *) { return think ? this : nullptr; }
    void *getProperty(const char *key) {
        return (!strcmp(key,"SafeMode") ? safe : dual) ? kOSBooleanTrue : nullptr;
    }
    bool isInactive() { return inactive; }
    void setProperty(const char *, const char *) { ++warnings; }
    IOReturn accessThinkFanGated(unsigned fan, unsigned target, UInt8 *) {
        ++writes; levels[fan]=target; return fail ? kIOReturnNotReady : kIOReturnSuccess;
    }
    IOReturn accessPlatformFanCurve(UInt32, UInt32, UInt8 *);
    void expireThinkFanCurve(OSObject *, IOTimerEventSource *);
};
// PRODUCTION
int main() {
    UInt8 output[3]{}; ThinkVPC device;
    device.stopping=true;
    assert(device.accessPlatformFanCurve(0,7,output)==kIOReturnNotAttached && device.writes==0);
    device.expireThinkFanCurve(nullptr,nullptr);assert(device.writes==0 && device.timer.arms==0);
    device.stopping=false;
    assert(device.accessPlatformFanCurve(0,0,output)==kIOReturnBadArgument && device.writes==0);
    const unsigned invalidLevels[] {8U, 0x40U, 0x80U, 0x84U, 0x100U};
    for (auto level : invalidLevels)
        assert(device.accessPlatformFanCurve(0,level,output)==kIOReturnBadArgument && device.writes==0);
    assert(device.accessPlatformFanCurve(2,7,output)==kIOReturnBadArgument && device.writes==0);
    assert(device.accessPlatformFanCurve(0,7,nullptr)==kIOReturnBadArgument && device.writes==0);
    ReYogaVPC unsupported;
    assert(unsupported.accessThinkFanCurve(0,4,output)==kIOReturnUnsupported);
    device.thinkFanWatchdog=nullptr;
    assert(device.accessPlatformFanCurve(0,4,output)==kIOReturnUnsupported && device.writes==0);
    device.thinkFanWatchdog=&device.timer; device.inactive=true;
    assert(device.accessPlatformFanCurve(0,4,output)==kIOReturnNotReady && device.writes==0);
    device.inactive=false;
    device.safe=true;
    assert(device.accessPlatformFanCurve(0,4,output)==kIOReturnUnsupported && device.writes==0);
    device.safe=false; device.dual=false;
    assert(device.accessPlatformFanCurve(1,4,output)==kIOReturnUnsupported && device.writes==0);
    device.dual=true;
    assert(device.accessPlatformFanCurve(0,4,output)==0);
    assert(device.timer.arms==1);
    nowMS=1000; assert(device.accessPlatformFanCurve(1,7,output)==0);
    assert(device.timer.arms==1); // Renewals must not postpone the watchdog's tick.
    nowMS=6000; device.fail=true;
    device.expireThinkFanCurve(nullptr,nullptr);
    assert(device.thinkFanLease.expired(0,nowMS) && device.warnings==1);
    assert(device.levels[1]==7);
    device.fail=false; nowMS=6100;
    device.expireThinkFanCurve(nullptr,nullptr);
    assert(device.levels[0]==0x84 && device.thinkFanLease.deadline[0]==0);
    assert(device.thinkFanLease.deadline[1]!=0);
    nowMS=7000; device.expireThinkFanCurve(nullptr,nullptr);
    assert(device.levels[1]==0x84 && !device.thinkFanLease.active());
    device.fail=true; nowMS=8000;
    assert(device.accessPlatformFanCurve(0,7,output)!=0 && device.thinkFanLease.active());
    device.fail=false; nowMS=14000; device.expireThinkFanCurve(nullptr,nullptr);
    assert(device.levels[0]==0x84 && !device.thinkFanLease.active());
}
'''.replace('// PRODUCTION', '\n'.join(bodies))
        with tempfile.TemporaryDirectory() as directory:
            source = pathlib.Path(directory) / 'watchdog.cpp'
            source.write_text(fixture, encoding='utf-8')
            executable = pathlib.Path(directory) / 'watchdog.exe'
            result = subprocess.run([shutil.which('g++') or shutil.which('clang++'), '-std=c++14',
                                     '-Wall', '-Wextra', '-Werror', '-I', str(ROOT), str(source),
                                     '-o', str(executable)], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
