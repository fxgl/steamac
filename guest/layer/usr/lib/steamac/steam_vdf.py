"""Offset-preserving VDF and atomic file-write helpers for the Steam hooks."""
import os
import re
import tempfile


def vdf_unquote(token):
    if not token.startswith('"'):
        return token
    return re.sub(r'\\([\\"nrt])', lambda m: {"n": "\n", "r": "\r", "t": "\t"}.get(m[1], m[1]), token[1:-1])


def vdf_quote(value):
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t") + '"'


def vdf_entries(text, *, strict=False):
    """Return scalar (value, key start, value start, value end) spans and block close/key offsets.

    Keys are case-insensitive paths. Strict mode rejects repeated keys even when
    one or both values are blocks; otherwise only repeated scalars are rejected.
    """
    tokens, end = [], 0
    for m in re.finditer(r'//[^\n]*|"(?:\\.|[^"\\])*"|[{}]|[^\s{}"]+', text):
        # finditer skips unmatched quotes. Never rewrite a partially tokenized file.
        if text[end:m.start()].strip():
            raise ValueError("invalid VDF token")
        end = m.end()
        if not m[0].startswith("//"):
            tokens.append(m)
    if text[end:].strip():
        raise ValueError("invalid VDF token")

    values, blocks, starts, stack = {}, {}, {}, []
    i = 0
    while i < len(tokens):
        token = tokens[i]
        if token[0] == "}":
            if not stack:
                raise ValueError("unbalanced VDF closing brace")
            blocks[tuple(stack)] = token.start()
            stack.pop()
            i += 1
            continue
        if token[0] == "{" or i + 1 == len(tokens):
            raise ValueError("incomplete VDF key/value")
        key = vdf_unquote(token[0]).lower()
        path = (*stack, key)
        if strict and (path in starts or path in values):
            raise ValueError("duplicate VDF key")
        value = tokens[i + 1]
        if value[0] == "{":
            stack.append(key)
            starts[path] = token.start()
        elif value[0] == "}":
            raise ValueError("missing VDF value")
        else:
            if path in values:
                raise ValueError("duplicate VDF value")
            values[path] = (vdf_unquote(value[0]), token.start(), value.start(), value.end())
        i += 2
    if stack:
        raise ValueError("unbalanced VDF opening brace")
    return values, blocks, starts


def atomic_write(path, text, *, mode=0o600):
    """Replace a file atomically, preserving its mode if it already exists."""
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as out:
            out.write(text)
        os.chmod(tmp, path.stat().st_mode & 0o777 if path.exists() else mode)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)
