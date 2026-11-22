#!/usr/bin/env python3
"""Check physical keycaps and compositing masks against exported 600×540 artwork."""
import argparse
from pathlib import Path

import numpy as np
from PIL import Image


def key_regions():
    # Coordinates measured in the exported image with the sitter across the desk.
    # Keep these independent of the exporter's keyboard layout calculation.
    rows = [
        ("1234567890-=", [455, 431, 408, 384, 361, 337, 314, 290, 267, 243, 220, 196], 470),
        ("QWERTYUIOP[]", [443, 420, 397, 374, 351, 328, 305, 282, 259, 236, 213, 190], 455),
        ("ASDFGHJKL;'", [433, 410, 388, 365, 343, 320, 297, 275, 252, 230, 207], 441),
        ("ZXCVBNM,./", [420, 398, 375, 353, 331, 309, 287, 265, 243, 221], 428),
    ]
    keys = {32: (289, 415, 423, 431), 8: (170, 470, 194, 488), 127: (151, 470, 169, 488)}
    for symbols, starts, y in rows:
        for symbol, x in zip(symbols, starts):
            code = 1046 if symbol == "." else ord(symbol)
            keys[code] = (x, y, x + 20, y + 16)
    return keys


def verify_role(directory, accent):
    def read(name):
        with Image.open(directory / (name + ".png")) as image:
            return np.asarray(image.convert("RGBA"))

    idle, clean, pointer = (read(name) for name in ("idle0", "deskFree", "pointer"))
    if any(im.shape != (540, 600, 4) for im in (idle, clean, pointer)):
        raise ValueError(f"{directory}: invalid full-frame dimensions")
    cleared = (idle != clean).any(axis=2)
    touched = cleared | (pointer[..., 3] != 0)
    if not cleared.any() or not (pointer[400:462, 85:153, 3] > 245).any():
        raise ValueError(f"{directory}: missing clean plate or grip over the mouse")
    if touched[:290].any() or touched[:, 314:].any():
        raise ValueError(f"{directory}: mouse or clean plate extends outside its compositing region")
    minimum_accent = 10**6
    left_keys = set(map(ord, "12345QWERTASDFGZXCVB "))
    for code, (x0, y0, x1, y1) in key_regions().items():
        for phase in range(1, 6):
            name = f"key{code}-{phase}"
            key = read(name)
            if key.shape != (250, 600, 4):
                raise ValueError(f"{directory / name}: invalid lower-body dimensions")
            changed = (key != idle[290:]).any(axis=2)
            if code in left_keys and (changed & cleared[290:]).any():
                raise ValueError(f"{directory / name}: lit key or moving hand overlaps the old mouse arm")
            if phase == 3:
                badge_x = 480 if code in left_keys else 72
                badge = key[64:91, badge_x:badge_x+42, :3].astype(np.int16)
                badge_ink = (np.abs(badge - accent).max(axis=2) <= 6)
                if (badge_ink & changed[64:91, badge_x:badge_x+42]).sum() < 150:
                    raise ValueError(f"{directory / name}: missing key indicator on the striking hand's side")
                cap = key[y0-290:y1-290, x0:x1, :3].astype(np.int16)
                lit = (np.abs(cap - accent).max(axis=2) <= 6) & changed[y0-290:y1-290, x0:x1]
                visible = int(lit.sum())
                if visible < 16:
                    raise ValueError(f"{directory / name}: expected physical keycap has {visible} accent pixels")
                minimum_accent = min(minimum_accent, visible)
    print(f"{directory.name}: 48 separate keycaps, at least {minimum_accent} visible contact pixels, "
          "105 simultaneous left-hand phases with disjoint masks")
    if directory.name == "blue":
        previous = idle
        for i in range(1, 5):
            if not np.array_equal(idle, read(f"rest{i}")):
                raise ValueError(f"{directory}: whale tail moves while idle")
            meal = read(f"rice{i}")
            if meal.shape != idle.shape:
                raise ValueError(f"{directory}: invalid rice{i} dimensions")
            changed = (meal != idle).any(axis=2)
            if changed[:198].any() or changed[421:].any() or changed[:, :196].any() or changed[:, 414:].any():
                raise ValueError(f"{directory}: rice{i} changes the mouse, desk, tail or top of the head")
            if np.count_nonzero((meal != previous).any(axis=2)) < 500:
                raise ValueError(f"{directory}: meal pose {i} duplicates the preceding gesture")
            if i == 3:
                bite = meal[219:236, 295:314, :3]
                rice = (bite.min(axis=2) >= 185) & (np.ptp(bite, axis=2) <= 30)
                if (rice & changed[219:236, 295:314]).sum() < 32:
                    raise ValueError(f"{directory}: the chopsticks do not bring rice to the mouth")
            if i == 4 and changed[:254].any():
                raise ValueError(f"{directory}: the chewing pose must accept a separate face")
            previous = meal
        print("blue: four distinct meal poses with fixed keyboard, mouse and whale tail")
    else:
        reading = directory.name == "amber"
        prefix = "book" if reading else "toss"
        previous = idle
        for i in range(1, 5):
            pose = read(f"{prefix}{i}")
            delta = (pose != idle).any(axis=2)
            if delta[108:254, 208:389].any() or delta[421:].any() or delta[:, :156].any():
                raise ValueError(f"{directory / prefix}{i}: artwork overlaps the face overlay, mouse or desk")
            if not reading and delta[:, :310].any():
                raise ValueError(f"{directory / prefix}{i}: the other hand moved away from the keyboard")
            if (pose != previous).any(axis=2).sum() < 1000:
                raise ValueError(f"{directory / prefix}{i}: duplicate gesture")
            previous = pose
        if not reading:
            toy = Image.fromarray(read("toy"))
            if toy.getbbox() != (272, 243, 329, 296):
                raise ValueError(f"{directory}: cloud has moved off the expected source anchor")
            desk = Image.fromarray(read("tossDesk"))
            for i in (1, 2, 4):
                arm = Image.fromarray(read(f"tossArm{i}"))
                rebuilt = np.asarray(Image.alpha_composite(desk, arm).convert("RGBa"), dtype=np.int16)
                original = np.asarray(Image.fromarray(read(f"toss{i}")).convert("RGBa"), dtype=np.int16)
                if np.abs(rebuilt - original).max() > 2:
                    raise ValueError(f"{directory}: separate tossing arm {i} does not match the painted pose")
        print(f"{directory.name}: four distinct idle gestures, with a clear face region and stationary desk")
    moods = set()
    for i in range(1, 7 if directory.name == "blue" else 4):
        face = read(f"mood{i}")
        changed = (face != idle).any(axis=2)
        moods.add(face[108:254, 208:389].tobytes())
        changed[108:254, 208:389] = False
        if changed.any() or len(moods) != i:
            raise ValueError(f"{directory}/mood{i}: duplicate expression or changes outside the face")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", nargs="?", type=Path, default=Path("windows/assets"))
    args = parser.parse_args()
    for role, color in (("blue", (72, 102, 158)), ("amber", (163, 79, 37)), ("frost", (121, 99, 158))):
        verify_role(args.input / role, np.array(color))
