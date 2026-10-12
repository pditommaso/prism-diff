import Foundation

/// Computes greeting for a user.
struct Greeter {
    let name: String
    var excited: Bool = false

    func greet() -> String {
        let base = "Hello, \(name)"
        return excited ? base + "!" : base + "."
    }

    func farewell() -> String {
        return "Goodbye, \(name)."
    }
}

let g = Greeter(name: "World")
print(g.greet())
print(g.farewell())
// trailing comment
