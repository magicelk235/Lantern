/**
 * Regenerates ../conformance.json: golden omp RPC stdout streams plus the verdicts of omp's reference
 * decoders on them. OmpRPCTests (ConformanceTests.swift) replays every case through RPCFrameDecoder.
 *
 *   BUN_BE_BUN=1 omp run Tests/OmpRPCTests/Fixtures/oracle/generate.ts
 *
 * BUN_BE_BUN=1 makes the installed omp binary act as the Bun runtime it bundles, so the JSONL layer
 * is exactly the reader omp's own RpcClient uses.
 *
 * Oracles:
 * - TypeScript, normative: reference/rpc-frame.ts, verbatim from can1357/oh-my-pi v18.3.1
 *   (packages/coding-agent/src/modes/rpc/rpc-frame.ts, MIT), driven like RpcClient drives it:
 *   Bun.JSONL.parseChunk values -> RpcFrameDecoder.push. Its RpcFrameEncoder also produces the streams.
 * - Python, recorded for comparison: py_oracle.py over reference/omp_rpc_frame_decoder.py (verbatim
 *   decoder of python/omp-rpc v18.3.1).
 *
 * Streams are stored as line specs; long runs of a repeated 4-character unit are compressed to
 * [unit, count] segments. The Swift side rebuilds each stream and checks its sha256.
 */
import { createHash } from "node:crypto";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { MAX_RPC_FRAME_BYTES, MAX_RPC_REASSEMBLED_BYTES, RpcFrameDecoder, RpcFrameEncoder } from "./reference/rpc-frame";

/** rpc-frame.ts's RPC_CHUNK_PAYLOAD_BYTES (not exported). */
const CHUNK = 256 * 1024;

type Segment = string | [unit: string, count: number] | { bytes: string };
type LineSpec =
	| { base: number; replace?: [find: string, replacement: string]; crlf?: true; noNewline?: true }
	| { range: [start: number, end: number] }
	| { segments: Segment[] };

interface TsVerdict {
	ok: boolean;
	/** Indices into `frames` of the frames decoded (before the error, if any). */
	frames: number[];
	error?: string;
	/** "chunk": an RpcFrameDecoder rule (message compared exactly); "parse": JSONL/UTF-8/JSON failure. */
	errorKind?: "chunk" | "parse";
	/** Decoding ended while a chunk sequence was still open (the reference decoder has no end-of-stream check). */
	pendingAtEOF?: boolean;
}

// MARK: - Segments

function compress(text: string): Segment[] {
	const segments: Segment[] = [];
	let literal = "";
	let i = 0;
	while (i < text.length) {
		const unit = text.slice(i, i + 4);
		if (/^[\x20-\x7e]{4}$/.test(unit)) {
			let count = 1;
			while (text.startsWith(unit, i + count * 4)) count++;
			if (count >= 16) {
				if (literal) segments.push(literal);
				literal = "";
				segments.push([unit, count]);
				i += count * 4;
				continue;
			}
		}
		literal += text[i];
		i++;
	}
	if (literal) segments.push(literal);
	return segments;
}

function expand(segments: Segment[]): Buffer {
	return Buffer.concat(
		segments.map((segment) => {
			if (typeof segment === "string") return Buffer.from(segment, "utf8");
			if (Array.isArray(segment)) return Buffer.from(segment[0].repeat(segment[1]), "utf8");
			return Buffer.from(segment.bytes, "base64");
		}),
	);
}

function raw(...parts: Array<string | number[]>): LineSpec {
	return {
		segments: parts.map((part) => (typeof part === "string" ? part : { bytes: Buffer.from(part).toString("base64") })),
	};
}

// MARK: - Base stream

const baseLines: string[] = [];
const encoder = new RpcFrameEncoder();
function emit(frame: object): number {
	const first = baseLines.length;
	for (const line of encoder.encodeFrames(frame)) baseLines.push(line);
	return first;
}

