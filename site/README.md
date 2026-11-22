# site

The landing page published to GitHub Pages by `.github/workflows/pages.yml`.
One static page: no framework, no external requests, no web fonts.

## Files

| File | What it is |
|---|---|
| `index.html` | the page |
| `assets/site.css` | its styles, light and dark (`prefers-color-scheme`) |
| `assets/hero.js` | the copy buttons, and the hero: animates `assets/from-tree/hero.json` |
| `assets/icon.svg` | the page icon |
| `assets/from-tree/` | git-ignored; written by `build.py`: `hero.json` and the README figure from `docs/figures/` |
| `fitcheck.py` | run by `build.py`: fails when a command box is cut off at 1440 or 390 px |
| `build.py` | gathers `assets/from-tree/` and checks the page against the tree |

## Preview

```sh
python3 -I site/build.py
python3 -m http.server 8000 --directory site    # then open http://127.0.0.1:8000/
```

## The hero

It shows what crosses the pod router, one case at a time. Each case is one that
`tests/router-forwarding-local.sh` asserts against two real Zenoh routers on
every pull request (`.github/workflows/router-forwarding.yml`):

| Who | Operation | Key | Result | Decided by |
|---|---|---|---|---|
| fabric router | subscribe | `*/**` | accepted as interest only | `fabric-interest` |
| pod identity | put | `<slot>/test/ping` | reaches the fabric | `pod-firstparty` |
| pod identity | put | `outside/test/blocked` | denied | default deny |
| pod identity | put | `release/goat/test/local-write` | denied | default deny |
| other identity | put | `<slot>/other/write` | denied | default deny |
| fabric router | put | `release/goat/test/pong` | reaches the pod's app | `pod-inbound-fabric-data` |

`<slot>` and `release/goat` are the test's `SLOT` and `INBOUND`. `build.py`
reads them from the test, reads the access-control rules and the default from
`host/zenoh-router.json5.tmpl`, and fails if a key the page shows is no longer
in the test or a rule it names is no longer in the template. With reduced motion
the hero shows every case at once.

## Where each number comes from

Every number is in an element with `data-measure="<key>"`; `build.py` measures
it and fails if the page says something else.

| Key | On the page | Measured as |
|---|---|---|
| `containers` | containers | services in `compose/docker-compose.yml` |
| `rules` | allow rules over a default deny | entries of `access_control.rules` in `host/zenoh-router.json5.tmpl` |
| `sdks` | client SDK languages | directories in `clients/connect/` |
| `requirements` | requirements at the boundary | numbered items under "The seven requirements" in `docs/partner-contract.md` |

## Command and output boxes

Every `<pre>` on the page is marked `data-box="command"` or `data-box="output"`. A command box shows the whole command at any width: it wraps at spaces, each line of it a `<span class="ln">` with a hanging indent, and Copy copies the exact text. An output box may scroll inside its box on a narrow screen, and its caption says so. `build.py` ends by running `fitcheck.py`, which loads the page in headless Chrome at 1440 and 390 px wide and fails when a box is cut off.
