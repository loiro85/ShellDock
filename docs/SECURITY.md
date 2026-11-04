# Seguridad

## Revisión realizada (noviembre 2026)
Corregido:
- **Inyección de opciones en ssh**: un host o usuario que empezara por `-` (p. ej. `-oProxyCommand=…`) se interpretaba como opción de `ssh` y podía ejecutar un comando local. Era alcanzable desde enlaces `ssh://`, sesiones importadas y archivos `.mxtsessions`. Ahora se validan host, usuario y salto, y toda invocación de ssh lleva `--` antes del host.
- **Sesiones importadas**: se descartan los argumentos extra de ssh y las carpetas compartidas con la VM.
- **Enlaces ssh:// y telnet://** de otras apps: piden confirmación antes de conectar.
- **Servidores maliciosos (SFTP/FTP)**: los nombres con `/`, `..` o saltos de línea se descartan (evita escribir fuera de la carpeta de descarga) y las rutas con CR/LF no llegan a órdenes FTP (inyección de comandos).
- **RDP**: los campos se limpian de saltos de línea (no se pueden añadir opciones al `.rdp`).
- **Datos en disco**: `sessions.json` y los logs, `0600`; directorios de logs y temporales de edición, `0700`.
- **Socket de ControlMaster en /tmp**: se comprueba que el directorio es del usuario y no un enlace (evita secuestro por otro usuario local); si no, se crea uno nuevo con `mkdtemp`.
- **Askpass**: además del token, solo atiende a procesos del mismo usuario (`getpeereid`).
- **Llavero**: elementos `WhenUnlockedThisDeviceOnly`.
- **Binario**: *hardened runtime* y un único entitlement (`virtualization`); se retiraron `disable-library-validation` y `usb`.
- **Imagen de Alpine**: se verifica su SHA-256 fijado en el código (ARM e Intel) al descargarla y en cada uso.
- **Servidor HTTP**: por defecto solo escucha en 127.0.0.1; exponerlo a la red es una opción explícita.
- **Opciones de desarrollo** (`--demo`, `--probe`, `--snapshot`, `--open`, `--vm-selftest`): solo con `SHELLDOCK_DEV=1`.
- **Pérdida de datos**: `sessions.json` ilegible ya no se sobrescribe (se guarda copia) y los campos nuevos no invalidan archivos antiguos.

## Límites conocidos
- La firma es ad-hoc: macOS mostrará el aviso de Gatekeeper en otros Macs hasta firmar con Developer ID y notarizar (`scripts/make_installer.sh` lo hace si defines `SIGN_IDENTITY`, `INSTALLER_IDENTITY` y `NOTARY_PROFILE`).
- Telnet, Rlogin, TCP, FTP sin TLS y VNC no cifran la conexión (el editor lo avisa). VNC-auth solo usa 8 caracteres de contraseña.
- La política de claves de host `no` desactiva la verificación; está en Ajustes y no es la predeterminada (`accept-new`).
- La contraseña maestra bloquea la ventana pero no cifra `sessions.json` (que no contiene contraseñas, solo hosts y usuarios).
- El Mini Linux entra como root sin contraseña dentro de una VM con red NAT; comparte solo la carpeta elegida.
- Sin auditoría externa ni fuzzing del cliente SFTP/RFB.
