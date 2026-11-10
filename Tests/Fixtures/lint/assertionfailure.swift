// Fixture: must FAIL the no-crash lint gate.
func unreachable() { assertionFailure("should not happen") }
