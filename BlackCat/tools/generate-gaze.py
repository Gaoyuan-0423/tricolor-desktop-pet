#!/usr/bin/env python3
"""Build GAZ1 inverse sampling fields for the 600×540 desktop-pet frames.

The fields store head rotation/nod and horizontal/vertical iris motion independently.
Regenerate after changing head placement or eyes. Coordinates are master pixels,
top-left origin. Displacements are signed eighth pixels, in order Hxx, Hxy,
Hyx, Hyy, Ex, Ey. Sample the two eye channels at the head-adjusted point.
"""
from pathlib import Path
import struct
import zlib

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
SIZE = (600, 540)
# Each iris is measured on the exported neutral frame. The two radii control
# elastic falloff into the sclera and eyelids, not a rendered pupil shape.
THEMES = {
    'blue': {
        'head': (299, 154, 266, 106, 180),
        'eyes': [(269.8, 193.7, 15.91, 13.0), (332.0, 186.2, 13.76, 13.0)],
        'eye_travel': (6.10, 3.53)
    },
    'amber': {
        'head': (298, 133, 224, 103, 174),
        'eyes': [(264.2, 159.5, 14.19, 11.96), (323.8, 149.1, 14.62, 11.44)],
        'eye_travel': (5.46, 3.12)
    },
    'frost': {
        'head': (302, 143, 245, 105, 177),
        'eyes': [(276.5, 179.4, 13.76, 9.62), (332.0, 171.8, 13.33, 10.14)],
        'eye_travel': (5.19, 2.87)
    }
}


def ease(lo, hi, x):
    t = np.clip((x-lo)/(hi-lo), 0.0, 1.0)
    return t*t*(3.0 - 2.0*t)


def build(theme):
    settings = THEMES[theme]
    with Image.open(ROOT/'windows'/'assets'/theme/'idle0.png') as source:
        if source.size != SIZE:
            raise ValueError(f'{theme}: expected {SIZE}, got {source.size}')
    cx, cy, neck, full_width, outer_width = settings['head']
    y, x = np.indices((SIZE[1], SIZE[0]), dtype=float)
    # The turn is anchored above the neck. Facial features have a small extra
    # translation over the hair mass to suggest yaw, in addition to a head tilt.
    weight = ((1-ease(full_width, outer_width, np.abs(x-cx))) *
              (1-ease(neck-45, neck+7, y)) * ease(1, 11, y))
    # Hearts float in a fixed overlay at screen right. Give them a clear margin.
    weight *= 1-ease(391, 417, x)*(1-ease(157, 189, y))
    cheek = np.exp(-((x-cx)/96)**2 - ((y-(neck-75))/77)**2)
    turn_x = -weight*(3.7 + .043*(neck-y) + 3.2*cheek)
    turn_y = -weight*(.038*(x-cx))
    nod_x = -weight*(.012*(x-cx))
    nod_y = -weight*(4.1 + .012*(y-cy) + 3.2*cheek)
    iris_x, iris_y = np.zeros_like(x), np.zeros_like(y)
    travel_x, travel_y = settings['eye_travel']
    for pupil_x, pupil_y, radius_x, radius_y in settings['eyes']:
        # Several irises in the original drawings already touch an eyelid.
        # Taper across the limbus and peripheral sclera to preserve the outline
        # at full gaze. Pinning the aperture edge pulls a dark streak inside.
        influence = np.exp(-.82*((x-pupil_x)/radius_x)**2
                           -.85*((y-pupil_y)/radius_y)**2)
        iris_x -= travel_x*influence
        iris_y -= travel_y*influence
    field = np.stack((turn_x,turn_y,nod_x,nod_y,iris_x,iris_y), axis=-1)
    field = np.rint(field*8).clip(-127,127).astype(np.int8)
    yy, xx = np.where(np.any(field != 0, axis=-1))
    l,t,r,b = int(xx.min())-1,int(yy.min())-1,int(xx.max())+2,int(yy.max())+2
    header = struct.pack('<4s4H', b'GAZ1', l, t, r-l, b-t)
    return zlib.compress(header+field[t:b,l:r].tobytes(), 9)


if __name__ == '__main__':
    dest = ROOT/'windows'/'gaze'
    dest.mkdir(exist_ok=True)
    for theme in THEMES:
        compressed = build(theme)
        path = dest/f'{theme}.gaze'
        path.write_bytes(compressed)
        print(path.name, len(compressed), 'bytes')
