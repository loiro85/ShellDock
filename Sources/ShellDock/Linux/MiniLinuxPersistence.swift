import Foundation

/// Persistencia del Mini Linux. Alpine arranca en modo "diskless" (todo en memoria): para que lo instalado y lo configurado
/// sobreviva se usa una carpeta del Mac compartida como `/persist`:
///  - `state.tar`  copia de /etc, /root y /home (se guarda cada minuto, tras cada `apk` y al cerrar);
///  - `cache/`     paquetes descargados por apk (se reinstalan al arrancar sin volver a descargarlos).
enum MiniLinuxPersistence {
    static var folder: URL { Paths.vmDir.appendingPathComponent("persist", isDirectory: true) }
    static let scriptName = ".shelldock-init.sh"

    static func prepare() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = folder.appendingPathComponent(scriptName)
        try initScript.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Borra todo lo instalado y configurado (vuelve a un Alpine recién descargado).
    static func reset() throws {
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
    }

    static var sizeOnDisk: Int64 {
        guard let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        return e.compactMap { ($0 as? URL).flatMap { try? $0.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize } }.reduce(0) { $0 + Int64($1) }
    }

    /// Línea que se envía a la consola tras iniciar sesión: monta las carpetas y ejecuta el script de arranque.
    static func setupLine(cols: Int, rows: Int) -> String {
        "stty -echo; export TERM=xterm-256color LANG=C.UTF-8; stty cols \(cols) rows \(rows); hostname shelldock-linux; "
        + "modprobe virtiofs 2>/dev/null; mkdir -p /mnt/mac /persist; mount -t virtiofs mac /mnt/mac 2>/dev/null; "
        + "mount -t virtiofs persist /persist 2>/dev/null && . /persist/\(scriptName); "
        + "alias ll='ls -la'; PS1='\\[\\e[1;32m\\]\\u@shelldock-linux\\[\\e[0m\\]:\\[\\e[1;34m\\]\\w\\[\\e[0m\\]# '; "
        + "stty echo; clear; echo \"Alpine Linux $(cat /etc/alpine-release) · $(uname -m) · " + tr("Mac en /mnt/mac · «apk add <paquete>» instala y se conserva") + "\""
    }

    static var initScript: String { """
    # ShellDock Mini Linux: red, repositorios y estado persistente (generado por la app; no lo edites)
    P=/persist
    echo "\(tr("· red…"))"
    ip link set eth0 up
    udhcpc -i eth0 -q -n -t 5 >/dev/null 2>&1
    if [ -f $P/state.tar ]; then
      echo "\(tr("· restaurando tu configuración y archivos…"))"
      tar xf $P/state.tar -C / 2>/dev/null
    fi
    V=$(cut -d. -f1,2 /etc/alpine-release)
    printf '%s\\n' /media/vda/apks "https://dl-cdn.alpinelinux.org/alpine/v$V/main" "https://dl-cdn.alpinelinux.org/alpine/v$V/community" > /etc/apk/repositories
    mkdir -p $P/cache && ln -sfn $P/cache /etc/apk/cache
    cat > /usr/local/bin/shelldock-save <<'SAVE'
    #!/bin/sh
    P=/persist; M=/tmp/.sd-saved
    [ -d $P ] || exit 0
    if [ -f $M ] && [ -z "$(find /etc /root /home -newer $M -print 2>/dev/null | head -n1)" ]; then exit 0; fi
    # la marca se atrasa 3 s para no perder archivos creados en el mismo segundo que el guardado anterior
    touch -t "$(date -d "@$(( $(date +%s) - 3 ))" +%Y%m%d%H%M.%S)" $M.new 2>/dev/null || touch $M.new
    tar cf $P/state.tar.tmp --exclude=etc/resolv.conf -C / etc root home 2>/dev/null && mv $P/state.tar.tmp $P/state.tar && mv $M.new $M
    sync
    SAVE
    mkdir -p /usr/local/sbin
    cat > /usr/local/sbin/apk <<'WRAP'
    #!/bin/sh
    /sbin/apk "$@"; rc=$?
    case "$1" in add|del|upgrade|fix) /usr/local/bin/shelldock-save >/dev/null 2>&1 ;; esac
    exit $rc
    WRAP
    chmod +x /usr/local/bin/shelldock-save /usr/local/sbin/apk
    if grep -qvE '^(alpine-base|alpine-baselayout|busybox|alpine-keys|apk-tools|openrc|musl-utils)$' /etc/apk/world 2>/dev/null && [ -n "$(ls $P/cache 2>/dev/null)" ]; then
      echo "\(tr("· reinstalando tus paquetes…"))"
      /sbin/apk update -q >/dev/null 2>&1
      /sbin/apk fix -q 2>&1 | tail -n 3
    fi
    mkdir -p /etc/crontabs
    echo '* * * * * /usr/local/bin/shelldock-save' > /etc/crontabs/root
    crond -b 2>/dev/null
    /usr/local/bin/shelldock-save
    """ }
}
