"""Replay the kernel's bounded table export without executing firmware methods."""
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which('g++') or shutil.which('clang++'), 'C++ compiler required')
class ACPICaptureTests(unittest.TestCase):
    def test_capture_limits_safe_mode_and_cleanup(self):
        source = (ROOT / 'ReYogaSMC/ReYogaVPC.cpp').read_text(encoding='utf-8')
        start = source.index('    if (auto requested = OSDynamicCast(OSBoolean, dict->getObject("ExportACPITables")))')
        body = source[start:source.index('    if (auto requested = OSDynamicCast(OSBoolean, dict->getObject("ExportDSDT")))', start)]
        fixture = r'''
#include "ReYogaSMC/ControlValidation.hpp"
#include <cassert>
#include <map>
#include <string>
#include <vector>
#define OSDynamicCast(type, value) dynamic_cast<type *>(value)
#define OSSafeReleaseNULL(value) ((value)=nullptr)
#define AlwaysLog(...) ((void)0)
using UInt32=unsigned;
constexpr int kIOReturnSuccess=0, kIOReturnNotReady=1;
struct OSObject { virtual ~OSObject()=default; };
struct OSBoolean : OSObject { bool value; explicit OSBoolean(bool v):value(v){} bool getValue(){return value;} };
OSBoolean yes(true),no(false); OSObject *kOSBooleanTrue=&yes,*kOSBooleanFalse=&no;
struct OSData : OSObject { unsigned length=36; unsigned getLength() const{return length;} };
struct OSDictionary : OSObject {
 std::map<std::string,OSObject *> values;
 static OSDictionary *withCapacity(unsigned){static OSDictionary result;result.values.clear();return &result;}
 OSObject *getObject(const char *key){return values[key];}
 void setObject(const char *key,OSObject *value){values[key]=value;}
};
struct OSArray : OSObject {
 std::vector<OSObject *> values;
 static OSArray *withCapacity(unsigned){static OSArray result;result.values.clear();return &result;}
 bool setObject(OSObject *value){values.push_back(value);return true;}
 unsigned getCount(){return values.size();}
};
static void setPropertyNumber(OSDictionary *,const char *,unsigned,unsigned){}
struct Device {
 std::vector<OSData> tables; unsigned validations=0;
 const OSData *getACPITableData(const char *signature,unsigned index){
  unsigned position=std::string(signature)=="DSDT"?0:index+1;
  return position<tables.size()?&tables[position]:nullptr;
 }
 int validateObject(const char *){++validations;return 0;}
};
struct ReYogaVPC {
 Device device; Device *vpc=&device,*ec=&device; OSDictionary properties;
 bool think=true; unsigned status=99;
 ReYogaVPC(){properties.values["ACPIECPath"]=&yes;properties.values["ACPIHKEYPath"]=&yes;device.tables.resize(3);}
 void *metaCast(const char *){return think?this:nullptr;}
 OSObject *getProperty(const char *key){return properties.getObject(key);}
 void removeProperty(const char *key){properties.values.erase(key);}
 void setProperty(const char *key,OSObject *value){properties.values[key]=value;}
 void setProperty(const char *,UInt32 value,unsigned){status=value;}
 void exportTables(OSDictionary *dict){
 // PRODUCTION
 }
};
int main(){
 OSDictionary request;request.values["ExportACPITables"]=&yes;
 ReYogaVPC driver;driver.exportTables(&request);
 assert(driver.status==0 && driver.device.validations==5);
 auto tables=dynamic_cast<OSArray *>(driver.getProperty("ExportedACPITables"));
 assert(tables && tables->getCount()==3);
 request.values["ExportACPITables"]=&no;driver.exportTables(&request);
 assert(!driver.getProperty("ExportedACPITables") && !driver.getProperty("ThinkPadACPIEvidence"));
 request.values["ExportACPITables"]=&yes;
 for(unsigned failure=0;failure<7;++failure){
  ReYogaVPC invalid;
  if(failure==0)invalid.properties.values["SafeMode"]=&yes;
  if(failure==1)invalid.think=false;
  if(failure==2)invalid.device.tables.clear();
  if(failure==3)invalid.device.tables[0].length=35;
  if(failure==4)invalid.device.tables.resize(257);
  if(failure==5){invalid.device.tables.resize(17);for(auto &table:invalid.device.tables)table.length=1024*1024;}
  if(failure==6)invalid.properties.values.erase("ACPIECPath");
  invalid.exportTables(&request);
  assert(invalid.status!=0 && !invalid.getProperty("ExportedACPITables"));
  assert(invalid.device.validations==0);
 }
}
'''.replace('// PRODUCTION', body)
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / 'capture.cpp'
            path.write_text(fixture, encoding='utf-8')
            executable = pathlib.Path(directory) / 'capture.exe'
            build = subprocess.run([shutil.which('g++') or shutil.which('clang++'), '-std=c++14',
                                    '-Wall', '-Wextra', '-Werror', '-I', str(ROOT), str(path), '-o', str(executable)],
                                   capture_output=True, text=True, timeout=30)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
