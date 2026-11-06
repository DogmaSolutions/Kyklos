#!/usr/bin/env python3
"""validate-scenario.py <scenario.md> [workspace-root]

Lints a working-scenario file. A scenario declares the BOUNDED slice a task touches:
the SLNX modules in scope + their package producer->consumer edges. This linter is the guard against a
malformed OR fabricated scenario reaching the tooling — it checks that every declared .slnx actually EXISTS,
that edges reference only declared modules, and that the dependency graph is acyclic (a DAG).

Python (not bash) because the job is a markdown-table parse + a topological sort — unreasonable in pure bash.
Runs locally with the stdlib only (no network, no .NET), i.e. inside any ephemeral container. Exit 0 = valid.
"""
import os
import re
import sys

def main():
    if len(sys.argv) < 2:
        print("usage: validate-scenario.py <scenario.md> [workspace-root]", file=sys.stderr)
        return 2
    path = sys.argv[1]
    root = sys.argv[2] if len(sys.argv) > 2 else os.path.dirname(os.path.dirname(os.path.abspath(path)))
    try:
        text = open(path, encoding="utf-8").read()
    except OSError as e:
        print(f"  FAIL cannot read scenario file: {e}")
        print("\n== 0 passed, 1 failed ==")
        return 1

    npass = nfail = 0
    def ok(m):
        nonlocal npass; npass += 1; print(f"  ok   {m}")
    def bad(m):
        nonlocal nfail; nfail += 1; print(f"  FAIL {m}")
    warns = []
    def warn(m):
        warns.append(m)

    lines = text.splitlines()

    # --- frontmatter ---
    fm = {}
    if lines and lines[0].strip() == "---":
        for i in range(1, len(lines)):
            if lines[i].strip() == "---":
                break
            m = re.match(r'^(\w+):\s*(.*)$', lines[i])
            if m:
                fm[m.group(1)] = m.group(2).strip()
    (ok if fm.get("scenario") else bad)("frontmatter has non-empty 'scenario'")
    (ok if fm.get("description") else bad)("frontmatter has non-empty 'description'")

    # --- section slicer ---
    def section(title):
        out, grab = [], False
        for ln in lines:
            if re.match(r'^##\s+', ln):
                grab = ln.strip().lower().startswith("## " + title.lower())
                continue
            if grab:
                out.append(ln)
        return out

    # --- modules table ---
    modules = {}   # name -> dict(repo, slnx, role, package)
    for ln in section("modules in scope"):
        if not ln.strip().startswith("|"):
            continue
        cells = [c.strip() for c in ln.strip().strip("|").split("|")]
        if len(cells) < 5 or cells[0].lower() in ("name", "") or set(cells[0]) <= set("-: "):
            continue  # header / separator
        name, repo, slnx, role, package = cells[:5]
        if name in modules:
            bad(f"duplicate module name: {name}")
            continue
        modules[name] = dict(repo=repo, slnx=slnx, role=role, package=package)

    if modules:
        ok(f"parsed {len(modules)} module(s)")
    else:
        bad("no modules declared in '## Modules in scope'")

    for name, m in modules.items():
        # slnx must exist on disk (this is what rejects a fabricated file name)
        slnx_abs = m["slnx"] if os.path.isabs(m["slnx"]) else os.path.join(root, m["slnx"])
        (ok if os.path.isfile(slnx_abs) else bad)(f"module {name}: slnx exists ({m['slnx']})")
        # role
        if m["role"] not in ("library", "root-app"):
            bad(f"module {name}: role must be library|root-app (got '{m['role']}')")
        # library must carry a package id
        if m["role"] == "library" and (not m["package"] or m["package"] == "—"):
            bad(f"module {name}: a library must declare a non-empty package id")

    # --- relationships (edges) ---
    edges = []   # (producer, consumer)
    for ln in section("relationships"):
        s = ln.strip()
        if not s.startswith("- "):
            continue
        chain = [p.strip() for p in re.split(r'->|→', s[2:]) if p.strip()]
        for a, b in zip(chain, chain[1:]):
            edges.append((a, b))

    edge_ok = True
    for a, b in edges:
        for endp in (a, b):
            if endp not in modules:
                bad(f"edge references undeclared module: {endp}  (in '{a} -> {b}')")
                edge_ok = False
    if edges and edge_ok:
        ok(f"parsed {len(edges)} edge(s); all endpoints declared")
    elif not edges:
        warn("no relationships declared (single-solution / independent modules?)")

    # --- DAG check (Kahn topological sort) ---
    if edge_ok:
        indeg = {n: 0 for n in modules}
        adj = {n: [] for n in modules}
        for a, b in edges:
            adj[a].append(b); indeg[b] += 1
        queue = [n for n in modules if indeg[n] == 0]
        seen = 0
        while queue:
            n = queue.pop()
            seen += 1
            for c in adj[n]:
                indeg[c] -= 1
                if indeg[c] == 0:
                    queue.append(c)
        if seen == len(modules):
            ok("relationship graph is acyclic (DAG)")
        else:
            cyc = [n for n in modules if indeg[n] > 0]
            bad(f"relationship graph has a CYCLE (involving: {', '.join(sorted(cyc))})")

    # --- package resolution (soft): a library that produces nothing consumed is dead weight ---
    producers = {a for a, _ in edges}
    for name, m in modules.items():
        if m["role"] == "library" and name not in producers:
            warn(f"library {name} is not consumed by any edge (dead weight?)")

    # --- deploy groupings (optional): must reference declared modules only ---
    for ln in section("deploy groupings"):
        s = ln.strip()
        if not s.startswith("- "):
            continue
        for tok in re.findall(r'[A-Za-z0-9._-]+', s.split(":", 1)[-1]):
            if tok in modules or tok in ("pack", "together"):
                continue
        ok("deploy groupings parsed (optional, informational)")
        break

    for w in warns:
        print(f"  warn {w}")
    print(f"\n== {npass} passed, {nfail} failed ==")
    return 1 if nfail else 0

if __name__ == "__main__":
    sys.exit(main())
