"""Execute production EC selection with real/fake and ambiguous ACPI namespaces."""
import pathlib
import shutil
import subprocess
import tempfile
import unittest
try:
    from .source_tools import function
except ImportError:
    from source_tools import function

ROOT = pathlib.Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which('g++') or shutil.which('clang++'), 'C++ compiler required')
class ECSelectionTests(unittest.TestCase):
    def test_parent_priority_unique_fallback_and_ambiguity(self):
        source = (ROOT / 'ReYogaSMC/ReYogaBaseService.cpp').read_text(encoding='utf-8')
        method = function(source, 'bool ReYogaBaseService::findPNP(')
        fixture = r'''
#include <cassert>
#include <cstring>
#include <vector>
#define DebugLog(...) ((void)0)
#define AlwaysLog(...) ((void)0)
#define OSDynamicCast(type, value) dynamic_cast<type *>(value)
struct OSObject { virtual ~OSObject() = default; };
struct OSString {
 const char *value;
 static OSString *withCString(const char *value) { return new OSString{value}; }
 void release() { delete this; }
};
struct IOACPIPlatformDevice : OSObject {
 const char *name, *hid;
 IOACPIPlatformDevice(const char *name, const char *hid) : name(name), hid(hid) {}
 bool compareName(OSString *id, void *) { return !strcmp(id->value,hid); }
 const char *getName() { return name; }
};
static int gIOACPIPlane=0, kIORegistryIterateRecursively=1;
static std::vector<IOACPIPlatformDevice *> devices;
struct IORegistryIterator {
 unsigned index=0;
 static IORegistryIterator *iterateOver(int,int) { return new IORegistryIterator; }
 IOACPIPlatformDevice *getNextObject() { return index < devices.size() ? devices[index++] : nullptr; }
 void release() { delete this; }
};
struct ReYogaBaseService { bool findPNP(const char *, IOACPIPlatformDevice **); };
// IMPLEMENTATION
int main() {
 ReYogaBaseService service;
 IOACPIPlatformDevice fake("EC","ACID0001"), real("EC0","PNP0C09"), other("H_EC","PNP0C09");
 IOACPIPlatformDevice *selected=&real;
 devices={&fake,&other,&real};
 assert(service.findPNP("PNP0C09",&selected) && selected==&real);
 selected=nullptr; devices={&fake,&real};
 assert(service.findPNP("PNP0C09",&selected) && selected==&real);
 selected=&fake; devices={&fake,&real,&other};
 assert(!service.findPNP("PNP0C09",&selected) && !selected);
 selected=nullptr; devices={&fake};
 assert(!service.findPNP("PNP0C09",&selected) && !selected);
 assert(!service.findPNP(nullptr,&selected));
 assert(!service.findPNP("PNP0C09",nullptr));
}
'''.replace('// IMPLEMENTATION', method)
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / 'selection.cpp'
            path.write_text(fixture, encoding='utf-8')
            executable = pathlib.Path(directory) / 'selection.exe'
            result = subprocess.run([shutil.which('g++') or shutil.which('clang++'), '-std=c++14',
                                     '-Wall', '-Wextra', '-Werror', str(path), '-o', str(executable)],
                                    capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
