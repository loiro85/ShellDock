import socket, struct, sys, subprocess
# uso: rfbserver.py <puerto> <none|auth> ; imprime el puerto cuando está listo
mode = sys.argv[2]
srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", int(sys.argv[1]))); srv.listen(1); print("ready", flush=True)
c, _ = srv.accept()
def rd(n):
    b = b""
    while len(b) < n:
        d = c.recv(n - len(b))
        if not d: raise SystemExit
        b += d
    return b
c.sendall(b"RFB 003.008\n"); rd(12)
challenge = bytes(range(16))
if mode == "none":
    c.sendall(bytes([1, 1])); rd(1); c.sendall(struct.pack(">I", 0))
else:
    c.sendall(bytes([1, 2])); rd(1); c.sendall(challenge)
    resp = rd(16)
    key = bytes(int(f"{b:08b}"[::-1], 2) for b in b"secret".ljust(8, b"\0"))
    exp = subprocess.run(["openssl", "enc", "-des-ecb", "-nopad", "-K", key.hex()], input=challenge, capture_output=True).stdout
    if resp != exp:
        c.sendall(struct.pack(">I", 1) + struct.pack(">I", 6) + b"badpwd"); raise SystemExit
    c.sendall(struct.pack(">I", 0))
rd(1)
name = b"fake"
c.sendall(struct.pack(">HH", 64, 32) + bytes([32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0]) + struct.pack(">I", len(name)) + name)
while True:
    t = rd(1)[0]
    if t == 0: rd(19)
    elif t == 2:
        rd(1); n = struct.unpack('>H', rd(2))[0]; rd(4 * n)
    elif t == 3:
        rd(9)
        # Raw 4x2 rojo en (0,0); Hextile 64x32: fondo azul + subrect verde (2x2 en 10,5)
        out = bytes([0, 0]) + struct.pack(">H", 2)
        out += struct.pack(">HHHHi", 0, 0, 4, 2, 0) + b"\x00\x00\xff\x00" * 8
        tiles = b""
        for ty in range(0, 32, 16):
            for tx in range(0, 64, 16):
                if (tx, ty) == (0, 0):
                    tiles += bytes([2 | 4 | 8]) + b"\xff\x00\x00\x00" + b"\x00\xff\x00\x00" + bytes([1]) + bytes([(10 << 4) | 5, (1 << 4) | 1])
                else:
                    tiles += bytes([0])
        out += struct.pack(">HHHHi", 0, 0, 64, 32, 5) + tiles
        c.sendall(out)
        break
import time; time.sleep(3)
