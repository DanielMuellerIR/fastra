#!/usr/bin/env python3
"""Zeilenhöhen linear im vorhandenen Baum abgleichen, ohne neue Knoten."""
from pathlib import Path
import sys

base = Path(sys.argv[1]) / 'Sources/CodeEditTextView/TextLineStorage'
storage = (base / 'TextLineStorage.swift').read_text()
nodes = (base / 'TextLineStorage+Node.swift').read_text()
if ('var root: Node<Data>?' not in storage
        or any(value not in nodes for value in ['var height: CGFloat', 'var leftSubtreeHeight: CGFloat',
                                               'var left: Node<NodeData>?', 'var right: Node<NodeData>?'])):
    raise SystemExit('Zeilenhöhen: Baumstruktur passt nicht zum Patch')

path = base / 'TextLineStorage+FastraHeights.swift'
expected = '''import Foundation

extension TextLineStorage {
    // Fastra-Patch: Hoehen ohne zweiten Zeilenbaum aktualisieren.
    // Bereiche und Indizes bleiben unveraendert; nur die Hoehensummen
    // werden nach den Kindern von unten nach oben neu berechnet.
    public func fastraUpdateHeights(_ transform: (Data) -> CGFloat) {
        func visit(_ node: Node<Data>?) -> CGFloat {
            guard let node else { return 0 }
            let leftHeight = visit(node.left)
            let rightHeight = visit(node.right)
            node.height = transform(node.data)
            node.leftSubtreeHeight = leftHeight
            return leftHeight + node.height + rightHeight
        }
        height = visit(root)
    }
}
'''
changed = not path.exists()
if changed:
    path.write_text(expected)
if path.read_text() != expected:
    raise SystemExit('Zeilenhöhen: Selbstprüfung fehlgeschlagen')
print('changed' if changed else 'unchanged')
