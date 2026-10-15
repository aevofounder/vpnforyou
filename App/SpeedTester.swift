import Foundation
import VPNCore

/// One speed test run: latency, download, upload against speed.cloudflare.com,
/// either through the VPN (the core's local proxy) or directly.
/// Each phase stops after `SpeedTest.phaseSeconds`, so a slow line does not
/// eat the whole 35 MB.
final class SpeedTester: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Measurement {
        var bytes: Int64
        var seconds: TimeInterval
        var failed: Bool

        var megabitsPerSecond: Double? {
            failed && bytes == 0 ? nil : SpeedTest.megabitsPerSecond(bytes: bytes, seconds: seconds)
        }
    }

    private final class Phase {
        let task: URLSessionTask
        let started = Date()
        var bytes: Int64 = 0
        var lastReport = Date.distantPast
        let progress: @Sendable (Double) -> Void
        var continuation: CheckedContinuation<Measurement, Never>?

        init(task: URLSessionTask, progress: @escaping @Sendable (Double) -> Void,
             continuation: CheckedContinuation<Measurement, Never>) {
            self.task = task
            self.progress = progress
            self.continuation = continuation
        }
    }

    private let lock = NSLock()
    private var phase: Phase?
    private var session: URLSession!
    private let core: CoreSession?

    init(route: SpeedRoute, core: CoreSession?) {
        self.core = route == .vpn ? core : nil
        super.init()
        session = URLSession(configuration: NetworkProbe.configuration(route: route, core: core),
                             delegate: self, delegateQueue: nil)
    }

    func invalidate() {
        session.invalidateAndCancel()
    }

    /// Median time of small requests on a warm connection, in milliseconds.
    func latency() async -> Double? {
        var samples: [Double] = []
        for index in 0..<(SpeedTest.latencySamples + 1) {
            if Task.isCancelled { return nil }
            let started = Date()
            guard let (_, response) = try? await session.data(for: SpeedTest.latencyRequest()),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { continue }
            // The first request also opens the connection and TLS: skip it.
            if index > 0 { samples.append(Date().timeIntervalSince(started) * 1_000) }
        }
        return SpeedTest.median(samples)
    }

    func download(progress: @escaping @Sendable (Double) -> Void) async -> Measurement {
        await run(session.dataTask(with: SpeedTest.downloadRequest()), progress: progress)
    }

    func upload(progress: @escaping @Sendable (Double) -> Void) async -> Measurement {
        let body = Data(count: SpeedTest.uploadBytes)
        return await run(session.uploadTask(with: SpeedTest.uploadRequest(), from: body), progress: progress)
    }

    private func run(_ task: URLSessionTask, progress: @escaping @Sendable (Double) -> Void) async -> Measurement {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                phase = Phase(task: task, progress: progress, continuation: continuation)
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    // MARK: - Delegate

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        ProxyAuthDelegate.answer(challenge, core: core)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        count(Int64(data.count), task: dataTask)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        count(bytesSent, task: task)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let failed: Bool
        if let error = error as? URLError, error.code == .cancelled {
            failed = false
        } else if let http = task.response as? HTTPURLResponse {
            failed = error != nil || !(200..<300).contains(http.statusCode)
        } else {
            failed = true
        }
        finish(task: task, failed: failed)
    }

    private func count(_ bytes: Int64, task: URLSessionTask) {
        lock.lock()
        guard let phase, phase.task === task else {
            lock.unlock()
            return
        }
        phase.bytes += bytes
        let now = Date()
        let elapsed = now.timeIntervalSince(phase.started)
        var report: Double?
        if now.timeIntervalSince(phase.lastReport) >= 0.2 {
            phase.lastReport = now
            report = SpeedTest.megabitsPerSecond(bytes: phase.bytes, seconds: elapsed)
        }
        let overTime = elapsed >= SpeedTest.phaseSeconds
        lock.unlock()

        if let report { phase.progress(report) }
        if overTime {
            finish(task: task, failed: false)
            task.cancel()
        }
    }

    private func finish(task: URLSessionTask, failed: Bool) {
        lock.lock()
        guard let phase, phase.task === task, let continuation = phase.continuation else {
            lock.unlock()
            return
        }
        phase.continuation = nil
        self.phase = nil
        let measurement = Measurement(bytes: phase.bytes, seconds: Date().timeIntervalSince(phase.started), failed: failed)
        lock.unlock()
        continuation.resume(returning: measurement)
    }
}
