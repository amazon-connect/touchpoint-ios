// Fixture: must FAIL the no-crash lint gate (a library never ends the process).
import Darwin
func quit() { exit(1) }
