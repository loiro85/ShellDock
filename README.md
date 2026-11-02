# ShellDock

Cliente de terminal y herramientas remotas para macOS, inspirado en el flujo de trabajo de MobaXterm (aplicación original, sin código ni recursos de terceros).

Incluye: terminal local, SSH (con panel SFTP que reutiliza la conexión), SFTP/FTP/FTPS, Telnet, TCP crudo, puerto serie, visor VNC nativo, lanzador RDP, túneles SSH, snippets, MultiExec, escáner de puertos, Wake-on-LAN, gestor de claves, importador de sesiones `.mxtsessions` y un **Mini Linux** (Alpine en una VM con Virtualization.framework y carpeta compartida en `/mnt/mac`). Sin límite de sesiones.

## Compilar
    scripts/build_app.sh      # genera dist/ShellDock.app (firma ad-hoc con entitlement de virtualización)
    swift test                # 31 pruebas

## Limitaciones conocidas
- RDP se abre con «Windows App» / Microsoft Remote Desktop (no incrustado; requeriría FreeRDP).
- X11 requiere XQuartz.
- Mini Linux necesita el entitlement `com.apple.security.virtualization`; para distribuir hace falta firmar con Developer ID.
- Comprobar el nombre «ShellDock» (marca) antes de publicar.