/** Chunk boundaries 1…6 of this frame each split one multi-byte character, in every possible way. */
function straddlingFrame() {
	const splits: Array<[char: string, bytesBefore: number]> = [
		["é", 1],
		["€", 1],
		["€", 2],
		["😀", 1],
		["😀", 2],
		["😀", 3],
	];
	const frame = { id: "req_2", type: "response", command: "get_messages", success: true, data: { text: "" } };
	const lead = 'escapes \\ " \n \t / ✓ ';
	let text = lead;
	let offset = Buffer.byteLength(JSON.stringify(frame), "utf8") - 3 + Buffer.byteLength(JSON.stringify(lead), "utf8") - 2;
	splits.forEach(([char, before], k) => {
		const start = (k + 1) * CHUNK - before;
		text += "x".repeat(start - offset) + char;
		offset = start + Buffer.byteLength(char, "utf8");
	});
	// The last chunk carries 3n+1 bytes, so its base64 ends in "==".
	let tail = 1000;
	while (((offset + tail + 3) % CHUNK) % 3 !== 1) tail++;
	frame.data.text = text + "x".repeat(tail);

	const bytes = Buffer.from(JSON.stringify(frame), "utf8");
	splits.forEach(([char, before], k) => {
		const start = (k + 1) * CHUNK - before;
		if (bytes.subarray(start, start + Buffer.byteLength(char, "utf8")).toString("utf8") !== char)
			throw new Error(`split ${k} is misplaced`);
	});
	return frame;
}

/** An ASCII frame whose last chunk carries 3n+2 bytes, so its base64 ends in a single "=". */
function singlePadFrame() {
	const frame = {
		type: "tool_execution_end",
		toolCallId: "toolu_1",
		toolName: "bash",
		result: { content: [{ type: "text", text: "" }] },
		isError: false,
	};
	const empty = Buffer.byteLength(JSON.stringify(frame), "utf8");
	let count = 1_100_000;
	while (((empty + count) % CHUNK) % 3 !== 2) count++;
	frame.result.content[0].text = "y".repeat(count);
	return frame;
}

emit({
	type: "ready",
	protocolVersion: 1,
	supportedProtocolVersions: [1, 2],
	maxFrameBytes: MAX_RPC_FRAME_BYTES,
	maxReassembledFrameBytes: MAX_RPC_REASSEMBLED_BYTES,
});
emit({
	type: "available_commands_update",
	commands: [{ name: "compact", source: "builtin", description: "Compact the conversation — keep ✓ 🚀" }],
});
emit({ id: "req_1", type: "response", command: "negotiate_protocol", success: true, data: { protocolVersion: 2 } });
encoder.setProtocolVersion(2);
emit({
	type: "message_update",
	messageId: "msg-1",
	assistantMessageEvent: { type: "text_delta", delta: 'Grüße, 世界 😀\n"quoted" \\ /' },
	message: { role: "assistant", content: [] },
});
const a0 = emit(straddlingFrame());
const aCount = baseLines.length - a0;
const eventLine = emit({
	type: "tool_execution_update",
	toolCallId: "toolu_1",
	partialResult: { content: [{ type: "text", text: "tick" }] },
});
const b0 = emit(singlePadFrame());
const bCount = baseLines.length - b0;
emit({ type: "prompt_result", id: "req_2", agentInvoked: true, status: "completed", sessionSettled: true });
emit({ type: "session_settled" });

const chunkLine = (i: number) => JSON.parse(baseLines[i]) as { chunkId: string; count: number; byteLength: number; data: string };
const aFirst = chunkLine(a0);
const bFirst = chunkLine(b0);
if (aFirst.count !== 7 || aCount !== 7 || bFirst.count !== bCount || bCount < 5) throw new Error("unexpected chunking");
if (!chunkLine(a0 + aCount - 1).data.endsWith("==") || !chunkLine(b0 + bCount - 1).data.endsWith("=")) throw new Error("unexpected padding");
const aLength = aFirst.byteLength;
const all = baseLines.length;

// MARK: - Cases

const range = (start: number, end: number): LineSpec => ({ range: [start, end] });
const base = (i: number): LineSpec => ({ base: i });
const replace = (i: number, find: string, replacement: string): LineSpec => ({ base: i, replace: [find, replacement] });
const replaceInA = (find: string, replacement: string): LineSpec[] =>
	Array.from({ length: aCount }, (_, k) => replace(a0 + k, find, replacement));
