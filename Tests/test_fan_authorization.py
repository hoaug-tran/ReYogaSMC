"""Exercise the production kernel delegation and fan guards without hardware."""
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


class FanAuthorizationTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('g++') or shutil.which('clang++'), 'C++ compiler required')
    def test_kernel_session_grant_and_fan_only_scope(self):
        source = (ROOT / 'ReYogaSMC/ReYogaSMCUserClient.cpp').read_text(encoding='utf-8')
        bodies = '\n'.join(function(source, 'IOReturn ReYogaSMCUserClient::' + name + '(') for name in
                           ('methodAuthorizeThinkFan', 'thinkFanGated', 'methodReadEC', 'closeGated'))
        harness = r'''
#include <cassert>
#include <cstdint>
#include <cstring>
#include "ControlValidation.hpp"
using UInt64 = uint64_t; using UInt32 = uint32_t; using UInt8 = uint8_t;
using IOByteCount = unsigned long; using IOReturn = int;
constexpr int kIOReturnSuccess=0, kIOReturnNotPermitted=-1, kIOReturnNotOpen=-2, kIOReturnBadArgument=-3;
constexpr unsigned kRYSMCMaxFanIndex=1, kRYSMCFanCurveFullSpeed=0x47, kRYSMCFanQueryRPM=0x100;
struct OSObject { virtual ~OSObject()=default; };
struct IOExternalMethodArguments {
    const void *structureInput=nullptr; unsigned structureInputSize=0;
    void *structureOutput=nullptr; IOByteCount structureOutputSize=0; UInt64 scalarInput[2]{};
};
class ReYogaSMCUserClient;
struct Provider {
    ReYogaSMCUserClient *client=nullptr; bool opened=true, stopping=false; int writes=0, reads=0;
    bool isOpen(ReYogaSMCUserClient *owner) { return opened && owner==client; }
    int accessThinkFan(UInt32, UInt32 request, UInt8 *) { if(request!=0x100) ++writes; else ++reads; return 0; }
    int accessThinkFanCurve(UInt32, UInt32, UInt8 *) { ++writes; return 0; }
    void restoreUserControls() {} void close(ReYogaSMCUserClient *) { opened=false; }
};
class ReYogaSMCUserClient : public OSObject {
public:
    bool administrator_=false, stopping_=false, inactive=false, ownerAuditTokenValid_=true, fanAuthorized_=false;
    uint32_t ownerAuditToken_[8]{1,2,3,4,5,6,7,8}; Provider *provider_=nullptr;
    bool isInactive() { return inactive; } void clearNotificationGated() {}
    IOReturn readECGated(UInt64, UInt8 *, IOByteCount *) { ++provider_->reads; return 0; }
    enum class FanRequestMode { Direct, Watchdog };
    static IOReturn methodAuthorizeThinkFan(OSObject *, void *, IOExternalMethodArguments *);
    static IOReturn methodReadEC(OSObject *, void *, IOExternalMethodArguments *);
    IOReturn thinkFanGated(UInt64, UInt64, UInt8 *, FanRequestMode);
    IOReturn closeGated();
};
// PRODUCTION
int main() {
    Provider provider; ReYogaSMCUserClient app, broker;
    app.provider_=&provider; broker.provider_=&provider; provider.client=&app;
    UInt8 reply[3]{}; using Mode=ReYogaSMCUserClient::FanRequestMode;
    assert(app.thinkFanGated(0,0x100,reply,Mode::Direct)==0 && provider.writes==0);
    for(unsigned mode : {4U,0x47U,0x84U}) assert(app.thinkFanGated(0,mode,reply,Mode::Direct)==kIOReturnNotPermitted);
    assert(app.thinkFanGated(0,4,reply,Mode::Watchdog)==kIOReturnNotPermitted);
    uint32_t audit[8]; memcpy(audit,app.ownerAuditToken_,sizeof(audit));
    IOExternalMethodArguments args; args.structureInput=audit; args.structureInputSize=sizeof(audit);
    assert(broker.methodAuthorizeThinkFan(&broker,nullptr,&args)==kIOReturnNotPermitted);
    broker.administrator_=true;
    for(unsigned index=0;index<8;++index) {
        audit[index]^=1;
        assert(broker.methodAuthorizeThinkFan(&broker,nullptr,&args)==kIOReturnNotPermitted && !app.fanAuthorized_);
        audit[index]^=1;
    }
    args.structureInputSize=sizeof(audit)-1;
    assert(broker.methodAuthorizeThinkFan(&broker,nullptr,&args)==kIOReturnNotPermitted);
    args.structureInputSize=sizeof(audit);
    app.ownerAuditTokenValid_=false;
    assert(broker.methodAuthorizeThinkFan(&broker,nullptr,&args)==kIOReturnNotPermitted);
    app.ownerAuditTokenValid_=true; app.stopping_=true;
    assert(broker.methodAuthorizeThinkFan(&broker,nullptr,&args)==kIOReturnNotPermitted);
    app.stopping_=false; app.inactive=true;
    assert(broker.methodAuthorizeThinkFan(&broker,nullptr,&args)==kIOReturnNotPermitted);
    app.inactive=false; provider.opened=false;
    assert(broker.methodAuthorizeThinkFan(&broker,nullptr,&args)==kIOReturnNotPermitted);
    provider.opened=true; provider.client=nullptr;
    assert(broker.methodAuthorizeThinkFan(&broker,nullptr,&args)==kIOReturnNotPermitted);
    provider.client=&app;
    assert(broker.methodAuthorizeThinkFan(&broker,nullptr,&args)==0 && app.fanAuthorized_);
    for(unsigned mode : {4U,0x47U,0x84U}) assert(app.thinkFanGated(0,mode,reply,Mode::Direct)==0);
    assert(app.thinkFanGated(0,4,reply,Mode::Watchdog)==0 && provider.writes==4);
    assert(app.thinkFanGated(2,4,reply,Mode::Direct)==kIOReturnBadArgument);
    assert(app.thinkFanGated(0,8,reply,Mode::Direct)==kIOReturnBadArgument);
    args.structureOutput=reply; args.structureOutputSize=1;
    assert(app.methodReadEC(&app,nullptr,&args)==kIOReturnNotPermitted);
    // Closing the temporary broker must not revoke or close the GUI's provider claim.
    assert(broker.closeGated()==0 && app.fanAuthorized_ && provider.opened);
    assert(app.closeGated()==0 && !app.fanAuthorized_);
    provider.opened=true;
    assert(app.thinkFanGated(0,4,reply,Mode::Direct)==kIOReturnNotPermitted);
}
'''
        harness = harness.replace('// PRODUCTION', bodies).replace('#include <cassert>', '#include <cassert>\n#include <initializer_list>')
        with tempfile.TemporaryDirectory() as folder:
            path = pathlib.Path(folder)
            (path / 'main.cpp').write_text(harness, encoding='utf-8')
            executable = path / ('authorization.exe' if sys.platform == 'win32' else 'authorization')
            build = subprocess.run([shutil.which('g++') or shutil.which('clang++'), '-std=c++14', '-Wall', '-Wextra', '-Werror', '-I',
                                    str(ROOT / 'ReYogaSMC'), str(path / 'main.cpp'), '-o', str(executable)],
                                   capture_output=True, text=True, timeout=60)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            run = subprocess.run([str(executable)], capture_output=True, text=True, timeout=10)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)

    @unittest.skipUnless(sys.platform == 'darwin', 'macOS XPC and Security frameworks required')
    def test_native_broker_and_client_compile(self):
        with tempfile.TemporaryDirectory() as folder:
            for source in ('main.m', 'FanAuthorizationClient.m'):
                result = subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-fblocks', '-Wall', '-Wextra', '-Werror',
                                         '-mmacosx-version-min=11.0', '-c', str(ROOT / 'ReYogaSMCFanHelper' / source),
                                         '-o', str(pathlib.Path(folder) / (source + '.o'))],
                                        capture_output=True, text=True, timeout=60)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            broker = pathlib.Path(folder) / 'broker'
            linked = subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-fblocks', '-Wall', '-Wextra', '-Werror',
                                     '-mmacosx-version-min=11.0', str(ROOT / 'ReYogaSMCFanHelper/main.m'),
                                     '-framework', 'Foundation', '-framework', 'Security', '-framework', 'IOKit',
                                     '-lbsm', '-o', str(broker)], capture_output=True, text=True, timeout=60)
            self.assertEqual(linked.returncode, 0, linked.stdout + linked.stderr)
            invalid = subprocess.run([str(broker)], capture_output=True, text=True, timeout=5)
            self.assertEqual(invalid.returncode, 1, 'Broker must reject missing root-owned configuration')

    @unittest.skipUnless(shutil.which('swiftc') and sys.platform in ('darwin', 'linux'), 'Swift on macOS/Linux required')
    def test_installer_quotes_shell_data(self):
        source = (ROOT / 'ReYogaSMCApp/System/FanAuthorization.swift').read_text(encoding='utf-8')
        quote = function(source, 'private static func shellQuote(')
        harness = r'''
import Foundation
enum InstallerQuoteTest {
    // PRODUCTION
    static func run() {
        for value in ["plain", "with spaces", "a'b", "\"; exit 9; #", "`id` $(id) $HOME", "line\none\n", "Tiếng Việt"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            // Process.arguments uses filesystem encoding on macOS; feed exact UTF-8 through stdin.
            let input = Pipe(); process.standardInput = input
            let pipe = Pipe(); process.standardOutput = pipe
            try! process.run()
            input.fileHandleForWriting.write(Data(("printf '%s' " + shellQuote(value) + "\n").utf8))
            try! input.fileHandleForWriting.close()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            precondition(process.terminationStatus == 0 && data == Data(value.utf8),
                         "Shell roundtrip failed for \(value.debugDescription): got \(Array(data)), expected \(Array(value.utf8))")
        }
    }
}
InstallerQuoteTest.run()
'''.replace('// PRODUCTION', quote)
        with tempfile.TemporaryDirectory() as folder:
            path = pathlib.Path(folder)
            (path / 'main.swift').write_text(harness, encoding='utf-8')
            executable = path / 'quote'
            build = subprocess.run(['swiftc', str(path / 'main.swift'), '-o', str(executable)],
                                   capture_output=True, text=True, timeout=60)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
