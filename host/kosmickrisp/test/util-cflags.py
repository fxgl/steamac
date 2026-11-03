#!/usr/bin/env python3
"""Print the compiler flags Mesa's build used for one of its sources (default src/util/u_queue.c, from
compile_commands.json), with relative include paths made absolute: the tests in this directory are built
with them (util_queue_finish.c with u_queue.c's, nir_object_ids.c with src/compiler/nir/nir_serialize.c's).
Usage: util-cflags.py <mesa build dir> [source path suffix]"""
import json
import shlex
import sys

build = sys.argv[1]
source = sys.argv[2] if len(sys.argv) > 2 else 'src/util/u_queue.c'
for entry in json.load(open(build + '/compile_commands.json')):
    if not entry['file'].endswith(source):
        continue
    flags, skip = [], False
    for arg in shlex.split(entry['command'])[1:]:
        if skip:
            skip = False
        elif arg in ('-o', '-c', '-MF', '-MQ'):
            skip = True
        elif arg == '-MD' or arg.endswith(source):
            pass
        else:
            if arg.startswith('-I') and not arg.startswith('-I/'):
                arg = '-I' + entry['directory'] + '/' + arg[2:]
            flags.append(arg)
    print(' '.join(shlex.quote(f) for f in flags))
    sys.exit(0)
sys.exit(source + ' not in ' + build + '/compile_commands.json')
