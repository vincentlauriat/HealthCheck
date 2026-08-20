import SwiftUI

/// Diagramme de Sankey de la répartition du poids : barres de nœuds sur
/// 3 colonnes, rubans de Bézier dont l'épaisseur est proportionnelle aux kg.
/// Dessin maison — Swift Charts n'a pas de Sankey.
struct WeightSankeyView: View {
    let sankey: WeightSankey

    private static let colors: [String: Color] = [
        "poids": .purple,
        "maigre": .cyan,
        "graisse": .orange,
        "muscle": .red,
        "os": .gray,
        "autres": .teal
    ]

    private let barWidth: CGFloat = 14
    private let nodeGap: CGFloat = 14
    private let labelWidth: CGFloat = 118

    /// Position verticale calculée d'un nœud.
    private struct PlacedNode {
        let node: WeightSankey.Node
        let x: CGFloat
        let yTop: CGFloat
        let height: CGFloat
    }

    var body: some View {
        GeometryReader { geo in
            let placed = layout(in: geo.size)
            ZStack(alignment: .topLeading) {
                ForEach(ribbons(placed: placed, size: geo.size), id: \.id) { ribbon in
                    ribbon.path
                        .fill(ribbon.color.opacity(0.30))
                }
                ForEach(placed, id: \.node.id) { item in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Self.colors[item.node.id, default: .secondary])
                        .frame(width: barWidth, height: max(item.height, 3))
                        .position(x: item.x + barWidth / 2, y: item.yTop + max(item.height, 3) / 2)
                    nodeLabel(item)
                }
            }
        }
    }

    // MARK: - Layout

    private func layout(in size: CGSize) -> [PlacedNode] {
        let columns = Set(sankey.nodes.map(\.column)).sorted()
        let usableWidth = size.width - labelWidth
        let columnX: (Int) -> CGFloat = { column in
            columns.count <= 1 ? 0 : CGFloat(column) / CGFloat(columns.count - 1) * (usableWidth - self.barWidth)
        }
        // Échelle commune : la colonne la plus chargée (le poids total) tient
        // dans la hauteur en gardant les proportions entre colonnes.
        let maxNodesInColumn = Dictionary(grouping: sankey.nodes, by: \.column).values.map(\.count).max() ?? 1
        let scale = (size.height - CGFloat(maxNodesInColumn - 1) * nodeGap - 8) / sankey.totalKg

        var placed: [PlacedNode] = []
        for column in columns {
            let columnNodes = sankey.nodes.filter { $0.column == column }
            var y: CGFloat
            if column == 0 {
                y = 4
            } else {
                // Aligne le haut de la colonne sur le haut de son premier
                // parent pour des rubans quasi droits.
                y = placed.first.map(\.yTop) ?? 4
            }
            for node in columnNodes {
                let height = node.kg * scale
                placed.append(PlacedNode(node: node, x: columnX(column), yTop: y, height: height))
                y += height + nodeGap
            }
        }
        return placed
    }

    // MARK: - Rubans

    private struct Ribbon {
        let id: String
        let path: Path
        let color: Color
    }

    private func ribbons(placed: [PlacedNode], size: CGSize) -> [Ribbon] {
        let byId = Dictionary(uniqueKeysWithValues: placed.map { ($0.node.id, $0) })
        let scale = placed.first { $0.node.column == 0 }.map { $0.height / $0.node.kg } ?? 1
        // Décalage cumulé de sortie (côté source) et d'entrée (côté cible).
        var outOffset: [String: CGFloat] = [:]
        var inOffset: [String: CGFloat] = [:]

        return sankey.links.compactMap { link in
            guard let source = byId[link.from], let target = byId[link.to] else { return nil }
            let thickness = link.kg * scale
            let ys = source.yTop + (outOffset[link.from] ?? 0)
            let yt = target.yTop + (inOffset[link.to] ?? 0)
            outOffset[link.from, default: 0] += thickness
            inOffset[link.to, default: 0] += thickness

            let x1 = source.x + barWidth
            let x2 = target.x
            let midX = (x1 + x2) / 2

            var path = Path()
            path.move(to: CGPoint(x: x1, y: ys))
            path.addCurve(
                to: CGPoint(x: x2, y: yt),
                control1: CGPoint(x: midX, y: ys),
                control2: CGPoint(x: midX, y: yt)
            )
            path.addLine(to: CGPoint(x: x2, y: yt + thickness))
            path.addCurve(
                to: CGPoint(x: x1, y: ys + thickness),
                control1: CGPoint(x: midX, y: yt + thickness),
                control2: CGPoint(x: midX, y: ys + thickness)
            )
            path.closeSubpath()
            return Ribbon(id: "\(link.from)->\(link.to)", path: path, color: Self.colors[link.to, default: .secondary])
        }
    }

    // MARK: - Libellés

    @ViewBuilder
    private func nodeLabel(_ item: PlacedNode) -> some View {
        let share = item.node.kg / sankey.totalKg
        VStack(alignment: .leading, spacing: 1) {
            Text(item.node.label)
                .font(.caption.weight(.semibold))
            Text("\(item.node.kg.formatted(.number.precision(.fractionLength(1)))) kg · \(share.formatted(.percent.precision(.fractionLength(0))))")
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .frame(width: labelWidth - 8, alignment: .leading)
        .position(
            x: item.x + barWidth + 10 + (labelWidth - 8) / 2,
            y: item.yTop + max(item.height, 3) / 2
        )
    }
}
