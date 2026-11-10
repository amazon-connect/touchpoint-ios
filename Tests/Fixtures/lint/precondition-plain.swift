// Fixture: must FAIL the no-crash lint gate: bare precondition, not preconditionFailure.
func check(_ n: Int) { precondition(n > 0) }
