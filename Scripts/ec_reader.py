"""Bounded snapshots of the standard ACPI EC address space."""
import ctypes
import datetime
import hashlib
import json
import pathlib
import platform
import re
import struct
import time
import urllib.request


def read_byte(read_port, write_port, offset, timeout=0.05):
    if not 0 <= offset < 256:
        raise ValueError('EC offset must fit in one byte')
    def wait(mask, expected):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            status = read_port(0x66)
            if status & mask == expected:
                return
            time.sleep(0.001)
        raise TimeoutError('EC status timeout')
    # A pending response belongs to another transaction; never consume it.
    wait(3, 0)
    write_port(0x66, 0x80)
    wait(2, 0)
    write_port(0x62, offset)
    wait(3, 1)
    return read_port(0x62)


class PawnEC:
    def __init__(self, module):
        from ctypes import wintypes as w
        self.api = ctypes.WinDLL('kernel32', use_last_error=True)
        self.handle = self.mutex = None
        self.locked = False
        signatures = {
            'CreateFileW': ([w.LPCWSTR, w.DWORD, w.DWORD, w.LPVOID, w.DWORD, w.DWORD, w.HANDLE], w.HANDLE),
            'CreateMutexW': ([w.LPVOID, w.BOOL, w.LPCWSTR], w.HANDLE),
            'WaitForSingleObject': ([w.HANDLE, w.DWORD], w.DWORD),
            'ReleaseMutex': ([w.HANDLE], w.BOOL),
            'CloseHandle': ([w.HANDLE], w.BOOL),
            'DeviceIoControl': ([w.HANDLE, w.DWORD, w.LPVOID, w.DWORD, w.LPVOID, w.DWORD, ctypes.POINTER(w.DWORD), w.LPVOID], w.BOOL),
        }
        for name, (arguments, result) in signatures.items():
            fn = getattr(self.api, name); fn.argtypes = arguments; fn.restype = result
        try:
            self.handle = self.api.CreateFileW(r'\\?\GLOBALROOT\Device\PawnIO', 3, 3, None, 3, 0x80, None)
            if self.handle == ctypes.c_void_p(-1).value:
                self.handle = None
                raise ctypes.WinError(ctypes.get_last_error())
            self.mutex = self.api.CreateMutexW(None, False, r'Global\Access_EC')
            if not self.mutex:
                raise ctypes.WinError(ctypes.get_last_error())
            state = self.api.WaitForSingleObject(self.mutex, 1000)
            self.locked = state in (0, 0x80)
            if state != 0:
                raise RuntimeError('EC mutex unavailable or abandoned; snapshot cancelled')
            self.ioctl(0x821, module, 0)
        except Exception:
            self.close(); raise

    def ioctl(self, code, data, count):
        source = ctypes.create_string_buffer(data)
        target = ctypes.create_string_buffer(max(count, 1))
        size = ctypes.c_ulong(0)
        ok = self.api.DeviceIoControl(self.handle, (41394 << 16) | (code << 2), source, len(data), target, count, ctypes.byref(size), None)
        if not ok:
            raise ctypes.WinError(ctypes.get_last_error())
        if size.value != count:
            raise IOError('PawnIO returned an unexpected response size')
        return target.raw[:count]

    def execute(self, name, values, count):
        request = name.encode('ascii').ljust(32, b'\0') + struct.pack('<' + 'q' * len(values), *values)
        return self.ioctl(0x841, request, count)

    def read_port(self, port):
        return struct.unpack('<q', self.execute('ioctl_pio_read', [port], 8))[0]

    def write_port(self, port, value):
        # Only the READ command and its address are sent; no EC register writes.
        self.execute('ioctl_pio_write', [port, value], 0)

    def close(self):
        if self.locked:
            self.api.ReleaseMutex(self.mutex); self.locked = False
        for name in ('mutex', 'handle'):
            value = getattr(self, name, None)
            if value:
                self.api.CloseHandle(value); setattr(self, name, None)


def module_binary(offline):
    item = json.loads(pathlib.Path(__file__).with_name('pawnio.json').read_text())
    path = pathlib.Path.home() / '.cache' / 'reyoga' / 'pawnio' / (item['sha256'] + '.bin')
    if not path.exists():
        if offline:
            raise FileNotFoundError('Pinned PawnIO module is not cached; offline mode prevents download')
        with urllib.request.urlopen(item['url'], timeout=30) as response:
            data = response.read(1024 * 1024)
        if hashlib.sha256(data).hexdigest() != item['sha256']:
            raise ValueError('PawnIO module checksum mismatch')
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    data = path.read_bytes()
    if hashlib.sha256(data).hexdigest() != item['sha256']:
        raise ValueError('Cached PawnIO module checksum mismatch')
    return data


def collect(output, source, enabled=False, offline=False):
    result = {'status': 'not_requested', 'address_space': 'ACPI EmbeddedControl', 'length': 256,
              'scope': 'Unbanked EC bytes only; excludes SystemMemory, indexed and vendor banked regions',
              'timestamp_utc': datetime.datetime.now(datetime.timezone.utc).isoformat()}
    if not enabled:
        result['reason'] = 'Use --ec-read to request a live snapshot on Windows or Linux'
        return result
    backend = None
    try:
        if platform.system() == 'Linux':
            result['backend'] = 'Linux ec_sys'
            paths = sorted(pathlib.Path('/sys/kernel/debug/ec').glob('ec*/io'))
            if not paths:
                raise FileNotFoundError('No ec_sys interface. Load ec_sys with write_support=0 and mount debugfs, then run with read permission')
            result['controllers'] = []
            for index, path in enumerate(paths):
                with path.open('rb', buffering=0) as handle:
                    data = handle.read(256)
                if len(data) != 256:
                    raise IOError(f'{path}: expected 256 bytes, received {len(data)}')
                name = f'ec-{index}.bin'; (output / name).write_bytes(data)
                result['controllers'].append({'source': str(path), 'file': name, 'sha256': hashlib.sha256(data).hexdigest(), 'bytes': list(data)})
        elif platform.system() == 'Windows':
            result['backend'] = 'PawnIO LpcACPIEC'
            if 'PNP0C09' not in source or not all(re.search(r'0x0*' + x + r'\b', source, re.I) for x in ('62', '66')):
                raise ValueError('A complete disassembled ACPI EC declaration with ports 0x62/0x66 is required for this backend')
            backend = PawnEC(module_binary(offline))
            values = []; failures = []
            for offset in range(256):
                try:
                    value = read_byte(backend.read_port, backend.write_port, offset)
                    if not 0 <= value <= 255:
                        raise ValueError('EC response is not a byte')
                    values.append(value)
                except (OSError, ValueError) as error:
                    failures.append({'offset': offset, 'reason': str(error)})
                    values.extend([None] * (256 - offset))
                    break  # Do not continue after an uncertain controller transaction.
            controller = {'bytes': values, 'failures': failures}
            if not failures:
                data = bytes(values); name = 'ec-0.bin'; (output / name).write_bytes(data)
                controller.update(file=name, sha256=hashlib.sha256(data).hexdigest())
            result['controllers'] = [controller]
            result['status'] = 'partial' if failures else 'collected'
        else:
            result.update(status='unsupported', reason='Live EC collection uses Windows PawnIO or Linux ec_sys')
            return result
        if result['status'] == 'not_requested':
            result['status'] = 'collected'
    except (OSError, ValueError, RuntimeError) as error:
        result.update(status='unavailable', reason=str(error))
    finally:
        if backend:
            backend.close()
    return result
