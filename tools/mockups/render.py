#!/usr/bin/env python3
"""Product-shot style images of the Cheeko Gotchi running Claude Buddy.

  tools/buddy_sim/render.sh                   # first: draws the screens (tools/buddy_sim/out/*.ppm)
  .venv/bin/python tools/mockups/render.py    # -> docs/images/*.jpg|png

A small ray marcher (numpy only): the device is a signed distance field (lime
bumper case with rounded edges, black glass set slightly into it, USB-C port
on top, measured off a photo of the real unit) and the screen pictures are
mapped onto the glass with its real rounded corners. Studio lighting:
softbox key, rim fill, sky/ground ambient, ambient occlusion, Fresnel
reflections on the glass, and soft drop shadows on a grey sweep.
"""
import os

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
SCREENS = os.path.join(ROOT, "tools", "buddy_sim", "out")
OUT = os.path.join(ROOT, "docs", "images")
FONT = os.path.join(ROOT, "tools", "fonts", "Inter.ttf")

# ---- Device geometry, millimetres. Local axes: x right, y up, z out of the screen. ----
W, H, D = 42.0, 48.5, 12.0   # case
RC, RE = 11.5, 3.6           # corner radius seen from the front, edge rounding
GW, GH, RG = 37.4, 43.6, 9.2  # glass
RECESS = 0.7                 # glass sits this far below the bumper's lip
SW, SH = 32.2, 39.7          # visible screen: 240 x 296 px
SCREEN_DY = -0.2
CORNER_PX = 42               # the glass hides the screen's corners (radius in pixels; 40 on the panel, +2 hides the mask edge)
USB_W, USB_H, USB_DEPTH = 9.0, 3.2, 2.2

LIME = np.array([214, 226, 112]) / 255.0
SLOT = np.array([0.03, 0.03, 0.035])


def srgb_to_linear(c):
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def linear_to_srgb(c):
    c = np.clip(c, 0, 1)
    return np.where(c <= 0.0031308, c * 12.92, 1.055 * c ** (1 / 2.4) - 0.055)


LIME_LIN = srgb_to_linear(LIME)


def normalize(v):
    return v / np.linalg.norm(v, axis=-1, keepdims=True)


def rotation(yaw, pitch, roll):
    cy, sy, cp, sp, cr, sr = np.cos(yaw), np.sin(yaw), np.cos(pitch), np.sin(pitch), np.cos(roll), np.sin(roll)
    ry = np.array([[cy, 0, sy], [0, 1, 0], [-sy, 0, cy]])
    rx = np.array([[1, 0, 0], [0, cp, -sp], [0, sp, cp]])
    rz = np.array([[cr, -sr, 0], [sr, cr, 0], [0, 0, 1]])
    return ry @ rx @ rz


def sd_round_rect(x, y, hx, hy, r):
    qx, qy = np.abs(x) - hx + r, np.abs(y) - hy + r
    return np.hypot(np.maximum(qx, 0), np.maximum(qy, 0)) + np.minimum(np.maximum(qx, qy), 0) - r


def smax(a, b, k):
    h = np.clip(0.5 - 0.5 * (b - a) / k, 0, 1)
    return a * h + b * (1 - h) + k * h * (1 - h)


def sd_device(q):
    x, y, z = q[:, 0], q[:, 1], q[:, 2]
    # rounded slab
    d2 = sd_round_rect(x, y, W / 2 - RE, H / 2 - RE, RC - RE)
    wz = np.abs(z) - (D / 2 - RE)
    body = np.hypot(np.maximum(d2, 0), np.maximum(wz, 0)) + np.minimum(np.maximum(d2, wz), 0) - RE
    # glass pocket in the front
    pocket = np.maximum(sd_round_rect(x, y, GW / 2, GH / 2, RG), (D / 2 - RECESS) - z)
    body = smax(body, -pocket, 0.45)
    # USB-C port in the top
    port = np.maximum(sd_round_rect(x, z, USB_W / 2, USB_H / 2, USB_H / 2 - 0.1), (H / 2 - USB_DEPTH) - y)
    return smax(body, -port, 0.25)


