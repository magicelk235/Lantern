"""Chunk decoder of omp's Python RPC client, for conformance fixtures.

`_MAX_*`/`_RPC_CHUNK_PAYLOAD_BYTES`, `_PendingRpcChunks` and `_RpcFrameDecoder` are copied verbatim
from python/omp-rpc/src/omp_rpc/client.py at can1357/oh-my-pi v18.3.1 (MIT, see LICENSE); only the
imports and the `RpcError`/`JsonObject` stand-ins below are local.
"""

from __future__ import annotations

import base64
import binascii
import json
from dataclasses import dataclass, field
from typing import Any, cast

JsonObject = dict[str, Any]


class RpcError(Exception):
    pass


_MAX_RPC_FRAME_BYTES = 1024 * 1024
_MAX_RPC_REASSEMBLED_BYTES = 64 * 1024 * 1024
_RPC_CHUNK_PAYLOAD_BYTES = 256 * 1024


@dataclass(slots=True)
class _PendingRpcChunks:
    chunk_id: str
    count: int
    byte_length: int
    next_index: int = 0
    chunks: list[bytes] = field(default_factory=list)
    received_bytes: int = 0


class _RpcFrameDecoder:
    def __init__(self) -> None:
        self._pending: _PendingRpcChunks | None = None

    def push(self, value: object) -> JsonObject | None:
        if not isinstance(value, dict) or value.get("type") != "rpc_chunk":
            if self._pending is not None:
                raise RpcError("RPC chunk sequence was interrupted")
            if not isinstance(value, dict):
                raise RpcError("RPC frame must be a JSON object")
            return cast(JsonObject, value)

        chunk_id = value.get("chunkId")
        index = value.get("index")
        count = value.get("count")
        byte_length = value.get("byteLength")
        data = value.get("data")
        max_chunk_count = (
            _MAX_RPC_REASSEMBLED_BYTES + _RPC_CHUNK_PAYLOAD_BYTES - 1
        ) // _RPC_CHUNK_PAYLOAD_BYTES
        if (
            not isinstance(chunk_id, str)
            or not chunk_id
            or len(chunk_id) > 128
            or not isinstance(index, int)
            or isinstance(index, bool)
            or not isinstance(count, int)
            or isinstance(count, bool)
            or not isinstance(byte_length, int)
            or isinstance(byte_length, bool)
            or index < 0
            or count < 2
            or count > max_chunk_count
            or index >= count
            or byte_length < _MAX_RPC_FRAME_BYTES
            or byte_length > _MAX_RPC_REASSEMBLED_BYTES
            or not isinstance(data, str)
            or not data
        ):
            raise RpcError("Invalid RPC chunk metadata")
        try:
            chunk = base64.b64decode(data, validate=True)
        except (binascii.Error, ValueError) as exc:
            raise RpcError("Invalid RPC chunk data") from exc
        if base64.b64encode(chunk).decode("ascii") != data:
            raise RpcError("Invalid RPC chunk data")
        if len(chunk) > _RPC_CHUNK_PAYLOAD_BYTES:
            raise RpcError("RPC chunk payload exceeds the transport limit")

        if self._pending is None:
            if index != 0:
                raise RpcError("RPC chunk sequence must start at index 0")
            self._pending = _PendingRpcChunks(chunk_id, count, byte_length)
        pending = self._pending
        if (
            pending.chunk_id != chunk_id
            or pending.count != count
            or pending.byte_length != byte_length
            or pending.next_index != index
        ):
            raise RpcError("RPC chunk sequence mismatch")
        pending.chunks.append(chunk)
        pending.received_bytes += len(chunk)
        pending.next_index += 1
        if pending.received_bytes > pending.byte_length:
            raise RpcError("RPC chunk sequence exceeds its declared length")
        if pending.next_index < pending.count:
            return None
        if pending.received_bytes != pending.byte_length:
            raise RpcError("RPC chunk sequence length mismatch")

        self._pending = None
        try:
            decoded = b"".join(pending.chunks).decode("utf-8")
            frame = json.loads(decoded)
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise RpcError("Failed to decode reassembled RPC frame") from exc
        if not isinstance(frame, dict):
            raise RpcError("RPC frame must be a JSON object")
        return cast(JsonObject, frame)
