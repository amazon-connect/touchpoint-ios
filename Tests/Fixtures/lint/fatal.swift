// Fixture: must FAIL the no-crash lint gate.
func boom() -> Never { fatalError("unreachable") }
