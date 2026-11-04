"""Tokenizador de literales de cadena de Swift (con interpolaciones anidadas) y clasificación por contexto."""
import re

class Lit:
    def __init__(self, start, end, parts):
        self.start, self.end, self.parts = start, end, parts   # parts: [("t", texto) | ("e", expr)]
    @property
    def has_interp(self): return any(k == "e" for k, _ in self.parts)
    def key(self):
        return "".join(v if k == "t" else "%@" for k, v in self.parts)
    def exprs(self): return [v for k, v in self.parts if k == "e"]
    def raw_text(self): return "".join(v for k, v in self.parts if k == "t")

def scan(src):
    """Devuelve los literales de nivel superior (las cadenas dentro de interpolaciones se ignoran)."""
    out, i, n = [], 0, len(src)
    while i < n:
        c = src[i]
        if src.startswith("//", i):
            j = src.find("\n", i); i = n if j < 0 else j; continue
        if src.startswith("/*", i):
            j = src.find("*/", i); i = n if j < 0 else j + 2; continue
        if src.startswith('"""', i):          # multilínea: se salta (scripts de shell, etc.)
            j = src.find('"""', i + 3); i = n if j < 0 else j + 3; continue
        if c == '"':
            lit, j = read_string(src, i)
            out.append(lit); i = j; continue
        i += 1
    return out

def read_string(src, i):
    start = i; i += 1; parts = []; buf = []
    n = len(src)
    while i < n:
        c = src[i]
        if c == "\\":
            if src[i + 1] == "(":
                if buf: parts.append(("t", "".join(buf))); buf = []
                depth = 1; j = i + 2
                while depth and j < n:
                    ch = src[j]
                    if ch == '"':
                        _, j = read_string(src, j); continue
                    if ch == "(": depth += 1
                    elif ch == ")": depth -= 1
                    j += 1
                parts.append(("e", src[i + 2:j - 1])); i = j; continue
            buf.append(src[i:i + 2]); i += 2; continue
        if c == '"':
            if buf: parts.append(("t", "".join(buf)))
            return Lit(start, i + 1, parts), i + 1
        buf.append(c); i += 1
    return Lit(start, n, parts), n

# Llamadas de SwiftUI cuyo primer argumento literal se localiza automáticamente (LocalizedStringKey)
SWIFTUI_CALLS = r'(?:Text|Button|Label|Toggle|Picker|Section|TextField|SecureField|Stepper|Menu|DisclosureGroup|GroupBox|CommandMenu|Window|LabeledContent|ProgressView)\(\s*$'
SWIFTUI_MODS = r'\.(?:help|navigationTitle|confirmationDialog|alert|navigationSubtitle)\(\s*$'

def context(src, lit):
    pre = src[max(0, lit.start - 80):lit.start]
    pre_line = pre.split("\n")[-1]
    if re.search(SWIFTUI_CALLS, pre_line) or re.search(SWIFTUI_MODS, pre_line): return "view"
    return "other"
