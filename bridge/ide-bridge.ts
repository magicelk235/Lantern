/**
 * omp IDE bridge — the only omp-side code of omp IDE.
 *
 * One file, two modes, chosen at load from the environment:
 *
 *   daemon mode  OMP_IDE_BRIDGE_SOCK, OMP_IDE_SESSION_KEY, OMP_IDE_BRIDGE_TOKEN and OMP_IDE_DAEMON_PID are set and this
 *                process's parent is that daemon: ompd spawned this omp's interactive TUI on a PTY with
 *                `-e <APP_SUPPORT>/bridge/ide-bridge.ts`. Anything this omp spawns inherits the variables (Bun keeps
 *                passing the launch environment to children even after `delete process.env.X`), so a nested `omp` in a
 *                bash tool fails the parent check and runs in lock mode. At the main session's `session_start` the
 *                bridge dials ompd's bridge socket and sends `hello` without waiting for the verdict (ompd registers
 *                this process's pid right after spawning it; a hello that beats it is held until then). After
 *                `welcome` it answers requests and pushes activity, title and agent-tree events. A process the daemon
 *                rejects gets lock-mode treatment for its session file.
 *   lock mode    otherwise; installed as <agentDir>/extensions/omp-ide-bridge.ts so every omp loads it. Refuses to
 *                open a session file the daemon owns: SIGKILL at load (argv --resume/-r/--session), SIGKILL at
 *                `session_start`, `{cancel: true}` from `session_before_switch`. SIGKILL is the only exit that neither
 *                omp's load guard blocks nor appends `session_exit` to the owned JSONL.
 * Both modes veto `session_before_switch` into a daemon-owned file, so a session TUI's `/resume` cannot open another
 * IDE session's file.
 *
 * Ownership: ompd holds flock(LOCK_EX) on $APP_SUPPORT/run/owned-sessions/<sha256(canonical sessionFile)>.lock for
 * every session it owns; APP_SUPPORT = $OMPD_HOME or ~/Library/Application Support/omp-ide. The bridge probes it with
 * a shared non-blocking lock (open O_SHLOCK|O_NONBLOCK fails with EAGAIN while ompd holds it).
 *
 * Wire: JSON lines over the unix socket.
 *   bridge -> ompd  {t:"hello", v:1, sessionKey, token, pid, ompVersion, capabilities, session:{id, file, onDisk,
 *                    leafId, cwd, artifactsDir, title}}                               first frame, exactly once
 *                   {t:"res", id, ok:true, result} | {t:"res", id, ok:false, error}  one per req
 *                   {t:"evt", seq, ts, agentId, kind, data}                           only after welcome
 *                   {t:"gap", ts, from, to, dropped}                                  evts from..to were dropped
 *   ompd -> bridge  {t:"welcome", v} | {t:"reject", reason}                           verdict on hello
 *                   {t:"req", id, method, params}
 * evt kinds: activity {state:"busy"|"idle"} (the main agent started a run / finished it with no background job left),
 * title {title} (the session name changed), registry:registered|status_changed|metadata_changed|removed (data = agent
 * row), before_subagent_spawn, session_start, session_shutdown, session_switch (per agent instance; data.session is the
 * session info), bridge:error. `agentId` is the agent the event is about (registry rows: the row;
 * before_subagent_spawn: the spawning parent). `seq` is per process and gap-free except where a `gap` frame says
 * otherwise.
 *
 * Graceful stop (`session.shutdown`): the reply goes out first, then the main AgentSession is disposed —
 * what the TUI's own /exit does: `session_exit {kind:"normal"}` with the pending tool calls, the turn aborted,
 * subagents, kernels and tool processes torn down — and the process exits 0 through omp's postmortem `quit`.
 * `ctx.shutdown()` is not used: in the TUI it waits until the session is idle with no background work.
 *
 * Internal omp subpaths (registry/agent-lifecycle, registry/persisted-agents, modes/agent-hub-runtime) and
 * @oh-my-pi/pi-utils are imported dynamically: a missing module turns the matching capability off instead of failing
 * the extension load.
 */
import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";
import * as ompModule from "@oh-my-pi/pi-coding-agent";
import * as crypto from "node:crypto";
import * as fs from "node:fs";
import * as net from "node:net";
import * as os from "node:os";
import * as path from "node:path";

// ---------------------------------------------------------------------------------------------------------------------
// Structural views of the omp host objects (read from the omp 18.3.1 bundle; there is no type package to import).
// ---------------------------------------------------------------------------------------------------------------------

type AnyRecord = Record<string, unknown>;

interface SessionManagerLike {
	getSessionFile(): string | undefined;
	getSessionId(): string;
	getCwd(): string;
	getLeafId(): string | null | undefined;
	getArtifactsDir(): string | undefined;
	isSessionOnDisk(): boolean;
	ensureOnDisk(): Promise<void>;
	flush(): Promise<void>;
	appendCustomEntry(customType: string, data: unknown): string;
	getSessionName?(): string | undefined;
	onSessionNameChanged?(listener: () => void): () => void;
}

interface AgentSessionLike {
	sessionManager: SessionManagerLike;
	isStreaming?: boolean;
	prompt(text: string, options?: { streamingBehavior?: "steer" | "followUp" }): Promise<unknown>;
	abort(options?: { reason?: string }): Promise<void>;
	dispose(): Promise<void>;
}

interface AgentRefLike {
	id: string;
	displayName?: string;
	kind?: string;
	parentId?: string;
	status: string;
	session?: AgentSessionLike | null;
	sessionFile?: string | null;
	createdAt?: number;
	lastActivity?: number;
	activity?: unknown;
	lifecycle?: unknown;
	history?: unknown;
}

interface AgentRegistryLike {
	list(): AgentRefLike[];
	get(id: string): AgentRefLike | undefined;
	onChange(listener: (event: { type: string; ref: AgentRefLike }) => void): () => void;
}

