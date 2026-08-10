import Darwin
import Foundation

public struct HerdrSocketIdentity: Equatable, Sendable {
  public let device: UInt64
  public let inode: UInt64
  public let owner: UInt32
  public let permissions: UInt16

  public init(device: UInt64, inode: UInt64, owner: UInt32, permissions: UInt16) {
    self.device = device
    self.inode = inode
    self.owner = owner
    self.permissions = permissions
  }
}

public struct HerdrSocketClientConfiguration: Equatable, Sendable {
  public let endpoint: URL
  public let expectedOwner: UInt32
  public let timeoutSeconds: TimeInterval
  public let maximumRecordBytes: Int

  init(
    endpoint: URL,
    expectedOwner: UInt32,
    timeoutSeconds: TimeInterval = 2,
    maximumRecordBytes: Int = 1_048_576
  ) throws {
    guard endpoint.isFileURL, endpoint.path.hasPrefix("/"),
      !endpoint.path.unicodeScalars.contains(where: { $0.value == 0 }),
      endpoint.standardizedFileURL.path == endpoint.path,
      timeoutSeconds.isFinite, (0.05...60).contains(timeoutSeconds),
      (1_024...1_048_576).contains(maximumRecordBytes)
    else {
      throw HerdrSocketClientError.invalidConfiguration
    }
    let parent = endpoint.deletingLastPathComponent().standardizedFileURL
    guard parent.resolvingSymlinksInPath().path == parent.path else {
      throw HerdrSocketClientError.invalidConfiguration
    }
    let address = sockaddr_un()
    guard endpoint.path.utf8.count + 1 <= MemoryLayout.size(ofValue: address.sun_path) else {
      throw HerdrSocketClientError.socketPathTooLong
    }
    self.endpoint = endpoint
    self.expectedOwner = expectedOwner
    self.timeoutSeconds = timeoutSeconds
    self.maximumRecordBytes = maximumRecordBytes
  }

  public init(
    endpoint: URL,
    timeoutSeconds: TimeInterval = 2,
    maximumRecordBytes: Int = 1_048_576
  ) throws {
    try self.init(
      endpoint: endpoint,
      expectedOwner: geteuid(),
      timeoutSeconds: timeoutSeconds,
      maximumRecordBytes: maximumRecordBytes
    )
  }
}

public enum HerdrSocketClientError: Error, Equatable, Sendable {
  case invalidConfiguration
  case unsafeSocket
  case unsafePeer
  case socketPathTooLong
  case socketFailure(Int32)
  case timedOut
  case cancelled
  case writeFailed(Int32)
  case connectionClosed
  case recordTooLarge
  case incompleteRecord
  case invalidRecord
  case responseIDMismatch
  case invalidRemoteError
  case remote(String)
  case socketChanged
}

public struct HerdrNDJSONParser: Sendable {
  private let maximumRecordBytes: Int
  private var buffer = Data()

  public init(maximumRecordBytes: Int) throws {
    guard (1...1_048_576).contains(maximumRecordBytes) else {
      throw HerdrSocketClientError.invalidConfiguration
    }
    self.maximumRecordBytes = maximumRecordBytes
  }

  public mutating func append(_ data: Data) throws -> [Data] {
    guard !data.isEmpty else { return [] }
    buffer.append(data)
    var records: [Data] = []
    while let newline = buffer.firstIndex(of: 0x0A) {
      let record = Data(buffer[..<newline])
      guard !record.isEmpty, record.count <= maximumRecordBytes else {
        throw record.isEmpty
          ? HerdrSocketClientError.invalidRecord
          : HerdrSocketClientError.recordTooLarge
      }
      records.append(record)
      buffer.removeSubrange(...newline)
    }
    guard buffer.count <= maximumRecordBytes else {
      throw HerdrSocketClientError.recordTooLarge
    }
    return records
  }

  public mutating func finish() throws {
    guard buffer.isEmpty else { throw HerdrSocketClientError.incompleteRecord }
  }
}

struct HerdrSocketExchange: Sendable {
  let record: Data
  let socketIdentity: HerdrSocketIdentity
}

struct HerdrSocketExchangeStep: Sendable {
  let request: Data
  let validate: @Sendable (HerdrSocketExchange) throws -> Void
}

protocol HerdrSocketExchanging: Sendable {
  func exchange(
    configuration: HerdrSocketClientConfiguration,
    request: Data
  ) async throws -> HerdrSocketExchange

