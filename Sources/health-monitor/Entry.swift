import Foundation

@main
struct App {
    static func main() async {
        do {
            try await runMain()
        } catch {
            fputs("health-monitor: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
