# ShellDock — plan de requisitos y arquitectura

Cliente de terminal y administración remota **nativo para macOS** (Apple Silicon e Intel), con las mismas
funcionalidades que ofrece MobaXterm y **sin límites** de sesiones, pestañas ni tareas.
Nombre provisional "ShellDock"; es una aplicación **original** (no usa código, nombre, marca ni recursos de MobaXterm).

## 1. Qué hace MobaXterm y cómo se resuelve en macOS

| # | Función de MobaXterm | Equivalente en ShellDock | Cómo | Viabilidad |
|---|---|---|---|---|
| 1 | Pestañas de sesiones, sin límite en la versión de pago | Pestañas + paneles divididos, sin límites | SwiftUI/AppKit | Alta |
| 2 | Gestor de sesiones (carpetas, iconos, búsqueda) | Igual, **sin límite**; importa/exporta `.mxtsessions` y JSON | JSON en Application Support | Alta |
| 3 | Contraseñas guardadas | Llavero de macOS (Keychain) | Security.framework | Alta |
| 4 | SSH (claves, agente, salto, X11, compresión, keepalive) | OpenSSH del sistema en un pty (todas sus opciones) | `/usr/bin/ssh` + SwiftTerm | Alta |
| 5 | Navegador SFTP lateral junto a la sesión SSH | Panel lateral con subir/bajar/arrastrar/editar/permisos | `sftp` sobre ControlMaster | Alta |
| 6 | Telnet, Rlogin, Raw TCP | Telnet y TCP crudo nativos | Network.framework | Alta |
| 7 | Puerto serie | Terminal serie (baudios, bits, paridad, control de flujo) | termios | Alta |
| 8 | FTP / FTPS | Cliente FTP en el mismo panel de ficheros | `curl` / URLSession | Media |
| 9 | VNC | Visor VNC integrado (protocolo RFB propio) | Swift | Media |
| 10 | RDP | Lanzar con cliente RDP del sistema; integrado con FreeRDP en fase posterior | Proceso externo / FreeRDP | Media-Baja |
| 11 | Servidor X11 integrado | Integración con XQuartz (detección, `DISPLAY`, instalación guiada) | XQuartz | Media |
| 12 | Terminal local con "mini Linux" (Cygwin) y sus utilidades | Terminal local + **caja de herramientas GNU/Unix propia** en el PATH + **mini Linux (Alpine) en una máquina virtual interna** | Virtualization.framework | Media |
| 13 | Túneles SSH (gestor gráfico) | Gestor de túneles local/remoto/dinámico, arranque/parada | `ssh -L/-R/-D` | Alta |
| 14 | MultiExec (teclear en varias sesiones) | Difusión de teclado a pestañas elegidas | SwiftTerm | Alta |
| 15 | Macros y "snippets" | Biblioteca de snippets y macros con variables | JSON | Alta |
| 16 | Resaltado de sintaxis y temas | Temas de color, fuentes, resaltado de palabras clave | SwiftTerm | Alta |
| 17 | Logs de sesión y grabación | Registro a fichero y búsqueda en el scrollback | FileHandle | Alta |
| 18 | Herramientas de red (ping, escáner de puertos, traceroute…) | Panel de herramientas de red | `Network`/procesos | Alta |
| 19 | Gestor de claves SSH | Generar/importar/copiar clave pública a servidores | `ssh-keygen`, `ssh-copy-id` | Alta |
| 20 | Editor de texto remoto | Editor integrado + abrir en editor externo y subir al guardar | SwiftUI | Media |
| 21 | Sincronización y exportación de configuración | Exportar/importar todo en un fichero | JSON | Alta |

### El "mini Linux interno"
En MobaXterm es un Cygwin con ~cientos de comandos para tener un entorno Unix en Windows. En macOS ya hay Unix, pero:

1. **Caja de herramientas propia (siempre disponible):** carpeta dentro de la app con utilidades GNU/Linux estáticas
   (busybox, coreutils, grep, sed, awk, find, tar, rsync, curl, nano…) añadida al `PATH` del terminal local, de modo que
   los scripts se comporten como en Linux aunque la Mac no tenga Homebrew.
2. **Mini Linux real en una VM interna:** Alpine Linux arrancado con `Virtualization.framework` (arm64/x86_64 según el Mac),
   con consola integrada en una pestaña, carpeta compartida con macOS y red NAT. Sirve para ejecutar scripts Bash/POSIX
   exactamente como en Linux. Todo dentro de la app (imagen incluida o descargada al primer uso y cacheada).

