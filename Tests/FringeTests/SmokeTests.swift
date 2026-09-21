import Testing

@testable import Fringe

@Test func targetIsImportable() {
    #expect(WidgetSpan.wide == WidgetSpan(columns: 2, rows: 1))
}
