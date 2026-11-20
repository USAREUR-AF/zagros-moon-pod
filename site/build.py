#!/usr/bin/env python3
"""Prepare site/ for publishing and check its numbers. Standard library only.

    python3 -I site/build.py

1. Reads the pod router's access-control rules from host/zenoh-router.json5.tmpl
   and the keys tests/router-forwarding-local.sh publishes, and writes the cases
   the hero animates to site/assets/from-tree/hero.json (git-ignored). Each case
   is one the test asserts on every pull request; the build fails if a key or a
   rule the page names is no longer in those files.
2. Copies the README figure beside it.
3. Measures the numbers on the page and fails if site/index.html states anything else.
"""

import json
import os
import re
import shutil
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SITE = os.path.join(ROOT, "site")
OUT = os.path.join(SITE, "assets", "from-tree")
TEST = "tests/router-forwarding-local.sh"
TEMPLATE = "host/zenoh-router.json5.tmpl"

# (who sends, operation, key with {slot}/{inbound}, the source text the test uses for it,
#  where it ends, the template rule that decides it or None for the default deny)
CASES = [
    ("fabric", "declare_subscriber", "*/**", '"*/**"', "pod", "fabric-interest"),
    ("pod", "put", "{slot}/test/ping", 'f"{slot}/test/ping"', "fabric", "pod-firstparty"),
    ("pod", "put", "outside/test/blocked", '"outside/test/blocked"', "denied", None),
    ("pod", "put", "{inbound}/test/local-write", 'f"{inbound}/test/local-write"', "denied", None),
    ("other", "put", "{slot}/other/write", 'f"{slot}/other/write"', "denied", None),
    ("fabric", "put", "{inbound}/test/pong", 'f"{inbound}/test/pong"', "pod", "pod-inbound-fabric-data"),
]


def read(rel):
    with open(os.path.join(ROOT, rel)) as f:
        return f.read()


def rules(template):
    acl = template[template.index("access_control:") :]
    out = []
    for m in re.finditer(r'id: "([a-z-]+)",\s*messages: \[([^\]]*)\],\s*flows: \[([^\]]*)\],\s*permission: "(\w+)",\s*key_exprs: \[([^\]]*)\]', acl):
        out.append(
            {
                "id": m.group(1),
                "messages": re.findall(r'"([a-z_]+)"', m.group(2)),
                "flows": re.findall(r'"(\w+)"', m.group(3)),
                "permission": m.group(4),
                "key_exprs": re.findall(r'"([^"]+)"', m.group(5)),
            }
        )
    default = re.search(r'default_permission: "(\w+)"', acl).group(1)
    return out, default


def main():
    os.makedirs(OUT, exist_ok=True)
    for name in ("moon-pod-light.svg", "moon-pod-dark.svg"):
        shutil.copyfile(os.path.join(ROOT, "docs/figures", name), os.path.join(OUT, name))
    test, template, compose = read(TEST), read(TEMPLATE), read("compose/docker-compose.yml")
    slot = re.search(r'^SLOT="([^"]+)"', test, re.M).group(1)
    inbound = re.search(r'^INBOUND="([^"]+)"', test, re.M).group(1)
    acl, default = rules(template)
    ids = {r["id"] for r in acl}
    bad = 0
    if default != "deny":
        print(f"{TEMPLATE}: default_permission is {default}; the page says deny")
        bad += 1
    cases = []
    for who, op, key, source, end, rule in CASES:
        if source not in test:
            print(f"{TEST}: no longer uses {source}; the page shows it")
            bad += 1
        if rule and rule not in ids:
            print(f"{TEMPLATE}: no rule {rule}; the page names it")
            bad += 1
        cases.append({"who": who, "op": op, "key": key.format(slot=slot, inbound=inbound), "end": end, "rule": rule})
    zenoh = re.search(r"image: eclipse/zenoh:([0-9.]+)@sha256:", compose).group(1)
    with open(os.path.join(OUT, "hero.json"), "w") as f:
        json.dump({"slot": slot, "inbound": inbound, "default": default, "rules": acl, "cases": cases, "zenoh": zenoh}, f, indent=1)

    contract = read("docs/partner-contract.md")
    section = contract[contract.index("## The seven requirements") :]
    section = section[: section.index("\n## ", 5)]
    services = re.split(r"^\S", compose[compose.index("\nservices:") + 10 :], maxsplit=1, flags=re.M)[0]
    measured = {
        "containers": str(len(re.findall(r"^  [a-z0-9-]+:\s*$", services, re.M))),
        "rules": str(len(acl)),
        "sdks": str(len([d for d in os.listdir(os.path.join(ROOT, "clients/connect")) if os.path.isdir(os.path.join(ROOT, "clients/connect", d))])),
        "requirements": str(len(re.findall(r"^\d+\. \*\*", section, re.M))),
    }
    page = read("site/index.html")
    stated = dict(re.findall(r'data-measure="([a-z0-9-]+)">([^<]*)<', page))
    for key, value in measured.items():
        if stated.get(key) != value:
            print(f"site/index.html: {key} says {stated.get(key)}, the tree gives {value}")
            bad += 1
    for key in stated.keys() - measured.keys():
        print(f'site/index.html: data-measure="{key}" is not measured by site/build.py')
        bad += 1
    if bad:
        return 1
    print("site: hero cases found in the test and the template; numbers:", ", ".join(f"{k}={v}" for k, v in measured.items()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
