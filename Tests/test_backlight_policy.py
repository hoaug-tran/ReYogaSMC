"""Run production backlight intent and keypress code with a deterministic timer."""
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest
try:
    from .source_tools import function, kernel_sources
except ImportError:
    from source_tools import function, kernel_sources

ROOT = pathlib.Path(__file__).resolve().parents[1]


class BacklightPolicyTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('g++') or shutil.which('clang++'), 'C++ compiler required')
    def test_explicit_off_idle_recovery_and_missing_timer(self):
        source = kernel_sources('ReYogaVPC')
        methods = '\n'.join(function(source, signature) for signature in (
            'void ReYogaVPC::rememberBacklight(', 'bool ReYogaVPC::setUserBacklight(',
            'void ReYogaVPC::backlightRest(', 'void ReYogaVPC::stimulateBacklight('))
        timeout_branch = function(source, 'else if (!strcmp(key, backlightTimeoutPrompt))')
        fixture = r'''#include <cassert>
#include <cstring>
using UInt32=unsigned; using UInt64=unsigned long long;
struct OSObject {virtual ~OSObject(){}}; constexpr int kSecondScale=1;
struct OSNumber:OSObject {UInt64 value;OSNumber(UInt64 v):value(v){} UInt64 unsigned64BitValue(){return value;} UInt32 unsigned32BitValue(){return value;}};
#define OSDynamicCast(type,object) dynamic_cast<type*>(object)
#define DebugLog(...) do {} while (0)
#define AlwaysLog(...) do {} while (0)
const char *backlightTimeoutPrompt="BacklightTimeout";
void clock_get_uptime(UInt64*) {}
struct IOTimerEventSource { unsigned scheduled=0; void cancelTimeout(){scheduled=0;}
void setTimeout(unsigned seconds,int){scheduled=seconds;} };
struct ReYogaVPC {
    unsigned backlightLevel=1,backlightLevelSaved=0,backlightTimeout=30;
    bool backlightCap=true,fail=false,backlightAutomaticOff=false,stopping=false;
    UInt64 backlightStimulation=0;
    IOTimerEventSource timer; IOTimerEventSource *backlightPoller=&timer;
    bool setBacklight(unsigned level){if(fail)return false;backlightLevel=level;return true;}
    void rememberBacklight(UInt32); bool setUserBacklight(UInt32);
    void backlightRest(OSObject*,IOTimerEventSource*);
    static constexpr unsigned maximumBacklightTimeoutSeconds=3600;
    void setProperty(const char*,unsigned,unsigned){}
    bool updateBacklight(){return true;}
    void timeoutValue(OSObject *rawValue){const char *key=backlightTimeoutPrompt;if(false){} TIMEOUT_BRANCH }
    void stimulateBacklight();
    void keyPressed(){stimulateBacklight();}
};
METHODS
int main(){
    ReYogaVPC d;
    assert(d.setUserBacklight(2)); assert(d.backlightLevelSaved==2 && d.timer.scheduled==30);
    d.backlightRest(nullptr,&d.timer); assert(d.backlightLevel==0 && d.backlightLevelSaved==2);
    d.rememberBacklight(0); assert(d.backlightLevelSaved==2);
    d.keyPressed(); assert(d.backlightLevel==2);
    assert(d.setUserBacklight(0)); d.keyPressed();
    assert(d.backlightLevel==0 && d.backlightLevelSaved==0 && d.timer.scheduled==0);
    d.backlightTimeout=0xffffffff; d.rememberBacklight(0); d.keyPressed(); assert(d.backlightLevel==0);
    d.backlightPoller=nullptr; d.backlightLevelSaved=1; d.keyPressed(); assert(d.backlightLevel==0);
    d.fail=true; assert(!d.setUserBacklight(2)); assert(d.backlightLevelSaved==1);
    assert(!d.setUserBacklight(3));
    d.fail=false;d.backlightPoller=&d.timer;d.stopping=true;d.keyPressed();assert(d.backlightLevel==0);
    d.stopping=false;d.backlightTimeout=30;
    for(UInt64 invalid:{3601ULL,0xffffffffULL,0x100000000ULL}){
        OSNumber n(invalid);d.timeoutValue(&n);assert(d.backlightTimeout==30);
    }
    OSNumber valid(3600);d.timeoutValue(&valid);assert(d.backlightTimeout==3600);
    OSNumber disabled(0);d.timeoutValue(&disabled);assert(d.backlightTimeout==0&&d.timer.scheduled==0);
}
'''.replace('METHODS', methods).replace('TIMEOUT_BRANCH', timeout_branch).replace('#include <cstring>', '#include <cstring>\n#include <initializer_list>')
        with tempfile.TemporaryDirectory() as directory:
            cpp = pathlib.Path(directory) / 'backlight.cpp'
            cpp.write_text(fixture)
            executable = cpp.with_suffix('.exe')
            sanitizers = ['-fsanitize=address,undefined', '-fno-omit-frame-pointer'] if sys.platform != 'win32' else []
            build = subprocess.run([shutil.which('g++') or shutil.which('clang++'), '-std=c++14', *sanitizers,
                                    str(cpp), '-o', str(executable)], capture_output=True, text=True, timeout=60)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            run = subprocess.run([str(executable)], capture_output=True, text=True, timeout=10)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
