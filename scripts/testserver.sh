#!/usr/bin/env bash
# Servidor SSH de pruebas en 127.0.0.1:2222 (sin privilegios, solo para el usuario actual).
# Uso: scripts/testserver.sh start|stop|status
set -euo pipefail
D=/tmp/sd-test
case "${1:-start}" in
  start)
    mkdir -p "$D"; chmod 700 "$D"
    [ -f "$D/host_ed25519" ] || ssh-keygen -q -t ed25519 -N '' -f "$D/host_ed25519"
    [ -f "$D/client_ed25519" ] || ssh-keygen -q -t ed25519 -N '' -f "$D/client_ed25519" -C shelldock-test
    cp "$D/client_ed25519.pub" "$D/authorized_keys"; chmod 600 "$D/authorized_keys"
    cat > "$D/sshd_config" <<CFG
Port 2222
ListenAddress 127.0.0.1
HostKey $D/host_ed25519
AuthorizedKeysFile $D/authorized_keys
PidFile $D/sshd.pid
UsePAM no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
StrictModes no
PermitTTY yes
AllowTcpForwarding yes
GatewayPorts no
Subsystem sftp /usr/libexec/sftp-server
LogLevel ERROR
CFG
    if [ -f "$D/sshd.pid" ] && kill -0 "$(cat "$D/sshd.pid")" 2>/dev/null; then echo "ya en marcha"; exit 0; fi
    nohup /usr/sbin/sshd -D -f "$D/sshd_config" -E "$D/sshd.log" >/dev/null 2>&1 &
    sleep 1
    echo "sshd de pruebas en 127.0.0.1:2222 · clave: $D/client_ed25519 · usuario: $(whoami)"
    ;;
  stop)
    [ -f "$D/sshd.pid" ] && kill "$(cat "$D/sshd.pid")" 2>/dev/null || true
    rm -f "$D/sshd.pid"; echo parado ;;
  status)
    if [ -f "$D/sshd.pid" ] && kill -0 "$(cat "$D/sshd.pid")" 2>/dev/null; then echo activo; else echo parado; fi ;;
esac