interface AgentLifecycleLike {
	ensureLive(id: string): Promise<AgentSessionLike>;
	park(id: string): Promise<void>;
	release(id: string, ref?: AgentRefLike, options?: { tombstone?: boolean }): Promise<boolean>;
}

interface IrcBusLike {
	send(message: { from: string; to: string; body: string }): Promise<unknown>;
}

interface OmpRootLike {
	AgentRegistry?: { global(): AgentRegistryLike };
	MAIN_AGENT_ID?: string;
	VERSION?: string;
}

/** Handler ctx. The public type narrows `sessionManager` to read-only; at runtime it is the live manager. */
interface CtxLike {
	sessionManager: SessionManagerLike;
	getAsyncJobSnapshot?(): { running?: unknown[] } | null;
	hasPendingMessages?(): boolean;
	ui?: { notify?(message: string, type?: "info" | "warning" | "error"): void };
}

interface Internals {
	AgentLifecycleManager?: { global(): AgentLifecycleLike };
	ensurePersistedRoster?: (registry: AgentRegistryLike, rootSessionFile?: string) => Promise<string | undefined>;
	createAgentHubRuntime?: () => { irc: IrcBusLike };
	/** omp's postmortem `quit(code)`: runs the remaining cleanups, then exits (what the TUI's /exit ends with). */
	quit?: (code: number) => Promise<void>;
	errors: Record<string, string>;
}

type Handler = (event: unknown, ctx: unknown) => unknown;
type On = (event: string, handler: Handler) => void;

// ---------------------------------------------------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------------------------------------------------

const WIRE_VERSION = 1;
/** Userland socket backlog above which `evt`s are dropped (and reported with one `gap`). Replies are never dropped. */
const MAX_BACKLOG_BYTES = 1 << 20;
/** `evt`s produced between `hello` and the daemon's verdict are held back; beyond this they become a `gap`. */
const MAX_QUEUED_BEFORE_WELCOME = 1024;
/** While background jobs outlive the main agent's run, how often the bridge checks whether the session went idle. */
const SETTLE_RECHECK_MS = 1000;
const MAX_INBOUND_CHARS = 16 << 20;
const MAX_STRING = 16_384;
const MAX_ARRAY = 5_000;
const MAX_KEYS = 500;
const MAX_DEPTH = 10;
/** macOS <fcntl.h>: open(2) takes a shared flock(2) lock; with O_NONBLOCK it fails with EAGAIN while one is held. */
const O_SHLOCK = 0x10;
const O_NONBLOCK = 0x4;

const omp = ompModule as unknown as OmpRootLike;
const MAIN_AGENT_ID = omp.MAIN_AGENT_ID ?? "Main";
const EVAL_ID = crypto.randomUUID();

interface DaemonEnv {
	sock: string;
	sessionKey: string;
	token: string;
}

/** The daemon wiring, if ompd itself spawned this process (see header); otherwise lock mode. */
function daemonEnv(): DaemonEnv | undefined {
	const sock = process.env.OMP_IDE_BRIDGE_SOCK;
	const sessionKey = process.env.OMP_IDE_SESSION_KEY;
	const token = process.env.OMP_IDE_BRIDGE_TOKEN;
	const daemonPid = process.env.OMP_IDE_DAEMON_PID;
	if (!sock || !sessionKey || !token || !daemonPid) {
		if (sock || sessionKey || token || daemonPid) writeStderr("ide-bridge: incomplete OMP_IDE_* environment; lock mode");
		return undefined;
	}
	// Inherited by a process this daemon-spawned omp started: it must not pose as the session's bridge.
	return String(process.ppid) === daemonPid ? { sock, sessionKey, token } : undefined;
}

function appSupportDir(): string {
	const home = process.env.OMPD_HOME;
	if (home) {
		if (home === "~") return os.homedir();
		return home.startsWith("~/") ? path.join(os.homedir(), home.slice(2)) : home;
	}
	return path.join(os.homedir(), "Library", "Application Support", "omp-ide");
}

const OWNED_DIR = path.join(appSupportDir(), "run", "owned-sessions");

const DAEMON = daemonEnv();

// ---------------------------------------------------------------------------------------------------------------------
// Duplicate-load guard. A daemon-spawned omp usually loads this file twice: the lock-mode copy from the agent's
// extensions dir (auto-discovered, loaded first) and ompd's copy via `-e` (loaded last). The factory is re-bound, not
// re-imported, for child and revived sessions, so one evaluation serves the whole process. The last evaluation wins
// (ompd's `-e` copy over a possibly stale global copy) unless the owner already dialed the daemon; handlers of a
// superseded evaluation stay registered but do nothing.
// ---------------------------------------------------------------------------------------------------------------------

interface GuardSlot {
	/** The evaluation of this file that serves the process. */
	owner: string;
	/** The owner dialed the daemon; later evaluations no longer take over. */
	connected: boolean;
}

const GUARD = Symbol.for("omp-ide.bridge");
const guardSlots = globalThis as unknown as Record<symbol, GuardSlot | undefined>;
if (!guardSlots[GUARD]?.connected) guardSlots[GUARD] = { owner: EVAL_ID, connected: false };

function owns(): boolean {
	return guardSlots[GUARD]?.owner === EVAL_ID;
}

// ---------------------------------------------------------------------------------------------------------------------
// Helpers (none of these may throw into a host callback)
// ---------------------------------------------------------------------------------------------------------------------

function errText(e: unknown): string {
	return e instanceof Error ? e.message : String(e);
}

function isRecord(v: unknown): v is AnyRecord {
	return typeof v === "object" && v !== null && !Array.isArray(v);
}

function writeStderr(line: string): void {
	try {
		fs.writeSync(2, `${line}\n`);
	} catch {
		// stderr closed: nothing left to tell.
	}
}

/** Daemon-mode diagnostics; ompd captures omp's stderr. Lock mode stays silent (it may be inside a TUI). */
function log(message: string): void {
	if (DAEMON) writeStderr(`ide-bridge: ${message}`);
}

