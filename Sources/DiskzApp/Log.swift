import Foundation

/// Appends timestamped lines to ~/Library/Logs/diskz.log.
enum Log {
    static let path = NSHomeDirectory() + "/Library/Logs/diskz.log"

    static func write(_ message: String) {
        let format = DateFormatter()
        format.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = Data("\(format.string(from: Date())) \(message)\n".utf8)
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: line)
        }
    }
}
