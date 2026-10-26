import struct, sys, os

def read_cstr(f):
    b = bytearray()
    while True:
        c = f.read(1)
        if not c or c == b'\0':
            break
        b += c
    return b.decode('utf-8', 'replace')

def parse(path):
    f = open(path, 'rb')
    assert f.read(4) == b'GMAD'
    ver = f.read(1)[0]
    steamid, ts = struct.unpack('<QQ', f.read(16))
    if ver > 1:
        while read_cstr(f):
            pass
    name = read_cstr(f); desc = read_cstr(f); author = read_cstr(f)
    aver = struct.unpack('<i', f.read(4))[0]
    files = []
    while True:
        num = struct.unpack('<I', f.read(4))[0]
        if num == 0:
            break
        fname = read_cstr(f)
        size, crc = struct.unpack('<qI', f.read(12))
        files.append((fname, size, crc))
    base = f.tell()
    out = []
    off = base
    for fname, size, crc in files:
        out.append((fname, size, off))
        off += size
    return f, name, desc, out

if __name__ == '__main__':
    cmd = sys.argv[1]
    f, name, desc, files = parse(sys.argv[2])
    if cmd == 'list':
        print('NAME:', name)
        print('DESC:', desc[:500])
        for fn, sz, off in files:
            print(f'{sz:12d} {fn}')
    elif cmd == 'extract':
        dst = sys.argv[3]
        for fn, sz, off in files:
            p = os.path.join(dst, fn)
            os.makedirs(os.path.dirname(p), exist_ok=True)
            f.seek(off)
            with open(p, 'wb') as o:
                remaining = sz
                while remaining > 0:
                    chunk = f.read(min(remaining, 1 << 20))
                    o.write(chunk)
                    remaining -= len(chunk)
        print('extracted', len(files))
