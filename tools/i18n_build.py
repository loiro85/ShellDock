#!/usr/bin/env python3
"""Genera Resources/Localization/<idioma>.lproj/Localizable.strings a partir de tools/translations/t*.py.
   Falla si falta alguna clave o si los marcadores «%@» no coinciden entre idiomas."""
import glob, importlib.util, os, re, sys
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LANGS = ["en", "fr", "it", "de", "pt"]          # es = identidad (las claves están en español)
NOISE = ("PS1=", "terminal%@")

T = {}
for f in sorted(glob.glob(os.path.join(ROOT, "tools/translations/t*.py"))):
    spec = importlib.util.spec_from_file_location(os.path.basename(f)[:-3], f); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
    for k, v in m.T.items():
        assert k not in T, f"clave duplicada: {k}"
        assert len(v) == len(LANGS), f"{k}: {len(v)} traducciones"
        T[k] = v

keys = [l.rstrip("\n") for l in open(os.path.join(ROOT, "tools/i18n_keys.txt")) if l.strip()]
keys += [l.rstrip("\n") for l in open(os.path.join(ROOT, "tools/i18n_extra_keys.txt")) if l.strip()]
keys = [k for k in dict.fromkeys(keys) if not any(n in k for n in NOISE)]
# claves que no necesitan traducción (marcas, nombres propios, símbolos)
UNTRANSLATED = {"ShellDock", "Dracula", "Nord", "Monokai", "One Dark", "Gruvbox", "Matrix", "SSH", "Telnet", "Mosh", "Rlogin", "SFTP", "Ping", "Traceroute", "Whois", "DNS (dig)", "Menlo"}
missing = [k for k in keys if k not in T and k not in UNTRANSLATED]
bad = []
for k, v in T.items():
    n = k.count("%@")
    for lang, t in zip(LANGS, v):
        if t.count("%@") != n: bad.append((k, lang))
unused = [k for k in T if k not in keys]
if missing: print("FALTAN traducciones:\n  " + "\n  ".join(missing)); 
if bad: print("Marcadores %@ distintos:", bad)
if unused: print(f"(aviso) {len(unused)} traducciones sin uso:", unused[:5])
if missing or bad: sys.exit(1)

def esc(s): return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") if "\\n" not in s else s.replace('"', '\\"')
def write(lang, mapping, name="Localizable.strings"):
    d = os.path.join(ROOT, "Resources/Localization", lang + ".lproj"); os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, name), "w", encoding="utf-8") as f:
        f.write("/* Generado por tools/i18n_build.py: no editar a mano */\n")
        for k, v in mapping: f.write(f'"{esc(k)}" = "{esc(v)}";\n')

for i, lang in enumerate(LANGS): write(lang, [(k, T[k][i]) for k in keys if k in T])
write("es", [(k, k) for k in keys])          # español: identidad (evita caer en el idioma de desarrollo)
INFO = {"NSLocalNetworkUsageDescription": ("ShellDock connects to servers on your local network.", "ShellDock se connecte à des serveurs de votre réseau local.", "ShellDock si connette a server della tua rete locale.", "ShellDock verbindet sich mit Servern in Ihrem lokalen Netzwerk.", "O ShellDock liga-se a servidores da sua rede local.", "ShellDock se conecta a servidores de tu red local."),
        "NSAppleEventsUsageDescription": ("ShellDock asks for passwords with a system dialog.", "ShellDock demande les mots de passe via une fenêtre système.", "ShellDock richiede le password con una finestra di sistema.", "ShellDock fragt Passwörter über einen Systemdialog ab.", "O ShellDock pede palavras-passe com um diálogo do sistema.", "ShellDock pide contraseñas con un diálogo del sistema.")}
for i, lang in enumerate(LANGS + ["es"]): write(lang, [(k, v[i]) for k, v in INFO.items()], "InfoPlist.strings")
print(f"OK: {len(keys)} claves × {len(LANGS) + 1} idiomas → Resources/Localization")
