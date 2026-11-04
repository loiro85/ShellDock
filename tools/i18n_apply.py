#!/usr/bin/env python3
"""Envuelve en tr(...) las cadenas de tipo String con texto de interfaz y convierte las interpolaciones de las vistas.
   Uso: tools/i18n_apply.py [--apply]   (sin --apply solo muestra lo que cambiaría)"""
import sys, glob, re, os
sys.path.insert(0, os.path.dirname(__file__))
from i18n_lib import scan, context

APPLY = "--apply" in sys.argv
EXCLUDE_FILES = ("DemoData.swift", "Themes.swift", "Localization.swift", "SFTPClient.swift:protocol")
DENY = ("NSLog(", "print(", "environment", ".arguments", "executableURL", "Process(", "args +=", "args.append", "a += [", "stty", "modprobe",
        "echo ", "UserDefaults", "forResource", "CodingKeys", "dateFormat", "pathExtension", "appendingPathComponent", "case \"", "== \"",
        "fatalError", "#selector", "Notification.Name", "forKey", "protocolError(", "\"-Q\"", "months =", "service =", "themeName =", "fontName =",
        "log(\"", "ProcessInfo", "hasPrefix(", "u{1b}", "\\r\\n")
MARK = re.compile(r"[áéíóúñÁÉÍÓÚ¿¡…«»]|\b(el|la|los|las|de|del|que|para|con|una|un|no|se|en|por|sin|al|más|es|ya|o|y|tu|su)\b", re.I)
VOCAB = set("""Abrir Activar Activo Ajustes Amarillo Azul Cambiar Cancelar Carpeta Cerrada Cerrar Comentario Conectado Conectar Desactivar Desactivada Dividir
Eliminar Enviar Fallo Grupo Guardada Guardar Herramientas Huella Naranja Navegador Otros Parado Permisos Propietario Renombrar Rojo Rosa Ruta Serie
Sesiones Subcarpeta Subir Tipo Turquesa Verde Violeta Preferencias Ninguno Nombre Usuario Puerto Notas Color Archivo Descargar Copiar Pegar Borrar Atrás
Buscar Ejecutar Detener Iniciar Aplicar Abrir Cargar Error Aceptar Cerrar Probar Escanear Generar Contraseña Clave Agente Automático Dinámico Oscuro Claro
Editar Nueva Nuevo Sesión Túneles Túnel Macros Claves Servidor Servidores Utilidades Herramientas Diagnóstico Terminal MultiExec""".split())
VOCAB_PHRASES = {"Agente SSH", "Clave privada", "Conexiones activas", "Editar / abrir", "Fin de fichero", "Host demasiado largo", "Host o IP", "Interfaces de red",
                 "Mensaje mal formado", "No existe", "Nuevo snippet", "Paquete enviado", "Permiso denegado", "Puerto cerrado", "Remoto (-R)", "Local (-L)",
                 "Dinámico SOCKS (-D)", "TCP crudo", "Tabla ARP", "Tabla de rutas", "Terminal local", "Ya existe %@", "Importadas %@ sesiones", "Macro %@",
                 "Terminal local %@", "Error %@", "Falta el host", "Escribe un host", "Excluir de MultiExec", "Incluir en MultiExec", "Mostrar sesiones", "Ocultar sesiones"}

def only_noise(key):
    t = re.sub(r"%@", "", key)
    return not re.search(r"[A-Za-zÁÉÍÓÚáéíóúñÑ]{3,}", t) or key in {"%@/tcp", "http://%@:%@/"}

def wrap_ok(key, line):
    if any(d in line for d in DENY): return False
    if len(key) < 2 or not re.search(r"[A-Za-zÁÉÍÓÚáéíóúñÑ]", key): return False
    if re.fullmatch(r"[#a-z0-9_\-\.:=/\\$ ]+", key) and not MARK.search(key): return False   # identificadores, rutas
    if key in VOCAB_PHRASES or key in VOCAB: return True
    if only_noise(key): return False
    m = MARK.search(key)
    if m and (" " in key or re.search(r"[áéíóúñÁÉÍÓÚ¿¡…«»]", key)): return True      # un solo «no», «en»… no cuenta
    return False

def process(path):
    src = open(path).read(); lits = scan(src); edits = []; keys = []
    lines = src.split("\n")
    for l in lits:
        ln = src.count("\n", 0, l.start) + 1; line = lines[ln - 1].strip()
        key = l.key(); ctx = context(src, l)
        if not re.search(r"[A-Za-zÁÉÍÓÚáéíóúñÑ]{2,}", key) and not l.has_interp: continue
        if src[max(0, l.start - 3):l.start] == "tr(":      # ya envuelta
            if not only_noise(key): keys.append(key)
            continue
        if ctx == "view":
            if only_noise(key): continue
            keys.append(key)
            if l.has_interp or (path.endswith("ShellDockApp.swift") and not line.startswith("Window(")):
                edits.append((l, "tr(" + '"' + l.raw_key_text() + '"' + "".join(', "\\(%s)"' % e for e in l.exprs()) + ")", key, ln, line))
        elif wrap_ok(key, line):
            keys.append(key)
            edits.append((l, "tr(" + '"' + l.raw_key_text() + '"' + "".join(', "\\(%s)"' % e for e in l.exprs()) + ")", key, ln, line))
    return src, edits, keys

def raw_key_text(self):
    return "".join(v if k == "t" else "%@" for k, v in self.parts)
import i18n_lib; i18n_lib.Lit.raw_key_text = raw_key_text

all_keys = []
for f in sorted(glob.glob("Sources/**/*.swift", recursive=True)):
    if f.endswith(EXCLUDE_FILES): continue
    src, edits, keys = process(f)
    all_keys += keys
    if not edits: continue
    if APPLY:
        out = src
        for l, new, *_ in sorted(edits, key=lambda e: -e[0].start):
            out = out[:l.start] + new + out[l.end:]
        open(f, "w").write(out)
    else:
        for l, new, key, ln, line in edits: print(f"{f.replace('Sources/ShellDock/','')}:{ln}: {key}")
seen = []; [seen.append(k) for k in all_keys if k not in seen]
open("tools/i18n_keys.txt", "w").write("\n".join(seen) + "\n")
print(f"\n{len(seen)} claves distintas", file=sys.stderr)
