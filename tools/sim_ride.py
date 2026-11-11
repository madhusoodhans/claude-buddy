#!/usr/bin/env python3
"""Ride a real route on the Cheeko Gotchi nav screen, driven from the Mac over USB.

Plays the iPhone's part: sends the route, then a GPS fix, the next turn and the
trip once per second, exactly as the app will (cheeko/PROTOCOL.md).

  .venv/bin/python tools/sim_ride.py --from 12.9763,77.5929 --to 12.9784,77.6408
  .venv/bin/python tools/sim_ride.py --gpx ride.gpx --kmh 50

--from/--to routes with the public OSRM demo server (OpenStreetMap data; fine
for light testing, not for heavy use).
"""
import argparse
import datetime
import glob
import json
import math
import os
import random
import struct
import sys
import time
import unicodedata
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

import serial

MANEUVER = {
    "none": 0, "straight": 1, "slight left": 2, "left": 3, "sharp left": 4,
    "slight right": 5, "right": 6, "sharp right": 7, "uturn": 8, "roundabout": 9,
    "arrive": 10, "keep left": 11, "keep right": 12, "uturn left": 13,
}
STATE_NAVIGATING, STATE_ARRIVED = 1, 3
MAX_ROUTE = 5800
CHUNK = 60


# ---------------------------------------------------------------------------
# Link to the device
# ---------------------------------------------------------------------------