## 2. Requisitos técnicos

- **Plataforma:** macOS 13+ (probado en macOS 27, Xcode 27.2, Swift 6.4). Binario universal si es posible.
- **Lenguaje/UI:** Swift + SwiftUI con piezas AppKit. Proyecto **Swift Package** (sin editor gráfico) + script que arma el `.app`.
- **Emulador de terminal:** [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (MIT): xterm/VT, 256 colores/truecolor, ratón, sixel, pty local.
- **Seguridad:** contraseñas en Keychain; entitlements de red, ficheros, USB/serie y virtualización; firma ad-hoc local (Developer ID para distribuir).
- **Dependencias del sistema:** `/usr/bin/ssh`, `sftp`, `ssh-keygen`; XQuartz opcional (X11).
- **Sin límites:** no hay contadores ni restricciones de sesiones, carpetas, túneles, macros ni pestañas.

## 3. Arquitectura

```
Package.swift
Sources/ShellDock/
  App/            ShellDockApp, AppState, ventanas, menús, ajustes
  Model/          Session, SessionFolder, Tunnel, Snippet, Theme, Store (JSON)
  Terminal/       TerminalHost (SwiftTerm), SSHSession, LocalSession, TelnetSession, SerialSession, TCPSession
  Files/          SFTPClient (sftp batch + ControlMaster), FileBrowser UI, FTPClient
  Remote/         VNC (RFB), RDP launcher, X11 (XQuartz)
  Tools/          Túneles, MultiExec, Snippets, Red, Claves SSH
  Linux/          Toolbox (PATH), MiniLinuxVM (Virtualization.framework)
  UI/             Barra lateral, pestañas, ajustes, diálogos
Tests/            XCTest: modelo, parseo de `ls`, importador mxtsessions, Telnet, túneles
scripts/          build_app.sh (empaqueta .app + firma), snapshot, tests
```

## 4. Hitos (en orden, cada uno con criterios de aceptación)

| Hito | Contenido | Aceptación |
|---|---|---|
| M0 | Paquete, `.app`, ventana con barra lateral y pestañas, terminal local | La app abre y ejecuta `zsh` en una pestaña; test de arranque |
| M1 | Gestor de sesiones ilimitado, carpetas, búsqueda, Keychain, importar `.mxtsessions`, exportar/importar | Crear 1.000 sesiones sin límite; test de modelo e importador |
| M2 | SSH completo (claves, contraseña desde Keychain, salto, X11, reconexión) | Conexión real a un servidor SSH local de pruebas |
| M3 | Panel SFTP: listar, navegar, subir, bajar, arrastrar, borrar, renombrar, mkdir, chmod, editar | Operaciones reales contra el servidor de pruebas; test de parseo |
| M4 | Telnet, TCP crudo, serie | Telnet contra un servidor de pruebas local; test de IAC |
| M5 | Túneles, MultiExec, snippets/macros, temas, log, búsqueda, herramientas de red, gestor de claves | Pruebas por función |
| M6 | VNC integrado, lanzador RDP, integración XQuartz/X11, FTP | Visor VNC contra servidor de pruebas; detección XQuartz |
| M7 | Caja de herramientas GNU + mini Linux (Alpine VM) | `uname -a` en la VM desde una pestaña |
| M8 | Pulido: iconos, ajustes, atajos, documentación, empaquetado `.dmg` | Checklist completa |

## 5. Pruebas y servidor de pruebas

- Un `sshd` de pruebas local en puerto no privilegiado (`/usr/sbin/sshd -p 2222` con claves y usuario propios) para verificar
  SSH, SFTP, túneles y X11 sin tocar el sistema; servidor Telnet y TCP mínimos en Python para probar los clientes.
- `XCTest` para lógica pura; capturas de ventana (`--snapshot`) para revisar la interfaz sin intervención manual.

## 6. Riesgos y decisiones

- **RDP integrado** requiere compilar FreeRDP: se deja como fase posterior; mientras tanto se lanza el cliente RDP instalado.
- **X11**: macOS no incluye servidor X; se usa XQuartz (software libre) con instalación guiada.
- **Mini Linux (VM)**: necesita el entitlement `com.apple.security.virtualization`; la imagen Alpine se cachea en Application Support.
- **No se reutiliza nada de MobaXterm** (código, nombre, iconos, textos): la app replica las **funciones**, no el producto. Comprobar el nombre final antes de publicar.
