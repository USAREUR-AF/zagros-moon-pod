#!/usr/bin/env python3
"""Draw the repository's figures from the tree.

    python3 -I docs/figures/make-figures.py           # write docs/figures/*.svg
    python3 -I docs/figures/make-figures.py --check   # exit 1 if a committed figure is out of date

Each figure is written twice, `<name>-light.svg` and `<name>-dark.svg`, for a
`<picture>` element. Image names, versions and the SDK languages are read from
compose/docker-compose.yml and clients/connect/; the rest follows README.md and
docs/architecture.md. The output is deterministic. Standard library only.
"""

import os
import re
import sys
from xml.sax.saxutils import escape

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
THEMES = {
    "light": {
        "paper": "#ffffff", "panel": "#f6f8fa", "ink": "#1f2328", "quiet": "#59636e", "rule": "#d1d9e0",
        "line": "#818b98", "accent": "#0969da", "accent_soft": "#ddf4ff", "on_accent": "#ffffff",
        "good": "#1a7f37", "good_bg": "#dafbe1", "crit": "#cf222e", "crit_bg": "#ffebe9", "mute": "#6e7781",
        "s0": "#0969da", "s1": "#bc4c00", "s2": "#1a7f37", "s3": "#8250df",
    },
    "dark": {
        "paper": "#0d1117", "panel": "#161b22", "ink": "#e6edf3", "quiet": "#9198a1", "rule": "#3d444d",
        "line": "#7d8590", "accent": "#4493f8", "accent_soft": "#132c4c", "on_accent": "#0d1117",
        "good": "#3fb950", "good_bg": "#12261e", "crit": "#f85149", "crit_bg": "#2f1517", "mute": "#8b949e",
        "s0": "#4493f8", "s1": "#f0883e", "s2": "#3fb950", "s3": "#bc8cff",
    },
}
SANS = "-apple-system, BlinkMacSystemFont, 'Segoe UI', 'Noto Sans', Helvetica, Arial, sans-serif"
MONO = "ui-monospace, SFMono-Regular, 'SF Mono', Menlo, Consolas, 'Liberation Mono', monospace"
FUNCTIONS = ["filter", "correlate", "fuse", "quality"]
ENGINES = [("python", "Python"), ("rust", "Rust"), ("go", "Go"), ("java", "Java"),
           ("cpp", "C++"), ("erlang", "Erlang"), ("zig", "Zig")]


def n(v):
    return ("%.1f" % v).rstrip("0").rstrip(".")


def tw(s, size, mono=False, bold=False):
    """Text width estimate; the browser check in the README confirms it."""
    if mono:
        return len(s) * size * 0.61
    w = 0.0
    for c in s:
        if c in "il.,:;|!'`·1 ":
            w += 0.30
        elif c in "ft()[]/-":
            w += 0.36
        elif c in "mwMW@%":
            w += 0.86
        elif c.isupper() or c in "0123456789≤≥²→":
            w += 0.64
        else:
            w += 0.55
    return w * size * (1.06 if bold else 1.0)


def wrap(s, width, size, mono=False, bold=False):
    out, line = [], ""
    for word in s.split(" "):
        t = word if not line else line + " " + word
        if tw(t, size, mono, bold) <= width or not line:
            line = t
        else:
            out.append(line)
            line = word
    if line:
        out.append(line)
    return out


