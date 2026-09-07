import SwiftUI

/// What lives in the nook when music isn't playing. Scrolling over the notch
/// steps through these in order.
///
/// Adding a component is meant to be cheap: a case here, an entry in
/// `descriptor`, and a view in the switch in `NotchContentRoot`. Sizing used to
/// be a fourth branch buried inside `updateSize()`, which is why each new mode
/// cost more than the last — the component now declares its own metrics and the
/// shell just asks.
public enum NookMode: String, CaseIterable {
    case critter, weather, agents, stats, command

    /// The mode `step` places away, wrapping in both directions.
    public func advanced(by step: Int) -> NookMode {
        let all = NookMode.allCases
        guard let index = all.firstIndex(of: self) else { return .critter }
        let n = all.count
        return all[((index + step) % n + n) % n]
    }

    /// Menu title.
    public var title: String {
        switch self {
        case .critter: return "Critter"
        case .weather: return "Weather"
        case .agents:  return "Agents"
        case .stats:   return "System"
        case .command: return "Command"
        }
    }
}

/// How much room a component wants, in the two states it can be in.
///
/// `peek` is the band below the cutout while the notch is closed; `expandedBody`
/// the body on hover. `expandedWidth` is a *minimum* — the shell takes the max
/// of it and whatever the strips below need, so a component never has to know
/// what else is on screen.
public struct NookMetrics: Equatable {
    public var peek: CGFloat
    public var expandedBody: CGFloat
    public var expandedWidth: CGFloat

    public init(peek: CGFloat, expandedBody: CGFloat, expandedWidth: CGFloat) {
        self.peek = peek
        self.expandedBody = expandedBody
        self.expandedWidth = expandedWidth
    }

    /// Body height for the given open state.
    public func body(open: Bool) -> CGFloat { open ? expandedBody : peek }
}

/// The handful of live facts a component's size may depend on. Passing a value
/// type keeps the sizing pure, so it can be unit-tested without a running app.
public struct NookContext: Equatable {
    /// Sessions in the agent table — the agent panel grows a row each.
    public var agentCount: Int

    public init(agentCount: Int = 0) {
        self.agentCount = agentCount
    }
}

/// A view that can occupy the nook. Static because the shell needs the numbers
/// while deciding how big to make the window, which is before any instance of
/// the view exists.
public protocol NookComponent {
    static func metrics(_ context: NookContext) -> NookMetrics
}

public extension NookMode {
    /// The component's own sizing. One switch, in one file, instead of the same
    /// switch repeated in `updateSize`, the mode stack and the menu.
    func metrics(_ context: NookContext) -> NookMetrics {
        switch self {
        case .critter: return CreatureView.metrics(context)
        case .weather: return WeatherView.metrics(context)
        case .agents:  return AgentModeView.metrics(context)
        case .stats:   return StatsView.metrics(context)
        case .command: return CommandView.metrics(context)
        }
    }
}

/// Pure window-sizing for the nook, split out of the view so the arithmetic can
/// be tested. The view supplies what's showing; this decides how big the window
/// has to be for all of it to fit.
public enum NookLayout {

    /// A strip hanging below the mode body (agent panel, captions, shelf).
    public struct Strip: Equatable {
        public var height: CGFloat
        public var minWidth: CGFloat

        public init(height: CGFloat, minWidth: CGFloat) {
            self.height = height
            self.minWidth = minWidth
        }
    }

    /// The window size for a nook mode plus its strips.
    public static func size(base: CGSize, mode: NookMode, open: Bool,
                            context: NookContext, strips: [Strip]) -> CGSize {
        size(base: base, metrics: mode.metrics(context), open: open, strips: strips)
    }

    /// The window size for any component's metrics plus its strips.
    ///
    /// Takes metrics rather than a `NookMode` so components that *take over*
    /// the nook rather than being scrolled to — a running Live session — size
    /// themselves through the same arithmetic instead of a second copy of it.
    ///
    /// Width is the widest thing showing but never narrower than the notch;
    /// height is the cutout plus the component's body plus every strip.
    public static func size(base: CGSize, metrics: NookMetrics, open: Bool,
                            strips: [Strip]) -> CGSize {
        var width = base.width
        var height = base.height + metrics.body(open: open)
        if open { width = max(width, metrics.expandedWidth) }
        for strip in strips {
            width = max(width, strip.minWidth)
            height += strip.height
        }
        return CGSize(width: width, height: height)
    }
}
