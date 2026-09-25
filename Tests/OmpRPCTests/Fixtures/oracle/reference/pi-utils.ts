// `isRecord` from packages/utils/src/type-guards.ts (@oh-my-pi/pi-utils) at can1357/oh-my-pi v18.3.1 (MIT, see LICENSE),
// the only import rpc-frame.ts needs from that package.
export function isRecord(value: unknown): value is Record<string, unknown> {
	return !!value && typeof value === "object" && !Array.isArray(value);
}
