# Paridad con MobaXterm

Estado real, tras revisar la lista oficial de funciones de MobaXterm (mobaxterm.mobatek.net/features.html).
✅ implementado y verificado · 🟡 parcial o sin verificar del todo · ❌ no implementado

## Sesiones
| Función | Estado | Cómo se verificó |
|---|---|---|
| SSH (clave y contraseña) | ✅ | App real contra sshd local (clave) y servidor paramiko (contraseña con «ñ», Llavero→askpass) |
| SFTP (panel + pestaña propia) | ✅ | Pruebas automáticas (subida/descarga 250 KB idénticas, chmod, rename, recursivo) y app real |
| FTP / FTPS | ✅ | Servidor FTP de prueba (ida y vuelta, contraseña errónea). FTPS no probado contra un servidor TLS real |
| Telnet, TCP crudo, Rlogin | ✅ | Servidores falsos (negociación IAC, saludo rlogin) |
| Serie | ✅ | Par de pty; sin hardware real |
| VNC | ✅ | Servidor RFB falso (sin contraseña, VNC-auth verificado con OpenSSL, Hextile/Raw); no probado con un VNC real |
| RDP | 🟡 | Genera `.rdp` y abre Windows App/Remote Desktop (no incrustado, requeriría FreeRDP). No probado con el cliente instalado |
| Mosh | 🟡 | Argumentos probados; `mosh` no está instalado aquí |
| Navegador web | 🟡 | Compila y solo admite http(s); sin prueba automática |
| Terminal local | ✅ | App real |
| Mini Linux (Alpine) | ✅ | Arranca en ~1 s, red, repos online, `apk add` y estado persistente verificados con VM reiniciada |
| XDMCP, AWS S3, sesión «File» | ❌ | |

## Terminal y productividad
| Función | Estado | Notas |
|---|---|---|
| Pestañas, «+», renombrar, color, duplicar, reconectar | ✅ | |
| Dividir (cuadrícula) | ✅ | |
| MultiExec con «Exclude» | ✅ | Probado con eventos de teclado reales; teclear en cualquier terminal se replica |
| Macros (grabar/reproducir) y snippets | ✅ | Grabación probada por pruebas unitarias del texto; el reproductor, en uso real |
| Resaltado de palabras clave | 🟡 | Solo Telnet/TCP/serie (SwiftTerm no deja filtrar la salida del pty local/SSH) |
| Buscar en la terminal (⌘F) | 🟡 | Enlazado a la barra integrada de SwiftTerm; no verificado visualmente |
| Registro de sesiones a archivo | ✅ | Permisos 0600 |
| Contraseña maestra | ✅ | PBKDF2-SHA256 (200 000 vueltas); bloquea la interfaz, no cifra archivos |
| Seguir la carpeta del terminal en el panel SFTP | ❌ | |
| Desacoplar pestaña a ventana, atajos personalizables, ZMODEM | ❌ | |

## SSH
| Función | Estado |
|---|---|
| Panel de archivos que reutiliza la conexión (ControlMaster) | ✅ |
| Salto por bastión (ProxyJump) | ✅ (validación probada; sin servidor intermedio real) |
| Túneles locales/remotos/dinámicos | ✅ (túnel real contra sshd de prueba) |
| X11 forwarding | 🟡 requiere XQuartz (no hay servidor X propio) |
| Agente, compresión, keepalive, comando de inicio | ✅ |
| Monitorización remota (CPU, RAM, disco, uptime) | ✅ |
| Editor de texto integrado para archivos remotos | ✅ |
| Gestor de claves SSH | ✅ |

## Herramientas y servidores
| Función | Estado |
|---|---|
| Escáner de puertos y de red, ping, traceroute, DNS, whois, WoL | ✅ |
| Hashes, Base64/URL/Hex, contraseñas, subred, fecha Unix | ✅ |
| Servidor HTTP de archivos | ✅ (solo local por defecto) |
| Servidores FTP/TFTP/SSH embebidos, captura de paquetes, diff de carpetas | ❌ |
| Gestor de paquetes MobApt | 🟡 equivalente: `apk` en el Mini Linux |