class SVG:
    def __init__(self, w, h, title, desc):
        self.w, self.h, self.title, self.desc = w, h, title, desc
        self.items = []

    def add(self, s):
        self.items.append(s)

    def rect(self, x, y, w, h, fill="panel", stroke="rule", rx=8, sw=1, dash=None):
        d = ' stroke-dasharray="%s"' % dash if dash else ""
        self.add('<rect x="%s" y="%s" width="%s" height="%s" rx="%s" fill="{%s}" stroke="{%s}" stroke-width="%s"%s/>'
                 % (n(x), n(y), n(w), n(h), n(rx), fill, stroke, n(sw), d))

    def text(self, x, y, s, size=14, fill="ink", anchor="start", bold=False, mono=False, italic=False):
        self.add('<text x="%s" y="%s" font-size="%s" fill="{%s}" text-anchor="%s"%s%s%s>%s</text>'
                 % (n(x), n(y), n(size), fill, anchor, ' font-weight="600"' if bold else "",
                    ' font-family="%s"' % MONO if mono else "", ' font-style="italic"' if italic else "", escape(s)))

    def lines(self, x, y, rows, size=14, lead=1.4, **kw):
        for i, r in enumerate(rows):
            self.text(x, y + i * size * lead, r, size, **kw)
        return y + len(rows) * size * lead

    def line(self, x1, y1, x2, y2, stroke="line", sw=1.5, dash=None, arrow=False):
        d = ' stroke-dasharray="%s"' % dash if dash else ""
        m = ' marker-end="url(#arrow)"' if arrow else ""
        self.add('<line x1="%s" y1="%s" x2="%s" y2="%s" stroke="{%s}" stroke-width="%s"%s%s/>'
                 % (n(x1), n(y1), n(x2), n(y2), stroke, n(sw), d, m))

    def path(self, d, stroke="line", fill="none", sw=1.5, dash=None, arrow=False):
        dd = ' stroke-dasharray="%s"' % dash if dash else ""
        m = ' marker-end="url(#arrow)"' if arrow else ""
        f = "none" if fill == "none" else "{%s}" % fill
        self.add('<path d="%s" fill="%s" stroke="{%s}" stroke-width="%s"%s%s/>' % (d, f, stroke, n(sw), dd, m))

    def circle(self, x, y, r, fill="ink", stroke=None, sw=1.5):
        s = ' stroke="{%s}" stroke-width="%s"' % (stroke, n(sw)) if stroke else ""
        f = "none" if fill == "none" else "{%s}" % fill
        self.add('<circle cx="%s" cy="%s" r="%s" fill="%s"%s/>' % (n(x), n(y), n(r), f, s))

    def ellipse(self, x, y, rx, ry, fill="none", stroke="line", sw=1.5, dash=None, opacity=None):
        d = ' stroke-dasharray="%s"' % dash if dash else ""
        f = "none" if fill == "none" else "{%s}" % fill
        o = ' fill-opacity="%s"' % opacity if opacity is not None else ""
        self.add('<ellipse cx="%s" cy="%s" rx="%s" ry="%s" fill="%s"%s stroke="{%s}" stroke-width="%s"%s/>'
                 % (n(x), n(y), n(rx), n(ry), f, o, stroke, n(sw), d))

    def render(self, theme):
        t = THEMES[theme]
        body = "\n".join(self.items)
        for k, v in t.items():
            body = body.replace("{%s}" % k, v)
        return ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %d %d" width="%d" height="%d" role="img" '
                'aria-labelledby="t d" font-family="%s">\n<title id="t">%s</title>\n<desc id="d">%s</desc>\n'
                '<defs><marker id="arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" '
                'orient="auto-start-reverse"><path d="M0,0L10,5L0,10z" fill="%s"/></marker></defs>\n'
                '<rect width="100%%" height="100%%" rx="12" fill="%s"/>\n%s\n</svg>\n'
                % (self.w, self.h, self.w, self.h, SANS.replace("'", "&apos;"), escape(self.title), escape(self.desc),
                   t["line"], t["paper"], body))


def header(f, title, sub):
    """Title and subtitle at the top left."""
    f.text(24, 38, title, 20, bold=True)
    f.text(24, 62, sub, 14, fill="quiet")

# ---------------------------------------------------------------- tree facts

def compose_images():
    """service name -> image reference without its digest, from compose/docker-compose.yml."""
    out, svc = {}, None
    with open(os.path.join(ROOT, "compose", "docker-compose.yml"), encoding="utf-8") as fh:
        for line in fh:
            m = re.match(r"^  ([a-z0-9-]+):\s*$", line)
            if m:
                svc = m.group(1)
            m = re.match(r"^\s+image:\s*(\S+)", line)
            if m and svc:
                out[svc] = m.group(1).split("@")[0]
    return out


