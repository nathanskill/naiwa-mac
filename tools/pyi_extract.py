# 只解析 PyInstaller 归档，不执行任何内容
import sys, struct, zlib, os, marshal
exe, out = sys.argv[1], sys.argv[2]
data = open(exe, 'rb').read()
MAGIC = b'MEI\x0c\x0b\x0a\x0b\x0e'
pos = data.rfind(MAGIC)
# cookie: magic(8) len(4) toc(4) toclen(4) pyver(4) pylib(64)
magic, pkglen, tocoff, toclen, pyver = struct.unpack('!8sIIII', data[pos:pos+24])
pylib = data[pos+24:pos+88].split(b'\0')[0]
tail = len(data) - (pos + 88)
start = len(data) - pkglen - tail if False else pos + 88 - pkglen
print('pyver', pyver, pylib, 'pkg start', start)
toc = data[start+tocoff:start+tocoff+toclen]
i = 0; entries = []
while i < len(toc):
    elen, eoff, clen, ulen, cflag, typ = struct.unpack('!IIIIBc', toc[i:i+18])
    name = toc[i+18:i+elen].rstrip(b'\0').decode('utf-8', 'replace')
    i += elen
    entries.append((name, eoff, clen, ulen, cflag, typ.decode()))
os.makedirs(out, exist_ok=True)
for name, eoff, clen, ulen, cflag, typ in entries:
    blob = data[start+eoff:start+eoff+clen]
    if cflag: blob = zlib.decompress(blob)
    safe = name.replace('..', '__').lstrip('/\\')
    if typ == 's': safe += '.pyc_body'
    p = os.path.join(out, safe)
    os.makedirs(os.path.dirname(p) or out, exist_ok=True)
    open(p, 'wb').write(blob)
    print(typ, ulen, name)