function attempt<T>(read: () => T, fallback: T): T {
	try {
		return read();
	} catch {
		return fallback;
	}
}

/** JSON-safe, bounded copy. Class instances (sessions, buses, managers) collapse to `[ClassName]`. */
function sanitize(v: unknown, depth = 0): unknown {
	if (v === null || v === undefined) return v;
	switch (typeof v) {
		case "string":
			return v.length > MAX_STRING ? `${v.slice(0, MAX_STRING)}…[+${v.length - MAX_STRING} chars]` : v;
		case "number":
			return Number.isFinite(v) ? v : String(v);
		case "boolean":
			return v;
		case "bigint":
		case "symbol":
			return v.toString();
		case "function":
			return undefined;
	}
	if (depth >= MAX_DEPTH) return "[depth limit]";
	if (Array.isArray(v)) {
		const out = v.slice(0, MAX_ARRAY).map((x) => sanitize(x, depth + 1) ?? null);
		if (v.length > MAX_ARRAY) out.push(`[+${v.length - MAX_ARRAY} items]`);
		return out;
	}
	if (v instanceof Date) return Number.isNaN(v.getTime()) ? null : v.toISOString();
	if (v instanceof Error) return { error: v.message };
	if (v instanceof Map) return sanitize(Object.fromEntries(v), depth + 1);
	if (v instanceof Set) return sanitize([...v], depth + 1);
	const proto: unknown = Object.getPrototypeOf(v);
	if (proto !== Object.prototype && proto !== null) {
		const name = attempt(() => (proto as { constructor?: { name?: string } }).constructor?.name, undefined);
		return `[${name || "object"}]`;
	}
	const out: AnyRecord = {};
	const keys = Object.keys(v);
	for (const key of keys.slice(0, MAX_KEYS)) {
		let value: unknown;
		try {
			value = (v as AnyRecord)[key];
		} catch {
			continue;
		}
		const clean = sanitize(value, depth + 1);
		if (clean !== undefined) out[key] = clean;
	}
	if (keys.length > MAX_KEYS) out["…"] = `[+${keys.length - MAX_KEYS} keys]`;
	return out;
}

function frame(value: AnyRecord): string {
	return `${JSON.stringify(value)}\n`;
}

// ---------------------------------------------------------------------------------------------------------------------
// Ownership lock (both modes)
// ---------------------------------------------------------------------------------------------------------------------

/** ompd's lock name rule (OwnershipLock.canonicalPath): realpath of the file; for a file not on disk yet, realpath of
 *  its directory plus its name; the path as given if neither resolves. */
function lockPathFor(sessionFile: string): string {
	let canonical = sessionFile;
	try {
		canonical = fs.realpathSync(sessionFile);
	} catch {
		try {
			canonical = path.join(fs.realpathSync(path.dirname(sessionFile)), path.basename(sessionFile));
		} catch {
			// Neither resolves: hash the path as given.
		}
	}
	return path.join(OWNED_DIR, `${crypto.createHash("sha256").update(canonical).digest("hex")}.lock`);
}

/** True while ompd holds the ownership lock of `sessionFile`. */
function isDaemonOwned(sessionFile: string | null | undefined): sessionFile is string {
	if (!sessionFile || process.platform !== "darwin") return false;
	let fd: number;
	try {
		fd = fs.openSync(lockPathFor(sessionFile), fs.constants.O_RDONLY | O_SHLOCK | O_NONBLOCK);
	} catch (e) {
		const code = (e as { code?: string }).code;
		return code === "EAGAIN" || code === "EWOULDBLOCK"; // ENOENT: never owned
	}
	try {
		fs.closeSync(fd);
	} catch {
		// The probe lock goes away with the process anyway.
	}
	return false;
}

/** `--resume/-r/--session <path|id-prefix>`; a bare `--resume` opens a picker and is caught at `session_start`. */
function argvResumeTarget(): string | undefined {
	const argv = process.argv;
	for (let i = 0; i < argv.length; i++) {
		const arg = argv[i] ?? "";
		if (arg === "--resume" || arg === "-r" || arg === "--session") {
			const value = argv[i + 1];
			return value && !value.startsWith("-") ? value : undefined;
		}
		const inline = /^(?:--resume|--session|-r)=(.+)$/.exec(arg);
		if (inline) return inline[1];
	}
	return undefined;
}

/** A daemon-owned session file named by `target`: a path, or a session-id prefix recorded in a lock body. */
function ownedSessionFor(target: string): string | undefined {
	const candidate = path.resolve(target);
	if (fs.existsSync(candidate)) return isDaemonOwned(candidate) ? candidate : undefined;
	let names: string[];
	try {
		names = fs.readdirSync(OWNED_DIR).filter((name) => name.endsWith(".lock"));
	} catch {
		return undefined;
	}
	const needle = target.toLowerCase();
	for (const name of names) {
		try {
			const body: unknown = JSON.parse(fs.readFileSync(path.join(OWNED_DIR, name), "utf8"));
			if (!isRecord(body) || typeof body.sessionFile !== "string" || typeof body.sessionId !== "string") continue;
			if (body.sessionId.toLowerCase().startsWith(needle) && isDaemonOwned(body.sessionFile)) return body.sessionFile;
		} catch {
			// Unreadable or half-written body: not a match.
		}
	}
	return undefined;
}

/** Refuse a daemon-owned session. Only SIGKILL leaves the JSONL untouched (see header). */
function refuse(sessionFile: string, where: string): void {
	writeStderr(`omp IDE: ${sessionFile} is open in omp IDE (${where}); open it from the IDE instead.`);
	process.kill(process.pid, "SIGKILL");
}

if (!DAEMON) {
	// Load time: extensions load before the session is created, so nothing has been written yet.
	try {
		const target = argvResumeTarget();
		const owned = target === undefined ? undefined : ownedSessionFor(target);
		if (owned !== undefined) refuse(owned, "--resume");
	} catch {
		// Never break the host's startup; session_start checks again.
	}
}

