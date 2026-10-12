import Foundation
import OSLog

/// Computes a friendly greeting for a user.
struct Greeter {
    let name: String
    var excited: Bool = true
    var language: String = "en"

    func greet() -> String {
        let base = language == "it" ? "Ciao, \(name)" : "Hello, \(name)"
        return excited ? base + "!" : base + "."
    }

    func farewell() -> String {
            return "Goodbye, \(name)."
    }
}

let g = Greeter(name: "Prism")
print(g.greet())
