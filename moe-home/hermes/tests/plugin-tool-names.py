#!/usr/bin/env python3
"""Every tool name Moe's own Hermes plugins register, read out of their source.

The gate's `BUILTIN` table in `hooks/confirm-send.sh` is a hand-written list,
and a Moe plugin tool missing from it is classified `unknown`, which puts a
"This is not a tool Moe recognises" dialog in front of the person — over one
of Moe's own tools. That has now happened three times, each time found by the
owner rather than by a test:

    moe_followups      2026-09-06   "stop reminding me about that"
    cronjob_manage     2026-09-11   "check in on me in five minutes"
    connections_list   2026-09-20   "are you connected to my gmail and github?"

A list that is kept in step by remembering is a list that goes out of step.
`test-confirm-hook.sh` runs this, and requires the gate to classify every name
it prints as something other than `unknown`, so the next omission is a red
suite here instead of a dialog there.

    plugin-tool-names.py <plugins-dir>

Only names that are LITERAL in the source are printed. The per-connector
`<name>_<verb>` tools are built in a loop from the connector list and have no
literal to read; they are declared by the connector manifests, which the gate
reads directly, so they are covered and are not this file's business.

Deliberately reads the source rather than importing it: importing a plugin
runs its module body, which on this Mac reaches Hermes, the person's config
and their connectors. A test must not need any of that to be true.
"""
import ast
import os
import sys


def _module_level_assignments(tree):
    """`NAME = "..."` and `NAME = {... "name": "..." ...}` at module level.

    Module level only. A local of the same name inside some function is not a
    declaration of anything — an earlier draft of this file walked the whole
    tree and read a synthetic module name out of a function body, which would
    have made the test demand that the gate know a tool that does not exist.
    """
    consts, schemas = {}, {}
    for node in tree.body:
        if not isinstance(node, ast.Assign) or len(node.targets) != 1:
            continue
        target = node.targets[0]
        if not isinstance(target, ast.Name):
            continue
        if isinstance(node.value, ast.Constant) and isinstance(node.value.value, str):
            consts[target.id] = node.value.value
        elif isinstance(node.value, ast.Dict):
            for key, value in zip(node.value.keys, node.value.values):
                if (isinstance(key, ast.Constant) and key.value == "name"
                        and isinstance(value, ast.Constant) and isinstance(value.value, str)):
                    schemas[target.id] = value.value
    return consts, schemas


def _parse(path):
    try:
        return ast.parse(open(path, encoding="utf-8", errors="replace").read(), path)
    except (OSError, SyntaxError):
        return None


def _sibling_aliases(tree):
    """`from . import location as _location` → {"_location": "location"}."""
    out = {}
    # Anywhere in the module: moe-screen imports them inside register().
    for node in ast.walk(tree):
        if isinstance(node, ast.ImportFrom) and node.level == 1 and not node.module:
            for a in node.names:
                out[a.asname or a.name] = a.name
    return out


def _registered(tree, consts, schemas, siblings=None):
    """Tool names this module registers, as literals; unresolvable ones skipped.

    `siblings` maps a sibling module's alias to its constants, so
    `name=_location.TOOL_NAME` resolves — moe-screen registered moe_location
    and moe_open_settings that way, and neither was ever read here, so the
    gate's table missed both and nothing went red (2026-11-14).
    """
    siblings = siblings or {}

    def resolve(node):
        if isinstance(node, ast.Constant) and isinstance(node.value, str):
            return node.value                      # register_tool("blueprint_list", …)
        if isinstance(node, ast.Name):
            return consts.get(node.id)             # register_tool(name=CONNECTIONS_TOOL, …)
        if (isinstance(node, ast.Attribute) and isinstance(node.value, ast.Name)
                and node.value.id in siblings):    # …name=_location.TOOL_NAME
            return siblings[node.value.id].get(node.attr)
        if isinstance(node, ast.Subscript):        # …=_followups.TOOL_SCHEMA["name"]
            key = node.slice
            holder = node.value
            if (isinstance(key, ast.Constant) and key.value == "name"
                    and isinstance(holder, ast.Attribute)):
                return schemas.get(holder.attr)
            if (isinstance(key, ast.Constant) and key.value == "name"
                    and isinstance(holder, ast.Name)):
                return schemas.get(holder.id)
        return None

    found = []
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        func = node.func
        called = func.attr if isinstance(func, ast.Attribute) else getattr(func, "id", "")
        if called != "register_tool":
            continue
        arg = next((kw.value for kw in node.keywords if kw.arg == "name"), None)
        if arg is None and node.args:
            arg = node.args[0]
        name = resolve(arg) if arg is not None else None
        if name:
            found.append(name)
    return found


def python_files(root):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(d for d in dirnames if d not in ("tests", "__pycache__"))
        for filename in sorted(filenames):
            if filename.endswith(".py"):
                yield os.path.join(dirpath, filename)


def tool_names(root):
    """Sorted tool names every plugin under `root` registers."""
    trees = [(p, _parse(p)) for p in python_files(root)]
    trees = [(p, t) for p, t in trees if t is not None]
    # Constants stay with their own module; a schema dict is shared, because a
    # plugin may register a tool by a schema a sibling module owns (moe-screen
    # registers its follow-ups tool as `_followups.TOOL_SCHEMA["name"]`).
    per_file, schemas = {}, {}
    for path, tree in trees:
        consts, file_schemas = _module_level_assignments(tree)
        per_file[path] = consts
        schemas.update(file_schemas)
    names = set()
    for path, tree in trees:
        here = os.path.dirname(path)
        siblings = {alias: per_file.get(os.path.join(here, mod + ".py"), {})
                    for alias, mod in _sibling_aliases(tree).items()}
        names.update(_registered(tree, per_file[path], schemas, siblings))
    return sorted(names)


def main(argv):
    root = argv[1] if len(argv) > 1 else "."
    if not os.path.isdir(root):
        sys.stderr.write("plugin-tool-names.py: %s is not a directory\n" % root)
        return 2
    names = tool_names(root)
    if not names:
        # Silence here would make the test that reads this pass over nothing.
        sys.stderr.write("plugin-tool-names.py: no register_tool calls under %s\n" % root)
        return 1
    print("\n".join(names))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
