#if DEBUG
import Foundation
import CullerKit

/// DEBUG (`-hangWatch`): logs every main-thread stall longer than 100 ms ("HANG"), for performance work.
enum HangWatch {
    static func start() {
        let t = Thread {
            while true {
                let sem = DispatchSemaphore(value: 0)
                let start = DispatchTime.now()
                DispatchQueue.main.async { sem.signal() }
                sem.wait()
                let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6
                if ms > 100 { Log.session.info("HANG \(Int(ms), privacy: .public) ms") }
                Thread.sleep(forTimeInterval: 0.03)
            }
        }
        t.qualityOfService = .userInteractive
        t.start()
    }
}
#endif
