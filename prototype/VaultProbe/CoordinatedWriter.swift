import Foundation

enum WriteMode: String, CaseIterable {
    case coordinated = "NSFileCoordinator"
    case raw = "FileManager"
}

struct CoordinatedWriter {
    static func write(_ text: String, to fileURL: URL, mode: WriteMode) -> (milliseconds: Double, failure: String?) {
        let data = Data(text.utf8)
        var failure: String?
        let start = DispatchTime.now()

        switch mode {
        case .raw:
            do {
                try data.write(to: fileURL, options: .atomic)
            } catch {
                failure = error.localizedDescription
            }

        case .coordinated:
            let coordinator = NSFileCoordinator(filePresenter: nil)
            var coordinationError: NSError?
            coordinator.coordinate(writingItemAt: fileURL, options: .forReplacing, error: &coordinationError) { target in
                do {
                    try data.write(to: target, options: .atomic)
                } catch {
                    failure = error.localizedDescription
                }
            }
            if let coordinationError {
                failure = "coordinate: \(coordinationError.localizedDescription)"
            }
        }

        let nanos = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
        return (Double(nanos) / 1_000_000, failure)
    }
}
