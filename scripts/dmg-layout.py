"""Write a minimal Finder layout without opening or automating Finder."""
import sys
from pathlib import Path

from ds_store import DSStore

folder = Path(sys.argv[1])
with DSStore.open(str(folder / ".DS_Store"), "w+") as store:
    store["."]["bwsp"] = {
        "ShowToolbar": False,
        "ShowStatusBar": False,
        "ShowTabView": False,
        "ShowPathbar": False,
        "ShowSidebar": False,
        "ContainerShowSidebar": False,
        "WindowBounds": "{{160, 120}, {580, 420}}",
    }
    store["."]["icvp"] = {
        "viewOptionsVersion": 1,
        "backgroundType": 0,
        "iconSize": 96.0,
        "textSize": 12.0,
        "labelOnBottom": True,
        "showItemInfo": False,
        "showIconPreview": True,
        "arrangeBy": "none",
        "gridSpacing": 100.0,
        "gridOffsetX": 0.0,
        "gridOffsetY": 0.0,
    }
    store["."]["vstl"] = ("type", b"icnv")
    store["."]["vSrn"] = ("long", 1)
    store["字迹.app"]["Iloc"] = (145, 130)
    store["Applications"]["Iloc"] = (435, 130)
    store["安装说明.txt"]["Iloc"] = (290, 295)
