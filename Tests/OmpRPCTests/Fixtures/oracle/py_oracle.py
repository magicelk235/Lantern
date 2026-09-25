"""Verdicts of omp's Python RPC client for the conformance cases (invoked by generate.ts).

    python3 -B py_oracle.py <dir>

Decodes every <dir>/<n>.bin the way omp-rpc's RpcClient reads stdout (text mode with universal
newlines and errors="replace", str.strip(), skip empty lines, json.loads, _RpcFrameDecoder.push) and
prints a JSON array with one verdict per file, ordered by <n>.
"""

from __future__ import annotations

import io
import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "reference"))

from omp_rpc_frame_decoder import RpcError, _RpcFrameDecoder  # noqa: E402


def verdict(data: bytes) -> dict[str, object]:
    decoder = _RpcFrameDecoder()
    frames = 0
    try:
        for line in io.TextIOWrapper(io.BytesIO(data), encoding="utf-8", errors="replace"):
            stripped = line.strip()
            if not stripped:
                continue
            if decoder.push(json.loads(stripped)) is not None:
                frames += 1
    except (RpcError, ValueError) as error:
        return {"ok": False, "frameCount": frames, "error": str(error)}
    return {"ok": True, "frameCount": frames, "pendingAtEOF": decoder._pending is not None}


def main() -> None:
    directory = sys.argv[1]
    names = sorted((name for name in os.listdir(directory) if name.endswith(".bin")), key=lambda name: int(name[:-4]))
    verdicts = []
    for name in names:
        with open(os.path.join(directory, name), "rb") as file:
            verdicts.append(verdict(file.read()))
    json.dump(verdicts, sys.stdout)


if __name__ == "__main__":
    main()
