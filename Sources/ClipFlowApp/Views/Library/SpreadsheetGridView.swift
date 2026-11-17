import AppKit
import SwiftUI

/// Compact grid for a copied table. Detail scrolls; the history row shows the first cells and a cue.
struct SpreadsheetGridView: View {
    enum Style {
        case detail
        case inline
    }

    let grid: SpreadsheetPreviewGrid
    var style: Style = .detail

    @Environment(\.colorScheme) private var colorScheme
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        let visible = slice
        VStack(alignment: .leading, spacing: 0) {
            if style == .detail {
                GeometryReader { proxy in
                    let sheet = measuredGrid(visible.rows)
                    if contentHeight > proxy.size.height + 1 {
                        ScrollView([.horizontal, .vertical], showsIndicators: true) {
                            sheet
                        }
                    } else {
                        // A short sheet stays under the title. A scroll view would center it.
                        VStack(spacing: 0) {
                            ScrollView(.horizontal, showsIndicators: true) {
                                sheet
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
                .onPreferenceChange(GridContentHeightKey.self) { contentHeight = $0 }
            } else {
                gridBody(visible.rows, scrolls: false)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 4)
            }
            if let caption = visible.caption {
                Text(caption)
                    .font(.system(size: style == .detail ? 10 : 9))
                    .foregroundStyle(ClipFlowPalette.secondaryText(for: colorScheme))
                    .lineLimit(1)
                    .padding(.horizontal, style == .detail ? 12 : 6)
                    .padding(.bottom, style == .detail ? 8 : 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: style == .detail ? .infinity : nil, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityText)
    }

    private var slice: (rows: [[String]], caption: String?) {
        if style == .detail {
            return (grid.rows, grid.overflowCaption)
        }
        let rows = grid.rows.prefix(Self.inlineRowLimit).map { Array($0.prefix(Self.inlineColumnLimit)) }
        let caption = SpreadsheetPreviewGrid.overflowCaption(
            omittedRows: grid.omittedRowCount + max(0, grid.rows.count - rows.count),
            omittedColumns: grid.omittedColumnCount + max(0, grid.columnCount - (rows.first?.count ?? 0))
        )
        return (Array(rows), caption)
    }

    private var accessibilityText: String {
        let rows = grid.rows.count + grid.omittedRowCount
        let columns = grid.columnCount + grid.omittedColumnCount
        return "表格，\(rows) 行 \(columns) 列"
    }

    private var line: Color { Color.primary.opacity(0.12) }
    private var fontSize: CGFloat { style == .detail ? 12 : 11 }

    private func measuredGrid(_ rows: [[String]]) -> some View {
        gridBody(rows, scrolls: true)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(GeometryReader { proxy in
                Color.clear.preference(key: GridContentHeightKey.self, value: proxy.size.height)
            })
    }

    private func gridBody(_ rows: [[String]], scrolls: Bool) -> some View {
        let widths = scrolls ? columnWidths(for: rows) : []
        return VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                HStack(spacing: 0) {
                    ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                        cellView(cell, scrolls: scrolls, width: widths.indices.contains(column) ? widths[column] : nil)
                            .overlay(alignment: .trailing) {
                                if column + 1 < row.count {
                                    Rectangle().fill(line).frame(width: 1)
                                }
                            }
                    }
                }
                .background(rowIndex.isMultiple(of: 2) ? Color.primary.opacity(0.035) : Color.clear)
                .overlay(alignment: .bottom) {
                    if rowIndex + 1 < rows.count {
                        Rectangle().fill(line).frame(height: 1)
                    }
                }
            }
        }
        .overlay(Rectangle().strokeBorder(line, lineWidth: 1))
        .fixedSize(horizontal: scrolls, vertical: false)
    }

    private func cellView(_ text: String, scrolls: Bool, width: CGFloat?) -> some View {
        Text(display(text))
            .font(.system(size: fontSize))
            .monospacedDigit()
            .foregroundStyle(Color.primary)
            .lineLimit(scrolls ? 3 : 1)
            .multilineTextAlignment(.leading)
            .textSelection(.enabled)
            .padding(.horizontal, scrolls ? 8 : 6)
            .padding(.vertical, scrolls ? 5 : 3)
            .frame(minHeight: scrolls ? 28 : 20, alignment: .leading)
            .frame(maxWidth: width == nil ? .infinity : width, alignment: .leading)
            .frame(width: width, alignment: .leading)
    }

    private func display(_ text: String) -> String {
        guard style == .inline else { return text }
        return text.replacingOccurrences(of: "\n", with: " ")
    }

    private func columnWidths(for rows: [[String]]) -> [CGFloat] {
        let font = NSFont.systemFont(ofSize: fontSize)
        let count = rows.map(\.count).max() ?? 0
        var widths = Array(repeating: CGFloat(56), count: count)
        for row in rows {
            for (index, cell) in row.enumerated() {
                let measured = ceil((cell as NSString).size(withAttributes: [.font: font]).width + 28)
                widths[index] = min(220, max(widths[index], measured))
            }
        }
        return widths
    }

    private static let inlineRowLimit = 3
    private static let inlineColumnLimit = 4
}

private struct GridContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
