// Fixture: must pass the no-crash lint gate.
struct Clean {
    var count: Int = 0  /* retries; the docs mention fatalError() but this is a comment */
    func value(from host: String?) -> String {
        guard let host, !host.isEmpty else { return "Done!" }
        let flag = host != "x" && !host.hasPrefix("y")   // `!=` and prefix `!` are not force-unwraps
        return flag ? "\(host) ok!" : host
    }
}