const aTail = range(a0 + aCount, all);

function chunkLines(chunkId: string, payload: Buffer): LineSpec[] {
	const count = Math.ceil(payload.length / CHUNK);
	return Array.from({ length: count }, (_, index) => ({
		segments: compress(
			`${JSON.stringify({
				type: "rpc_chunk",
				chunkId,
				index,
				count,
				byteLength: payload.length,
				data: payload.subarray(index * CHUNK, (index + 1) * CHUNK).toString("base64"),
			})}\n`,
		),
	}));
}

/** A MAX_RPC_FRAME_BYTES payload: `head`, then `fill` bytes, then `tail`. */
function payload(head: string | Buffer, fill: string, tail: string | Buffer): Buffer {
	const h = Buffer.from(head);
	const t = Buffer.from(tail);
	return Buffer.concat([h, Buffer.alloc(MAX_RPC_FRAME_BYTES - h.length - t.length, fill), t]);
}

function lastChars(line: number, count: number): string {
	const data = chunkLine(line).data;
	return data.slice(data.length - count);
}

/** The base64 character whose value is `char`'s value with its lowest bit set. */
function withLowBitSet(char: string): string {
	const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
	return alphabet[alphabet.indexOf(char) | 1];
}

const aLast = a0 + aCount - 1;
const aLastTail = lastChars(aLast, 4); // "xy=="
const bLast = b0 + bCount - 1;
const bLastTail = lastChars(bLast, 4); // "xyz="
const aSecondData = chunkLine(a0 + 1).data;