  func exchange(
    configuration: HerdrSocketClientConfiguration,
    request: Data,
    expectedSocketIdentity: HerdrSocketIdentity
  ) async throws -> HerdrSocketExchange

  func exchangeValidatedSequence(
    configuration: HerdrSocketClientConfiguration,
    steps: [HerdrSocketExchangeStep]
  ) async throws -> [HerdrSocketExchange]
}

extension HerdrSocketExchanging {
  func exchange(
    configuration: HerdrSocketClientConfiguration,
    request: Data,
    expectedSocketIdentity: HerdrSocketIdentity
  ) async throws -> HerdrSocketExchange {
    let result = try await exchange(configuration: configuration, request: request)
    guard result.socketIdentity == expectedSocketIdentity else {
      throw HerdrSocketClientError.socketChanged
    }
    return result
  }

  func exchangeValidatedSequence(
    configuration: HerdrSocketClientConfiguration,
    steps: [HerdrSocketExchangeStep]
  ) async throws -> [HerdrSocketExchange] {
    guard (1...16).contains(steps.count) else {
      throw HerdrSocketClientError.invalidConfiguration
    }
    var exchanges: [HerdrSocketExchange] = []
    var expectedSocketIdentity: HerdrSocketIdentity?
    for step in steps {
      let result: HerdrSocketExchange
      if let expectedSocketIdentity {
        result = try await exchange(
          configuration: configuration,
          request: step.request,
          expectedSocketIdentity: expectedSocketIdentity
        )
      } else {
        result = try await exchange(configuration: configuration, request: step.request)
        expectedSocketIdentity = result.socketIdentity
      }
      try step.validate(result)
      exchanges.append(result)
    }
    return exchanges
  }
}

struct SystemHerdrSocketExchange: HerdrSocketExchanging {
  private let connectionObserver: @Sendable (URL) -> Void

  init() {
    connectionObserver = { _ in }
  }

  init(connectionObserver: @escaping @Sendable (URL) -> Void) {
    self.connectionObserver = connectionObserver
  }

  func exchange(
    configuration: HerdrSocketClientConfiguration,
    request: Data
  ) async throws -> HerdrSocketExchange {
    let connectionObserver = connectionObserver
    let operation = Task.detached(priority: nil) {
      try Self.exchangeSynchronously(
        configuration: configuration,
        request: request,
        expectedSocketIdentity: nil,
        connectionObserver: connectionObserver
      )
    }
    return try await withTaskCancellationHandler {
      try await operation.value
    } onCancel: {
      operation.cancel()
    }
  }

  func exchange(
    configuration: HerdrSocketClientConfiguration,
    request: Data,
    expectedSocketIdentity: HerdrSocketIdentity
  ) async throws -> HerdrSocketExchange {
    let connectionObserver = connectionObserver
    let operation = Task.detached(priority: nil) {
      try Self.exchangeSynchronously(
        configuration: configuration,
        request: request,
        expectedSocketIdentity: expectedSocketIdentity,
        connectionObserver: connectionObserver
      )
    }
    return try await withTaskCancellationHandler {
      try await operation.value
    } onCancel: {
      operation.cancel()
    }
  }

  private static func exchangeSynchronously(
    configuration: HerdrSocketClientConfiguration,
    request: Data,
    expectedSocketIdentity: HerdrSocketIdentity?,
    connectionObserver: @Sendable (URL) -> Void
  ) throws -> HerdrSocketExchange {
    try withConnectedSocket(
      configuration: configuration,
      expectedSocketIdentity: expectedSocketIdentity,
      connectionObserver: connectionObserver
    ) { descriptor, identity in
      let deadline = monotonicSeconds() + configuration.timeoutSeconds
      try writeAll(descriptor: descriptor, data: request, deadline: deadline)
      return HerdrSocketExchange(
        record: try readFirstRecord(
          descriptor: descriptor,
          maximumRecordBytes: configuration.maximumRecordBytes,
          deadline: deadline
        ),
        socketIdentity: identity
      )
    }
  }

