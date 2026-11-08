import Foundation

/// Streams release assets to a temporary file; never keeps a disk image in RAM.
final class BazziteDownload: NSObject, URLSessionDownloadDelegate {
    let destination: URL
    let expectedBytes: Int64
    let progress: (Double) -> Void
    let done = DispatchSemaphore(value: 0)
    var error: Error?
    private var received = false
    init(destination: URL, expectedBytes: Int64, progress: @escaping (Double) -> Void) {
        self.destination = destination
        self.expectedBytes = expectedBytes
        self.progress = progress
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > expectedBytes {
            error = OptionError("Bazzite download exceeds the manifest size")
            downloadTask.cancel()
        }
        progress(min(1, Double(totalBytesWritten) / Double(expectedBytes)))
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 else {
                throw OptionError("GitHub asset download returned HTTP \((downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0)")
            }
            let bytes = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard Int64(bytes) == expectedBytes else { throw OptionError("Bazzite asset size mismatch") }
            try FileManager.default.moveItem(at: location, to: destination)
            received = true
        } catch { self.error = error }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if self.error == nil { self.error = error }
        if !received && self.error == nil { self.error = OptionError("Bazzite asset download was incomplete") }
        done.signal()
    }
}