const cases: Array<{ name: string; lines: LineSpec[] }> = [
	// Streams omp emits
	{ name: "stream/golden", lines: [range(0, all)] },
	{ name: "stream/final-frame-without-newline", lines: [range(0, all - 1), { base: all - 1, noNewline: true }] },
	{ name: "stream/crlf-inside-sequence", lines: [range(0, a0 + 1), { base: a0 + 1, crlf: true }, { base: a0 + 2, crlf: true }, range(a0 + 3, all)] },
	{ name: "stream/blank-lines-inside-sequence", lines: [range(0, a0 + 2), raw("\n", " \t\r\n", "\n"), range(a0 + 2, all)] },
	{ name: "stream/negative-zero-index", lines: [range(0, a0), replace(a0, '"index":0,', '"index":-0,'), range(a0 + 1, all)] },
	{ name: "stream/integral-float-index", lines: [range(0, a0 + 1), replace(a0 + 1, '"index":1,', '"index":1.0,'), range(a0 + 2, all)] },
	{ name: "stream/exponent-index", lines: [range(0, a0 + 1), replace(a0 + 1, '"index":1,', '"index":1e0,'), range(a0 + 2, all)] },
	{ name: "stream/chunk-id-128-ascii", lines: [range(0, a0), ...replaceInA('"chunkId":"rpc-1"', `"chunkId":"${"c".repeat(128)}"`), aTail] },
	{ name: "stream/chunk-id-128-utf16-units", lines: [range(0, a0), ...replaceInA('"chunkId":"rpc-1"', `"chunkId":"${"😀".repeat(64)}"`), aTail] },

	// Sequence structure
	{ name: "chunk/chunk-id-mismatch", lines: [range(0, a0 + 2), replace(a0 + 2, '"chunkId":"rpc-1"', '"chunkId":"rpc-9"'), aTail] },
	{ name: "chunk/index-gap", lines: [range(0, a0 + 2), range(a0 + 3, all)] },
	{ name: "chunk/index-swapped", lines: [range(0, a0 + 2), base(a0 + 3), base(a0 + 2), range(a0 + 4, all)] },
	{ name: "chunk/index-repeated", lines: [range(0, a0 + 3), base(a0 + 2), range(a0 + 3, all)] },
	{ name: "chunk/must-start-at-index-0", lines: [range(0, a0), range(a0 + 1, all)] },
	{ name: "chunk/count-mismatch", lines: [range(0, a0 + 2), replace(a0 + 2, `"count":${aCount},`, `"count":${aCount + 1},`), aTail] },
	{ name: "chunk/byte-length-mismatch", lines: [range(0, a0 + 2), replace(a0 + 2, `"byteLength":${aLength},`, `"byteLength":${aLength + 1},`), aTail] },
	{ name: "chunk/declared-length-exceeds-data", lines: [range(0, a0), ...replaceInA(`"byteLength":${aLength},`, `"byteLength":${aLength + 1},`), aTail] },
	{ name: "chunk/data-exceeds-declared-length", lines: [range(0, a0), ...replaceInA(`"byteLength":${aLength},`, `"byteLength":${6 * CHUNK - 1},`), aTail] },
	{ name: "chunk/interleaved-event", lines: [range(0, a0 + 2), base(eventLine), range(a0 + 2, all)] },
	{ name: "chunk/interleaved-array", lines: [range(0, a0 + 2), raw("[1,2]\n"), range(a0 + 2, all)] },
	{ name: "chunk/interleaved-number", lines: [range(0, a0 + 2), raw("42\n"), range(a0 + 2, all)] },
	{ name: "chunk/interleaved-new-sequence", lines: [range(0, a0 + 2), base(b0), range(a0 + 2, all)] },
	{ name: "chunk/stream-ends-mid-sequence", lines: [range(0, a0 + 3)] },

	// Metadata
	{ name: "metadata/byte-length-above-reassembly-limit", lines: [range(0, a0), ...replaceInA(`"byteLength":${aLength},`, `"byteLength":${MAX_RPC_REASSEMBLED_BYTES + 1},`), aTail] },
	{ name: "metadata/byte-length-below-frame-limit", lines: [range(0, a0), ...replaceInA(`"byteLength":${aLength},`, `"byteLength":${MAX_RPC_FRAME_BYTES - 1},`), aTail] },
	{ name: "metadata/count-above-limit", lines: [range(0, a0), replace(a0, `"count":${aCount},`, `"count":${Math.ceil(MAX_RPC_REASSEMBLED_BYTES / CHUNK) + 1},`), range(a0 + 1, all)] },
	{ name: "metadata/count-below-two", lines: [range(0, a0), replace(a0, `"count":${aCount},`, '"count":1,'), range(a0 + 1, all)] },
	{ name: "metadata/index-not-below-count", lines: [range(0, aLast), replace(aLast, `"index":${aCount - 1},`, `"index":${aCount},`), aTail] },
	{ name: "metadata/fractional-index", lines: [range(0, a0), replace(a0, '"index":0,', '"index":0.5,'), range(a0 + 1, all)] },
	{ name: "metadata/negative-index", lines: [range(0, a0), replace(a0, '"index":0,', '"index":-1,'), range(a0 + 1, all)] },
	{ name: "metadata/string-count", lines: [range(0, a0), replace(a0, `"count":${aCount},`, `"count":"${aCount}",`), range(a0 + 1, all)] },
	{ name: "metadata/empty-chunk-id", lines: [range(0, a0), ...replaceInA('"chunkId":"rpc-1"', '"chunkId":""'), aTail] },
	{ name: "metadata/chunk-id-129-ascii", lines: [range(0, a0), ...replaceInA('"chunkId":"rpc-1"', `"chunkId":"${"c".repeat(129)}"`), aTail] },
	{ name: "metadata/chunk-id-130-utf16-units", lines: [range(0, a0), ...replaceInA('"chunkId":"rpc-1"', `"chunkId":"${"😀".repeat(65)}"`), aTail] },
	{ name: "metadata/numeric-chunk-id", lines: [range(0, a0), replace(a0, '"chunkId":"rpc-1"', '"chunkId":1'), range(a0 + 1, all)] },

	// Data
	{ name: "data/missing", lines: [raw(`{"type":"rpc_chunk","chunkId":"x","index":0,"count":4,"byteLength":${MAX_RPC_FRAME_BYTES}}\n`)] },
	{ name: "data/empty", lines: [raw(`{"type":"rpc_chunk","chunkId":"x","index":0,"count":4,"byteLength":${MAX_RPC_FRAME_BYTES},"data":""}\n`)] },
	{ name: "data/not-a-string", lines: [raw(`{"type":"rpc_chunk","chunkId":"x","index":0,"count":4,"byteLength":${MAX_RPC_FRAME_BYTES},"data":["QQ=="]}\n`)] },
	{ name: "data/character-outside-alphabet", lines: [range(0, a0 + 1), replace(a0 + 1, `"data":"${aSecondData.slice(0, 4)}`, `"data":"!${aSecondData.slice(1, 4)}`), aTail] },
	{ name: "data/escaped-newline", lines: [range(0, a0 + 1), replace(a0 + 1, '"data":"', '"data":"\\n'), aTail] },
	{ name: "data/non-canonical-pad-bits-double", lines: [range(0, aLast), replace(aLast, aLastTail, aLastTail[0] + withLowBitSet(aLastTail[1]) + "=="), aTail] },
	{ name: "data/non-canonical-pad-bits-single", lines: [range(0, bLast), replace(bLast, bLastTail, bLastTail.slice(0, 2) + withLowBitSet(bLastTail[2]) + "="), range(bLast + 1, all)] },
	{ name: "data/missing-padding", lines: [range(0, aLast), replace(aLast, `${aLastTail}"}`, `${aLastTail.slice(0, 2)}"}`), aTail] },
	{
		name: "data/payload-above-chunk-limit",
		lines: [{ segments: [`{"type":"rpc_chunk","chunkId":"big","index":0,"count":4,"byteLength":${MAX_RPC_FRAME_BYTES},"data":"`, ["AAAA", CHUNK / 3 + 1], '"}\n'] }],
	},

	// Reassembled payload
	{ name: "payload/invalid-utf8", lines: chunkLines("u8", payload('{"type":"x","s":"', "a", Buffer.concat([Buffer.from([0xff]), Buffer.from('"}')]))) },
	{ name: "payload/overlong-utf8", lines: chunkLines("u8", payload('{"type":"x","s":"', "a", Buffer.concat([Buffer.from([0xc0, 0xaf]), Buffer.from('"}')]))) },
	{ name: "payload/utf8-surrogate", lines: chunkLines("u8", payload('{"type":"x","s":"', "a", Buffer.concat([Buffer.from([0xed, 0xa0, 0x80]), Buffer.from('"}')]))) },
	{ name: "payload/truncated-utf8-sequence", lines: chunkLines("u8", payload('{"type":"x","s":"', "a", Buffer.concat([Buffer.from([0xf0, 0x9f, 0x98]), Buffer.from('"}')]))) },
	{ name: "payload/leading-bom", lines: chunkLines("bom", payload(Buffer.concat([Buffer.from([0xef, 0xbb, 0xbf]), Buffer.from('{"type":"bom","s":"')]), "a", '"}')) },
	{ name: "payload/whitespace-and-newlines", lines: chunkLines("ws", payload('{\n  "type": "pretty",\r\n\t"s": "', "a", '"\n}\n')) },
	{ name: "payload/array", lines: chunkLines("arr", payload('["', "a", '"]')) },
	{ name: "payload/string", lines: chunkLines("str", payload('"', "a", '"')) },
	{ name: "payload/unterminated-json", lines: chunkLines("cut", payload('{"type":"x","s":"', "a", "aa")) },
	{ name: "payload/trailing-data", lines: chunkLines("trail", payload('{"type":"x","s":"', "a", '"} x')) },

	// Line layer
	{ name: "lines/crlf", lines: [raw('{"type":"a","n":1}\r\n{"type":"b","n":2}\r\n')] },
	{ name: "lines/blank-and-whitespace-lines", lines: [raw('\n \t \r\n{"type":"a"}\n\n\r\n  \n{"type":"b"}\n')] },
	{ name: "lines/bom-at-stream-start", lines: [raw([0xef, 0xbb, 0xbf], '{"type":"a"}\n{"type":"b"}\n')] },
	{ name: "lines/bom-on-second-line", lines: [raw('{"type":"a"}\n', [0xef, 0xbb, 0xbf], '{"type":"b"}\n')] },
	{ name: "lines/final-line-without-newline", lines: [raw('{"type":"a"}\n{"type":"b"}')] },
	{ name: "lines/incomplete-final-line", lines: [raw('{"type":"a"}\n{"type":"b","s":"unterminated')] },
	{ name: "lines/malformed-line", lines: [raw('{"type":"a"}\n{type:b}\n{"type":"c"}\n')] },
	{ name: "lines/control-character-in-string", lines: [raw('{"type":"a","s":"', [0x01], '"}\n')] },
	{ name: "lines/number-frame", lines: [raw('{"type":"a"}\n42\n')] },
	{ name: "lines/array-frame", lines: [raw('[{"type":"a"}]\n')] },
	{ name: "lines/null-frame", lines: [raw("null\n")] },
	{ name: "lines/string-frame", lines: [raw('"ready"\n')] },
	{
		name: "lines/invalid-utf8-replaced",
		lines: [
			raw(
				'{"type":"u","a":"', [0xff],
				'","b":"', [0xc0, 0xaf],
				'","c":"', [0xed, 0xa0, 0x80],
				'","d":"', [0xf0, 0x9f, 0x98], "x",
				'","e":"', [0xe2, 0x82],
				'","f":"', [0xf4, 0x90, 0x80, 0x80],
				'","g":"', [0x80, 0xbf],
				'","h":"', [0xf8, 0x88, 0x80, 0x80, 0x80],
				'","i":"', [0xe0, 0x80, 0x80],
				'","j":"ok ', [0xe2, 0x82, 0xac], '"}\n',
			),
		],
	},
	{ name: "lines/escapes", lines: [raw(String.raw`{"type":"e","s":"\u00e9\ud83d\ude00\n\t\"\\\/\b\f\r\u0000 \uFFFF"}` + "\n")] },
	{ name: "lines/numbers", lines: [raw('{"type":"n","a":-0,"b":1e5,"c":1.5e-7,"d":12345678901234567890,"e":0.1,"f":-123.456E+2,"g":9007199254740993,"h":5e-324,"i":1.7976931348623157e308}\n')] },
	{ name: "lines/duplicate-keys", lines: [raw('{"type":"d","k":1,"k":2}\n')] },
	{ name: "lines/line-separators-in-string", lines: [raw('{"type":"u","s":"a\u2028b\u2029c"}\n')] },
	{ name: "lines/nested-64", lines: [raw(`{"type":"deep","v":${"[".repeat(63)}${"]".repeat(63)}}\n`)] },
	{ name: "lines/whitespace-inside-values", lines: [raw('{ "type" : "w" ,\t"a" : [ 1 , 2 , { } , [ ] ] }\r\n')] },
];

