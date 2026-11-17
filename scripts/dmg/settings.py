# dmgbuild settings: dmgbuild -s scripts/dmg/settings.py -D app=bin/Rays.app -D background=<tiff> Rays <out.dmg>
import os.path

app = defines["app"]  # noqa: F821 (provided by dmgbuild)
format = "UDZO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
icon_locations = {os.path.basename(app): (170, 190), "Applications": (490, 190)}
background = defines["background"]  # noqa: F821
window_rect = ((200, 200), (660, 400))
icon_size = 112
text_size = 13
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
default_view = "icon-view"