class Link:
    def __init__(self, port):
        self.s = serial.Serial(port, 115200, timeout=0.8)
        while self.s.read(4000):  # opening the port resets the board; let it boot
            pass
        self.hello = False

    def send(self, msg: bytes):
        line = b"@" + msg.hex().encode() + b"\n"
        for _ in range(3):
            self.s.write(line)
            deadline = time.time() + 2
            while time.time() < deadline:
                reply = self.s.readline().decode(errors="replace").strip()
                if reply == "ok":
                    return
                if reply == "@20":
                    self.hello = True
                elif reply.startswith("err"):
                    raise RuntimeError(f"device rejected message 0x{msg[0]:02x}: {reply}")
        raise RuntimeError("device stopped answering")

    def screenshot(self, path):
        from PIL import Image  # only needed for --shots

        self.s.write(b"shot\n")
        while True:
            line = self.s.readline().decode(errors="replace").strip()
            if not line:
                raise RuntimeError("no response to 'shot'")
            if line.startswith("SHOT "):
                break
        _, w, h, n = line.split()
        w, h, n = int(w), int(h), int(n)
        data = self.s.read(n)
        self.s.readline()
        img = Image.new("RGB", (w, h))
        px = img.load()
        for i in range(min(w * h, len(data) // 2)):
            v = data[2 * i] | data[2 * i + 1] << 8
            px[i % w, i // w] = ((v >> 11) << 3, ((v >> 5) & 0x3F) << 2, (v & 0x1F) << 3)
        img.save(path)


def dm(v):
    return int(round(v * 10))


def send_route(link, pts, roads=()):
    link.send(b"\x01")
    for i in range(0, len(pts), CHUNK):
        link.send(b"\x02" + b"".join(struct.pack("<ii", dm(x), dm(y)) for x, y in pts[i:i + CHUNK]))
    link.send(b"\x03")
    link.send(b"\x04")
    for road in roads:
        for i in range(0, len(road) - 1, CHUNK - 1):
            part = road[i:i + CHUNK]
            if len(part) >= 2:
                link.send(b"\x05" + b"".join(struct.pack("<ii", dm(x), dm(y)) for x, y in part))


def send_pos(link, x, y, heading, speed):
    link.send(struct.pack("<BiiHH", 0x10, dm(x), dm(y), int(heading % 360 * 100), int(speed * 100)))


def device_text(name):
    """The device's fonts are ASCII: fold accents and curly quotes, drop the rest."""
    name = name.replace("\u2019", "'").replace("\u2018", "'").replace("\u2013", "-").replace("\u2014", "-")
    return unicodedata.normalize("NFKD", name).encode("ascii", "ignore")[:47]


def send_turn(link, kind, exit_no, idx, dist, name):
    link.send(struct.pack("<BBBHI", 0x11, MANEUVER[kind], exit_no, idx, int(dist)) + device_text(name))


def send_upcoming(link, turns):
    link.send(b"\x15" + b"".join(struct.pack("<BBH", MANEUVER[k], e, i) for i, k, e, _ in turns))


def send_road(link, name):
    link.send(b"\x16" + device_text(name))


def send_trip(link, eta, remain_m, remain_min):
    link.send(struct.pack("<BBBIH", 0x12, eta.hour, eta.minute, int(remain_m), int(remain_min)))


def send_state(link, state):
    link.send(bytes([0x13, state]))


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

class Projection:
    """Lat/lon -> metres east/north of an origin. Accurate enough for a city ride."""

    def __init__(self, lat0, lon0):
        self.lat0, self.lon0 = lat0, lon0
        self.kx = 111320 * math.cos(math.radians(lat0))
        self.ky = 110540

    def __call__(self, lat, lon):
        return ((lon - self.lon0) * self.kx, (lat - self.lat0) * self.ky)

    def inverse(self, x, y):
        return (self.lat0 + y / self.ky, self.lon0 + x / self.kx)


def bearing(a, b):
    return math.degrees(math.atan2(b[0] - a[0], b[1] - a[1]))


def classify(delta):
    a, right = abs(delta), delta > 0
    if a > 165:
        return "uturn"
    if a > 120:
        return "sharp right" if right else "sharp left"
    if a > 55:
        return "right" if right else "left"
    return "slight right" if right else "slight left"


def turns_from_shape(pts, min_angle=25, window=20):
    """Bends in the route shape. Compares the direction `window` metres before and
    after each point, so a turn drawn as several small kinks still counts once."""
    cum = [0.0]
    for a, b in zip(pts, pts[1:]):
        cum.append(cum[-1] + math.dist(a, b))

    def at(p):
        i = next((k for k in range(1, len(cum)) if cum[k] >= p), len(cum) - 1)
        seg = cum[i] - cum[i - 1]
        t = (p - cum[i - 1]) / seg if seg else 0
        return (pts[i - 1][0] + (pts[i][0] - pts[i - 1][0]) * t, pts[i - 1][1] + (pts[i][1] - pts[i - 1][1]) * t)

    bends = []
    for i in range(1, len(pts) - 1):
        before, after = at(max(0, cum[i] - window)), at(min(cum[-1], cum[i] + window))
        d = (bearing(pts[i], after) - bearing(before, pts[i]) + 540) % 360 - 180
        if abs(d) < min_angle:
            continue
        if bends and cum[i] - cum[bends[-1][0]] < window * 2:  # same bend: keep the sharper point
            if abs(d) > abs(bends[-1][1]):
                bends[-1] = (i, d)
            continue
        bends.append((i, d))
    return [(i, classify(d), 0, "") for i, d in bends]


def add_missing_bends(pts, turns, min_angle=50, near=40):
    """Routers skip bends where the road keeps its name, but a 90 degree bend still
    needs announcing on a bike. Adds sharp shape bends that no maneuver covers."""
    cum = [0.0]
    for a, b in zip(pts, pts[1:]):
        cum.append(cum[-1] + math.dist(a, b))
    known = [cum[i] for i, *_ in turns]
    extra = [t for t in turns_from_shape(pts, min_angle)
             if all(abs(cum[t[0]] - k) > near for k in known)]
    return sorted(turns + extra, key=lambda t: t[0])


def merge_u_turns(pts, turns, within=45):
    """Two turns the same way a few metres apart (e.g. through a median gap onto
    the other side of a divided road) are one U-turn for the rider."""
    cum = [0.0]
    for a, b in zip(pts, pts[1:]):
        cum.append(cum[-1] + math.dist(a, b))
    side = {"left": "L", "sharp left": "L", "right": "R", "sharp right": "R"}
    out = []
    for t in turns:
        if out and side.get(t[1]) and side.get(out[-1][1]) == side[t[1]] and cum[t[0]] - cum[out[-1][0]] < within:
            first = out.pop()
            out.append((first[0], "uturn left" if side[t[1]] == "L" else "uturn", 0, t[3] or first[3]))
        else:
            out.append(t)
    return out


def osrm_route(frm, to):
    (lat1, lon1), (lat2, lon2) = frm, to
    url = (f"https://router.project-osrm.org/route/v1/driving/{lon1},{lat1};{lon2},{lat2}"
           "?overview=full&geometries=geojson&steps=true")
    req = urllib.request.Request(url, headers={"User-Agent": "cheeko-nav-sim/0.1"})
    data = json.load(urllib.request.urlopen(req, timeout=20))
    if data.get("code") != "Ok":
        raise SystemExit(f"OSRM: {data.get('message', data.get('code'))}")
    route = data["routes"][0]
    coords = route["geometry"]["coordinates"]  # [lon, lat]
    proj = Projection(coords[0][1], coords[0][0])
    pts = [proj(lat, lon) for lon, lat in coords]

    turns, search_from = [], 0
    for leg in route["legs"]:
        for step in leg["steps"]:
            m = step["maneuver"]
            kind, mod = m["type"], m.get("modifier", "straight")
            if kind == "depart" or kind == "exit roundabout" or kind == "exit rotary":
                continue
            if kind in ("new name", "continue") and mod == "straight":
                continue
            exit_no = 0
            if kind == "arrive":
                maneuver = "arrive"
            elif kind in ("roundabout", "rotary", "roundabout turn"):
                maneuver, exit_no = "roundabout", m.get("exit", 0)
            elif kind in ("fork", "merge", "on ramp", "off ramp") and mod.startswith("slight"):
                maneuver = "keep left" if "left" in mod else "keep right"
            else:
                maneuver = mod if mod in MANEUVER else "straight"
            if maneuver == "straight":  # "carry on" steps hide the real next turn
                continue
            # Nearest route point to the maneuver, searching forward so order is kept.
            mx, my = proj(m["location"][1], m["location"][0])
            idx = min(range(search_from, len(pts)), key=lambda i: (pts[i][0] - mx) ** 2 + (pts[i][1] - my) ** 2)
            search_from = idx
            name = "Destination" if maneuver == "arrive" else (step.get("name") or step.get("ref") or "")
            turns.append((idx, maneuver, exit_no, name))
    routed = len(turns)
    turns = add_missing_bends(pts, turns)
    bends = len(turns) - routed
    turns = merge_u_turns(pts, turns)
    print(f"route: {route['distance'] / 1000:.1f} km, {len(pts)} points, {routed} turns from the router "
          f"+ {bends} bends from the road shape, {len(turns)} prompts after merging U-turns")
    start_name = route["legs"][0]["steps"][0].get("name", "")
    return pts, turns, proj, start_name


def gpx_route(path):
    root = ET.parse(path).getroot()
    pts_ll = [(float(e.get("lat")), float(e.get("lon"))) for e in root.iter() if e.tag.endswith(("trkpt", "rtept"))]
    if len(pts_ll) < 2:
        raise SystemExit("no track points in GPX")
    proj = Projection(*pts_ll[0])
    pts = [proj(lat, lon) for lat, lon in pts_ll]
    turns = turns_from_shape(pts) + [(len(pts) - 1, "arrive", 0, "Destination")]
    return pts, turns, proj, ""


# Street network for the map background, from OpenStreetMap via Overpass.
ROAD_TYPES = ("motorway|trunk|primary|secondary|tertiary|unclassified|residential|living_street|"
              "motorway_link|trunk_link|primary_link|secondary_link|tertiary_link")
MAX_ROADS, MAX_ROAD_PTS = 1900, 15500


def fetch_roads(proj, pts, margin=300):
    xs, ys = [p[0] for p in pts], [p[1] for p in pts]
    s, w = proj.inverse(min(xs) - margin, min(ys) - margin)
    n, e = proj.inverse(max(xs) + margin, max(ys) + margin)
    query = (f'[out:json][timeout:25];way["highway"~"^({ROAD_TYPES})$"]'
             f"({s:.5f},{w:.5f},{n:.5f},{e:.5f});out geom;")
    cache = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".cache",
                         f"roads_{s:.4f}_{w:.4f}_{n:.4f}_{e:.4f}.json")
    if os.path.exists(cache):
        data = json.load(open(cache))
    else:
        req = urllib.request.Request("https://overpass-api.de/api/interpreter",
                                     data=urllib.parse.urlencode({"data": query}).encode(),
                                     headers={"User-Agent": "cheeko-nav-sim/0.1"})
        try:
            data = json.load(urllib.request.urlopen(req, timeout=40))
        except Exception as err:  # the map still works without side streets
            print(f"roads: couldn't fetch street network ({err}); riding without it")
            return []
        os.makedirs(os.path.dirname(cache), exist_ok=True)
        json.dump(data, open(cache, "w"))

    roads = []
    for way in data.get("elements", []):
        line = []
        for node in way.get("geometry", []):
            p = proj(node["lat"], node["lon"])
            if not line or math.dist(line[-1], p) >= 3:  # drop near-duplicate points
                line.append(p)
        if len(line) >= 2:
            roads.append(line)

    # Over the device's limits: keep the roads nearest the route.
    sample = pts[::max(1, len(pts) // 200)]
    def near(line):
        return min(math.dist(a, b) for a in line[::max(1, len(line) // 6)] for b in sample)
    roads.sort(key=near)
    kept, n_pts, n_lines = [], 0, 0
    for line in roads:
        pieces = max(1, math.ceil((len(line) - 1) / (CHUNK - 1)))
        if n_lines + pieces > MAX_ROADS or n_pts + len(line) + pieces > MAX_ROAD_PTS:
            break
        kept.append(line)
        n_lines += pieces
        n_pts += len(line) + pieces
    print(f"roads: {len(kept)} streets from OpenStreetMap ({n_pts} points)")
    return kept


def thin(pts, turns):
    """Keep under the device's route limit by dropping every other point (turn points kept)."""
    while len(pts) > MAX_ROUTE:
        keep = {i for i, *_ in turns} | {0, len(pts) - 1}
        new_index, kept = {}, []
        for i, p in enumerate(pts):
            if i in keep or i % 2 == 0:
                new_index[i] = len(kept)
                kept.append(p)
        turns = [(new_index[i], *rest) for i, *rest in turns]
        pts = kept
    return pts, turns


# ---------------------------------------------------------------------------
# Ride
# ---------------------------------------------------------------------------

def ride(link, pts, turns, kmh, roads=(), start_name="", shots=None, shot_every=5.0, max_seconds=None, start_km=0.0):
    cum = [0.0]
    for a, b in zip(pts, pts[1:]):
        cum.append(cum[-1] + math.dist(a, b))
    total = cum[-1]

    def point_at(p):
        p = max(0.0, min(p, total))
        i = max(0, min(len(pts) - 2, next((k for k in range(1, len(cum)) if cum[k] >= p), len(cum) - 1) - 1))
        seg = cum[i + 1] - cum[i]
        t = (p - cum[i]) / seg if seg else 0
        return (pts[i][0] + (pts[i + 1][0] - pts[i][0]) * t, pts[i][1] + (pts[i + 1][1] - pts[i][1]) * t)

    send_route(link, pts, roads)
    send_state(link, STATE_NAVIGATING)
    cruise = kmh / 3.6
    prog, v, last, last_fix = min(start_km * 1000, total), 0.0, time.time(), 0.0
    started, last_shot, shot_no = time.time(), time.time(), 0

    while True:
        now = time.time()
        dt, last = now - last, now
        nxt = next((t for t in turns if cum[t[0]] > prog + 1), turns[-1])
        to_turn = cum[nxt[0]] - prog
        target = min(cruise, 4.5) if to_turn < 60 and nxt[1] != "arrive" else cruise
        v += max(-2.5 * dt, min(1.5 * dt, target - v))
        prog += v * dt

        if link.hello:  # device restarted: give it the route again
            link.hello = False
            send_route(link, pts, roads)
            send_state(link, STATE_NAVIGATING)

        if prog >= total:
            x, y = pts[-1]
            send_pos(link, x, y, bearing(pts[-2], pts[-1]), 0)
            send_turn(link, "arrive", 0, len(pts) - 1, 0, "Destination")
            send_state(link, STATE_ARRIVED)
            print("arrived")
            return

        if now - last_fix >= 1.0:
            last_fix = now
            x, y = point_at(prog)
            a, b = point_at(prog - 2), point_at(prog + 5)
            send_pos(link, x + random.uniform(-1.5, 1.5), y + random.uniform(-1.5, 1.5),
                     bearing(a, b) + random.uniform(-3, 3), v)
            send_turn(link, nxt[1], nxt[2], nxt[0], to_turn, nxt[3])
            k = turns.index(nxt)
            send_upcoming(link, turns[k + 1:k + 3])
            passed = [t for t in turns[:k] if t[3]]
            send_road(link, passed[-1][3] if passed else start_name)
            remain = total - prog
            eta = datetime.datetime.now() + datetime.timedelta(seconds=remain / cruise)
            send_trip(link, eta, remain, math.ceil(remain / cruise / 60))
            sys.stdout.write(f"\r{prog / 1000:5.2f}/{total / 1000:.2f} km  {v * 3.6:4.0f} km/h  "
                             f"next: {nxt[1]} in {to_turn:4.0f} m  {nxt[3][:30]:30}")
            sys.stdout.flush()
        if shots and now - last_shot >= shot_every:
            last_shot = now
            shot_no += 1
            link.screenshot(f"{shots}/ride_{shot_no:03d}.png")
        if max_seconds and now - started > max_seconds:
            print("\nstopping (--seconds)")
            return
        time.sleep(0.05)


def latlon(s):
    lat, lon = (float(v) for v in s.split(","))
    return lat, lon


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--from", dest="frm", type=latlon, help="start, as lat,lon")
    ap.add_argument("--to", type=latlon, help="destination, as lat,lon")
    ap.add_argument("--gpx", help="ride a GPX track instead of routing")
    ap.add_argument("--kmh", type=float, default=35, help="cruising speed (default 35)")
    ap.add_argument("--port", help="serial port (default: first /dev/cu.usbmodem*)")
    ap.add_argument("--shots", help="save a screenshot of the device into this folder every --shot-every s")
    ap.add_argument("--shot-every", type=float, default=5.0)
    ap.add_argument("--seconds", type=float, help="stop after this many seconds")
    ap.add_argument("--start-km", type=float, default=0, help="start this far along the route")
    ap.add_argument("--no-roads", action="store_true", help="skip the OpenStreetMap street network")
    args = ap.parse_args()

    if args.gpx:
        pts, turns, proj, start_name = gpx_route(args.gpx)
    elif args.frm and args.to:
        pts, turns, proj, start_name = osrm_route(args.frm, args.to)
    else:
        ap.error("give --from and --to, or --gpx")
    pts, turns = thin(pts, turns)
    roads = [] if args.no_roads else fetch_roads(proj, pts)

    port = args.port or (sorted(glob.glob("/dev/cu.usbmodem*")) or [None])[0]
    if not port:
        raise SystemExit("no Cheeko Gotchi on /dev/cu.usbmodem*")
    ride(Link(port), pts, turns, args.kmh, roads, start_name, args.shots, args.shot_every, args.seconds, args.start_km)


if __name__ == "__main__":
    main()