  private static func withConnectedSocket<Result>(
    configuration: HerdrSocketClientConfiguration,
    expectedSocketIdentity: HerdrSocketIdentity?,
    connectionObserver: @Sendable (URL) -> Void,
    operation: (Int32, HerdrSocketIdentity) throws -> Result
  ) throws -> Result {
    let before = try socketIdentity(configuration: configuration)
    guard expectedSocketIdentity == nil || before == expectedSocketIdentity else {
      throw HerdrSocketClientError.socketChanged
    }
    connectionObserver(configuration.endpoint)
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw HerdrSocketClientError.socketFailure(errno) }
    defer { Darwin.close(descriptor) }
    try setCloseOnExec(descriptor)
    var noSignal: Int32 = 1
    guard
      setsockopt(
        descriptor,
        SOL_SOCKET,
        SO_NOSIGPIPE,
        &noSignal,
        socklen_t(MemoryLayout<Int32>.size)
      ) == 0
    else {
      throw HerdrSocketClientError.socketFailure(errno)
    }
    let flags = try fileStatusFlags(descriptor)
    guard fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
      throw HerdrSocketClientError.socketFailure(errno)
    }
    try connect(
      descriptor: descriptor,
      path: configuration.endpoint.path,
      deadline: monotonicSeconds() + configuration.timeoutSeconds
    )
    try validatePeer(descriptor: descriptor, expectedOwner: configuration.expectedOwner)
    let after = try socketIdentity(configuration: configuration)
    guard before == after else { throw HerdrSocketClientError.socketChanged }
    return try operation(descriptor, before)
  }

  private static func socketIdentity(
    configuration: HerdrSocketClientConfiguration
  ) throws -> HerdrSocketIdentity {
    try validateParent(configuration: configuration)
    var value = stat()
    guard lstat(configuration.endpoint.path, &value) == 0,
      (value.st_mode & S_IFMT) == S_IFSOCK,
      value.st_uid == configuration.expectedOwner,
      (value.st_mode & 0o600) == 0o600,
      (value.st_mode & 0o077) == 0
    else {
      throw HerdrSocketClientError.unsafeSocket
    }
    return HerdrSocketIdentity(
      device: UInt64(value.st_dev),
      inode: UInt64(value.st_ino),
      owner: value.st_uid,
      permissions: UInt16(value.st_mode & 0o777)
    )
  }

  private static func validateParent(
    configuration: HerdrSocketClientConfiguration
  ) throws {
    let parent = configuration.endpoint.deletingLastPathComponent().standardizedFileURL
    var value = stat()
    guard parent.resolvingSymlinksInPath().path == parent.path,
      lstat(parent.path, &value) == 0,
      (value.st_mode & S_IFMT) == S_IFDIR,
      value.st_uid == configuration.expectedOwner,
      (value.st_mode & 0o022) == 0
    else {
      throw HerdrSocketClientError.unsafeSocket
    }
  }

  private static func validatePeer(descriptor: Int32, expectedOwner: UInt32) throws {
    var effectiveUser: uid_t = 0
    var effectiveGroup: gid_t = 0
    guard getpeereid(descriptor, &effectiveUser, &effectiveGroup) == 0 else {
      throw HerdrSocketClientError.socketFailure(errno)
    }
    guard effectiveUser == expectedOwner else { throw HerdrSocketClientError.unsafePeer }
  }

  private static func setCloseOnExec(_ descriptor: Int32) throws {
    while true {
      if fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 { return }
      if errno == EINTR { continue }
      throw HerdrSocketClientError.socketFailure(errno)
    }
  }

  private static func fileStatusFlags(_ descriptor: Int32) throws -> Int32 {
    while true {
      let flags = fcntl(descriptor, F_GETFL)
      if flags >= 0 { return flags }
      if errno == EINTR { continue }
      throw HerdrSocketClientError.socketFailure(errno)
    }
  }

  private static func connect(
    descriptor: Int32,
    path: String,
    deadline: TimeInterval
  ) throws {
    let pathBytes = Array(path.utf8)
    var address = sockaddr_un()
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard !pathBytes.isEmpty, pathBytes.count + 1 <= capacity else {
      throw HerdrSocketClientError.socketPathTooLong
    }
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { bytes in
      bytes.copyBytes(from: pathBytes)
    }
    let status = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    if status == 0 { return }
    guard errno == EINPROGRESS else {
      throw HerdrSocketClientError.socketFailure(errno)
    }
    try wait(descriptor: descriptor, events: Int16(POLLOUT), deadline: deadline)
    var socketError: Int32 = 0
    var length = socklen_t(MemoryLayout<Int32>.size)
    guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0 else {
      throw HerdrSocketClientError.socketFailure(errno)
    }
    guard socketError == 0 else { throw HerdrSocketClientError.socketFailure(socketError) }
  }

  private static func writeAll(
    descriptor: Int32,
    data: Data,
    deadline: TimeInterval
  ) throws {
    try data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        try cancellationCheck()
        let count = Darwin.write(
          descriptor,
          bytes.baseAddress?.advanced(by: offset),
          bytes.count - offset
        )
        if count > 0 {
          offset += count
          continue
        }
        if count == -1, errno == EINTR { continue }
        if count == -1, errno == EAGAIN || errno == EWOULDBLOCK {
          try wait(descriptor: descriptor, events: Int16(POLLOUT), deadline: deadline)
          continue
        }
        throw HerdrSocketClientError.writeFailed(errno)
      }
    }
  }

  private static func readFirstRecord(
    descriptor: Int32,
    maximumRecordBytes: Int,
    deadline: TimeInterval
  ) throws -> Data {
    var parser = try HerdrNDJSONParser(maximumRecordBytes: maximumRecordBytes)
    var bytes = [UInt8](repeating: 0, count: 4_096)
    while true {
      try cancellationCheck()
      try wait(descriptor: descriptor, events: Int16(POLLIN), deadline: deadline)
      let count = Darwin.read(descriptor, &bytes, bytes.count)
      if count > 0 {
        if let first = try parser.append(Data(bytes.prefix(count))).first { return first }
        continue
      }
      if count == 0 {
        try parser.finish()
        throw HerdrSocketClientError.connectionClosed
      }
      if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
      throw HerdrSocketClientError.socketFailure(errno)
    }
  }

  private static func wait(
    descriptor: Int32,
    events: Int16,
    deadline: TimeInterval
  ) throws {
    while true {
      try cancellationCheck()
      let remaining = deadline - monotonicSeconds()
      guard remaining > 0 else { throw HerdrSocketClientError.timedOut }
      var polled = pollfd(fd: descriptor, events: events, revents: 0)
      let milliseconds = Int32(max(1, min(remaining * 1_000, 100)))
      let status = Darwin.poll(&polled, 1, milliseconds)
      if status > 0 {
        if polled.revents & Int16(POLLNVAL) != 0 {
          throw HerdrSocketClientError.socketFailure(EBADF)
        }
        if polled.revents & (events | Int16(POLLHUP) | Int16(POLLERR)) != 0 { return }
        continue
      }
      if status == 0 { continue }
      if errno == EINTR { continue }
      throw HerdrSocketClientError.socketFailure(errno)
    }
  }

  private static func cancellationCheck() throws {
    if Task.isCancelled { throw HerdrSocketClientError.cancelled }
  }

  private static func monotonicSeconds() -> TimeInterval {
    var value = timespec()
    clock_gettime(CLOCK_MONOTONIC_RAW, &value)
    return TimeInterval(value.tv_sec) + TimeInterval(value.tv_nsec) / 1_000_000_000
  }
}

