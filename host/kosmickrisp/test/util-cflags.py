#!/usr/bin/env python3
"""Print the compiler flags Mesa's build used for src/util/u_queue.c (from compile_commands.json),
with relative include paths made absolute: test/util_queue_finish.c is built with them.
Usage: util-cflags.py <mesa build dir>"""
import json
import shlex
import sys

build = sys.argv[1]
for entry in json.load(open(build + '/compile_commands.json')):
    if not entry['file'].endswith('src/util/u_queue.c'):
        continue
    flags, skip = [], False
    for arg in shlex.split(entry['command'])[1:]:
        if skip:
            skip = False
        elif arg in ('-o', '-c', '-MF', '-MQ'):
            skip = True
        elif arg == '-MD' or arg.endswith('u_queue.c'):
            pass
        else:
            if arg.startswith('-I') and not arg.startswith('-I/'):
                arg = '-I' + entry['directory'] + '/' + arg[2:]
            flags.append(arg)
    print(' '.join(shlex.quote(f) for f in flags))
    sys.exit(0)
sys.exit('u_queue.c not in ' + build + '/compile_commands.json')
