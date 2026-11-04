# Configuración de dmgbuild (se usa desde scripts/make_installer.sh; no requiere Finder).
import os
app = os.environ["DMG_APP"]
files = [app]
symlinks = {"Applications": "/Applications"}
badge_icon = os.path.join(os.environ["DMG_ROOT"], "scripts/AppIcon.icns")
background = os.path.join(os.environ["DMG_ROOT"], "scripts/dmg/background.tiff")
format = "UDZO"
filesystem = "HFS+"
window_rect = ((200, 120), (660, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 112
text_size = 13
arrange_by = None
icon_locations = {os.path.basename(app): (170, 210), "Applications": (490, 210)}
