import Darwin
import Foundation
import IDEProtocol
import IDETransport
import OmpdCore

let usage = """
    usage: ompd run [--omp <path>] [--omp-arg <arg>]... [--session-dir <dir>]
           ompd status [--json]
           ompd --version

      run      Start the daemon (normally launched by the omp IDE LaunchAgent). $OMPD_HOME relocates its files.
               --omp          omp executable for new sessions (default: $OMP_BIN, PATH, /opt/homebrew/bin/omp)
               --omp-arg      argument appended to every new session's omp command line (repeatable)
               --session-dir  omp --session-dir for new sessions (default: omp's per-workspace directory)
      status   Ask the running daemon for its sessions and PTYs (session TUIs and terminals).
    """

struct UsageError: Error, CustomStringConvertible {
    let description: String
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("ompd: \(message)\n".utf8))
    exit(1)
}

func parseRun(_ arguments: ArraySlice<String>) throws -> DaemonRunner.Options {
    var options = DaemonRunner.Options()
    var rest = arguments
    func value(for flag: String) throws -> String {
        guard let value = rest.popFirst() else { throw UsageError(description: "\(flag) needs a value") }
        return value
    }
    while let argument = rest.popFirst() {
        switch argument {
        case "--omp": options.ompExecutable = try value(for: argument)
        case "--omp-arg": options.ompArguments.append(try value(for: argument))
        case "--session-dir": options.sessionDirectory = try value(for: argument)
        default: throw UsageError(description: "unknown argument \(argument)")
        }
    }
    return options
}

func status(json: Bool) async throws {
    let paths = AppSupportPaths.standard
    guard let tokenData = FileManager.default.contents(atPath: paths.token.path(percentEncoded: false)),
          let token = String(data: tokenData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    else {
        fail("ompd is not running (no token at \(paths.token.path(percentEncoded: false)))")
    }
    let client = IDEClient(socketPath: paths.socket.path(percentEncoded: false), token: token, clientVersion: "ompd-cli \(ompdVersion)")
    do {
        _ = try await client.connect()
    } catch {
        fail("cannot reach ompd at \(paths.socket.path(percentEncoded: false)): \(error)")
    }
    let result = try await client.call(DaemonStatus.self, Empty())
    await client.close()
    if json {
        let encoder = IDECoding.encoder()
        encoder.outputFormatting.insert(.prettyPrinted)
        FileHandle.standardOutput.write(try encoder.encode(result) + Data("\n".utf8))
        return
    }
    print(StatusTable.render(result))
}

enum StatusTable {
    static func render(_ status: DaemonStatus.Result) -> String {
        var lines = [
            "ompd \(status.daemonVersion)  pid \(status.pid)  up since \(stamp(status.startedAt))\(status.readOnly ? "  READ-ONLY (manifest write failed)" : "")",
            "",
        ]
        if status.sessions.isEmpty {
            lines.append("no sessions")
        } else {
            var rows = [["SESSION", "STATUS", "PTY", "LAST ACTIVE", "WORKSPACE", "TITLE"]]
            for entry in status.sessions {
                rows.append([
                    entry.sessionKey, entry.closedByUser && entry.status == .closed ? "closed (by user)" : entry.status.rawValue,
                    entry.ptyId ?? "-", entry.lastActiveAt.map(stamp) ?? "-", entry.workspace, entry.title ?? "-",
                ])
            }
            lines += table(rows)
        }
        lines.append("")
        if status.ptys.isEmpty {
            lines.append("no PTYs")
        } else {
            var rows = [["PTY", "SESSION", "PID", "SIZE", "CWD", "COMMAND"]]
            for pty in status.ptys {
                rows.append([
                    pty.ptyId, pty.sessionKey ?? "-", pty.pid.map(String.init) ?? (pty.running ? "?" : "exited"),
                    "\(pty.cols)x\(pty.rows)", pty.cwd, pty.command.joined(separator: " "),
                ])
            }
            lines += table(rows)
        }
        return lines.joined(separator: "\n")
    }

    private static func table(_ rows: [[String]]) -> [String] {
        let widths = rows[0].indices.map { column in rows.map { $0[column].count }.max() ?? 0 }
        return rows.map { row in
            row.enumerated().map { column, cell in
                column == row.count - 1 ? cell : cell.padding(toLength: widths[column], withPad: " ", startingAt: 0)
            }.joined(separator: "  ")
        }
    }

    private static func stamp(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
    }
}

let arguments = CommandLine.arguments.dropFirst()
switch arguments.first {
case "run":
    let options: DaemonRunner.Options
    do {
        options = try parseRun(arguments.dropFirst())
    } catch {
        fail("\(error)\n\(usage)")
    }
    do {
        exit(try await DaemonRunner.run(options))
    } catch {
        DaemonRunner.console("ompd failed: \(error)")
        exit(1)
    }
case "status":
    let rest = Array(arguments.dropFirst())
    guard rest.isEmpty || rest == ["--json"] else { fail("usage: ompd status [--json]") }
    do {
        try await status(json: rest == ["--json"])
    } catch {
        fail("\(error)")
    }
case "--version", "version":
    print("ompd \(ompdVersion)")
case "--help", "-h", "help":
    print(usage)
default:
    fail(usage)
}