class Device:
    def __init__(self, screen, pos, yaw=0.0, pitch=0.0, roll=0.0, scale=1.0):
        img = np.asarray(Image.open(screen).convert("RGB"), dtype=np.float32) / 255.0
        self.tex = srgb_to_linear(img)
        self.pos = np.array(pos, dtype=np.float64)
        self.R = rotation(yaw, pitch, roll)
        self.scale = scale

    def local(self, p):
        return ((p - self.pos) @ self.R) / self.scale

    def sdf(self, p):
        return sd_device(self.local(p)) * self.scale

    def screen(self, q):
        """Emitted colour of the screen at local points q on the glass (black outside the picture)."""
        th, tw = self.tex.shape[:2]
        u = (q[:, 0] + SW / 2) / SW * 240
        v = (SH / 2 - (q[:, 1] - SCREEN_DY)) / SH * 296
        cx = np.clip(u, CORNER_PX, 240 - CORNER_PX)
        cy = np.clip(v, CORNER_PX, 296 - CORNER_PX)
        corner = np.hypot(u - cx, v - cy)
        inside = (u >= 0) & (u < 240) & (v >= 0) & (v < 296)
        edge = np.clip(CORNER_PX + 0.5 - corner, 0, 1) * inside  # soft, anti-aliased corner
        # bilinear sample
        fu = np.clip(u * tw / 240 - 0.5, 0, tw - 1.001)
        fv = np.clip(v * th / 296 - 0.5, 0, th - 1.001)
        x0, y0 = fu.astype(int), fv.astype(int)
        ax, ay = (fu - x0)[:, None], (fv - y0)[:, None]
        t = self.tex
        c = (t[y0, x0] * (1 - ax) * (1 - ay) + t[y0, x0 + 1] * ax * (1 - ay)
             + t[y0 + 1, x0] * (1 - ax) * ay + t[y0 + 1, x0 + 1] * ax * ay)
        return c * edge[:, None]


KEY = normalize(np.array([-0.45, 0.75, 0.6]))
FILL = normalize(np.array([0.85, 0.15, 0.35]))


def env(r):
    """Studio surroundings seen in reflections: grey room, a big softbox and a strip light."""
    t = (r[:, 1] + 1) / 2
    c = (0.18 + 0.55 * t)[:, None] * np.array([0.95, 0.96, 1.0])
    box = np.clip((r @ KEY - 0.90) / 0.05, 0, 1) ** 2 * 5.0
    strip = np.clip((r @ FILL - 0.955) / 0.03, 0, 1) * 2.0
    return c + (box + strip)[:, None]


