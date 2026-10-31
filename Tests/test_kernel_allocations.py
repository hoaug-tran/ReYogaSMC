"""Fault-inject production WMI, ownership and notifier paths without kernel I/O."""
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


class KernelAllocationTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('g++') or shutil.which('clang++'), 'C++ compiler required')
    def test_allocation_pairing_notifier_and_init_ownership(self):
        wmi = (ROOT / 'ReYogaSMC/WMI.cpp').read_text()
        base = (ROOT / 'ReYogaSMC/ReYogaBaseService.cpp').read_text()
        smc = (ROOT / 'ReYogaSMC/ReYogaSMC.cpp').read_text()
        probe = function((ROOT / 'ReYogaSMC/ReYogaVPC.cpp').read_text(), 'void ReYogaVPC::probeWMI(')
        pair = probe.split('DebugLog("WMI available at %s", dev->getName());', 1)[1].split('wmi->release();', 1)[0] + 'wmi->release();'
        methods = '\n'.join([
            function(wmi, signature) for signature in ('void le_uuid_dec(', 'bool WMI::parseWDGEntry(',
                'bool WMI::enableEvent(', 'bool WMI::getEventData(')])
        methods += '\n' + '\n'.join((function(base, 'void ReYogaBaseService::free('),
            function(smc, 'void ReYogaSMC::stop('), function(smc, 'bool ReYogaSMC::vsmcNotificationHandler(')))
        fixture = r'''
#include <atomic>
#include <cassert>
#include <cstdio>
#include <cstring>
#include <map>
#include <string>
#include <vector>
using UInt8=unsigned char; using UInt32=unsigned; using IOReturn=int; using uuid_t=unsigned char[16];
constexpr int kIOReturnSuccess=0,kIOReturnUnsupported=1;
#define AlwaysLog(...) do{}while(0)
#define DebugLog(...) do{}while(0)
#define DBGLOG(...) do{}while(0)
#define SYSLOG(...) do{}while(0)
#define OSDynamicCast(type,object) dynamic_cast<type*>(object)
#define OSSafeReleaseNULL(p) do{if(p){(p)->release();(p)=nullptr;}}while(0)
using std::atomic_exchange_explicit;using std::memory_order_acq_rel;
bool failDictionary=false,failNumber=false,failString=false;int live=0,acpiCalls=0,removed=0,baseFrees=0;
struct OSObject { unsigned refs=1;OSObject(){++live;}virtual ~OSObject(){--live;}void retain(){++refs;}void release(){if(!--refs)delete this;} };
using OSMetaClassBase=OSObject;
struct OSNumber:OSObject { static OSNumber *withNumber(unsigned,unsigned){return failNumber?nullptr:new OSNumber;} };
struct OSString:OSObject {};
struct OSDictionary:OSObject {
    std::map<std::string,OSObject*> values;
    static OSDictionary *withCapacity(unsigned){return failDictionary?nullptr:new OSDictionary;}
    bool setObject(const char *name,OSObject *p){assert(p);p->retain();if(values.count(name))values[name]->release();values[name]=p;return true;}
    ~OSDictionary(){for(auto &v:values)v.second->release();}
};
namespace ReYogaProperty {
bool setString(OSDictionary *d,const char *key,const char*){if(failString)return false;auto p=new OSString;bool ok=d->setObject(key,p);p->release();return ok;}
bool setNumber(OSDictionary *d,const char *key,unsigned,unsigned bits){auto p=OSNumber::withNumber(0,bits);if(!p)return false;bool ok=d->setObject(key,p);p->release();return ok;}
}
OSString *parseWMIFlags(UInt8){return failString?nullptr:new OSString;}
void uuid_unparse_lower(uuid_t,char *out){strcpy(out,"guid");}
constexpr unsigned ACPI_WMI_EVENT=8;
const char *kWMIGuid="guid",*kWMINotifyId="notify",*kWMIObjectId="object",*kWMIInstanceCount="count",*kWMIFlags="flags",*kWMIFlagsText="text",*ACPINotifyName="_WED";
struct WMI_DATA {uuid_t guid;union{char object_id[2];unsigned char notify_id;};unsigned char instance_count,flags;};
struct IOService:OSObject { int evaluateObject(const char*,OSObject**,OSObject **p,unsigned){assert(p[0]);++acpiCalls;return 0;}
int callPlatformFunction(const char*,bool,void*,void*,void*,void*){return 0;} };
struct WMI {
    OSDictionary data,events;OSDictionary *mData=&data,*mEvent=&events;IOService device;IOService *mDevice=&device;
    bool parseWDGEntry(WMI_DATA*);bool enableEvent(const char*,bool);bool getEventData(UInt32,OSObject**);
    bool executeMethod(const char*,OSObject**,OSObject **p,unsigned){assert(p[0]);++acpiCalls;return true;}
};
struct OrderedSet { bool fail=false;std::vector<OSObject*> values;
bool setObject(OSObject *p){if(fail)return false;p->retain();values.push_back(p);return true;}
void removeObject(OSObject *p){for(auto i=values.begin();i!=values.end();++i)if(*i==p){p->release();values.erase(i);break;}}
~OrderedSet(){for(auto p:values)p->release();} };
struct Pairing {OrderedSet services,providers;OrderedSet *WMICollection=&services,*WMIProvCollection=&providers;
void insert(OSObject *wmi,OSObject *dev){ PAIR } };
struct Base:OSObject {void free(){++baseFrees;}void stop(IOService*){} };
struct Resource:OSObject {void removeEventSource(Resource*){} };
struct ReYogaBaseService:Base {using super=Base;Resource *workLoop=nullptr,*commandGate=nullptr;
OSObject *_notificationServices=nullptr,*_deliverNotification=nullptr;void free();};
struct Notifier { void remove(){++removed;} };
struct Timer:OSObject {void cancelTimeout(){}void disable(){} };
struct Loop {void removeEventSource(Timer*){} };
struct Gate {OSObject *owner;template<class F>void runAction(F f){f(owner,nullptr,nullptr,nullptr,nullptr);} };
namespace VirtualSMCAPI {struct Plugin {};const char *SubmitPlugin="submit";}
struct ReYogaSMC:ReYogaBaseService {using super=ReYogaBaseService;bool awake=true,ready=true;
Notifier *vsmcNotifier=nullptr;Timer *poller=nullptr;Loop loop;Loop *workLoop=&loop;Gate gate{this};Gate *commandGate=&gate;
std::atomic<bool> pluginSubmitted{false};VirtualSMCAPI::Plugin vsmcPlugin;
void terminate(){}void stop(IOService*);static bool vsmcNotificationHandler(void*,void*,IOService*,Notifier*);};
using IONotifier=Notifier;
METHODS
int main(){
    for(int failure=0;failure<4;++failure){
        int before=live;
        {WMI w;WMI_DATA b{};b.flags=ACPI_WMI_EVENT;failDictionary=failure==0;failString=failure==1;failNumber=failure==2;
        assert(w.parseWDGEntry(&b)==(failure==3));failDictionary=failString=failNumber=false;}
        assert(live==before);
    }
    {WMI w;failNumber=true;OSObject *output=reinterpret_cast<OSObject*>(1);int calls=acpiCalls;
     assert(!w.enableEvent("fixture",true));assert(!w.getEventData(1,&output));assert(output==nullptr&&calls==acpiCalls);
     failNumber=false;assert(w.enableEvent("fixture",true));assert(w.getEventData(1,&output));}
    for(int failure=0;failure<3;++failure){int before=live;{
        Pairing p;p.services.fail=failure==0;p.providers.fail=failure==1;auto dev=new OSObject;
        p.insert(new OSObject,dev);dev->release();
        assert(p.services.values.size()==p.providers.values.size());assert(p.services.values.size()==(failure==2?1:0));
    }assert(live==before);}
    {ReYogaBaseService b;b._notificationServices=new OSObject;b._deliverNotification=new OSObject;b.free();assert(!b._notificationServices&&!b._deliverNotification);}
    {auto smc=new ReYogaSMC;IOService provider;Notifier notifier;smc->poller=new Timer;smc->vsmcNotifier=&notifier;
     assert(ReYogaSMC::vsmcNotificationHandler(smc,nullptr,&provider,&notifier));
     assert(ReYogaSMC::vsmcNotificationHandler(smc,nullptr,&provider,&notifier));assert(smc->refs==2);
     smc->stop(&provider);assert(removed==1&&!smc->awake&&!smc->ready&&!smc->poller&&!smc->vsmcNotifier);
     smc->release();smc->release();}
    assert(live==0);
    unsigned char unaligned[17];for(unsigned i=0;i<17;++i)unaligned[i]=i;
    uuid_t decoded;le_uuid_dec(reinterpret_cast<uuid_t*>(unaligned+1),&decoded);
    assert(decoded[0]==4&&decoded[3]==1&&decoded[4]==6&&decoded[5]==5&&decoded[15]==16);
}
'''.replace('METHODS', methods).replace('PAIR', pair)
        with tempfile.TemporaryDirectory() as directory:
            cpp = pathlib.Path(directory) / 'kernel.cpp'
            cpp.write_text(fixture)
            executable = cpp.with_suffix('.exe')
            sanitizers = ['-fsanitize=address,undefined', '-fno-omit-frame-pointer'] if sys.platform != 'win32' else []
            build = subprocess.run([shutil.which('g++') or shutil.which('clang++'), '-std=c++14', *sanitizers, str(cpp),
                                    '-o', str(executable)], capture_output=True, text=True, timeout=60)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            run = subprocess.run([str(executable)], capture_output=True, text=True, timeout=10)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
