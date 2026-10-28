"""Run the production HP package decoder and bounded UTF-16 WMI conversion."""
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


class HPSensorSchemaTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('g++') or shutil.which('clang++'), 'C++ compiler required')
    def test_legacy_modern_raw_strings_and_boundaries(self):
        source = (ROOT / 'ReYogaSMC/SMC/DYSMC.cpp').read_text()
        methods = '\n'.join(function(source, signature) for signature in
            ('static OSString *sensorString(', 'static bool readNumericSensor('))
        fixture = r'''
#include <cassert>
#include <string>
#include <vector>
#include <cstdint>
#include "ReYogaSMC/ControlValidation.hpp"
using UInt32=uint32_t; using SInt32=int32_t;
#define OSDynamicCast(type,object) dynamic_cast<type*>(object)
struct OSObject { unsigned refs=1; virtual ~OSObject(){} void release(){if(!--refs)delete this;} void retain(){++refs;} };
struct OSNumber:OSObject { uint64_t n; OSNumber(uint64_t value):n(value){} uint64_t unsigned64BitValue(){return n;} unsigned unsigned32BitValue(){return n;} };
struct OSString:OSObject { std::string s; OSString(const char *value):s(value){} bool isEqualTo(const char *v){return s==v;}
static OSString *withCString(const char *v){return new OSString(v);} };
struct OSData:OSObject { std::vector<unsigned char> bytes; const void *getBytesNoCopy(){return bytes.data();} unsigned getLength(){return bytes.size();} };
struct OSArray { std::vector<OSObject*> objects; ~OSArray(){for(auto p:objects)p->release();}
unsigned getCount(){return objects.size();} OSObject *getObject(unsigned i){return i<objects.size()?objects[i]:nullptr;}
void replaceObject(unsigned i,OSObject *p){p->retain();objects[i]->release();objects[i]=p;} };
METHODS
OSObject *text(bool raw,const char *value){
    if(!raw)return new OSString(value);
    auto d=new OSData; std::string s=value; d->bytes={static_cast<unsigned char>(s.size()*2),0};
    for(unsigned char c:s){d->bytes.push_back(c);d->bytes.push_back(0);} return d;
}
void populate(OSArray &a,bool modern,bool raw,unsigned states){
    a.objects={text(raw,"CPU Temperature"),text(raw,"fixture"),new OSNumber(2),text(raw,""),new OSNumber(2)};
    if(modern)a.objects.push_back(new OSNumber(states));else a.objects.push_back(text(raw,"OK"));
    for(unsigned i=0;i<states;++i)a.objects.push_back(text(raw,"OK"));
    if(modern)a.objects.push_back(text(raw,"OK"));
    a.objects.push_back(new OSNumber(2));a.objects.push_back(new OSNumber(0xffffffff));a.objects.push_back(new OSNumber(425));
    if(modern)a.objects.push_back(new OSNumber(0));
}
int main(){
    for(bool modern:{false,true})for(bool raw:{false,true}){
        OSArray a;populate(a,modern,raw,1);UInt32 value=0,type=0;
        assert(readNumericSensor(&a,value,type)&&value==42500&&type==2);
        assert(sensorString(&a,0)->isEqualTo("CPU Temperature"));
        auto fault=new OSNumber(3);a.replaceObject(4,fault);fault->release();assert(!readNumericSensor(&a,value,type));
    }
    for(bool modern:{false,true}){OSArray a;populate(a,modern,false,0);UInt32 v=0,t=0;assert(!readNumericSensor(&a,v,t));}
    char decoded[16];
    unsigned char unicode[]={4,0,0x3d,0xd8,0,0xde};
    assert(ReYogaControl::decodeHPWMIString(unicode,sizeof unicode,decoded,sizeof decoded));
    assert(std::string(decoded)=="\xf0\x9f\x98\x80");
    assert(!ReYogaControl::decodeHPWMIString(unicode,sizeof unicode,decoded,4));
    unsigned char odd[]={3,0,65,0,66};assert(!ReYogaControl::decodeHPWMIString(odd,sizeof odd,decoded,sizeof decoded));
    unsigned char shortBuffer[]={8,0,65,0};assert(!ReYogaControl::decodeHPWMIString(shortBuffer,sizeof shortBuffer,decoded,sizeof decoded));
    unsigned char badSurrogate[]={2,0,0,0xd8};assert(!ReYogaControl::decodeHPWMIString(badSurrogate,sizeof badSurrogate,decoded,sizeof decoded));
    unsigned char embeddedNull[]={6,0,65,0,0,0,66,0};assert(!ReYogaControl::decodeHPWMIString(embeddedNull,sizeof embeddedNull,decoded,sizeof decoded));
}
'''.replace('METHODS', methods)
        with tempfile.TemporaryDirectory() as directory:
            cpp = pathlib.Path(directory) / 'hp.cpp'
            cpp.write_text(fixture)
            executable = cpp.with_suffix('.exe')
            sanitizers = ['-fsanitize=address,undefined', '-fno-omit-frame-pointer'] if sys.platform != 'win32' else []
            build = subprocess.run([shutil.which('g++') or shutil.which('clang++'), '-std=c++14', *sanitizers, '-I', str(ROOT),
                                    str(cpp), '-o', str(executable)], capture_output=True, text=True, timeout=60)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            run = subprocess.run([str(executable)], capture_output=True, text=True, timeout=10)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
