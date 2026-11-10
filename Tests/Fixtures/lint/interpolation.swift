// Fixture: must FAIL the no-crash lint gate — force-unwrap hidden inside a string interpolation.
func greet(_ name: String?) -> String { "Hello \(name!)" }
