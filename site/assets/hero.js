// The hero: what crosses the pod router, one case at a time, from
// assets/from-tree/hero.json (written by site/build.py from
// tests/router-forwarding-local.sh and host/zenoh-router.json5.tmpl). Every case
// is one that test asserts against two real Zenoh routers on each pull request.
(function () {
  "use strict";

  document.querySelectorAll("button.copy").forEach(function (b) {
    b.addEventListener("click", function () {
      var text = document.getElementById(b.dataset.copy).textContent;
      if (navigator.clipboard) navigator.clipboard.writeText(text).then(function () {
        b.textContent = "Copied"; setTimeout(function () { b.textContent = "Copy"; }, 1600);
      });
    });
  });

  var g = document.getElementById("pk"), log = document.getElementById("log"), head = document.getElementById("case");
  if (!g || !window.fetch) return;
  var reduce = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  var NS = "http://www.w3.org/2000/svg";

  function esc(s) { return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;"); }
  function pad(s, n) { s = String(s); while (s.length < n) s += " "; return s; }
  function el(name, attrs, text) {
    var n = document.createElementNS(NS, name);
    for (var k in attrs) n.setAttribute(k, attrs[k]);
    if (text !== undefined) n.textContent = text;
    g.appendChild(n); return n;
  }

  fetch("assets/from-tree/hero.json").then(function (r) { return r.json(); }).then(function (d) {
    document.getElementById("zv").textContent = "zenoh " + d.zenoh + ", mTLS";
    function short(k) { return k.split(d.slot).join("<slot>"); }
    var lines = [];
    function row(c) {
      var op = c.op === "declare_subscriber" ? "sub" : c.op;
      return esc(pad(c.who, 6) + " " + op + " " + pad(short(c.key), 30) + " ") +
        (c.end === "denied" ? '<span class="no">deny</span>' : '<span class="ok">allow</span>' + (c.op === "declare_subscriber" ? " interest only" : ""));
    }
    function push(h) { lines.push(h); if (lines.length > 6) lines.shift(); log.innerHTML = lines.join("\n"); }

    // lanes in the drawing: the pod app out at y 62, the fabric in at y 98, fabric interest at y 150, the other identity at y 208
    function lane(c) {
      if (c.op === "declare_subscriber") return { y: 150, from: 392, to: 300, cls: "pk fab" };
      if (c.who === "fabric") return { y: 98, from: 392, to: 122, cls: "pk fab" };
      if (c.who === "other") return { y: 208, from: 122, to: 196, cls: "pk other" };
      return { y: 62, from: 122, to: c.end === "fabric" ? 392 : 196, cls: "pk" };
    }
    var now = document.getElementById("now"), verdict = document.getElementById("verdict");
    function draw(c, u) {
      while (g.firstChild) g.removeChild(g.firstChild);
      var L = lane(c), x = L.from + (L.to - L.from) * u;
      now.textContent = (c.op === "declare_subscriber" ? "subscribe " : "put ") + short(c.key);
      el("line", { "class": "lane", x1: Math.min(L.from, L.to), x2: Math.max(L.from, L.to), y1: L.y, y2: L.y });
      el("circle", { "class": L.cls, cx: x, cy: L.y, r: 7 });
      verdict.textContent = "";
      verdict.removeAttribute("class");
      if (u >= 1) {
        var ok = c.end !== "denied";
        verdict.setAttribute("class", ok ? "ok" : "no");
        verdict.textContent = ok ? (c.rule === "fabric-interest" ? "accepted as interest only, by rule " : "allowed by rule ") + c.rule : "denied: no rule matches, so the default applies";
      }
    }
    function title(c) {
      head.textContent = c.who === "other" ? "another identity writes" : c.who === "fabric" ? "the fabric sends" : "your app sends";
    }

    if (reduce) {
      d.cases.forEach(function (c) { push(row(c)); });
      draw(d.cases[1], 1); title(d.cases[1]);
      return;
    }
    log.innerHTML = "";
    var i = 0;
    (function next() {
      var c = d.cases[i], t0 = performance.now();
      title(c);
      (function move(now) {
        var u = Math.min(1, (now - t0) / 1500);
        draw(c, 1 - Math.pow(1 - u, 2));
        if (u < 1) requestAnimationFrame(move);
        else {
          push(row(c));
          i = (i + 1) % d.cases.length;
          if (i === 0) setTimeout(function () { lines = []; next(); }, 4000);
          else setTimeout(next, 1300);
        }
      })(t0);
    })();
  }).catch(function () {});
})();
