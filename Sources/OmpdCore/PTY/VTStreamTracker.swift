/// Shadows the parser state of SwiftTerm's `EscapeSequenceParser` (VT500 table, SwiftTerm 1.20) plus the
/// UTF-8 put-back buffer of `Terminal.handlePrint`, fed with exactly the same chunks as the headless terminal.
///
/// It answers two questions the terminal itself does not expose:
/// - `isClean`: is the parser in ground state with no partial UTF-8 held? Only then is it safe to inject
///   probe sequences into the headless terminal.
/// - `pendingBytes`: the bytes of the sequence (or UTF-8 character) still in flight. A client that repaints from
///   a serialized screen must also receive these, otherwise the continuation that arrives in the next live chunk
///   would be misparsed ("no gap" on attach).
///
/// The transition table is a literal port of `EscapeSequenceParser.buildVt500TransitionTable()` (next states and
/// the actions that influence state or buffering); the fast paths of `parse(data:)` that skip the table (ground
/// print runs, CSI digits, the OSC/APC put loop) are mirrored because they change behaviour at chunk boundaries.
struct VTStreamTracker {
    enum State: UInt8 {
        case ground = 0, escape, escapeIntermediate, csiEntry, csiParam, csiIntermediate, csiIgnore
        case sosPmApcString, oscString, apcString, dcsEntry, dcsParam, dcsIgnore, dcsIntermediate, dcsPassthrough
    }

    enum Action: UInt8 {
        case ignore = 0, error, print, execute, oscStart, oscPut, oscEnd, csiDispatch, param, collect
        case escDispatch, clear, dcsHook, dcsPut, dcsUnhook
    }

    /// Longest in-flight sequence kept verbatim; beyond it only a neutral introducer is replayed.
    static let pendingLimit = 64 * 1024

    private(set) var state: State = .ground
    /// Bytes held by SwiftTerm's UTF-8 put-back buffer (an incomplete multi-byte character).
    private var heldUTF8: [UInt8] = []
    private var utf8Needed = 0
    /// Bytes of the escape sequence in flight, excluding C0 controls the terminal already executed.
    private var sequence: [UInt8] = []
    private var sequenceOverflowed = false

    var isClean: Bool { state == .ground && heldUTF8.isEmpty }

    /// Bytes that put a fresh parser into the same in-flight state (empty when clean).
    var pendingBytes: [UInt8] {
        if state == .ground { return heldUTF8 }
        if !sequenceOverflowed { return sequence }
        // Too long to keep: open an equivalent string state that swallows the remainder harmlessly.
        switch state {
        case .oscString: return Array("\u{1b}]9999;".utf8)
        case .apcString: return Array("\u{1b}_~".utf8)
        case .sosPmApcString: return Array("\u{1b}X".utf8)
        case .dcsEntry, .dcsParam, .dcsIgnore, .dcsIntermediate, .dcsPassthrough: return Array("\u{1b}P:".utf8)
        default: return []
        }
    }

