#!/usr/bin/env python3
"""Build the effect index (src/agent_effects.json) by probing every distinct mod line on the open build.
Resumable; pass --reset to start over (e.g. after loading a different build or changing probe logic)."""
import sys
from rpc import call

reset = "--reset" in sys.argv
while True:
    r = call("probe_batch", budget=20, reset=reset)["result"]
    reset = False
    print(r, flush=True)
    if r["remaining"] <= 0:
        break
print(call("effect_stats")["result"] | {"statsMoved": "..."})