// ---------------------------------------------------------------------------------------------------------------------
// Process-wide daemon-mode state (shared by every session instance of this evaluation)
// ---------------------------------------------------------------------------------------------------------------------

type Phase = "idle" | "connecting" | "accepted" | "rejected" | "closed";

interface Instance {
	ctx?: CtxLike;
	agentId?: string;
	isMain: boolean;
}

const S = {
	main: undefined as Instance | undefined,
	phase: "idle" as Phase,
	sock: undefined as net.Socket | undefined,
	rx: "",
	seq: 0,
	/** `evt` lines produced before the daemon's verdict on `hello`, flushed on welcome. */
	queued: [] as string[],
	/** Dropped `evt` seqs not yet reported; nothing is sent past a pending gap. */
	gap: undefined as { from: number; to: number } | undefined,
	registryUnsub: undefined as (() => void) | undefined,
	titleUnsub: undefined as (() => void) | undefined,
	/** Last `activity` state pushed; the session starts idle (the TUI waits for input). */
	activity: "idle" as "busy" | "idle",
	/** Re-checks for the end of background work after the main agent's run ended. */
	settleTimer: undefined as Timer | undefined,
	shuttingDown: false,
	internals: undefined as Promise<Internals> | undefined,
};

// Dynamic on purpose: these internal subpaths (and @oh-my-pi/pi-utils) are served to extensions by omp 18.3.1 but are not
// a public API. A static import of a missing module would fail the whole extension load (lock mode included); a dynamic
// one only turns a capability off.
function loadInternals(): Promise<Internals> {
	S.internals ??= (async () => {
		const out: Internals = { errors: {} };
		try {
			const mod = (await import("@oh-my-pi/pi-coding-agent/registry/agent-lifecycle")) as AnyRecord;
			if (typeof mod.AgentLifecycleManager === "function") {
				out.AgentLifecycleManager = mod.AgentLifecycleManager as unknown as Internals["AgentLifecycleManager"];
			} else out.errors.lifecycle = "AgentLifecycleManager export missing";
		} catch (e) {
			out.errors.lifecycle = errText(e);
		}
		try {
			const mod = (await import("@oh-my-pi/pi-coding-agent/registry/persisted-agents")) as AnyRecord;
			if (typeof mod.ensurePersistedRoster === "function") {
				out.ensurePersistedRoster = mod.ensurePersistedRoster as Internals["ensurePersistedRoster"];
			} else out.errors.persistedAgents = "ensurePersistedRoster export missing";
		} catch (e) {
			out.errors.persistedAgents = errText(e);
		}
		try {
			const mod = (await import("@oh-my-pi/pi-coding-agent/modes/agent-hub-runtime")) as AnyRecord;
			if (typeof mod.createAgentHubRuntime === "function") {
				out.createAgentHubRuntime = mod.createAgentHubRuntime as Internals["createAgentHubRuntime"];
			} else out.errors.agentHubRuntime = "createAgentHubRuntime export missing";
		} catch (e) {
			out.errors.agentHubRuntime = errText(e);
		}
		try {
			const mod = (await import("@oh-my-pi/pi-utils")) as AnyRecord;
			const postmortem = mod.postmortem as AnyRecord | undefined;
			if (typeof postmortem?.quit === "function") out.quit = postmortem.quit as Internals["quit"];
			else out.errors.postmortem = "postmortem.quit export missing";
		} catch (e) {
			out.errors.postmortem = errText(e);
		}
		return out;
	})();
	return S.internals;
}

function registryOrUndefined(): AgentRegistryLike | undefined {
	return attempt(() => omp.AgentRegistry?.global(), undefined);
}

function registry(): AgentRegistryLike {
	const reg = registryOrUndefined();
	if (!reg) throw new Error("AgentRegistry is not available in this omp build");
	return reg;
}

async function lifecycle(): Promise<AgentLifecycleLike> {
	const { AgentLifecycleManager, errors } = await loadInternals();
	if (!AgentLifecycleManager) throw new Error(`agent lifecycle unavailable: ${errors.lifecycle}`);
	return AgentLifecycleManager.global();
}

function mainCtx(): CtxLike {
	const ctx = S.main?.ctx;
	if (!ctx) throw new Error("no main session");
	return ctx;
}

/** The main agent's live AgentSession (the same session the TUI runs). */
function mainSession(): AgentSessionLike | undefined {
	return attempt(() => registryOrUndefined()?.get(MAIN_AGENT_ID)?.session ?? undefined, undefined);
}

function sessionInfo(ctx: CtxLike): AnyRecord {
	const sm = ctx.sessionManager;
	return {
		id: attempt(() => sm.getSessionId(), null),
		file: attempt(() => sm.getSessionFile(), undefined) ?? null,
		onDisk: attempt(() => sm.isSessionOnDisk(), false),
		leafId: attempt(() => sm.getLeafId(), undefined) ?? null,
		cwd: attempt(() => sm.getCwd(), null),
		artifactsDir: attempt(() => sm.getArtifactsDir(), undefined) ?? null,
		title: attempt(() => sm.getSessionName?.(), undefined) ?? null,
	};
}

/** Registry row as JSON: live objects stripped, `hasSession`/`isStreaming` derived. */
function refJson(ref: AgentRefLike | undefined): AnyRecord | null {
	if (!ref) return null;
	return {
		id: ref.id,
		displayName: ref.displayName ?? null,
		kind: ref.kind ?? null,
		parentId: ref.parentId ?? null,
		status: ref.status,
		hasSession: Boolean(ref.session),
		isStreaming: attempt(() => ref.session?.isStreaming === true, false),
		sessionFile: ref.sessionFile ?? null,
		createdAt: ref.createdAt ?? null,
		lastActivity: ref.lastActivity ?? null,
		activity: sanitize(ref.activity) ?? null,
		lifecycle: sanitize(ref.lifecycle) ?? null,
		history: sanitize(ref.history) ?? null,
	};
}