def sdk_languages():
    d = os.path.join(ROOT, "clients", "connect")
    return sorted(x for x in os.listdir(d) if os.path.isdir(os.path.join(d, x)))


# ---------------------------------------------------------------- figure

def fig_pod():
    imgs = compose_images()
    router, audit = imgs["zenoh-router"], imgs["audit-sink"]
    zenoh = router.split("/")[-1].replace(":", " ")
    langs = sdk_languages()
    W, H = 880, 528
    title = "One host you run, publishing into a goat fabric and receiving from it"
    f = SVG(W, H, title,
            "On your own host, applications built on the clients/ SDKs (%d languages) publish and subscribe "
            "through a %s router with mTLS that may write only your slot, <slot_id>/**; an audit-sink observes "
            "your slot; goat-cli and a goat-doctor timer run on the host beside the mesh client (NetBird, kernel "
            "WireGuard). Over the WireGuard mesh the router publishes your slot to the zagros sandbox fabric and "
            "receives your inbound prefix. The environment owner mints the slot, mTLS identity and single-use "
            "setup key with goat machine enroll, and controls access rules and what data may leave the pod. "
            "Used today to learn how a pod joins a goatnet." % (len(langs), zenoh))
    f.text(24, 38, title, 20, bold=True)
    f.text(24, 62, "Used today to learn how a pod joins a goatnet: build one and join the zagros sandbox.", 14, fill="quiet")

    # the pod (your host)
    px, py, pw, ph = 24, 92, 520, 392
    f.rect(px, py, pw, ph, fill="paper", stroke="accent", sw=2, rx=12)
    f.text(px + 20, py + 30, "Your host: you run it", 16, bold=True)
    f.text(px + 20, py + 52, "Ubuntu 24.04 · encrypted state volume", 14, fill="quiet")

    # your applications
    ax, ay, aw, ah = 44, 196, 140, 120
    f.rect(ax, ay, aw, ah, fill="panel", stroke="rule")
    f.text(ax + aw / 2, ay + 30, "Your apps", 15, anchor="middle", bold=True)
    f.text(ax + aw / 2, ay + 54, "clients/ SDKs", 13, anchor="middle", mono=True)
    f.text(ax + aw / 2, ay + 76, "%d languages" % len(langs), 14, anchor="middle")
    f.text(ax + aw / 2, ay + 98, "pub · sub", 14, anchor="middle", fill="quiet")

    # docker compose zone
    cx0, cy0, cw, ch = 204, 166, 320, 160
    f.rect(cx0, cy0, cw, ch, fill="paper", stroke="line", dash="5 4", rx=10)
    f.text(cx0 + 14, cy0 + 20, "docker compose · host network", 13, fill="quiet")
    rx_, ry_, rw, rh = 220, 196, 288, 56
    f.rect(rx_, ry_, rw, rh, fill="accent_soft", stroke="accent", sw=1.5)
    f.text(rx_ + 14, ry_ + 23, "zenoh-router", 15, bold=True)
    f.text(rx_ + 132, ry_ + 23, zenoh, 13, fill="quiet", mono=True)
    f.text(rx_ + 14, ry_ + 44, "mTLS · may write only <slot_id>/**", 14)
    bx, by, bw, bh = 220, 266, 288, 52
    f.rect(bx, by, bw, bh, fill="panel", stroke="rule")
    f.text(bx + 14, by + 22, "audit-sink", 15, bold=True)
    f.text(bx + 14, by + 42, "observes your slot · metrics only", 14, fill="quiet")
    f.line(ax + aw + 2, 224, rx_ - 2, 224, arrow=True)
    f.line(364, ry_ + rh + 1, 364, by - 3, arrow=True)

    # host systemd zone
    sx, sy, sw_, sh = 44, 342, 480, 124
    f.rect(sx, sy, sw_, sh, fill="paper", stroke="line", dash="5 4", rx=10)
    f.text(sx + 14, sy + 20, "on the host (systemd)", 13, fill="quiet")
    gx, gy, gw, gh = 60, 372, 214, 80
    f.rect(gx, gy, gw, gh, fill="panel", stroke="rule")
    f.text(gx + 14, gy + 24, "goat-cli", 15, bold=True, mono=True)
    f.text(gx + 14, gy + 46, "doctor · pub · sub · health", 14)
    f.text(gx + 14, gy + 67, "goat-doctor timer", 14, fill="quiet")
    mx, my, mw, mh = 290, 372, 218, 80
    f.rect(mx, my, mw, mh, fill="panel", stroke="rule")
    f.text(mx + 14, my + 24, "mesh client", 15, bold=True)
    f.text(mx + 14, my + 46, "NetBird", 14)
    f.text(mx + 14, my + 67, "kernel WireGuard", 14, fill="quiet")

    # the fabric (someone else's environment)
    fx, fy, fw, fh = 664, 92, 192, 392
    f.rect(fx, fy, fw, fh, fill="panel", stroke="line", sw=1.5, rx=12)
    f.text(fx + 16, fy + 30, "goat data fabric", 16, bold=True)
    f.text(fx + 16, fy + 52, "zagros sandbox", 14, fill="quiet")
    ex, ey, ew, eh = fx + 8, fy + 72, fw - 16, 132
    f.rect(ex, ey, ew, eh, fill="paper", stroke="rule")
    f.text(ex + 10, ey + 24, "goat machine enroll", 13, mono=True)
    f.text(ex + 12, ey + 48, "mints:", 14, fill="quiet")
    f.lines(ex + 12, ey + 70, ["your slot (a UUID)", "mTLS identity", "one-use setup key"], 14, lead=1.5)
    f.text(fx + 16, fy + 238, "The owner of this", 14, fill="quiet")
    f.text(fx + 16, fy + 258, "environment controls:", 14, fill="quiet")
    f.lines(fx + 16, fy + 286, ["· enrollment", "· access rules", "· what data may"], 14, lead=1.5)
    f.text(fx + 25, fy + 286 + 63, "leave the pod", 14)

    # between them: bundle in, data out and in, the mesh
    mid = (px + pw + fx) / 2
    f.text(mid, 112, "signed bundle", 13, anchor="middle", fill="quiet")
    f.text(mid, 128, "+ setup key", 13, anchor="middle", fill="quiet")
    f.line(fx - 2, 142, px + pw + 2, 142, dash="4 4", arrow=True)
    f.text(mid, 180, "publish", 13, anchor="middle", bold=True)
    f.text(mid, 198, "<slot_id>/**", 13, anchor="middle", mono=True)
    f.line(rx_ + rw + 2, 214, fx - 3, 214, stroke="accent", sw=2.5, arrow=True)
    f.line(fx - 2, 240, rx_ + rw + 3, 240, stroke="accent", sw=2.5, arrow=True)
    f.text(mid, 264, "subscribe", 13, anchor="middle", bold=True)
    f.text(mid, 282, "inbound prefix", 13, anchor="middle")
    f.line(mx + mw + 2, 412, fx - 2, 412, sw=4, stroke="line")
    f.text(mid, 400, "WireGuard mesh", 13, anchor="middle", fill="quiet")
    f.text(mid, 434, "both flows", 13, anchor="middle", fill="quiet")
    f.text(mid, 450, "ride this tunnel", 13, anchor="middle", fill="quiet")

    f.text(24, 512, "Inbound prefix: release/goat/** under a bilateral grant; on the sandbox, your own slot until one exists.", 14, fill="quiet")
    return f


FIGURES = [("moon-pod", fig_pod)]


def main(argv):
    check = "--check" in argv
    stale = []
    for name, fn in FIGURES:
        fig = fn()
        for theme in THEMES:
            p = os.path.join(HERE, "%s-%s.svg" % (name, theme))
            out = fig.render(theme)
            if check:
                if not os.path.isfile(p) or open(p, encoding="utf-8").read() != out:
                    stale.append(os.path.relpath(p, ROOT))
            else:
                with open(p, "w", encoding="utf-8") as fh:
                    fh.write(out)
                print(os.path.relpath(p, ROOT))
    if stale:
        print("out of date: " + ", ".join(stale) + "; run python3 -I docs/figures/make-figures.py", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
