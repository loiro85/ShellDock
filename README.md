# ShellDock

Cliente de terminal y herramientas remotas para macOS, inspirado en el flujo de trabajo de MobaXterm (aplicación original, sin código ni recursos de terceros).

Incluye:
- **Sesiones:** terminal local, SSH (con panel SFTP que reutiliza la conexión y salto por bastión), SFTP/FTP/FTPS, Telnet, Rlogin, TCP crudo, puerto serie, Mosh (si está instalado), VNC nativo, RDP (lanzador), Navegador web y **Mini Linux** (Alpine en una VM, carpeta compartida en `/mnt/mac`). Sin límite de sesiones; importador de `.mxtsessions`.
- **Interfaz tipo MobaXterm:** cinta con iconos y texto, árbol de sesiones, pestañas con «+», panel de archivos con arrastrar y soltar, editor de texto integrado, barra de monitorización remota (CPU, memoria, disco, uptime).
- **MultiExec:** muestra todas las terminales en cuadrícula; lo que se teclea va a todas, con casilla *Exclude* en cada una. **Dividir** muestra las terminales a la vez sin MultiExec.
- **Productividad:** macros (grabar y reproducir), snippets con variables y pausas, túneles SSH, resaltado de palabras clave (Telnet/TCP/serie), contraseña maestra opcional.
- **Herramientas:** escáner de puertos, ping/traceroute/DNS/whois, Wake-on-LAN, claves SSH, generador de contraseñas, hashes, Base64/URL/Hex, calculadora de subredes, fecha Unix, servidor HTTP de archivos.

## Instalar
    scripts/make_installer.sh --universal   # genera dist/ShellDock-<versión>.dmg y .pkg
Abre el `.dmg` y arrastra ShellDock a Aplicaciones, o ejecuta el `.pkg`. Sin Developer ID, en otros Macs: clic derecho → Abrir la primera vez.

## Compilar
    scripts/build_app.sh      # genera dist/ShellDock.app (firma ad-hoc con entitlement de virtualización)
    swift test                # 73 pruebas

## Limitaciones conocidas
- El resaltado de palabras clave aún no se aplica a SSH ni a la terminal local (SwiftTerm no permite interceptar su salida).
- Sin servidor X11 propio (usa XQuartz), sin XDMCP, sin gestor de paquetes MobApt (en Mini Linux se usa `apk`).
- RDP se abre con «Windows App» / Microsoft Remote Desktop (no incrustado; requeriría FreeRDP).
- X11 requiere XQuartz.
- Mini Linux necesita el entitlement `com.apple.security.virtualization`; para distribuir hace falta firmar con Developer ID.
- Comprobar el nombre «ShellDock» (marca) antes de publicar.

Idiomas: English (predeterminado), Español, Français, Italiano, Deutsch y Português; se cambia en Ajustes → Apariencia → Idioma y se aplica al momento (los menús del sistema, al reiniciar). Para añadir uno, crea `tools/translations/` con la nueva columna y ejecuta `tools/i18n_build.py`.

Documentos: `docs/PLAN.md`, `docs/MOBAXTERM_PARITY.md` (estado real frente a MobaXterm), `docs/SECURITY.md`.