function agentRow(id: string): AnyRecord | null {
	return refJson(registry().get(id));
}

function agentIdFor(ctx: CtxLike): string | undefined {
	const reg = registryOrUndefined();
	if (!reg) return undefined;
	const refs = attempt(() => reg.list(), [] as AgentRefLike[]);
	const sm = ctx.sessionManager;
	const file = attempt(() => sm.getSessionFile(), undefined);
	return (
		refs.find((r) => attempt(() => r.session?.sessionManager === sm, false))?.id ??
		(file === undefined ? undefined : refs.find((r) => r.sessionFile === file)?.id)
	);
}

async function probeCapabilities(ctx: CtxLike): Promise<Record<string, boolean>> {
	const internals = await loadInternals();
	const sm = ctx.sessionManager as unknown as AnyRecord;
	const reg = registryOrUndefined() as unknown as AnyRecord | undefined;
	const fn = (o: unknown, key: string) => attempt(() => typeof (o as AnyRecord | undefined)?.[key] === "function", false);
	const rows = fn(reg, "list") && fn(reg, "get");
	const lifecycleOk = rows && internals.AgentLifecycleManager !== undefined;
	return {
		"session.info": true,
		"session.ensureOnDisk": fn(sm, "ensureOnDisk"),
		"session.flush": fn(sm, "flush"),
		"entry.append": fn(sm, "appendCustomEntry") && fn(sm, "flush"),
		"jobs.snapshot": fn(ctx, "getAsyncJobSnapshot"),
		"agents.snapshot": rows,
		"agents.loadPersisted": rows && internals.ensurePersistedRoster !== undefined,
		"agent.revive": lifecycleOk,
		"agent.park": lifecycleOk,
		"agent.kill": lifecycleOk,
		"agent.prompt": lifecycleOk,
		"agent.message": rows && internals.createAgentHubRuntime !== undefined,
		introspect: true,
		"events.registry": rows && fn(reg, "onChange"),
		"events.activity": true,
		"events.title": fn(sm, "onSessionNameChanged") && fn(sm, "getSessionName"),
		"session.shutdown": fn(mainSession(), "dispose"),
	};
}

// ---------------------------------------------------------------------------------------------------------------------
// Daemon connection
// ---------------------------------------------------------------------------------------------------------------------

function evtLine(seq: number, agentId: string | undefined, kind: string, data: unknown): string {
	return frame({ t: "evt", seq, ts: Date.now(), agentId: agentId ?? null, kind, data: sanitize(data) ?? null });
}

function noteGap(seq: number): void {
	if (S.gap) S.gap.to = seq;
	else S.gap = { from: seq, to: seq };
}

/** Sends the pending `gap` once the backlog allows it. True when no gap is pending afterwards. */
function flushGap(): boolean {
	const gap = S.gap;
	if (!gap) return true;
	const sock = S.sock;
	if (S.phase !== "accepted" || !sock || sock.destroyed || sock.writableLength > MAX_BACKLOG_BYTES) return false;
	S.gap = undefined;
	sock.write(frame({ t: "gap", ts: Date.now(), from: gap.from, to: gap.to, dropped: gap.to - gap.from + 1 }));
	return true;
}

function emit(agentId: string | undefined, kind: string, data: unknown): void {
	try {
		if (S.phase !== "connecting" && S.phase !== "accepted") return;
		const seq = ++S.seq;
		if (S.phase === "connecting") {
			if (!S.gap && S.queued.length < MAX_QUEUED_BEFORE_WELCOME) S.queued.push(evtLine(seq, agentId, kind, data));
			else noteGap(seq);
			return;
		}
		const sock = S.sock;
		if (!sock || sock.destroyed) return;
		if (sock.writableLength > MAX_BACKLOG_BYTES || !flushGap()) {
			noteGap(seq);
			return;
		}
		sock.write(evtLine(seq, agentId, kind, data));
	} catch (e) {
		log(`event ${kind} not sent: ${errText(e)}`);
	}
}

/** Replies are never dropped: ompd is waiting for them. */
function reply(value: AnyRecord): void {
	const sock = S.sock;
	if (S.phase !== "accepted" || !sock || sock.destroyed) return;
	try {
		sock.write(frame(value));
	} catch (e) {
		log(`reply ${String(value.id)} not sent: ${errText(e)}`);
	}
}

function endConnection(next: "rejected" | "closed"): void {
	S.phase = next;
	S.queued = [];
	S.gap = undefined;
	for (const unsubscribe of [S.registryUnsub, S.titleUnsub]) {
		try {
			unsubscribe?.();
		} catch {
			// Host object already torn down.
		}
	}
	S.registryUnsub = undefined;
	S.titleUnsub = undefined;
	clearTimeout(S.settleTimer);
	S.settleTimer = undefined;
	const sock = S.sock;
	S.sock = undefined;
	try {
		if (next === "rejected") sock?.destroy();
		else sock?.end();
	} catch {
		// Socket already gone.
	}
}

function onWelcome(): void {
	const sock = S.sock;
	if (S.phase !== "connecting" || !sock) return;
	S.phase = "accepted";
	const queued = S.queued;
	S.queued = [];
	for (const line of queued) sock.write(line);
	flushGap();
}

function onReject(reason: string): void {
	if (S.phase !== "connecting") return;
	log(`the omp IDE daemon rejected this process: ${reason}`);
	endConnection("rejected");
	// Not the process ompd spawned (it got OMP_IDE_* from somewhere other than ompd): same rule as lock mode.
	const file = attempt(() => S.main?.ctx?.sessionManager.getSessionFile(), undefined);
	if (isDaemonOwned(file)) refuse(file, "rejected by the omp IDE daemon");
}

function onLine(line: string): void {
	let msg: unknown;
	try {
		msg = JSON.parse(line);
	} catch {
		log("unparsable frame from the daemon ignored");
		return;
	}
	if (!isRecord(msg)) return;
	switch (msg.t) {
		case "welcome":
			onWelcome();
			return;
		case "reject":
			onReject(typeof msg.reason === "string" ? msg.reason : "no reason given");
			return;
		case "req":
			if (S.phase === "accepted") void handleRequest(msg);
			return;
		default:
			return;
	}
}

