#!/usr/bin/env python3
"""Servidor FTP mínimo (solo para pruebas): raíz = argv[2], puerto = argv[1]. Usuario test / clave secreta."""
import os, socket, sys, threading, time, stat

PORT, ROOT = int(sys.argv[1]), os.path.realpath(sys.argv[2])
USER, PASS = "test", "secreta"

def listing(path):
    out = []
    for n in sorted(os.listdir(path)):
        st = os.lstat(os.path.join(path, n))
        d = "d" if stat.S_ISDIR(st.st_mode) else "-"
        perm = stat.filemode(st.st_mode)[1:]
        t = time.strftime("%b %e %H:%M", time.localtime(st.st_mtime))
        out.append(f"{d}{perm} 1 user group {st.st_size:>10} {t} {n}")
    return ("\r\n".join(out) + "\r\n").encode()

def handle(c):
    f = c.makefile("rwb", buffering=0)
    def send(s): f.write((s + "\r\n").encode())
    def real(p):
        full = os.path.realpath(os.path.join(ROOT, p.lstrip("/")))
        return full if full.startswith(ROOT) else ROOT
    send("220 test ftp")
    cwd, auth, user, rnfr, pasv = "/", False, "", None, None
    def data_conn():
        s, _ = pasv.accept(); return s
    while True:
        line = f.readline()
        if not line: break
        cmd, _, arg = line.decode(errors="replace").rstrip("\r\n").partition(" ")
        cmd = cmd.upper()
        if cmd == "USER": user = arg; send("331 clave?")
        elif cmd == "PASS":
            if user == USER and arg == PASS: auth = True; send("230 hola")
            else: send("530 login incorrecto")
        elif not auth and cmd not in ("QUIT", "FEAT", "SYST", "OPTS", "AUTH"): send("530 haz login")
        elif cmd == "SYST": send("215 UNIX Type: L8")
        elif cmd == "FEAT": send("211-Features:\r\n SIZE\r\n211 End")
        elif cmd == "OPTS": send("200 ok")
        elif cmd == "AUTH": send("534 sin TLS")
        elif cmd == "PWD": send(f'257 "{cwd}"')
        elif cmd == "TYPE": send("200 ok")
        elif cmd == "CWD":
            p = arg if arg.startswith("/") else os.path.join(cwd, arg)
            if os.path.isdir(real(p)): cwd = os.path.normpath(p); send("250 ok")
            else: send("550 no existe")
        elif cmd == "CDUP": cwd = os.path.dirname(cwd) or "/"; send("250 ok")
        elif cmd in ("PASV", "EPSV"):
            if pasv: pasv.close()
            pasv = socket.socket(); pasv.bind(("127.0.0.1", 0)); pasv.listen(1)
            p = pasv.getsockname()[1]
            send(f"227 Entering Passive Mode (127,0,0,1,{p >> 8},{p & 255})" if cmd == "PASV" else f"229 Entering Extended Passive Mode (|||{p}|)")
        elif cmd in ("LIST", "NLST"):
            target = arg.split()[-1] if arg and not arg.startswith("-") else ""
            p = real(os.path.join(cwd, target))
            if not os.path.isdir(p): send("550 no existe"); continue
            send("150 listando"); d = data_conn(); d.sendall(listing(p)); d.close(); send("226 hecho")
        elif cmd == "RETR":
            p = real(os.path.join(cwd, arg))
            if not os.path.isfile(p): send("550 no existe"); continue
            send("150 enviando"); d = data_conn()
            with open(p, "rb") as fh:
                while True:
                    b = fh.read(65536)
                    if not b: break
                    d.sendall(b)
            d.close(); send("226 hecho")
        elif cmd == "STOR":
            p = real(os.path.join(cwd, arg))
            send("150 recibiendo"); d = data_conn()
            with open(p, "wb") as fh:
                while True:
                    b = d.recv(65536)
                    if not b: break
                    fh.write(b)
            d.close(); send("226 hecho")
        elif cmd == "SIZE":
            p = real(os.path.join(cwd, arg)); send(f"213 {os.path.getsize(p)}" if os.path.isfile(p) else "550 no existe")
        elif cmd == "MKD":
            try: os.mkdir(real(os.path.join(cwd, arg))); send(f'257 "{arg}" creado')
            except Exception as e: send(f"550 {e}")
        elif cmd == "RMD":
            try: os.rmdir(real(os.path.join(cwd, arg))); send("250 ok")
            except Exception as e: send(f"550 {e}")
        elif cmd == "DELE":
            try: os.remove(real(os.path.join(cwd, arg))); send("250 ok")
            except Exception as e: send(f"550 {e}")
        elif cmd == "RNFR": rnfr = real(os.path.join(cwd, arg)); send("350 listo")
        elif cmd == "RNTO":
            try: os.rename(rnfr, real(os.path.join(cwd, arg))); send("250 ok")
            except Exception as e: send(f"550 {e}")
        elif cmd == "SITE":
            parts = arg.split()
            if len(parts) >= 3 and parts[0].upper() == "CHMOD":
                try: os.chmod(real(os.path.join(cwd, parts[2])), int(parts[1], 8)); send("200 ok")
                except Exception as e: send(f"550 {e}")
            else: send("500 no")
        elif cmd == "QUIT": send("221 adiós"); break
        else: send("502 no implementado")
    c.close()

s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("127.0.0.1", PORT)); s.listen(5)
print("READY", flush=True)
while True:
    c, _ = s.accept()
    threading.Thread(target=handle, args=(c,), daemon=True).start()
