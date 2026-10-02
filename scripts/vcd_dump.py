#!/usr/bin/env python3
"""Print selected signals of a VCD file per time step (debug helper for formal traces).

Usage: python scripts/vcd_dump.py trace.vcd sig1 sig2 ...
A signal matches if its full hierarchical name ends with the given text.
"""

import sys


def main():
    path, wanted = sys.argv[1], sys.argv[2:]
    ids, names, scope = {}, {}, []
    vals, rows, t = {}, [], None
    with open(path) as f:
        for line in f:
            tok = line.split()
            if not tok:
                continue
            if tok[0] == "$scope":
                scope.append(tok[2])
            elif tok[0] == "$upscope":
                scope.pop()
            elif tok[0] == "$var":
                full = ".".join(scope + [tok[4]])
                for w in wanted:
                    if full.endswith(w) and tok[3] not in ids:
                        ids[tok[3]] = w
            elif tok[0].startswith("#"):
                if t is not None:
                    rows.append((t, dict(vals)))
                t = int(tok[0][1:])
            elif tok[0][0] in "01xz" and len(tok) == 1:
                if tok[0][1:] in ids:
                    vals[ids[tok[0][1:]]] = tok[0][0]
            elif tok[0][0] == "b" and len(tok) == 2 and tok[1] in ids:
                v = tok[0][1:]
                vals[ids[tok[1]]] = hex(int(v, 2)) if set(v) <= {"0", "1"} else v
    if t is not None:
        rows.append((t, dict(vals)))
    for t, v in rows:
        print(t, " ".join(f"{w}={v.get(w, '?')}" for w in wanted))


if __name__ == "__main__":
    main()
