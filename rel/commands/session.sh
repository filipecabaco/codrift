#!/bin/sh
set -e
exec "$RELEASE_ROOT/bin/codrift" eval 'Codrift.CLI.Main.run(["session" | System.argv()])' -- "$@"