public actor HerdrSocketClient {
  private let configuration: HerdrSocketClientConfiguration
  private let requestID: @Sendable () -> String
  private let exchanger: any HerdrSocketExchanging

  public init(configuration: HerdrSocketClientConfiguration) {
    self.configuration = configuration
    self.requestID = { UUID().uuidString.lowercased() }
    self.exchanger = SystemHerdrSocketExchange()
  }

  init(
    configuration: HerdrSocketClientConfiguration,
    requestID: @escaping @Sendable () -> String,
    exchanger: any HerdrSocketExchanging = SystemHerdrSocketExchange()
  ) {
    self.configuration = configuration
    self.requestID = requestID
    self.exchanger = exchanger
  }

  func ping() async throws -> HerdrPong {
    let response: HerdrResponse<HerdrPong> = try await request(
      method: .ping,
      params: HerdrEmptyParameters()
    )
    return response.result
  }

  func snapshot() async throws -> HerdrSessionSnapshot {
    let response: HerdrResponse<HerdrSessionSnapshotResult> = try await request(
      method: .sessionSnapshot,
      params: HerdrEmptyParameters()
    )
    guard response.result.type == "session_snapshot" else {
      throw HerdrCompatibilityError.snapshotMismatch
    }
    return response.result.snapshot
  }

  func focusWorkspace(
    workspaceID: String,
    attestedBy handshake: HerdrHandshake
  ) async throws {
    guard handshake.snapshot.workspaces.contains(where: { $0.workspaceID == workspaceID }) else {
      throw HerdrTopologyError.bindingLost
    }
    let response: HerdrResponse<HerdrWorkspaceInfoResult> = try await request(
      method: .workspaceFocus,
      params: HerdrWorkspaceTargetParameters(workspaceID: workspaceID),
      expectedSocketIdentity: handshake.socketIdentity
    )
    try Self.validate(response: response, attestedBy: handshake)
    guard response.result.type == "workspace_info",
      response.result.workspace.workspaceID == workspaceID,
      response.result.workspace.focused
    else {
      throw HerdrTopologyError.invalidResponse
    }
  }

  func focusTab(
    tabID: String,
    attestedBy handshake: HerdrHandshake
  ) async throws {
    guard handshake.snapshot.tabs.contains(where: { $0.tabID == tabID }) else {
      throw HerdrTopologyError.bindingLost
    }
    let response: HerdrResponse<HerdrTabInfoResult> = try await request(
      method: .tabFocus,
      params: HerdrTabTargetParameters(tabID: tabID),
      expectedSocketIdentity: handshake.socketIdentity
    )
    try Self.validate(response: response, attestedBy: handshake)
    guard response.result.type == "tab_info",
      response.result.tab.tabID == tabID,
      response.result.tab.focused
    else {
      throw HerdrTopologyError.invalidResponse
    }
  }

  func focusPane(
    paneID: String,
    attestedBy handshake: HerdrHandshake
  ) async throws {
    guard handshake.snapshot.panes.contains(where: { $0.paneID == paneID }) else {
      throw HerdrTopologyError.bindingLost
    }
    let response: HerdrResponse<HerdrPaneInfoResult> = try await request(
      method: .paneFocus,
      params: HerdrPaneTargetParameters(paneID: paneID),
      expectedSocketIdentity: handshake.socketIdentity
    )
    try Self.validate(response: response, attestedBy: handshake)
    guard response.result.type == "pane_info",
      response.result.pane.paneID == paneID,
      response.result.pane.focused
    else {
      throw HerdrTopologyError.invalidResponse
    }
  }

  func createWorkspace(
    _ parameters: HerdrWorkspaceCreateParameters,
    attestedBy handshake: HerdrHandshake
  ) async throws -> HerdrWorkspaceCreatedResult {
    let response: HerdrResponse<HerdrWorkspaceCreatedResult> = try await request(
      method: .workspaceCreate,
      params: parameters,
      expectedSocketIdentity: handshake.socketIdentity
    )
    try Self.validate(response: response, attestedBy: handshake)
    guard response.result.type == "workspace_created" else {
      throw HerdrTopologyError.invalidResponse
    }
    return response.result
  }

  func applyLayout(
    _ parameters: HerdrLayoutApplyParameters,
    attestedBy handshake: HerdrHandshake
  ) async throws -> HerdrLayoutApplyResult {
    let response: HerdrResponse<HerdrLayoutApplyResult> = try await request(
      method: .layoutApply,
      params: parameters,
      expectedSocketIdentity: handshake.socketIdentity
    )
    try Self.validate(response: response, attestedBy: handshake)
    guard response.result.type == "layout_apply" else {
      throw HerdrTopologyError.invalidResponse
    }
    return response.result
  }

  func exportLayout(
    tabID: String,
    attestedBy handshake: HerdrHandshake
  ) async throws -> HerdrLayoutDescription {
    let response: HerdrResponse<HerdrLayoutExportResult> = try await request(
      method: .layoutExport,
      params: HerdrLayoutExportParameters(tabID: tabID),
      expectedSocketIdentity: handshake.socketIdentity
    )
    try Self.validate(response: response, attestedBy: handshake)
    guard response.result.type == "layout_export",
      response.result.layout.tabID == tabID
    else {
      throw HerdrTopologyError.invalidResponse
    }
    return response.result.layout
  }

  func processInfo(
    paneID: String,
    attestedBy handshake: HerdrHandshake
  ) async throws -> HerdrPaneProcessInfo {
    let response: HerdrResponse<HerdrPaneProcessInfoResult> = try await request(
      method: .paneProcessInfo,
      params: HerdrPaneProcessInfoParameters(paneID: paneID),
      expectedSocketIdentity: handshake.socketIdentity
    )
    try Self.validate(response: response, attestedBy: handshake)
    guard response.result.type == "pane_process_info",
      response.result.processInfo.paneID == paneID,
      response.result.processInfo.foregroundProcesses.count <= 256
    else {
      throw HerdrTopologyError.invalidResponse
    }
    return response.result.processInfo
  }

  func closePane(
    paneID: String,
    terminalID: String,
    attestedBy handshake: HerdrHandshake
  ) async throws {
    guard
      handshake.snapshot.panes.contains(where: {
        $0.paneID == paneID && $0.terminalID == terminalID && $0.agentSession == nil
      })
    else {
      throw HerdrHostError.incompatiblePane
    }
    let response: HerdrResponse<HerdrOKResult> = try await request(
      method: .paneClose,
      params: HerdrPaneTargetParameters(paneID: paneID),
      expectedSocketIdentity: handshake.socketIdentity
    )
    try Self.validate(response: response, attestedBy: handshake)
    guard response.result.type == "ok" else {
      throw HerdrTopologyError.invalidResponse
    }
    let post = try await self.handshake()
    guard post.socketIdentity == handshake.socketIdentity,
      !post.snapshot.panes.contains(where: { $0.terminalID == terminalID })
    else {
      throw HerdrTopologyError.invalidResponse
    }
  }

  func reportAgent(
    _ parameters: HerdrPaneReportAgentParameters,
    attestedBy handshake: HerdrHandshake
  ) async throws {
    let response: HerdrResponse<HerdrOKResult> = try await request(
      method: .paneReportAgent,
      params: parameters,
      expectedSocketIdentity: handshake.socketIdentity
    )
    try Self.validate(response: response, attestedBy: handshake)
    guard response.result.type == "ok" else { throw HerdrTopologyError.invalidResponse }
  }

  func reportMetadata(
    _ parameters: HerdrPaneReportMetadataParameters,
    attestedBy handshake: HerdrHandshake
  ) async throws {
    let response: HerdrResponse<HerdrOKResult> = try await request(
      method: .paneReportMetadata,
      params: parameters,
      expectedSocketIdentity: handshake.socketIdentity
    )
    try Self.validate(response: response, attestedBy: handshake)
    guard response.result.type == "ok" else { throw HerdrTopologyError.invalidResponse }
  }

  func renameAgent(
    _ parameters: HerdrAgentRenameParameters,
    attestedBy handshake: HerdrHandshake
  ) async throws -> HerdrAgentSnapshot {
    let response: HerdrResponse<HerdrAgentInfoResult> = try await request(
      method: .agentRename,
      params: parameters,
      expectedSocketIdentity: handshake.socketIdentity
    )
    try Self.validate(response: response, attestedBy: handshake)
    guard response.result.type == "agent_info",
      response.result.agent.paneID == parameters.target,
      response.result.agent.name == parameters.name
    else {
      throw HerdrTopologyError.invalidResponse
    }
    return response.result.agent
  }

  func startHostPane(
    paneID: String,
    workspaceID: String,
    tabID: String,
    expectedTerminalID: String?,
    agent: HerdrPaneReportAgentParameters,
    metadata: HerdrPaneReportMetadataParameters,
    alias: String
  ) async throws -> (handshake: HerdrHandshake, terminalID: String) {
    let ping = try prepareRequest(method: .ping, params: HerdrEmptyParameters())
    let snapshot = try prepareRequest(
      method: .sessionSnapshot,
      params: HerdrEmptyParameters()
    )
    let report = try prepareRequest(method: .paneReportAgent, params: agent)
    let metadataReport = try prepareRequest(method: .paneReportMetadata, params: metadata)
    let rename = try prepareRequest(
      method: .agentRename,
      params: HerdrAgentRenameParameters(target: paneID, name: alias)
    )
    let manifest = HerdrCompatibilityManifest.herdr080
    let steps = [
      HerdrSocketExchangeStep(request: ping.data) { exchange in
        let response: HerdrResponse<HerdrPong> = try Self.decode(
          exchange: exchange,
          id: ping.id
        )
        try Self.validate(pong: response.result, manifest: manifest)
      },
      HerdrSocketExchangeStep(request: snapshot.data) { exchange in
        let response: HerdrResponse<HerdrSessionSnapshotResult> = try Self.decode(
          exchange: exchange,
          id: snapshot.id
        )
        guard response.result.type == "session_snapshot",
          response.result.snapshot.version == manifest.version,
          response.result.snapshot.protocolVersion == manifest.protocolVersion,
          response.result.snapshot.panes.contains(where: {
            $0.paneID == paneID
              && $0.workspaceID == workspaceID
              && $0.tabID == tabID
              && (expectedTerminalID == nil || $0.terminalID == expectedTerminalID)
              && $0.agentSession == nil
          })
        else {
          throw HerdrHostError.incompatiblePane
        }
      },
      HerdrSocketExchangeStep(request: report.data) { exchange in
        let response: HerdrResponse<HerdrOKResult> = try Self.decode(
          exchange: exchange,
          id: report.id
        )
        guard response.result.type == "ok" else {
          throw HerdrTopologyError.invalidResponse
        }
      },
      HerdrSocketExchangeStep(request: metadataReport.data) { exchange in
        let response: HerdrResponse<HerdrOKResult> = try Self.decode(
          exchange: exchange,
          id: metadataReport.id
        )
        guard response.result.type == "ok" else {
          throw HerdrTopologyError.invalidResponse
        }
      },
      HerdrSocketExchangeStep(request: rename.data) { exchange in
        let response: HerdrResponse<HerdrAgentInfoResult> = try Self.decode(
          exchange: exchange,
          id: rename.id
        )
        guard response.result.type == "agent_info",
          response.result.agent.paneID == paneID,
          response.result.agent.name == alias
        else {
          throw HerdrTopologyError.invalidResponse
        }
      },
    ]
    let exchanges = try await exchanger.exchangeValidatedSequence(
      configuration: configuration,
      steps: steps
    )
    guard exchanges.count == steps.count else { throw HerdrSocketClientError.invalidRecord }
    let pong: HerdrResponse<HerdrPong> = try Self.decode(exchange: exchanges[0], id: ping.id)
    let snapshotResponse: HerdrResponse<HerdrSessionSnapshotResult> = try Self.decode(
      exchange: exchanges[1],
      id: snapshot.id
    )
    guard
      let pane = snapshotResponse.result.snapshot.panes.first(where: {
        $0.paneID == paneID && $0.workspaceID == workspaceID && $0.tabID == tabID
          && (expectedTerminalID == nil || $0.terminalID == expectedTerminalID)
      })
    else {
      throw HerdrHostError.incompatiblePane
    }
    return (
      HerdrHandshake(
        pong: pong.result,
        snapshot: snapshotResponse.result.snapshot,
        socketIdentity: pong.socketIdentity
      ),
      pane.terminalID
    )
  }

  func finishHostPane(
    paneID: String,
    workspaceID: String,
    tabID: String,
    terminalID: String,
    agent: HerdrPaneReportAgentParameters,
    metadata: HerdrPaneReportMetadataParameters
  ) async throws {
    let handshake = try await handshake()
    guard
      let pane = handshake.snapshot.panes.first(where: {
        $0.terminalID == terminalID && $0.agentSession == nil
      })
    else {
      throw HerdrHostError.incompatiblePane
    }
    let reboundAgent = HerdrPaneReportAgentParameters(
      paneID: pane.paneID,
      source: agent.source,
      agent: agent.agent,
      state: agent.state,
      message: agent.message,
      sequence: agent.sequence
    )
    let reboundMetadata = HerdrPaneReportMetadataParameters(
      paneID: pane.paneID,
      source: metadata.source,
      agent: metadata.agent,
      appliesToSource: metadata.appliesToSource,
      title: metadata.title,
      displayAgent: metadata.displayAgent,
      stateLabels: metadata.stateLabels,
      tokens: metadata.tokens,
      sequence: metadata.sequence
    )
    try await reportAgent(reboundAgent, attestedBy: handshake)
    try await reportMetadata(reboundMetadata, attestedBy: handshake)
  }

  public func handshake() async throws -> HerdrHandshake {
    let manifest = HerdrCompatibilityManifest.herdr080
    let pongResponse: HerdrResponse<HerdrPong> = try await request(
      method: .ping,
      params: HerdrEmptyParameters()
    )
    let pong = pongResponse.result
    try Self.validate(pong: pong, manifest: manifest)
    let snapshotResponse: HerdrResponse<HerdrSessionSnapshotResult> = try await request(
      method: .sessionSnapshot,
      params: HerdrEmptyParameters(),
      expectedSocketIdentity: pongResponse.socketIdentity
    )
    guard snapshotResponse.result.type == "session_snapshot",
      snapshotResponse.result.snapshot.version == pong.version,
      snapshotResponse.result.snapshot.protocolVersion == pong.protocolVersion
    else {
      throw HerdrCompatibilityError.snapshotMismatch
    }
    guard pongResponse.socketIdentity == snapshotResponse.socketIdentity else {
      throw HerdrSocketClientError.socketChanged
    }
    return HerdrHandshake(
      pong: pong,
      snapshot: snapshotResponse.result.snapshot,
      socketIdentity: pongResponse.socketIdentity
    )
  }

  private static func validate<Result: Sendable>(
    response: HerdrResponse<Result>,
    attestedBy handshake: HerdrHandshake
  ) throws {
    guard response.socketIdentity == handshake.socketIdentity else {
      throw HerdrSocketClientError.socketChanged
    }
  }

  private static func validate(
    pong: HerdrPong,
    manifest: HerdrCompatibilityManifest
  ) throws {
    guard pong.type == "pong" else { throw HerdrCompatibilityError.invalidPong }
    guard pong.version == manifest.version else {
      throw HerdrCompatibilityError.versionMismatch
    }
    guard pong.protocolVersion == manifest.protocolVersion else {
      throw HerdrCompatibilityError.protocolMismatch
    }
    guard pong.capabilities.liveHandoff else {
      throw HerdrCompatibilityError.missingLiveHandoff
    }
    guard pong.capabilities.detachedServerDaemon else {
      throw HerdrCompatibilityError.missingDetachedServerDaemon
    }
  }

  private func request<Parameters, Result>(
    method: HerdrMethod,
    params: Parameters,
    expectedSocketIdentity: HerdrSocketIdentity? = nil
  ) async throws -> HerdrResponse<Result>
  where Parameters: Encodable & Sendable, Result: Decodable & Sendable {
    let prepared = try prepareRequest(method: method, params: params)
    let exchange: HerdrSocketExchange
    if let expectedSocketIdentity {
      exchange = try await exchanger.exchange(
        configuration: configuration,
        request: prepared.data,
        expectedSocketIdentity: expectedSocketIdentity
      )
    } else {
      exchange = try await exchanger.exchange(
        configuration: configuration,
        request: prepared.data
      )
    }
    return try Self.decode(exchange: exchange, id: prepared.id)
  }

  private func prepareRequest<Parameters: Encodable & Sendable>(
    method: HerdrMethod,
    params: Parameters
  ) throws -> (id: String, data: Data) {
    let id = requestID()
    guard id.wholeMatch(of: /^[a-zA-Z0-9][a-zA-Z0-9._:-]{0,127}$/) != nil else {
      throw HerdrSocketClientError.invalidConfiguration
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(
      HerdrRequestEnvelope(id: id, method: method.rawValue, params: params)
    )
    guard data.count <= configuration.maximumRecordBytes else {
      throw HerdrSocketClientError.recordTooLarge
    }
    data.append(0x0A)
    return (id, data)
  }

  private static func decode<Result: Decodable & Sendable>(
    exchange: HerdrSocketExchange,
    id: String
  ) throws -> HerdrResponse<Result> {
    let envelope: HerdrWireResponse<Result>
    do {
      envelope = try JSONDecoder().decode(HerdrWireResponse<Result>.self, from: exchange.record)
    } catch {
      throw HerdrSocketClientError.invalidRecord
    }
    guard envelope.id == id else { throw HerdrSocketClientError.responseIDMismatch }
    switch (envelope.result, envelope.error) {
    case (.some(let value), .none):
      return HerdrResponse(result: value, socketIdentity: exchange.socketIdentity)
    case (.none, .some(let remote)):
      guard remote.code.wholeMatch(of: /^[a-z][a-z0-9_]{0,63}$/) != nil,
        remote.message.utf8.count <= 4_096,
        !remote.message.unicodeScalars.contains(where: { $0.value == 0 })
      else {
        throw HerdrSocketClientError.invalidRemoteError
      }
      throw HerdrSocketClientError.remote(remote.code)
    default:
      throw HerdrSocketClientError.invalidRecord
    }
  }
}

private enum HerdrMethod: String, Sendable {
  case ping
  case sessionSnapshot = "session.snapshot"
  case workspaceCreate = "workspace.create"
  case workspaceFocus = "workspace.focus"
  case tabFocus = "tab.focus"
  case paneFocus = "pane.focus"
  case layoutApply = "layout.apply"
  case layoutExport = "layout.export"
  case paneProcessInfo = "pane.process_info"
  case paneClose = "pane.close"
  case paneReportAgent = "pane.report_agent"
  case paneReportMetadata = "pane.report_metadata"
  case agentRename = "agent.rename"
}

private struct HerdrEmptyParameters: Codable, Sendable {}

private struct HerdrRequestEnvelope<Parameters: Encodable & Sendable>: Encodable, Sendable {
  let id: String
  let method: String
  let params: Parameters
}

private struct HerdrRemoteErrorPayload: Decodable, Sendable {
  let code: String
  let message: String
}

private struct HerdrWireResponse<Result: Decodable & Sendable>: Decodable, Sendable {
  let id: String
  let result: Result?
  let error: HerdrRemoteErrorPayload?
}

private struct HerdrResponse<Result: Sendable>: Sendable {
  let result: Result
  let socketIdentity: HerdrSocketIdentity
}
