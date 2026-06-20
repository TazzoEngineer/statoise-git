import Cocoa

/// Represents the graph layout info for a single commit row
struct GraphRowInfo {
    let lane: Int           // which lane this commit's node is in
    let lines: [GraphLine] // lines to draw (connections)
    let totalLanes: Int    // total number of active lanes at this row
    let hasLineAbove: Bool // whether to draw line above the node (has child)
    let hasLineBelow: Bool // whether to draw line below the node (has parent)
}

/// A line segment in the graph
struct GraphLine {
    let fromLane: Int
    let toLane: Int
    let colorIndex: Int
    let type: GraphLineType
}

enum GraphLineType {
    case passThrough    // lane passes through this row
    case nodeToParent   // from node downward to parent
    case branchOut      // merge commit: extra parent branch
}

/// Computes graph lane layout from log entries
class GitGraphCalculator {
    
    static func computeGraph(entries: [LogEntry]) -> [GraphRowInfo] {
        var result: [GraphRowInfo] = []
        // Active lanes: each lane tracks which commit hash it's "waiting for"
        var activeLanes: [String] = []
        
        for (rowIdx, entry) in entries.enumerated() {
            var lines: [GraphLine] = []
            
            // Find which lane this commit occupies
            var commitLane = activeLanes.firstIndex(of: entry.hash)
            
            let isFirstRow = (rowIdx == 0)
            let hasLineAbove: Bool
            
            if commitLane == nil {
                // New branch: add to first available slot or append
                commitLane = activeLanes.count
                activeLanes.append(entry.hash)
                hasLineAbove = false  // no child points to us from above
            } else {
                hasLineAbove = true   // a child already registered us in a lane
            }
            
            let lane = commitLane!
            let colorIdx = lane % laneColors.count
            
            // Draw pass-through lines for all active lanes (except the node lane)
            for (i, _) in activeLanes.enumerated() {
                if i == lane { continue }
                lines.append(GraphLine(fromLane: i, toLane: i, colorIndex: i % laneColors.count, type: .passThrough))
            }
            
            // Process parents
            let parents = entry.parents
            let hasLineBelow = !parents.isEmpty
            
            if parents.isEmpty {
                // Root commit: close this lane
                activeLanes.remove(at: lane)
            } else if parents.count == 1 {
                // Single parent: this lane now tracks the parent
                let parent = parents[0]
                
                // Check if parent is already in another lane
                if let existingLane = activeLanes.firstIndex(of: parent), existingLane != lane {
                    // Merge: draw line from current lane to existing lane, close current
                    lines.append(GraphLine(fromLane: lane, toLane: existingLane, colorIndex: colorIdx, type: .nodeToParent))
                    activeLanes.remove(at: lane)
                } else {
                    // Continue in same lane
                    activeLanes[lane] = parent
                    lines.append(GraphLine(fromLane: lane, toLane: lane, colorIndex: colorIdx, type: .nodeToParent))
                }
            } else {
                // Merge commit: first parent stays in this lane, others get new lanes
                activeLanes[lane] = parents[0]
                lines.append(GraphLine(fromLane: lane, toLane: lane, colorIndex: colorIdx, type: .nodeToParent))
                
                for pIdx in 1..<parents.count {
                    let parent = parents[pIdx]
                    // Check if already tracked
                    if activeLanes.contains(parent) { continue }
                    
                    // Add new lane for this parent
                    let newLane = activeLanes.count
                    activeLanes.append(parent)
                    lines.append(GraphLine(fromLane: lane, toLane: newLane, colorIndex: newLane % laneColors.count, type: .branchOut))
                }
            }
            
            result.append(GraphRowInfo(
                lane: lane,
                lines: lines,
                totalLanes: max(activeLanes.count, lane + 1),
                hasLineAbove: hasLineAbove && !isFirstRow,
                hasLineBelow: hasLineBelow
            ))
        }
        
        return result
    }
}

/// Colors for different lanes
let laneColors: [NSColor] = [
    .systemBlue,
    .systemGreen,
    .systemOrange,
    .systemPurple,
    .systemRed,
    .systemTeal,
    .systemPink,
    .systemYellow,
]

/// Custom view that draws the git graph for a single row
class GitGraphCellView: NSView {
    
    var graphRow: GraphRowInfo?
    var rowHeight: CGFloat = 20
    
    private let laneWidth: CGFloat = 14
    private let nodeRadius: CGFloat = 4
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        
        guard let info = graphRow else { return }
        
        let midY = bounds.height / 2
        let nodeX = CGFloat(info.lane) * laneWidth + laneWidth / 2
        let nodeColor = laneColors[info.lane % laneColors.count]
        
        // Draw line above node (from top edge to node center)
        if info.hasLineAbove {
            nodeColor.setStroke()
            let path = NSBezierPath()
            path.lineWidth = 1.5
            path.move(to: NSPoint(x: nodeX, y: bounds.height))
            path.line(to: NSPoint(x: nodeX, y: midY))
            path.stroke()
        }
        
        // Draw lines
        for line in info.lines {
            let color = laneColors[line.colorIndex % laneColors.count]
            color.setStroke()
            
            let path = NSBezierPath()
            path.lineWidth = 1.5
            
            let fromX = CGFloat(line.fromLane) * laneWidth + laneWidth / 2
            let toX = CGFloat(line.toLane) * laneWidth + laneWidth / 2
            
            switch line.type {
            case .passThrough:
                // Vertical line through entire cell
                path.move(to: NSPoint(x: fromX, y: bounds.height))
                path.line(to: NSPoint(x: toX, y: 0))
                
            case .nodeToParent:
                // Line from node center down to bottom
                if fromX == toX {
                    path.move(to: NSPoint(x: fromX, y: midY))
                    path.line(to: NSPoint(x: toX, y: 0))
                } else {
                    // Merging into another lane
                    path.move(to: NSPoint(x: fromX, y: midY))
                    path.line(to: NSPoint(x: toX, y: 0))
                }
                
            case .branchOut:
                // From node center to new lane at bottom
                path.move(to: NSPoint(x: fromX, y: midY))
                path.line(to: NSPoint(x: toX, y: 0))
            }
            
            path.stroke()
        }
        
        // Draw node circle
        let nodeRect = NSRect(
            x: nodeX - nodeRadius,
            y: midY - nodeRadius,
            width: nodeRadius * 2,
            height: nodeRadius * 2
        )
        
        nodeColor.setFill()
        let circle = NSBezierPath(ovalIn: nodeRect)
        circle.fill()
        
        NSColor.white.setFill()
        let innerRect = nodeRect.insetBy(dx: 1.5, dy: 1.5)
        let innerCircle = NSBezierPath(ovalIn: innerRect)
        innerCircle.fill()
        
        nodeColor.setFill()
        let dotRect = nodeRect.insetBy(dx: 2.5, dy: 2.5)
        let dot = NSBezierPath(ovalIn: dotRect)
        dot.fill()
    }
    
    /// Compute the required width based on the number of lanes
    static func widthForLanes(_ count: Int) -> CGFloat {
        return CGFloat(max(count, 1)) * 14 + 4
    }
}
