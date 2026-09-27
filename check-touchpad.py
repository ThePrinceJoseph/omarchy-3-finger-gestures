#!/usr/bin/env python3
"""Say how many fingers each touchpad can track. Three-finger gestures need 3.

Reads the multitouch slot count straight from the evdev device, so it needs
read access to /dev/input: run it with sudo, or as a user in the input group.
"""
import array, fcntl, glob, os, re, sys

EVIOCGABS = lambda code: (2 << 30) | (24 << 16) | (ord("E") << 8) | (0x40 + code)
ABS_MT_SLOT, ABS_MT_POSITION_X, ABS_MT_POSITION_Y = 0x2F, 0x35, 0x36

def absinfo(fd, code):
    buf = array.array("i", [0] * 6)  # value, min, max, fuzz, flat, resolution
    fcntl.ioctl(fd, EVIOCGABS(code), buf, True)
    return buf

def size_mm(info):
    return f"{(info[2] - info[1]) / info[5]:.0f} mm" if info[5] else "?"

found = False
for name_file in sorted(glob.glob("/sys/class/input/event*/device/name")):
    name = open(name_file).read().strip()
    if not re.search(r"touchpad|trackpad|clickpad", name, re.I):
        continue
    found = True
    node = "/dev/input/" + name_file.split("/")[4]
    try:
        fd = os.open(node, os.O_RDONLY | os.O_NONBLOCK)
    except OSError as e:
        print(f"{name} ({node}): cannot open ({e.strerror}). Try: sudo {sys.argv[0]}")
        continue
    try:
        fingers = absinfo(fd, ABS_MT_SLOT)[2] + 1
        w, h = size_mm(absinfo(fd, ABS_MT_POSITION_X)), size_mm(absinfo(fd, ABS_MT_POSITION_Y))
    except OSError as e:
        print(f"{name} ({node}): no multitouch info ({e.strerror}).")
        continue
    finally:
        os.close(fd)
    verdict = "fine for three-finger gestures" if fingers >= 3 else "too few contacts: three-finger gestures will not fire"
    print(f"{name} ({node}): tracks {fingers} fingers, {w} x {h}. {verdict}.")
if not found:
    print("No touchpad found among the input devices.")
