import Foundation
import KwekuKit

/// Every component on at once: how tall that is, and the one fact the closed
/// notch is allowed to carry.
enum DashboardTests {
    static func all() {
        rows()
        heights()
        status()
    }

    // MARK: Rows

    static func rows() {
        Check.run("the rows are the things you read, not the things you do") {
            Check.ok(DashboardLayout.rows == [.weather, .agents, .stats],
                     "got \(DashboardLayout.rows)")
            Check.ok(!DashboardLayout.rows.contains(.critter),
                     "the face is the frame, not a row")
            Check.ok(!DashboardLayout.rows.contains(.command),
                     "the prompt is an action; its enlarged form is a takeover")
        }
        Check.run("an enlarged row is a panel, not a taller line") {
            for row in DashboardLayout.rows {
                Check.ok(DashboardLayout.enlarged(row, agentCount: 3) > DashboardLayout.line,
                         "\(row.rawValue) unfolds into something worth unfolding")
            }
            // Each row keeps its own component's height rather than a shared
            // one, so unfolding weather and unfolding system aren't the same
            // gesture with the same result.
            Check.ok(DashboardLayout.enlarged(.weather, agentCount: 0)
                     != DashboardLayout.enlarged(.stats, agentCount: 0),
                     "each row is its own panel")
        }
        Check.run("the agents row is as tall as it has sessions") {
            let one = DashboardLayout.enlarged(.agents, agentCount: 1)
            let four = DashboardLayout.enlarged(.agents, agentCount: 4)
            Check.ok(four > one, "a row each")
            Check.ok(DashboardLayout.enlarged(.agents, agentCount: 0) >= DashboardLayout.line,
                     "and never collapses to nothing")
        }
    }

    // MARK: Heights

    static func heights() {
        Check.run("closed is the face band and nothing else") {
            Check.ok(DashboardLayout.closedBody == DashboardLayout.band,
                     "the notch at rest is what it always was")
        }
        Check.run("open is a line each, plus the one that's unfolded") {
            let plain = DashboardLayout.openBody(enlarged: .critter, agentCount: 0)
            let lines = CGFloat(DashboardLayout.rows.count) * DashboardLayout.line
            Check.eq(Double(plain),
                     Double(DashboardLayout.band + lines + DashboardLayout.footer
                            + DashboardLayout.padding),
                     "nothing enlarged is four plain lines")

            let withWeather = DashboardLayout.openBody(enlarged: .weather, agentCount: 0)
            Check.eq(Double(withWeather - plain),
                     Double(DashboardLayout.enlarged(.weather, agentCount: 0)
                            - DashboardLayout.line),
                     "enlarging one row costs exactly that row's panel, and nothing else moves")
        }
        Check.run("only one row is ever enlarged") {
            // Enlarging the tallest row is still cheaper than two of them —
            // the accordion can never stack two panels by accident.
            let stats = DashboardLayout.openBody(enlarged: .stats, agentCount: 0)
            let weather = DashboardLayout.openBody(enlarged: .weather, agentCount: 0)
            let plain = DashboardLayout.openBody(enlarged: .critter, agentCount: 0)
            let both = (stats - plain) + (weather - plain) + plain
            Check.ok(max(stats, weather) < both, "never both at once")
        }
        Check.run("the open notch stays a notch") {
            let tallest = DashboardLayout.openBody(enlarged: .agents, agentCount: 40)
            Check.ok(tallest < 320, "even forty sessions can't run off the screen, got \(tallest)")
        }
    }

    // MARK: Status line

    static func status() {
        Check.run("the closed band stays empty unless there's something owed") {
            Check.ok(DashboardStatus.line(agents: 0, waiting: 0) == nil,
                     "a band that always says something stops being read")
        }
        Check.run("it counts sessions, and waiting outranks running") {
            Check.ok(DashboardStatus.line(agents: 1, waiting: 0) == "1 agent", "singular")
            Check.ok(DashboardStatus.line(agents: 3, waiting: 0) == "3 agents", "plural")
            Check.ok(DashboardStatus.line(agents: 3, waiting: 1) == "1 waiting",
                     "the one with a deadline wins")
        }
    }
}
