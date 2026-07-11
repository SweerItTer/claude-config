#!/usr/bin/env python3
"""Minimal YAML parser for SeaPhone build configs.

DEPENDENCY-FREE: standard library only (no PyYAML).

Supports the subset used by building-config-*.yaml:
  - top-level `key: value`
  - top-level `key: [a, b, c]` flow list
  - one level of nested mapping under a `key:` with indented children
  - `#` comments and blank lines

Unsupported YAML features (multi-line strings, anchors, flow maps, deep
nesting, etc.) cause an explicit error with a line number rather than a
silent wrong parse.

Output: shell `KEY=value` assignments on stdout, suitable for
  eval "$(python3 yaml_parse.py config.yaml)"

Mapping rules to bash:
  - top-level `key: value`          -> KEY='value'            (string, dequoted)
  - top-level `key: [a, b, c]`      -> KEY='a b c'            (space-joined)
  - nested `parent:\n  child: v`    -> PARENT_CHILD='v'
  - nested `parent:\n  child: [a,b]`-> PARENT_CHILD='a b'

Keys are uppercased; `-` in keys becomes `_` (cross_compile_prefix -> CROSS_COMPILE_PREFIX).
"""

import sys


def die(msg, path, lineno):
    sys.stderr.write("%s:%d: %s\n" % (path, lineno, msg))
    sys.exit(1)


def dequote(v):
    v = v.strip()
    if len(v) >= 2 and ((v[0] == '"' and v[-1] == '"') or
                        (v[0] == "'" and v[-1] == "'")):
        return v[1:-1]
    return v


def parse_flow_list(v):
    # v like "[a, b, c]" or "[a,b,c]"
    v = v.strip()
    if not (v.startswith("[") and v.endswith("]")):
        return None
    inner = v[1:-1].strip()
    if not inner:
        return []
    return [dequote(x) for x in inner.split(",")]


def shell_quote(v):
    # Single-quote wrap; escape embedded single quotes as '\''
    return "'" + v.replace("'", "'\\''") + "'"


def emit(key, value):
    print("%s=%s" % (key, shell_quote(value)))


def parse(path):
    out = {}
    nested_key = None
    with open(path, "r", encoding="utf-8") as fp:
        lines = fp.readlines()
    for i, raw in enumerate(lines, start=1):
        line = raw.rstrip("\n")
        # strip comments (only when # starts a token preceded by whitespace or
        # at line start; tolerate inline-after-space comments)
        stripped = line.rstrip()
        # remove full-line comment
        if stripped.lstrip().startswith("#"):
            continue
        if not stripped.strip():
            nested_key = None  # blank line ends a nested block
            continue

        indent = len(line) - len(line.lstrip(" "))
        body = line.strip()

        if ":" not in body:
            die("expected 'key: value' or 'key:' (no colon found): %r" % body,
                path, i)

        key, _, val = body.partition(":")
        key = key.strip()
        if not key:
            die("empty key before colon: %r" % body, path, i)
        key_norm = key.upper().replace("-", "_")

        val = val.strip()

        if indent == 0:
            # top-level
            nested_key = None
            if val == "":
                # nested mapping follows
                nested_key = key_norm
                continue
            flow = parse_flow_list(val)
            if flow is not None:
                out[key_norm] = " ".join(flow)
            else:
                out[key_norm] = dequote(val)
        else:
            # indented line: must belong to a nested block
            if nested_key is None:
                die("indented line with no open mapping: %r" % body, path, i)
            sub_key = key_norm
            full = "%s_%s" % (nested_key, sub_key)
            if val == "":
                die("only one level of nesting supported (saw nested "
                    "'%s:'): %r" % (key, body), path, i)
            flow = parse_flow_list(val)
            if flow is not None:
                out[full] = " ".join(flow)
            else:
                out[full] = dequote(val)
    return out


def main(argv):
    if len(argv) != 2:
        sys.stderr.write("usage: yaml_parse.py <config.yaml>\n")
        return 2
    parsed = parse(argv[1])
    for k, v in parsed.items():
        emit(k, v)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
