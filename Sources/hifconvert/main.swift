import Darwin
@testable import Hifconverter

@main
struct HifconvertMain {
    static func main() {
        exit(Hifconvert.run(arguments: CommandLine.arguments))
    }
}