    mutating func consume(_ data: UnsafeBufferPointer<UInt8>) {
        let table = Self.table
        let end = data.count
        var i = 0
        while i < end {
            let code = data[i]

            if state == .ground && code > 0x1f {
                // Print run: mirrors the ground fast path plus the UTF-8 put-back of handlePrint.
                var j = i
                repeat {
                    trackPrinted(data[j])
                    j += 1
                } while j < end && data[j] > 0x1f
                i = j
                continue
            }
            if state == .csiParam && code > 0x2f && code < 0x3a {
                appendToSequence(code)
                i += 1
                continue
            }

            let transition = table[(Int(state.rawValue) << 8) | Int(code < 0xa0 ? code : 0xa0)]
            let action = Action(rawValue: transition >> 4)!
            var next = State(rawValue: transition & 15)!
            var fastLoopEnd: Int?

            switch action {
            case .error:
                if code > 0x9f {
                    switch state {
                    case .csiIgnore: next = .csiIgnore
                    case .dcsIgnore: next = .dcsIgnore
                    case .dcsPassthrough: next = .dcsPassthrough
                    default: break
                    }
                }
            case .clear:
                resetUTF8()
            case .oscEnd, .dcsUnhook:
                resetUTF8()
                if code == 0x1b { next = .escape }
            case .oscPut:
                var j = i
                while j < end {
                    let c = data[j]
                    if c == 0x07 || c == 0x18 || c == 0x1b { break }
                    j += 1
                }
                fastLoopEnd = j
            default:
                break
            }

            state = next
            if next == .ground {
                sequence.removeAll(keepingCapacity: true)
                sequenceOverflowed = false
            } else if Self.startsSequence(code, next: next) {
                sequence.removeAll(keepingCapacity: true)
                sequenceOverflowed = false
                sequence.append(code)
            } else if let j = fastLoopEnd {
                appendToSequence(UnsafeBufferPointer(rebasing: data[i..<j]))
                i = j - 1
            } else if action != .execute {
                appendToSequence(code)
            }
            i += 1
        }
    }

    // MARK: - Internals

    /// ESC and C1 introducers (re)start a sequence: whatever was in flight has been dispatched or dropped.
    /// (C1 bytes only reach the table outside ground state; in ground they are printed.)
    private static func startsSequence(_ code: UInt8, next: State) -> Bool {
        switch code {
        case 0x1b: return next == .escape
        case 0x90, 0x98, 0x9b, 0x9d, 0x9e, 0x9f: return true
        default: return false
        }
    }

    private mutating func trackPrinted(_ byte: UInt8) {
        if utf8Needed > 0 {
            utf8Needed -= 1
            if utf8Needed == 0 { heldUTF8.removeAll(keepingCapacity: true) } else { heldUTF8.append(byte) }
            return
        }
        let size: Int
        switch byte {
        case 0xc2...0xdf: size = 2
        case 0xe0...0xef: size = 3
        case 0xf0...0xf4: size = 4
        default: size = 1
        }
        if size > 1 {
            utf8Needed = size - 1
            heldUTF8.append(byte)
        }
    }

    private mutating func resetUTF8() {
        heldUTF8.removeAll(keepingCapacity: true)
        utf8Needed = 0
    }

    private mutating func appendToSequence(_ byte: UInt8) {
        guard !sequenceOverflowed else { return }
        if sequence.count >= Self.pendingLimit { sequenceOverflowed = true; return }
        sequence.append(byte)
    }

    private mutating func appendToSequence(_ bytes: UnsafeBufferPointer<UInt8>) {
        guard !sequenceOverflowed else { return }
        if sequence.count + bytes.count > Self.pendingLimit { sequenceOverflowed = true; return }
        sequence.append(contentsOf: bytes)
    }

    // MARK: - Transition table (port of EscapeSequenceParser.buildVt500TransitionTable)

