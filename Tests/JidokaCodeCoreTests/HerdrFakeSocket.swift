import Darwin
import Foundation

struct HerdrFakeReply: Sendable {
  let chunks: [Data]
  let delayNanoseconds: UInt64
  let dynamicResponse: (@Sendable (Data) -> Data)?

  init(chunks: [Data], delayNanoseconds: UInt64 = 0) {
    self.chunks = chunks
    self.delayNanoseconds = delayNanoseconds
    self.dynamicResponse = nil
  }

  init(_ text: String, splitAt: [Int] = [], delayNanoseconds: UInt64 = 0) {
    let data = Data(text.utf8)
    var chunks: [Data] = []
    var lower = 0
    for upper in splitAt where upper > lower && upper < data.count {
      chunks.append(Data(data[lower..<upper]))
      lower = upper
    }
    chunks.append(Data(data[lower...]))
    self.init(chunks: chunks, delayNanoseconds: delayNanoseconds)
  }

  init(dynamicResponse: @escaping @Sendable (Data) -> Data) {
    self.chunks = []
    self.delayNanoseconds = 0
    self.dynamicResponse = dynamicResponse
  }

  func responseChunks(for request: Data) -> [Data] {
    dynamicResponse.map { [$0(request)] } ?? chunks
  }
}

actor HerdrFakeRequestLog {
  private var records: [Data] = []

  func append(_ record: Data) {
    records.append(record)
  }

  func snapshot() -> [Data] {
    records
  }
}

final class HerdrFakeSocketServer: @unchecked Sendable {
  let rootURL: URL
  let socketURL: URL
  let requests = HerdrFakeRequestLog()

  private let listener: Int32
  private let task: Task<Void, Never>

  init(
    replies: [HerdrFakeReply],
    permissions: mode_t = 0o600,
    idleTimeoutSeconds: TimeInterval = 5
  ) throws {
    let rootURL = URL(
      fileURLWithPath: "/tmp/jh-\(UUID().uuidString.lowercased().prefix(8))",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: rootURL,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: rootURL.path
    )
    let socketURL = rootURL.appendingPathComponent("herdr.sock")
    let listener: Int32
    do {
      listener = try Self.makeListener(at: socketURL, permissions: permissions)
    } catch {
      try? FileManager.default.removeItem(at: rootURL)
      throw error
    }
    self.rootURL = rootURL
    self.socketURL = socketURL
    self.listener = listener
    let requestLog = requests
    task = Task.detached {
      defer {
        Darwin.close(listener)
        _ = Darwin.unlink(socketURL.path)
      }
      for reply in replies {
        guard !Task.isCancelled,
          let connection = Self.accept(
            listener: listener,
            timeoutSeconds: idleTimeoutSeconds
          )
        else { return }
        guard
          let request = Self.readLine(
            connection,
            maximumBytes: 1_048_576,
            timeoutSeconds: idleTimeoutSeconds
          )
        else {
          Darwin.close(connection)
          return
        }
        await requestLog.append(request)
        if reply.delayNanoseconds > 0 {
          try? await Task.sleep(nanoseconds: reply.delayNanoseconds)
        }
        for chunk in reply.responseChunks(for: request) {
          guard !Task.isCancelled, Self.writeAll(connection, data: chunk) else {
            Darwin.close(connection)
            return
          }
        }
        Darwin.close(connection)
      }
    }
  }

  deinit {
    task.cancel()
  }

  func finish() async {
    await task.value
    try? FileManager.default.removeItem(at: rootURL)
  }

  func cancel() async {
    task.cancel()
    await task.value
    try? FileManager.default.removeItem(at: rootURL)
  }

  private static func makeListener(at socketURL: URL, permissions: mode_t) throws -> Int32 {
    let pathBytes = Array(socketURL.path.utf8)
    var address = sockaddr_un()
    guard pathBytes.count + 1 <= MemoryLayout.size(ofValue: address.sun_path) else {
      throw HerdrFakeSocketError.socketPathTooLong
    }
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { bytes in
      bytes.copyBytes(from: pathBytes)
    }
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw HerdrFakeSocketError.socketFailure(errno) }
    var ownsDescriptor = true
    defer {
      if ownsDescriptor { Darwin.close(descriptor) }
    }
    let status = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard status == 0,
      Darwin.chmod(socketURL.path, permissions) == 0,
      Darwin.listen(descriptor, 8) == 0
    else {
      throw HerdrFakeSocketError.socketFailure(errno)
    }
    let flags = fcntl(descriptor, F_GETFL)
    guard flags >= 0,
      fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0,
      fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0
    else {
      throw HerdrFakeSocketError.socketFailure(errno)
    }
    ownsDescriptor = false
    return descriptor
  }

  private static func accept(listener: Int32, timeoutSeconds: TimeInterval) -> Int32? {
    let deadline = monotonicSeconds() + timeoutSeconds
    while !Task.isCancelled, monotonicSeconds() < deadline {
      var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
      let status = Darwin.poll(&descriptor, 1, 50)
      if status > 0 {
        let connection = Darwin.accept(listener, nil, nil)
        if connection >= 0 {
          var noSignal: Int32 = 1
          guard
            setsockopt(
              connection,
              SOL_SOCKET,
              SO_NOSIGPIPE,
              &noSignal,
              socklen_t(MemoryLayout<Int32>.size)
            ) == 0
          else {
            Darwin.close(connection)
            return nil
          }
          return connection
        }
        if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
        return nil
      }
      if status == -1, errno != EINTR { return nil }
    }
    return nil
  }

  private static func readLine(
    _ descriptor: Int32,
    maximumBytes: Int,
    timeoutSeconds: TimeInterval
  ) -> Data? {
    var result = Data()
    var byte: UInt8 = 0
    let deadline = monotonicSeconds() + timeoutSeconds
    while result.count <= maximumBytes, monotonicSeconds() < deadline {
      var polled = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
      let status = Darwin.poll(&polled, 1, 50)
      if status == 0 { continue }
      if status == -1 {
        if errno == EINTR { continue }
        return nil
      }
      let count = Darwin.read(descriptor, &byte, 1)
      if count == 1 {
        if byte == 0x0A { return result }
        result.append(byte)
      } else if count == 0 {
        return nil
      } else if errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK {
        return nil
      }
    }
    return nil
  }

  private static func writeAll(_ descriptor: Int32, data: Data) -> Bool {
    data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.write(
          descriptor,
          bytes.baseAddress?.advanced(by: offset),
          bytes.count - offset
        )
        if count > 0 {
          offset += count
        } else if count == -1, errno == EINTR {
          continue
        } else {
          return false
        }
      }
      return true
    }
  }

  private static func monotonicSeconds() -> TimeInterval {
    var value = timespec()
    clock_gettime(CLOCK_MONOTONIC_RAW, &value)
    return TimeInterval(value.tv_sec) + TimeInterval(value.tv_nsec) / 1_000_000_000
  }
}

enum HerdrFakeSocketError: Error {
  case socketPathTooLong
  case socketFailure(Int32)
}

final class HerdrRequestIDSequence: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String]

  init(_ values: [String]) {
    self.values = values
  }

  func next() -> String {
    lock.lock()
    defer { lock.unlock() }
    return values.isEmpty ? "unexpected-request" : values.removeFirst()
  }
}