function subscribeRegistry(): void {
	if (S.registryUnsub) return;
	const reg = registryOrUndefined();
	if (!reg || typeof reg.onChange !== "function") return;
	try {
		S.registryUnsub = reg.onChange((event) => {
			try {
				if (!owns()) return;
				emit(event.ref?.id, `registry:${event.type}`, refJson(event.ref));
			} catch (e) {
				log(`registry event dropped: ${errText(e)}`);
			}
		});
	} catch (e) {
		log(`registry subscription failed: ${errText(e)}`);
	}
}

/** `title` pushes whenever omp renames the main session (auto-title after the first turn, /name, …). */
function subscribeTitle(ctx: CtxLike): void {
	attempt(() => S.titleUnsub?.(), undefined);
	S.titleUnsub = undefined;
	const sm = ctx.sessionManager;
	if (typeof sm.onSessionNameChanged !== "function") return;
	try {
		S.titleUnsub = sm.onSessionNameChanged(() => {
			try {
				if (!owns()) return;
				emit(MAIN_AGENT_ID, "title", { title: attempt(() => sm.getSessionName?.(), undefined) ?? null });
			} catch (e) {
				log(`title event dropped: ${errText(e)}`);
			}
		});
	} catch (e) {
		log(`session name subscription failed: ${errText(e)}`);
	}
}

function setActivity(state: "busy" | "idle"): void {
	clearTimeout(S.settleTimer);
	S.settleTimer = undefined;
	if (S.activity === state) return;
	S.activity = state;
	emit(MAIN_AGENT_ID, "activity", { state });
}

/** The main agent's run ended (`agent_end`, where `isIdle()` still reads false): idle once no background job is running
 *  and nothing is queued, else checked again shortly (a finished job normally starts a new run first). */
function settleCheck(ctx: CtxLike): void {
	const running = attempt(() => ctx.getAsyncJobSnapshot?.()?.running?.length ?? 0, 0);
	const queued = attempt(() => ctx.hasPendingMessages?.() === true, false);
	if (running === 0 && !queued) return setActivity("idle");
	clearTimeout(S.settleTimer);
	S.settleTimer = setTimeout(() => {
		S.settleTimer = undefined;
		try {
			if (S.activity === "busy" && (S.phase === "connecting" || S.phase === "accepted")) settleCheck(ctx);
		} catch (e) {
			log(`settle check failed: ${errText(e)}`);
		}
	}, SETTLE_RECHECK_MS);
	S.settleTimer.unref?.();
}

/** Dials the daemon and sends `hello`; events queue from here until the verdict. */
async function connectDaemon(daemon: DaemonEnv, ctx: CtxLike): Promise<void> {
	S.phase = "connecting";
	const slot = guardSlots[GUARD];
	if (slot && slot.owner === EVAL_ID) slot.connected = true;
	subscribeRegistry();
	let capabilities: Record<string, boolean>;
	try {
		capabilities = await probeCapabilities(ctx);
	} catch (e) {
		log(`capability probe failed: ${errText(e)}`);
		capabilities = {};
	}
	if (S.phase !== "connecting") return;
	let sock: net.Socket;
	try {
		sock = net.createConnection({ path: daemon.sock });
	} catch (e) {
		log(`cannot dial the daemon: ${errText(e)}`);
		endConnection("closed");
		return;
	}
	S.sock = sock;
	sock.setEncoding("utf8");
	sock.on("data", (chunk: string | Buffer) => {
		try {
			S.rx += typeof chunk === "string" ? chunk : chunk.toString("utf8");
			for (let nl = S.rx.indexOf("\n"); nl >= 0; nl = S.rx.indexOf("\n")) {
				const line = S.rx.slice(0, nl);
				S.rx = S.rx.slice(nl + 1);
				if (line.trim()) onLine(line);
			}
			if (S.rx.length > MAX_INBOUND_CHARS) {
				log("oversized frame from the daemon; disconnecting");
				S.rx = "";
				endConnection("closed");
			}
		} catch (e) {
			log(`daemon frame handling failed: ${errText(e)}`);
		}
	});
	sock.on("drain", () => {
		try {
			flushGap();
		} catch (e) {
			log(`gap not sent: ${errText(e)}`);
		}
	});
	// An unhandled socket error would be fatal to the whole omp process.
	sock.on("error", (e: Error) => log(`daemon socket error: ${errText(e)}`));
	sock.on("close", () => {
		try {
			if (S.sock !== sock) return;
			if (S.phase === "connecting" || S.phase === "accepted") log("daemon socket closed");
			endConnection("closed");
		} catch {
			// Nothing to clean up.
		}
	});
	sock.write(
		frame({
			t: "hello",
			v: WIRE_VERSION,
			sessionKey: daemon.sessionKey,
			token: daemon.token,
			pid: process.pid,
			ompVersion: omp.VERSION ?? "unknown",
			capabilities,
			session: sessionInfo(ctx),
		}),
	);
}

// ---------------------------------------------------------------------------------------------------------------------
// Requests
// ---------------------------------------------------------------------------------------------------------------------

function requireString(params: AnyRecord, key: string): string {
	const value = params[key];
	if (typeof value !== "string" || value.trim() === "") throw new Error(`params.${key} must be a non-empty string`);
	return value;
}

async function handleRequest(msg: AnyRecord): Promise<void> {
	const id = msg.id;
	const method = typeof msg.method === "string" ? msg.method : "";
	try {
		const run = Object.hasOwn(METHODS, method) ? METHODS[method] : undefined;
		if (!run) throw new Error(`unknown method: ${method}`);
		const params = isRecord(msg.params) ? msg.params : {};
		const result = await run(params);
		reply({ t: "res", id, ok: true, result: sanitize(result) ?? null });
	} catch (e) {
		reply({ t: "res", id, ok: false, error: errText(e) || "failed" });
	}
}