    /// `(action << 4) | next`, indexed by `state << 8 | min(code, 0xa0)`.
    private static let table: [UInt8] = {
        var t = [UInt8](repeating: 0, count: 4095)
        func add(_ code: UInt8, _ state: State, _ action: Action, _ next: State) {
            t[(Int(state.rawValue) << 8) | Int(code)] = (action.rawValue << 4) | next.rawValue
        }
        func add(_ codes: [UInt8], _ state: State, _ action: Action, _ next: State) {
            for c in codes { add(c, state, action, next) }
        }
        func r(_ low: UInt8, _ high: UInt8) -> [UInt8] { Array(low..<high) }

        let states: [State] = (0...14).map { State(rawValue: $0)! }
        for state in states {
            for code in 0...UInt8(0xa0) { add(code, state, .error, .ground) }
        }
        let printables = r(0x20, 0x7f)
        let executables = r(0x00, 0x19) + r(0x1c, 0x20)
        add(printables, .ground, .print, .ground)
        for state in states {
            add([0x18, 0x1a, 0x99, 0x9a], state, .execute, .ground)
            add(r(0x80, 0x90), state, .execute, .ground)
            add(r(0x90, 0x98), state, .execute, .ground)
            add(0x9c, state, .ignore, .ground)
            add(0x1b, state, .clear, .escape)
            add(0x9d, state, .oscStart, .oscString)
            add([0x98, 0x9e], state, .ignore, .sosPmApcString)
            add(0x9f, state, .oscStart, .apcString)
            add(0x9b, state, .clear, .csiEntry)
            add(0x90, state, .clear, .dcsEntry)
        }
        add(executables, .ground, .execute, .ground)
        add(executables, .escape, .execute, .escape)
        add(0x7f, .escape, .ignore, .escape)
        add(executables, .oscString, .ignore, .oscString)
        add(executables, .apcString, .ignore, .apcString)
        add(executables, .csiEntry, .execute, .csiEntry)
        add(0x7f, .csiEntry, .ignore, .csiEntry)
        add(executables, .csiParam, .execute, .csiParam)
        add(0x7f, .csiParam, .ignore, .csiParam)
        add(executables, .csiIgnore, .execute, .csiIgnore)
        add(executables, .csiIntermediate, .execute, .csiIntermediate)
        add(0x7f, .csiIntermediate, .ignore, .csiIntermediate)
        add(executables, .escapeIntermediate, .execute, .escapeIntermediate)
        add(0x7f, .escapeIntermediate, .ignore, .escapeIntermediate)
        // osc
        add(0x5d, .escape, .oscStart, .oscString)
        add(printables, .oscString, .oscPut, .oscString)
        add(0x7f, .oscString, .oscPut, .oscString)
        add([0x9c, 0x1b, 0x18, 0x1a, 0x07], .oscString, .oscEnd, .ground)
        add(r(0x1c, 0x20), .oscString, .ignore, .oscString)
        // apc
        add(0x5f, .escape, .oscStart, .apcString)
        add(printables, .apcString, .oscPut, .apcString)
        add(0x7f, .apcString, .oscPut, .apcString)
        add([0x9c, 0x1b, 0x18, 0x1a, 0x07], .apcString, .oscEnd, .ground)
        add(r(0x1c, 0x20), .apcString, .ignore, .apcString)
        // sos/pm
        add([0x58, 0x5e], .escape, .ignore, .sosPmApcString)
        add(printables, .sosPmApcString, .ignore, .sosPmApcString)
        add(executables, .sosPmApcString, .ignore, .sosPmApcString)
        add(0x9c, .sosPmApcString, .ignore, .ground)
        add(0x7f, .sosPmApcString, .ignore, .sosPmApcString)
        // csi
        add(0x5b, .escape, .clear, .csiEntry)
        add(r(0x40, 0x7f), .csiEntry, .csiDispatch, .ground)
        add(r(0x30, 0x3a), .csiEntry, .param, .csiParam)
        add(0x3b, .csiEntry, .param, .csiParam)
        add([0x3c, 0x3d, 0x3e, 0x3f], .csiEntry, .collect, .csiParam)
        add(r(0x30, 0x3a), .csiParam, .param, .csiParam)
        add(0x3b, .csiParam, .param, .csiParam)
        add(r(0x40, 0x7f), .csiParam, .csiDispatch, .ground)
        add([0x3c, 0x3d, 0x3e, 0x3f], .csiParam, .ignore, .csiIgnore)
        add(0x3a, .csiParam, .param, .csiParam)
        add(r(0x20, 0x40), .csiIgnore, .ignore, .csiIgnore)
        add(0x7f, .csiIgnore, .ignore, .csiIgnore)
        add(r(0x40, 0x7f), .csiIgnore, .ignore, .ground)
        add(r(0x20, 0x30), .csiEntry, .collect, .csiIntermediate)
        add(r(0x20, 0x30), .csiIntermediate, .collect, .csiIntermediate)
        add(r(0x30, 0x40), .csiIntermediate, .ignore, .csiIgnore)
        add(r(0x40, 0x7f), .csiIntermediate, .csiDispatch, .ground)
        add(r(0x20, 0x30), .csiParam, .collect, .csiIntermediate)
        // esc intermediate
        add(r(0x20, 0x30), .escape, .collect, .escapeIntermediate)
        add(r(0x20, 0x30), .escapeIntermediate, .collect, .escapeIntermediate)
        add(r(0x30, 0x7f), .escapeIntermediate, .escDispatch, .ground)
        add(r(0x30, 0x50), .escape, .escDispatch, .ground)
        add(r(0x51, 0x58), .escape, .escDispatch, .ground)
        add([0x59, 0x5a, 0x5c], .escape, .escDispatch, .ground)
        add(r(0x60, 0x7f), .escape, .escDispatch, .ground)
        // dcs
        add(0x50, .escape, .clear, .dcsEntry)
        add(executables, .dcsEntry, .ignore, .dcsEntry)
        add(0x7f, .dcsEntry, .ignore, .dcsEntry)
        add(r(0x1c, 0x20), .dcsEntry, .ignore, .dcsEntry)
        add(r(0x20, 0x30), .dcsEntry, .collect, .dcsIntermediate)
        add(0x3a, .dcsEntry, .ignore, .dcsIgnore)
        add(r(0x30, 0x3a), .dcsEntry, .param, .dcsParam)
        add(0x3b, .dcsEntry, .param, .dcsParam)
        add([0x3c, 0x3d, 0x3e, 0x3f], .dcsEntry, .collect, .dcsParam)
        add(executables, .dcsIgnore, .ignore, .dcsIgnore)
        add(r(0x20, 0x80), .dcsIgnore, .ignore, .dcsIgnore)
        add(r(0x1c, 0x20), .dcsIgnore, .ignore, .dcsIgnore)
        add(executables, .dcsParam, .ignore, .dcsParam)
        add(0x7f, .dcsParam, .ignore, .dcsParam)
        add(r(0x1c, 0x20), .dcsParam, .ignore, .dcsParam)
        add(r(0x30, 0x3a), .dcsParam, .param, .dcsParam)
        add(0x3b, .dcsParam, .param, .dcsParam)
        add([0x3a, 0x3c, 0x3d, 0x3e, 0x3f], .dcsParam, .ignore, .dcsIgnore)
        add(r(0x20, 0x30), .dcsParam, .collect, .dcsIntermediate)
        add(executables, .dcsIntermediate, .ignore, .dcsIntermediate)
        add(0x7f, .dcsIntermediate, .ignore, .dcsIntermediate)
        add(r(0x1c, 0x20), .dcsIntermediate, .ignore, .dcsIntermediate)
        add(r(0x20, 0x30), .dcsIntermediate, .collect, .dcsIntermediate)
        add(r(0x30, 0x40), .dcsIntermediate, .ignore, .dcsIgnore)
        add(r(0x40, 0x7f), .dcsIntermediate, .dcsHook, .dcsPassthrough)
        add(r(0x40, 0x7f), .dcsParam, .dcsHook, .dcsPassthrough)
        add(r(0x40, 0x7f), .dcsEntry, .dcsHook, .dcsPassthrough)
        add(executables, .dcsPassthrough, .dcsPut, .dcsPassthrough)
        add(printables, .dcsPassthrough, .dcsPut, .dcsPassthrough)
        add(0x7f, .dcsPassthrough, .ignore, .dcsPassthrough)
        add([0x1b, 0x9c], .dcsPassthrough, .dcsUnhook, .ground)
        add(0xa0, .oscString, .oscPut, .oscString)
        add(0xa0, .apcString, .oscPut, .apcString)
        return t
    }()
}
