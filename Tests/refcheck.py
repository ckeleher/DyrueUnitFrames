#!/usr/bin/env python3
"""Cross-file reference check for the DyrueUnitFrames namespace.

The addon shares state through a single `ns` table populated across ~28 files.
Lua will not tell you about a typo in `ns.PartyGroup:UpdateVisiblity()` until
that line actually runs, which might be in a raid. This walks every file,
builds the set of things that are actually defined on `ns` and on each module
registered into it, and reports every call that has no matching definition.

Usage: python refcheck.py <addon root>
"""
import os
import re
import sys
from collections import defaultdict

# `local Foo = {}` ... `ns.Foo = Foo`  (module registration)
RE_NS_ASSIGN = re.compile(r'^\s*ns\.(\w+)\s*=\s*(\w+)\s*$', re.M)
# `function Foo:Bar(` / `function Foo.Bar(`
RE_MODULE_FN = re.compile(r'^\s*function\s+(\w+)[:.](\w+)\s*\(', re.M)
# `Foo.Bar = function` / `Foo.Bar = <value>`
RE_MODULE_FIELD = re.compile(r'^\s*(\w+)\.(\w+)\s*=\s*', re.M)
# `function ns:Bar(` / `function ns.Bar(`
RE_NS_FN = re.compile(r'^\s*function\s+ns[:.](\w+)\s*\(', re.M)
# `ns.Foo = { ... }` inline table
RE_NS_TABLE = re.compile(r'^\s*ns\.(\w+)\s*=\s*\{', re.M)
# `ns.foo = <anything>` simple field
RE_NS_SIMPLE = re.compile(r'^\s*ns\.(\w+)\s*=', re.M)

# Usages
RE_USE_NS_METHOD = re.compile(r'\bns[:.](\w+)\s*\(')
RE_USE_MODULE_METHOD = re.compile(r'\bns\.(\w+)[:.](\w+)\s*\(')

# Locals that alias a module: `local Foo = ns.Foo`
RE_LOCAL_ALIAS = re.compile(r'^\s*local\s+(\w+)\s*=\s*ns\.(\w+)\s*$', re.M)

BUILTIN_NS = {
    # populated by Core.lua at runtime rather than by a literal assignment
    "db", "frames", "elements", "elementOrder", "configSerial", "version",
    "addon", "L", "locales", "optionsFrame",
}


def scan(root):
    files = []
    for base, dirs, names in os.walk(root):
        dirs[:] = [d for d in dirs if d not in (".git", "Libs", "Probe")]
        for n in sorted(names):
            if n.endswith(".lua"):
                files.append(os.path.join(base, n))

    sources = {}
    for path in files:
        with open(path, encoding="utf-8-sig") as fh:
            sources[path] = fh.read()

    # Pass 1 — what is defined?
    module_of_local = {}          # local table name -> ns module name
    ns_fields = set(BUILTIN_NS)
    module_members = defaultdict(set)   # ns module name -> {member}

    for path, src in sources.items():
        local_to_ns = {}
        for m in RE_NS_ASSIGN.finditer(src):
            ns_name, local_name = m.group(1), m.group(2)
            ns_fields.add(ns_name)
            local_to_ns[local_name] = ns_name
            module_of_local.setdefault(local_name, ns_name)
        for m in RE_NS_TABLE.finditer(src):
            ns_fields.add(m.group(1))
        for m in RE_NS_SIMPLE.finditer(src):
            ns_fields.add(m.group(1))
        for m in RE_NS_FN.finditer(src):
            ns_fields.add(m.group(1))
        sources[path] = (src, local_to_ns)

    for path, (src, local_to_ns) in sources.items():
        # aliases like `local Compat = ns.Compat`
        for m in RE_LOCAL_ALIAS.finditer(src):
            local_to_ns[m.group(1)] = m.group(2)

        for m in RE_MODULE_FN.finditer(src):
            owner, member = m.group(1), m.group(2)
            ns_name = local_to_ns.get(owner) or module_of_local.get(owner)
            if ns_name:
                module_members[ns_name].add(member)
        for m in RE_MODULE_FIELD.finditer(src):
            owner, member = m.group(1), m.group(2)
            ns_name = local_to_ns.get(owner) or module_of_local.get(owner)
            if ns_name:
                module_members[ns_name].add(member)

    # Pass 2 — what is used?
    problems = []
    for path, (src, _) in sources.items():
        rel = os.path.relpath(path, root).replace("\\", "/")
        for i, line in enumerate(src.split("\n"), 1):
            stripped = line.strip()
            if stripped.startswith("--"):
                continue

            for m in RE_USE_MODULE_METHOD.finditer(line):
                mod, member = m.group(1), m.group(2)
                if mod not in ns_fields:
                    problems.append("%s:%d: ns.%s is never defined (ns.%s.%s)"
                                    % (rel, i, mod, mod, member))
                elif mod in module_members and member not in module_members[mod]:
                    problems.append("%s:%d: ns.%s has no member '%s'"
                                    % (rel, i, mod, member))

            for m in RE_USE_NS_METHOD.finditer(line):
                member = m.group(1)
                # skip `ns.Foo:Bar(` which the other regex already handled
                if re.search(r'\bns\.%s[:.]' % re.escape(member), line):
                    continue
                if member not in ns_fields:
                    problems.append("%s:%d: ns:%s is never defined" % (rel, i, member))

    return problems, ns_fields, module_members


def main(argv):
    root = argv[0] if argv else "."
    problems, ns_fields, module_members = scan(root)

    print("ns fields defined: %d" % len(ns_fields))
    print("modules with members: %d" % len(module_members))
    print()

    if problems:
        seen = set()
        for p in problems:
            if p not in seen:
                seen.add(p)
                print(p)
        print("\n%d problem(s)" % len(seen))
        return 1

    print("No dangling ns references.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
