import CoreAudio
import Darwin
import Foundation
import os

let logger = Logger(subsystem: "com.leksat.claude-dictation-pause", category: "main")
let mediaControlPath = "/opt/homebrew/bin/media-control"
let claudeInstallDir = FileManager.default.homeDirectoryForCurrentUser
  .appending(path: ".local/share/claude/").path
// Core Audio doesn't reliably notify about per-process input changes, so while
// any input device is running we poll which processes use it.
let pollInterval: Duration = .milliseconds(200)
// Bridges brief mic gaps so music doesn't blip between dictation segments.
let resumeDelay: Duration = .milliseconds(500)

func log(_ message: String) {
  logger.notice("\(message, privacy: .public)")
}

// MARK: - Process inspection

func parentPID(of pid: pid_t) -> pid_t? {
  var info = kinfo_proc()
  var size = MemoryLayout<kinfo_proc>.stride
  var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
  guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else {
    return nil
  }
  return info.kp_eproc.e_ppid
}

func executablePath(of pid: pid_t) -> String? {
  var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
  let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
  guard length > 0 else { return nil }
  return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
}

// Matches the claude binary itself and its children, e.g. the SoX `rec` fallback recorder.
func belongsToClaudeCode(_ pid: pid_t) -> Bool {
  var current = pid
  while current > 1 {
    if executablePath(of: current)?.hasPrefix(claudeInstallDir) == true {
      return true
    }
    guard let parent = parentPID(of: current), parent != current else { return false }
    current = parent
  }
  return false
}

// MARK: - Core Audio

func globalAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
  AudioObjectPropertyAddress(
    mSelector: selector,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
  )
}

func readObjectList(
  _ object: AudioObjectID,
  _ selector: AudioObjectPropertySelector
) -> [AudioObjectID] {
  var address = globalAddress(selector)
  var size: UInt32 = 0
  guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr else {
    return []
  }
  var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
  guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids) == noErr else {
    return []
  }
  return ids
}

func audioProcessObjects() -> [AudioObjectID] {
  readObjectList(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
}

func inputDevices() -> [AudioObjectID] {
  readObjectList(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
    .filter { device in
      var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreams,
        mScope: kAudioObjectPropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain
      )
      var size: UInt32 = 0
      return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }
}

func anyInputDeviceIsRunning() -> Bool {
  inputDevices().contains { device in
    readProperty(device, kAudioDevicePropertyDeviceIsRunningSomewhere, initial: UInt32(0)) == 1
  }
}

@MainActor
final class InputDeviceWatcher {
  private var observed = Set<AudioObjectID>()
  private let changes: AsyncStream<Void>.Continuation

  init(changes: AsyncStream<Void>.Continuation) {
    self.changes = changes
    listen(to: AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
    observeNewDevices()
  }

  func observeNewDevices() {
    let current = Set(inputDevices())
    observed.formIntersection(current)
    for device in current.subtracting(observed) {
      listen(to: device, kAudioDevicePropertyDeviceIsRunningSomewhere)
      observed.insert(device)
    }
  }

  private func listen(to object: AudioObjectID, _ selector: AudioObjectPropertySelector) {
    var address = globalAddress(selector)
    let changes = changes
    let status = AudioObjectAddPropertyListenerBlock(object, &address, .main) { _, _ in
      changes.yield()
    }
    if status != noErr {
      log("Failed to listen to audio object \(object): OSStatus \(status)")
    }
  }
}

func readProperty<Value: BitwiseCopyable>(
  _ object: AudioObjectID,
  _ selector: AudioObjectPropertySelector,
  initial: Value
) -> Value? {
  var address = globalAddress(selector)
  var value = initial
  var size = UInt32(MemoryLayout<Value>.size)
  guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else {
    return nil
  }
  return value
}

func claudeCodeIsRecording() -> Bool {
  audioProcessObjects().contains { object in
    guard
      readProperty(object, kAudioProcessPropertyIsRunningInput, initial: UInt32(0)) == 1,
      let pid = readProperty(object, kAudioProcessPropertyPID, initial: pid_t(0))
    else { return false }
    return belongsToClaudeCode(pid)
  }
}

// MARK: - Now Playing

enum MediaControlError: Error {
  case failed(arguments: [String], status: Int32)
}

struct NowPlaying: Decodable {
  let bundleIdentifier: String
  let playing: Bool
}

func mediaControl(_ arguments: [String]) async throws -> Data {
  try await Task.detached {
    let process = Process()
    process.executableURL = URL(filePath: mediaControlPath)
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    let data = try output.fileHandleForReading.readToEnd() ?? Data()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw MediaControlError.failed(arguments: arguments, status: process.terminationStatus)
    }
    return data
  }.value
}

func nowPlaying() async throws -> NowPlaying? {
  let data = try await mediaControl(["get", "--no-artwork"])
  return try JSONDecoder().decode(NowPlaying?.self, from: data)
}

// MARK: - Main

@MainActor
final class Controller {
  private var pausedApp: String?
  private var wasRecording = false

  func reconcile() async {
    let recording = claudeCodeIsRecording()
    if recording != wasRecording {
      wasRecording = recording
      log(recording ? "Claude Code started recording" : "Claude Code stopped recording")
    }
    do {
      if recording {
        guard pausedApp == nil, let current = try await nowPlaying(), current.playing else {
          return
        }
        _ = try await mediaControl(["pause"])
        pausedApp = current.bundleIdentifier
        log("Paused \(current.bundleIdentifier)")
      } else if let app = pausedApp {
        try await Task.sleep(for: resumeDelay)
        guard !claudeCodeIsRecording() else { return }
        pausedApp = nil
        // Don't resume if the user switched players or resumed manually meanwhile.
        guard let current = try await nowPlaying(), current.bundleIdentifier == app,
          !current.playing
        else {
          log("Not resuming \(app): now playing state changed")
          return
        }
        _ = try await mediaControl(["play"])
        log("Resumed \(app)")
      }
    } catch {
      log("Error: \(error)")
    }
  }
}

@MainActor
func run() async throws {
  log("Watching Claude Code microphone usage")
  let (changes, continuation) = AsyncStream.makeStream(
    of: Void.self,
    bufferingPolicy: .bufferingNewest(1)
  )
  let watcher = InputDeviceWatcher(changes: continuation)
  let controller = Controller()
  var nextChange = changes.makeAsyncIterator()
  while true {
    watcher.observeNewDevices()
    await controller.reconcile()
    if anyInputDeviceIsRunning() {
      try await Task.sleep(for: pollInterval)
    } else {
      await nextChange.next()
    }
  }
}

try await run()