// MARK: - Oracles

function assemble(lines: LineSpec[]): Buffer {
	const parts: Buffer[] = [];
	for (const spec of lines) {
		if ("range" in spec) {
			for (let i = spec.range[0]; i < spec.range[1]; i++) parts.push(Buffer.from(baseLines[i], "utf8"));
		} else if ("base" in spec) {
			let line = baseLines[spec.base];
			if (spec.replace) {
				const [find, replacement] = spec.replace;
				const at = line.indexOf(find);
				if (at < 0) throw new Error(`"${find}" not found in base line ${spec.base}`);
				line = line.slice(0, at) + replacement + line.slice(at + find.length);
			}
			if (spec.crlf) line = `${line.slice(0, -1)}\r\n`;
			if (spec.noNewline) line = line.slice(0, -1);
			parts.push(Buffer.from(line, "utf8"));
		} else {
			parts.push(expand(spec.segments));
		}
	}
	return Buffer.concat(parts);
}

const frameTable: string[] = [];
const frameIndex = new Map<string, number>();
function frameId(frame: object): number {
	const json = JSON.stringify(frame);
	let id = frameIndex.get(json);
	if (id === undefined) {
		id = frameTable.length;
		frameTable.push(json);
		frameIndex.set(json, id);
	}
	return id;
}

