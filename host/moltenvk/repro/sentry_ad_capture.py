#!/usr/bin/env python3
"""Check real MoltenVK diagnostic capture boundaries, not the Bodycam compiler crash."""
import pathlib
import re
import struct
import subprocess
import sys


def source_for(byte_count, line_count, library):
    lines = [
        "#include <metal_stdlib>",
        "using namespace metal;",
        "kernel void main0(device uint* result [[buffer(0)]],",
        "                  uint tid [[thread_index_in_threadgroup]])",
        "{",
    ]
    body = ["    result[0] = sentryAdCaptureMissing;"] if library else [
        "    threadgroup uint data[11616];",
        "    for (uint i = tid; i < 11616; i += 256) data[i] = i;",
        "    threadgroup_barrier(mem_flags::mem_threadgroup);",
        "    atomic_fetch_add_explicit((device atomic_uint*)result, data[(tid + 17) % 11616], memory_order_relaxed);",
    ]
    padding_start = len(lines)
    padding_end = line_count - len(body) - 1
    lines += ["// ad-padding"] * (padding_end - len(lines))
    middle = line_count // 2
    lines[middle] = "// sentryAdCaptureMiddle " + "x" * 1024
    lines += body + ["}"]
    remaining = byte_count - sum(len(line) + 1 for line in lines)
    if remaining < 0:
        raise ValueError("requested source is too small")
    padding = [i for i in range(padding_start, padding_end) if i != middle]
    each, extra = divmod(remaining, len(padding))
    for n, i in enumerate(padding):
        lines[i] += "x" * (each + (n < extra))
    source = "\n".join(lines) + "\n"
    if len(source.encode()) != byte_count or len(source.splitlines()) != line_count:
        raise ValueError("synthetic source dimensions do not match")
    return source


def check(log, source, byte_count, line_count, library, full):
    prefix = "[mvk-msl] "
    diagnostic = [line[len(prefix):] for line in log.splitlines() if line.startswith(prefix)]
    header = "// Library failure MSL " if library else "// Pipeline failure MSL stage=5 "
    starts = [i for i, line in enumerate(diagnostic) if line.startswith(header)]
    if not full:
        if any("capture=full" in diagnostic[i] for i in starts):
            raise ValueError("over-budget source was captured in full")
        if not library and (len(starts) != 1 or "capture=excerpt" not in diagnostic[starts[0]]):
            raise ValueError("over-budget pipeline source did not retain an excerpt")
        if "sentryAdCaptureMiddle" in "\n".join(diagnostic):
            raise ValueError("over-budget source unexpectedly retained its middle")
        if not diagnostic:
            raise ValueError("missing failure diagnostics")
        return
    if len(starts) != 1:
        raise ValueError("missing unique complete-source header")
    start = starts[0]
    if f"bytes={byte_count} lines={line_count} capture=full" not in diagnostic[start]:
        raise ValueError("source budget selected an excerpt or reported incorrect dimensions")
    captured = []
    record = diagnostic[start] + "\n"
    for line in diagnostic[start + 1:]:
        match = re.fullmatch(r"(\d+): (.*)", line)
        if match is None:
            break
        if int(match[1]) != len(captured) + 1:
            raise ValueError("numbered source has a gap")
        captured.append(match[2])
        record += line + "\n"
    if "\n".join(captured) + "\n" != source:
        raise ValueError("captured source differs, is incomplete, or truncates a long middle line")
    # The scanner keeps a bounded numbered record before reconstructing a <=256 KiB
    # attachment; extra/context fields are only short summaries on the server.
    if len(record.encode()) > 393216:
        raise ValueError("complete numbered source exceeds the launcher's 384 KiB capture cap")


def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: sentry_ad_capture.py <capture executable> <output directory>")
    executable = pathlib.Path(sys.argv[1]).resolve()
    output = pathlib.Path(sys.argv[2])
    output.mkdir(parents=True, exist_ok=True)
    failures = 0
    for library in (False, True):
        mode = "library" if library else "pipeline"
        for byte_count, line_count, full in (
            (112824, 1137, True),  # Exact STEAMAC-AD source dimensions, not its missing contents.
            (262144, 8192, True),  # Both inclusive source limits plus numbered-line overhead.
            (262145, 8192, False),
            (262144, 8193, False),
        ):
            name = f"{mode}-{byte_count}-{line_count}"
            source = source_for(byte_count, line_count, library)
            (output / f"{name}.metal").write_text(source)
            module = struct.pack("<I", 0x19960412) + source.encode() + b"\0"
            module += b"\0" * (-len(module) % 4)
            module_path = output / f"{name}.msl-module"
            module_path.write_bytes(module)
            run = subprocess.run([str(executable), str(module_path), mode], capture_output=True, text=True)
            (output / f"{name}.log").write_text(run.stderr)
            try:
                if run.returncode:
                    raise ValueError(f"harness exited {run.returncode}: {run.stdout.strip()} {run.stderr[-1000:]}")
                check(run.stderr, source, byte_count, line_count, library, full)
            except ValueError as error:
                print(f"FAIL {name}: {error}; log: {output / (name + '.log')}")
                failures += 1
            else:
                print(f"OK {name}: {'complete replayable source within 384 KiB' if full else 'bounded excerpt'}")
    return bool(failures)


if __name__ == "__main__":
    raise SystemExit(main())
