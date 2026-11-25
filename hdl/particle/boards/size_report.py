#!/usr/bin/env python3
"""Print an ECP5 size report from Yosys's `stat -json` output.

The design must be synthesized with `synth_ecp5 -noflatten`, so each module
keeps its own cells. Usage:

    size_report.py size_stat.json [--top ulx3s_board]

Two tables are printed:
  * Particle cores: each kind of core (a module named ParticleCpuCore*), how
    many there are, and its cells broken down by submodule.
  * The whole design: every module, how many instances it has, its own cells
    (excluding submodules) and those cells times the instance count.
"""

import argparse
import json
import sys

# Columns: (heading, cell types added together).
COLUMNS = [
    ("LUT4", ("LUT4",)),
    ("CCU2C", ("CCU2C",)),
    ("FF", ("TRELLIS_FF",)),
    ("LUTRAM", ("TRELLIS_DPR16X4",)),
    ("DP16KD", ("DP16KD",)),
    ("MULT18", ("MULT18X18D",)),
]


def clean(name):
    return name[1:] if name.startswith("\\") else name


def load(path):
    with open(path) as f:
        data = json.load(f)
    modules = {}
    for name, info in data["modules"].items():
        modules[clean(name)] = {clean(k): v for k, v in info.get("num_cells_by_type", {}).items()}
    return modules


def own(modules, name):
    """The module's own cells, as one number per column."""
    cells = modules[name]
    return [sum(cells.get(t, 0) for t in types) for _, types in COLUMNS]


def children(modules, name):
    """Submodule name -> instance count."""
    return {k: v for k, v in modules[name].items() if k in modules}


def total(modules, name):
    """The module's cells including all its submodules."""
    sums = own(modules, name)
    for child, count in children(modules, name).items():
        sums = [a + b * count for a, b in zip(sums, total(modules, child))]
    return sums


def instance_counts(modules, top):
    counts = {}

    def walk(name, mult):
        counts[name] = counts.get(name, 0) + mult
        for child, count in children(modules, name).items():
            walk(child, mult * count)

    walk(top, 1)
    return counts


def row(label, values, width):
    return f"{label:<{width}}" + "".join(f"{v:>9,}" for v in values)


def heading(first, width):
    return f"{first:<{width}}" + "".join(f"{h:>9}" for h, _ in COLUMNS)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("stat_json")
    parser.add_argument("--top", default="ulx3s_board")
    args = parser.parse_args()

    modules = load(args.stat_json)
    if args.top not in modules:
        sys.exit(f"[FAIL] top module {args.top} not in {args.stat_json}")
    counts = instance_counts(modules, args.top)
    design = total(modules, args.top)

    cores = sorted(n for n in counts if n.startswith("ParticleCpuCore"))
    if cores:
        print("Particle cores (each; including submodules)")
        width = 30
        for core in cores:
            print()
            print(heading(f"{core} x{counts[core]}", width))
            print(row("  core logic", own(modules, core), width))
            for child, count in sorted(children(modules, core).items()):
                label = f"  {child}" + (f" x{count}" if count > 1 else "")
                print(row(label, [v * count for v in total(modules, child)], width))
            print(row("  total", total(modules, core), width))
        print()
        core_sum = [0] * len(COLUMNS)
        for core in cores:
            core_sum = [a + b * counts[core] for a, b in zip(core_sum, total(modules, core))]
        n = sum(counts[c] for c in cores)
        print(row(f"All {n} cores", core_sum, width))
        share = 100.0 * core_sum[0] / design[0] if design[0] else 0.0
        print(f"  ({share:.0f}% of the design's LUT4s)")
        print()

    print("Whole design (own cells, excluding submodules)")
    width = 36
    print(heading("Module (instances)", width))
    for name in sorted(counts, key=lambda n: -own(modules, n)[0] * counts[n]):
        values = own(modules, name)
        if not any(values):
            continue
        label = f"{name} x{counts[name]}"
        print(row(label, [v * counts[name] for v in values], width))
    print(row("Total", design, width))


if __name__ == "__main__":
    main()