def render(devices, size, cam_dist=190.0, fov=30.0, ss=2):
    w, h = size[0] * ss, size[1] * ss
    tan = np.tan(np.radians(fov) / 2)
    js, is_ = np.mgrid[0:h, 0:w]
    u = (2 * (is_ + 0.5) / w - 1) * tan * w / h
    v = (1 - 2 * (js + 0.5) / h) * tan
    dirs = normalize(np.stack([u, v, -np.ones_like(u)], -1).reshape(-1, 3)).astype(np.float64)
    origin = np.array([0.0, 0.0, cam_dist])

    # Only march rays that come near some device.
    near = np.zeros(len(dirs), bool)
    for dv in devices:
        oc = dv.pos - origin
        tca = dirs @ oc
        d2 = (oc @ oc) - tca ** 2
        near |= d2 < (36 * dv.scale) ** 2
    idx = np.nonzero(near)[0]
    t = np.full(len(idx), cam_dist - 80.0)
    hit = np.zeros(len(idx), bool)
    live = np.ones(len(idx), bool)
    for _ in range(140):
        a = np.nonzero(live)[0]
        if len(a) == 0:
            break
        p = origin + dirs[idx[a]] * t[a, None]
        dist = np.min([dv.sdf(p) for dv in devices], axis=0)
        t[a] += dist * 0.9
        hit[a[dist < 0.004]] = True
        live[a[(dist < 0.004) | (t[a] > cam_dist + 120)]] = False

    color = np.zeros((len(dirs), 3))
    alpha = np.zeros(len(dirs))
    hi = idx[hit]
    p = origin + dirs[hi] * t[hit, None]
    vdir = dirs[hi]
    which = np.argmin([dv.sdf(p) for dv in devices], axis=0)
    out = np.zeros((len(hi), 3))
    for k, dv in enumerate(devices):
        m = which == k
        if not m.any():
            continue
        pk, vk = p[m], vdir[m]
        q = dv.local(pk)
        e = 0.02
        n_local = np.stack([sd_device(q + d) - sd_device(q - d) for d in np.eye(3) * e], -1)
        n = normalize(normalize(n_local) @ dv.R.T)
        refl = vk - 2 * (vk * n).sum(-1, keepdims=True) * n
        cos = np.clip(-(vk * n).sum(-1), 0, 1)

        # ambient occlusion against every device (they can shade each other)
        ao = np.ones(len(pk))
        for i, hgt in enumerate([0.6, 1.5, 3.0, 5.0]):
            s = np.min([d.sdf(pk + n * hgt) for d in devices], axis=0)
            ao -= (hgt - s) / hgt * 0.5 ** (i + 1)
        ao = np.clip(ao, 0.25, 1)[:, None]

        glass = (np.abs(q[:, 2] - (D / 2 - RECESS)) < 0.03) & \
                (sd_round_rect(q[:, 0], q[:, 1], GW / 2, GH / 2, RG) < -0.35)
        slot = (q[:, 1] > H / 2 - USB_DEPTH - 0.05) & (sd_round_rect(q[:, 0], q[:, 2], USB_W / 2, USB_H / 2, 1.5) < 0.05) \
            & (q[:, 1] < H / 2 - 0.15)

        def wrap(x, k=0.35):
            return np.clip((x + k) / (1 + k), 0, 1)

        light = (1.15 * wrap(n @ KEY) + 0.35 * wrap(n @ FILL) + 0.30 * (0.55 + 0.45 * n[:, 1]))[:, None]
        fres = (0.04 + 0.96 * (1 - cos) ** 5)[:, None]
        half = normalize(KEY - vk)
        spec = (np.clip((n * half).sum(-1), 0, 1) ** 28 * 0.45)[:, None]
        plastic = LIME_LIN * light * ao + spec * ao + fres * env(refl) * 0.35 * ao
        c = plastic
        c = np.where(slot[:, None], SLOT * light * ao, c)
        if glass.any():
            # black glass: the room reflects faintly, the lights clearly
            r = refl[glass]
            room = env(r)
            lights = np.clip(room - 0.75, 0, None)
            g = dv.screen(q[glass]) * 1.05 + np.array([0.002, 0.002, 0.003]) \
                + fres[glass] * (room * 0.18 + lights * 1.6)
            c[glass] = g
        out[m] = c
    color[hi] = out
    alpha[hi] = 1.0

    color = color.reshape(h, w, 3)
    alpha = alpha.reshape(h, w)
    tone = 1 - np.exp(-color * 1.25)  # soft highlight roll-off
    rgb = linear_to_srgb(tone) * alpha[..., None]  # premultiplied
    img = Image.fromarray((np.dstack([rgb, alpha]) * 255).astype(np.uint8), "RGBA")
    return img.resize(size, Image.LANCZOS)


def backdrop(size, top=(150, 154, 162), bottom=(222, 223, 226)):
    w, h = size
    y = np.linspace(0, 1, h)[:, None, None]
    grad = np.array(top) * (1 - y) + np.array(bottom) * y
    img = np.broadcast_to(grad, (h, w, 3)).copy()
    # a bright curved sweep, like a studio cyclorama
    yy, xx = np.mgrid[0:h, 0:w]
    arc = ((xx - w * 0.15) / (w * 1.1)) ** 2 + ((yy - h * 1.35) / (h * 0.85)) ** 2
    img += (np.clip(1 - arc, 0, 1) ** 0.6 * 34)[..., None]
    return Image.fromarray(np.clip(img, 0, 255).astype(np.uint8))


