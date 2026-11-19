# Figures

`make-figures.py` draws every figure in this directory. Image names and
versions come from `compose/docker-compose.yml`, the SDK languages from
`clients/connect/`; the rest follows `README.md` and `docs/architecture.md`.
Each figure is written in a light and a dark variant for a `<picture>` element.

```sh
python3 -I docs/figures/make-figures.py           # write the SVG files
python3 -I docs/figures/make-figures.py --check   # exit 1 if a committed file is out of date
```

| Figure | Shows |
|---|---|
| `moon-pod` | the pod on the host you run (your apps, the Zenoh router, the audit-sink, goat-cli, the mesh client), the publish and subscribe flows over the WireGuard mesh, and what the environment owner mints and controls |

Text is at least 13 units on an 880-unit canvas, so at least 12 px when the
README shows the figure at 760 px. Regenerate after a change to the compose
file or the SDK list.