function tsVerdict(bytes: Buffer): TsVerdict {
	const decoder = new RpcFrameDecoder();
	const frames: number[] = [];
	const parsed = Bun.JSONL.parseChunk(bytes, 0, bytes.length);
	try {
		for (const value of parsed.values) {
			const frame = decoder.push(value);
			if (frame) frames.push(frameId(frame));
		}
		if (parsed.error) throw parsed.error;
		if (!parsed.done) throw new Error("JSONL stream ended unexpectedly");
	} catch (error) {
		const message = error instanceof Error ? error.message : String(error);
		return { ok: false, frames, error: message, errorKind: message.startsWith("rpc ") ? "chunk" : "parse" };
	}
	let pendingAtEOF = false;
	try {
		decoder.push({ type: "end-of-stream-probe" });
	} catch {
		pendingAtEOF = true;
	}
	return { ok: true, frames, pendingAtEOF };
}

function run(command: string[], env: Record<string, string | undefined> = process.env): string {
	const result = Bun.spawnSync(command, { env: env as Record<string, string>, stderr: "inherit" });
	if (result.exitCode !== 0) throw new Error(`${command.join(" ")} exited with ${result.exitCode}`);
	return result.stdout.toString().trim();
}

const streams = cases.map((testCase) => assemble(testCase.lines));
const scratch = mkdtempSync(join(tmpdir(), "omprpc-oracle-"));
let pythonVerdicts: Array<Record<string, unknown>>;
try {
	streams.forEach((bytes, n) => writeFileSync(join(scratch, `${n}.bin`), bytes));
	pythonVerdicts = JSON.parse(run(["python3", "-B", join(import.meta.dir, "py_oracle.py"), scratch]));
} finally {
	rmSync(scratch, { recursive: true, force: true });
}