/** Runs once the `session.shutdown` reply is queued. Never throws: the process exits either way. */
async function shutdownProcess(session: AgentSessionLike): Promise<void> {
	try {
		await session.dispose();
	} catch (e) {
		log(`dispose failed during session.shutdown: ${errText(e)}`);
	}
	try {
		const { quit } = await loadInternals();
		if (quit) await quit(0);
	} catch (e) {
		log(`postmortem quit failed: ${errText(e)}`);
	}
	process.exit(0);
}

const METHODS: Record<string, (params: AnyRecord) => Promise<unknown>> = {
	async "session.info"() {
		return sessionInfo(mainCtx());
	},

	/** Crosses omp's lazy file-creation gate (the file otherwise appears with the first assistant reply). */
	async "session.ensureOnDisk"() {
		const ctx = mainCtx();
		await ctx.sessionManager.ensureOnDisk();
		return sessionInfo(ctx);
	},

	/** Drains omp's session writers (no fsync). */
	async "session.flush"() {
		const ctx = mainCtx();
		await ctx.sessionManager.flush();
		return sessionInfo(ctx);
	},

	/** Graceful stop: answers, then disposes the main session and exits 0 like the TUI's own /exit. */
	async "session.shutdown"() {
		const session = mainSession();
		if (typeof session?.dispose !== "function") throw new Error("the main session cannot be disposed from the bridge");
		if (!S.shuttingDown) {
			S.shuttingDown = true;
			// Next macrotask: `handleRequest` writes this reply first; dispose ends the daemon connection.
			setTimeout(() => void shutdownProcess(session), 0);
		}
		return { accepted: true };
	},

	/** The process-global agent tree: every depth, idle/parked/aborted rows, `parentId`. */
	async "agents.snapshot"() {
		return { agents: registry().list().map(refJson) };
	},

	/** After `--resume`: registers the session's persisted subagents as parked (or aborted, if tombstoned) rows. */
	async "agents.loadPersisted"() {
		const { ensurePersistedRoster, errors } = await loadInternals();
		if (!ensurePersistedRoster) throw new Error(`persisted roster unavailable: ${errors.persistedAgents}`);
		const root = await ensurePersistedRoster(registry(), mainCtx().sessionManager.getSessionFile());
		return { root: root ?? null, agents: registry().list().map(refJson) };
	},

	/** Revives a parked agent; it comes back idle (it does not continue an interrupted turn). */
	async "agent.revive"(params) {
		const id = requireString(params, "id");
		await (await lifecycle()).ensureLive(id);
		return { agent: agentRow(id) };
	},

	async "agent.park"(params) {
		const id = requireString(params, "id");
		if (id === MAIN_AGENT_ID) throw new Error("the main agent cannot be parked");
		await (await lifecycle()).park(id);
		return { agent: agentRow(id) };
	},

	/** `write agent://<id>` semantics: revives if parked; the reply reaches the sender (default Main) asynchronously. */
	async "agent.message"(params) {
		const id = requireString(params, "id");
		const body = requireString(params, "body");
		const from = typeof params.from === "string" && params.from !== "" ? params.from : MAIN_AGENT_ID;
		const { createAgentHubRuntime, errors } = await loadInternals();
		if (!createAgentHubRuntime) throw new Error(`agent hub runtime unavailable: ${errors.agentHubRuntime}`);
		const receipt = await createAgentHubRuntime().irc.send({ from, to: id, body });
		return { receipt, agent: agentRow(id) };
	},

	/** Agent Hub chat: revive, then prompt the agent's own session (steer if busy). The parent is not notified. */
	async "agent.prompt"(params) {
		const id = requireString(params, "id");
		const text = requireString(params, "text");
		const session = await (await lifecycle()).ensureLive(id);
		// The turn is observed through registry events; it is not awaited here.
		Promise.resolve()
			.then(() => session.prompt(text, { streamingBehavior: "steer" }))
			.catch((e: unknown) => emit(id, "bridge:error", { method: "agent.prompt", id, error: errText(e) }));
		return { accepted: true, agent: agentRow(id) };
	},

	/** Agent Hub `x`: abort if running, then release with a tombstone (terminal `aborted`). */
	async "agent.kill"(params) {
		const id = requireString(params, "id");
		if (id === MAIN_AGENT_ID) throw new Error("the main agent cannot be killed through the bridge");
		const ref = registry().get(id);
		if (!ref) throw new Error(`unknown agent: ${id}`);
		if (ref.status === "running" && ref.session) await ref.session.abort({ reason: "Killed from omp IDE" });
		const released = await (await lifecycle()).release(id, ref, { tombstone: true });
		return { released, agent: agentRow(id) };
	},

	/** Async jobs owned by the main session (delivered jobs are evicted by omp after 30 s). */
	async "jobs.snapshot"() {
		const ctx = mainCtx();
		if (typeof ctx.getAsyncJobSnapshot !== "function") throw new Error("getAsyncJobSnapshot unavailable");
		return { snapshot: ctx.getAsyncJobSnapshot() ?? null };
	},

	/** Appends an opaque `custom` entry (not model context) and flushes it. */
	async "entry.append"(params) {
		const customType = requireString(params, "customType");
		// Bare names are reserved by omp core (session.md#custom); extension records must be namespaced.
		if (!customType.includes(".")) throw new Error("customType must be namespaced, e.g. com.omp-ide.interrupted");
		const sm = mainCtx().sessionManager;
		const entryId = sm.appendCustomEntry(customType, params.data ?? {});
		await sm.flush();
		return { entryId, leafId: attempt(() => sm.getLeafId(), undefined) ?? null, onDisk: attempt(() => sm.isSessionOnDisk(), false) };
	},

	async introspect() {
		const internals = await loadInternals();
		const reg = registryOrUndefined();
		const registryMethods = reg
			? attempt(() => Object.getOwnPropertyNames(Object.getPrototypeOf(reg)).filter((k) => k !== "constructor").sort(), [])
			: [];
		return {
			wireVersion: WIRE_VERSION,
			ompVersion: omp.VERSION ?? null,
			pid: process.pid,
			evalId: EVAL_ID,
			mainAgentId: MAIN_AGENT_ID,
			capabilities: await probeCapabilities(mainCtx()),
			internalErrors: internals.errors,
			registryMethods,
		};
	},
};