def compose(devices_img, size, shadow_offset=(18, 70), blur=46, opacity=0.38, bg=None):
    bg = bg or backdrop(size)
    a = devices_img.split()[3]
    shadow = Image.new("L", size, 0)
    shadow.paste(a, shadow_offset)
    shadow = shadow.filter(ImageFilter.GaussianBlur(blur)).point(lambda v: int(v * opacity))
    bg = Image.composite(Image.new("RGB", size, (40, 42, 48)), bg, shadow)
    # devices_img is premultiplied: out = bg * (1 - a) + rgb
    b = np.asarray(bg, np.float32)
    d = np.asarray(devices_img, np.float32)
    o = b * (1 - d[..., 3:] / 255) + d[..., :3]
    return Image.fromarray(np.clip(o, 0, 255).astype(np.uint8))


def caption(img, items, y, size=30, color=(60, 62, 68)):
    draw = ImageDraw.Draw(img)
    font = ImageFont.truetype(FONT, size)
    try:
        font.set_variation_by_axes([24, 560])
    except Exception:
        pass
    for x, text in items:
        draw.text((x, y), text, font=font, fill=color, anchor="mm")


def px_per_mm(size, cam_dist, fov):
    """Scale at the z = 0 plane, for placing captions under the devices."""
    return size[1] / 2 / (np.tan(np.radians(fov) / 2) * cam_dist)


def screen(name):
    return os.path.join(SCREENS, name + ".ppm")


def main():
    os.makedirs(OUT, exist_ok=True)

    # Hero: the buddy cooking, and the usage meters, floating at angles.
    size = (1920, 1200)
    hero = render([
        Device(screen("face_working"), (-30, -8, 0), yaw=0.42, pitch=-0.12, roll=-0.17),
        Device(screen("meters"), (31, 12, -22), yaw=-0.38, pitch=0.16, roll=0.13),
    ], size, cam_dist=175, fov=32)
    compose(hero, size).save(os.path.join(OUT, "hero.jpg"), quality=92)
    print("hero.jpg")

    # The three pages, side by side.
    size = (2100, 880)
    xs = [-58, 0, 58]
    pages = render([
        Device(screen(n), (x, 6, 0), yaw=-x / 260, pitch=-0.06)
        for x, n in zip(xs, ["face_working", "meters", "day"])
    ], size, cam_dist=200, fov=30)
    img = compose(pages, size, shadow_offset=(0, 40), blur=30, opacity=0.3,
                  bg=backdrop(size, top=(214, 216, 220), bottom=(236, 237, 239)))
    k = px_per_mm(size, 200, 30)
    caption(img, [(size[0] / 2 + x * k, l) for x, l in zip(xs, ["Buddy", "Usage", "Today"])],
            size[1] / 2 - 6 * k + 25 * k + 60)
    img.save(os.path.join(OUT, "pages.png"))
    print("pages.png")

    # Every mood of the buddy.
    size = (2600, 700)
    names = ["face_working", "face_waiting", "face_done", "face_idle", "face_lost"]
    labels = ["Cooking", "Your turn", "All done", "Napping", "Looking for Mac"]
    xs = [-104, -52, 0, 52, 104]
    moods = render([
        Device(screen(n), (x, 4, 0), yaw=-0.22, pitch=-0.05)
        for x, n in zip(xs, names)
    ], size, cam_dist=215, fov=27)
    img = compose(moods, size, shadow_offset=(10, 34), blur=26, opacity=0.3,
                  bg=backdrop(size, top=(214, 216, 220), bottom=(236, 237, 239)))
    k = px_per_mm(size, 215, 27)
    caption(img, [(size[0] / 2 + x * k, l) for x, l in zip(xs, labels)], size[1] / 2 - 4 * k + 25 * k + 46, size=30)
    img.save(os.path.join(OUT, "moods.png"))
    print("moods.png")


if __name__ == "__main__":
    main()