// Verdicts first: decoding fills the frame table.
const verdicts = cases.map((testCase, n) => {
	const bytes = streams[n];
	return {
		name: testCase.name,
		lines: testCase.lines,
		byteCount: bytes.length,
		sha256: createHash("sha256").update(bytes).digest("hex"),
		ts: tsVerdict(bytes),
		python: pythonVerdicts[n],
	};
});
const { BUN_BE_BUN: _, ...ompEnv } = process.env;
const manifest = {
	generator: "Tests/OmpRPCTests/Fixtures/oracle/generate.ts",
	omp: run([process.execPath, "--version"], ompEnv),
	bun: Bun.version,
	python: run(["python3", "--version"]),
	reference: "can1357/oh-my-pi v18.3.1",
	base: baseLines.map(compress),
	frames: frameTable.map(compress),
	cases: verdicts,
};

for (const [n, compressed] of manifest.base.entries()) {
	if (expand(compressed).toString("utf8") !== baseLines[n]) throw new Error(`base line ${n} does not round-trip`);
}
writeFileSync(join(import.meta.dir, "..", "conformance.json"), `${JSON.stringify(manifest, null, 1)}\n`);

for (const entry of manifest.cases) {
	const ts = entry.ts;
	const py = entry.python as { ok: boolean; frameCount: number; error?: string; pendingAtEOF?: boolean };
	const tsSummary = ts.ok ? `ok ${ts.frames.length}${ts.pendingAtEOF ? " (pending at EOF)" : ""}` : `error after ${ts.frames.length}: ${ts.error}`;
	const pySummary = py.ok ? `ok ${py.frameCount}${py.pendingAtEOF ? " (pending at EOF)" : ""}` : `error after ${py.frameCount}: ${py.error}`;
	const agree = ts.ok === py.ok && ts.frames.length === py.frameCount;
	console.log(`${agree ? "  " : "≠ "}${entry.name.padEnd(46)} ts: ${tsSummary}${agree ? "" : `\n${" ".repeat(49)}py: ${pySummary}`}`);
}
console.log(`\n${manifest.cases.length} cases, ${manifest.frames.length} distinct frames -> conformance.json (${manifest.omp}, bun ${manifest.bun}, ${manifest.python})`);
