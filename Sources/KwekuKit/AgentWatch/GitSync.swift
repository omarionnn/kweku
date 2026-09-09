import Foundation

/// Recognising a git operation that talks to a remote, from the shell command
/// an agent is about to run.
///
/// The rim already lit up for these — a push is a `Bash` tool call like any
/// other, so it drew the amber tool comet. What it could not say was *which*
/// thing was happening, and talking to GitHub is the one tool call whose
/// outcome you might actually want to watch for.
///
/// This reads the command rather than wrapping git, because Claude Code's hook
/// payload already carries it: the installed hook forwards the whole stdin
/// object to the socket, `tool_input.command` included. Nothing new has to be
/// installed, and no `git` on the machine has to be intercepted.
///
/// It deliberately does not try to report a *fraction*. Measured on this repo,
/// a push takes ~1.2s and a fetch ~2.1s, nearly all of it SSH handshake and ref
/// negotiation; the object transfer is over in milliseconds. A percentage would
/// sit at zero and then jump, and `NotchRimStyle.progress` is documented as
/// being for things with a genuinely measurable extent, never an inferred one.
public enum GitSync {
    /// Which way the bytes are going.
    public enum Direction: String, Equatable, Sendable {
        case push
        case pull
    }

    /// Subcommands that reach the network, and the direction they read as.
    /// `clone` and `fetch` are pulls in every sense that matters here.
    private static let remoteSubcommands: [String: Direction] = [
        "push": .push,
        "pull": .pull,
        "fetch": .pull,
        "clone": .pull,
    ]

    /// Global options that take a separate value argument, so the token after
    /// them is that value and not the subcommand. `git -C ~/x push` is the
    /// common one here — every worktree command in this project uses it.
    private static let optionsTakingValue: Set<String> = ["-C", "-c", "--git-dir",
                                                          "--work-tree", "--namespace",
                                                          "--exec-path", "--config-env"]

    /// The direction of the first remote-touching git command in `command`,
    /// or nil when there isn't one.
    ///
    /// A compound command is split first, so `make test && git push` is seen.
    /// The first match wins: a line that both pushes and fetches is doing one
    /// thing as far as a single rim can say.
    public static func direction(forCommand command: String) -> Direction? {
        for segment in segments(of: command) {
            if let direction = directionOfSingle(segment) { return direction }
        }
        return nil
    }

    /// Split on the separators that start a new command. Quoting is not
    /// honoured, which can only ever cause a false *positive* on a line that
    /// mentions a push inside a string — a wrong colour on the rim for a second
    /// and nothing else. Missing a real push is the worse failure, so the
    /// bias goes this way on purpose.
    private static func segments(of command: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var index = command.startIndex
        while index < command.endIndex {
            let character = command[index]
            let next = command.index(after: index)
            if character == "&" || character == "|" {
                // `&&` and `||` and a bare pipe all begin a new command.
                parts.append(current)
                current = ""
                if next < command.endIndex, command[next] == character {
                    index = command.index(after: next)
                } else {
                    index = next
                }
                continue
            }
            if character == ";" || character == "\n" {
                parts.append(current)
                current = ""
                index = next
                continue
            }
            current.append(character)
            index = next
        }
        parts.append(current)
        return parts
    }

    /// One command, already split off. Finds `git` and then its subcommand,
    /// stepping over the global options that sit between them.
    private static func directionOfSingle(_ segment: String) -> Direction? {
        var tokens = segment.split(whereSeparator: \.isWhitespace).map(String.init)

        // Strip a leading `env` and any VAR=value assignments, which is how a
        // command with an environment override reaches the shell.
        while let first = tokens.first,
              first == "env" || (first.contains("=") && !first.hasPrefix("-")) {
            tokens.removeFirst()
        }

        // `git`, `/usr/bin/git`, `"git"` — compare on the last path component.
        guard let executable = tokens.first,
              executable.split(separator: "/").last.map(String.init)?
                  .trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) == "git"
        else { return nil }

        var rest = tokens.dropFirst()
        while let token = rest.first {
            if optionsTakingValue.contains(token) {
                rest = rest.dropFirst(2)   // the flag and its value
                continue
            }
            if token.hasPrefix("-") {
                rest = rest.dropFirst()    // a valueless flag, or --opt=value
                continue
            }
            return remoteSubcommands[token]
        }
        return nil
    }
}