// ---------------------------------------------------------------------------------------------------------------------
// Session hooks
// ---------------------------------------------------------------------------------------------------------------------

/** Refuses a switch (`/resume`, `/new` onto an existing file, …) into a session file the daemon owns. */
function vetoOwnedSwitch(event: unknown, rawCtx: unknown): { cancel: true } | undefined {
	try {
		const target = isRecord(event) && typeof event.targetSessionFile === "string" ? event.targetSessionFile : undefined;
		if (!isDaemonOwned(target)) return undefined;
		try {
			(rawCtx as CtxLike).ui?.notify?.(`${target} is open in omp IDE; open it from the IDE instead.`, "error");
		} catch {
			// Headless: the veto alone is enough.
		}
		return { cancel: true };
	} catch {
		return undefined;
	}
}

function registerLockMode(on: On): void {
	on("session_start", async (_event, rawCtx) => {
		if (!owns()) return;
		try {
			const file = (rawCtx as CtxLike).sessionManager.getSessionFile();
			if (isDaemonOwned(file)) refuse(file, "session_start");
		} catch {
			// Never break a session the daemon does not own.
		}
	});
	on("session_before_switch", async (event, rawCtx) => (owns() ? vetoOwnedSwitch(event, rawCtx) : undefined));
}

function registerDaemonMode(on: On, daemon: DaemonEnv): void {
	const inst: Instance = { isMain: false };

	on("session_start", async (_event, rawCtx) => {
		if (!owns()) return;
		try {
			const ctx = rawCtx as CtxLike;
			inst.ctx = ctx;
			inst.agentId = agentIdFor(ctx);
			if (!S.main && (inst.agentId === undefined || inst.agentId === MAIN_AGENT_ID)) {
				inst.isMain = true;
				inst.agentId ??= MAIN_AGENT_ID;
				S.main = inst;
				if (S.phase !== "idle") {
					log(`main session restarted after the daemon connection ended (${S.phase}); not reconnecting`);
					return;
				}
				// Not awaited: omp's startup waits for session_start handlers; the hello does not need the verdict.
				connectDaemon(daemon, ctx).catch((e: unknown) => {
					log(`daemon connection failed: ${errText(e)}`);
					endConnection("closed");
				});
				subscribeTitle(ctx);
				emit(inst.agentId, "session_start", { isMain: true, session: sessionInfo(ctx) });
				return;
			}
			emit(inst.agentId, "session_start", { isMain: false, session: sessionInfo(ctx) });
		} catch (e) {
			log(`session_start: ${errText(e)}`);
		}
	});

	on("session_switch", async (event, rawCtx) => {
		if (!owns()) return;
		try {
			const ctx = rawCtx as CtxLike;
			inst.ctx = ctx;
			if (inst.isMain) subscribeTitle(ctx);
			const ev = isRecord(event) ? event : {};
			emit(inst.agentId, "session_switch", {
				isMain: inst.isMain,
				reason: ev.reason ?? null,
				previousSessionFile: ev.previousSessionFile ?? null,
				session: sessionInfo(ctx),
			});
		} catch (e) {
			log(`session_switch: ${errText(e)}`);
		}
	});

	// Another IDE session's file (every file the daemon owns other than this session's own) is never opened here.
	on("session_before_switch", async (event, rawCtx) => (owns() ? vetoOwnedSwitch(event, rawCtx) : undefined));

	// Busy/idle of the session = the main agent's runs; child sessions fire these into their own instances.
	on("agent_start", async () => {
		if (!owns() || inst !== S.main) return;
		try {
			setActivity("busy");
		} catch (e) {
			log(`agent_start: ${errText(e)}`);
		}
	});

	on("agent_end", async (_event, rawCtx) => {
		if (!owns() || inst !== S.main) return;
		try {
			settleCheck(rawCtx as CtxLike);
		} catch (e) {
			log(`agent_end: ${errText(e)}`);
		}
	});

	on("before_subagent_spawn", async (event) => {
		if (!owns()) return undefined;
		try {
			const { type: _type, ...data } = isRecord(event) ? event : {};
			emit(inst.agentId, "before_subagent_spawn", data);
		} catch (e) {
			log(`before_subagent_spawn: ${errText(e)}`);
		}
		return undefined; // observe only; model routing stays with omp
	});

	on("session_shutdown", async () => {
		if (!owns()) return;
		try {
			const status = inst.agentId ? attempt(() => registryOrUndefined()?.get(inst.agentId ?? "")?.status, undefined) : undefined;
			emit(inst.agentId, "session_shutdown", { isMain: inst.isMain, status: status ?? null });
			// Child sessions shut down on every park; only the main session ends the connection.
			if (inst === S.main) {
				S.main = undefined;
				if (S.phase === "connecting" || S.phase === "accepted") endConnection("closed");
			}
		} catch (e) {
			log(`session_shutdown: ${errText(e)}`);
		}
	});
}

// ---------------------------------------------------------------------------------------------------------------------
// Factory: runs for the main session and again (same module state) for every child and revived session.
// ---------------------------------------------------------------------------------------------------------------------

export default function ideBridge(pi: ExtensionAPI): void {
	if (!owns()) return;
	// ExtensionAPI methods keep their binding when detached (extensions.md).
	const api = pi as unknown as { on: On; setLabel?: (label: string) => void };
	const on = api.on;
	attempt(() => api.setLabel?.("omp IDE bridge"), undefined);
	if (DAEMON) registerDaemonMode(on, DAEMON);
	else registerLockMode(on);
}
