import Foundation
import Network
import VideoToolbox
import CoreMedia
import CoreVideo
import AVFoundation

// Apple's sampleBufferRenderer supports background-thread enqueue, independent of UI layout.
final class VideoSurface: @unchecked Sendable {
    let layer = AVSampleBufferDisplayLayer()
    let renderer: AVSampleBufferVideoRenderer
    private let lock = NSLock()
    private var format: CMVideoFormatDescription?
    init() { renderer = layer.sampleBufferRenderer }
    func enqueue(_ pixel: CVPixelBuffer) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if format == nil {
            guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel, formatDescriptionOut: &format) == noErr else { return false }
        }
        guard let format else { return false }
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 60), presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else { return false }
        if let array = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary], let first = array.first {
            first[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        guard renderer.status != .failed else { return false }
        renderer.enqueue(sample)
        return true
    }
}

final class VideoReceiver: @unchecked Sendable {
    let queue = DispatchQueue(label: "HarmonyBridge.video", qos: .userInteractive)
    let lock = NSLock()
    var connection: NWConnection?
    var decoder: VTDecompressionSession?
    var format: CMVideoFormatDescription?
    var buffer = Data()
    var sps = Data(), pps = Data()
    var received = 0, decoded = 0, submitted = 0
    var timer: DispatchSourceTimer?
    var lastCounts = (0, 0, 0)
    var lastTime = Date()
    var stopped = false
    var onFrame: ((CVPixelBuffer) -> Bool)?
    var onStats: ((String) -> Void)?
    var onError: ((String) -> Void)?

    func start(port: UInt16, token: String) {
        queue.async { [self] in
            let socket = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            connection = socket
            socket.stateUpdateHandler = { [weak self] state in
                guard let self, !self.stopped else { return }
                if case .ready = state {
                    socket.send(content: Data((token + "\n").utf8), completion: .contentProcessed { error in
                        if let error { self.report(error.localizedDescription) }
                    })
                    self.read()
                }
                if case .failed(let error) = state { self.report(error.localizedDescription) }
            }
            socket.start(queue: queue)
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                self.lock.lock(); let counts = (self.received, self.decoded, self.submitted); self.lock.unlock()
                let now = Date(), elapsed = now.timeIntervalSince(self.lastTime)
                let info = String(format: "接收 %.1f · 解码 %.1f · 显示提交 %.1f FPS", Double(counts.0-self.lastCounts.0)/elapsed, Double(counts.1-self.lastCounts.1)/elapsed, Double(counts.2-self.lastCounts.2)/elapsed)
                self.lastCounts = counts; self.lastTime = now
                DispatchQueue.main.async { self.onStats?(info) }
            }
            self.timer = timer; timer.resume()
        }
    }
    func stop() {
        queue.async { [self] in
            stopped = true; connection?.cancel(); connection = nil; timer?.cancel(); timer = nil
            if let decoder { VTDecompressionSessionWaitForAsynchronousFrames(decoder); VTDecompressionSessionInvalidate(decoder) }
            decoder = nil; format = nil
        }
    }
    func report(_ message: String) { DispatchQueue.main.async { [weak self] in self?.onError?(message) } }
    func read() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 262144) { [weak self] data, _, complete, error in
            guard let self, !self.stopped else { return }
            if let data { self.buffer.append(data); self.consume() }
            if let error { self.report(error.localizedDescription); return }
            if complete { self.report("手机视频通道已关闭，请确认手机已开始共享屏幕"); return }
            self.read()
        }
    }
    func integer(_ data: Data, _ offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { ($0 << 8) | UInt32(data[data.startIndex+offset+$1]) }
    }
    func consume() {
        while buffer.count >= 16 {
            let length = Int(integer(buffer, 0)), flags = integer(buffer, 4)
            guard length > 0 && length <= 8_388_608 else { report("视频数据包无效"); connection?.cancel(); return }
            guard buffer.count >= length + 16 else { return }
            let payload = Data(buffer[buffer.startIndex+16..<buffer.startIndex+16+length])
            buffer.removeFirst(length + 16)
            if flags & 8 == 0 { lock.lock(); received += 1; lock.unlock() }
            decode(payload)
        }
    }
    func nals(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var starts: [(Int, Int)] = [], i = 0
        while i + 2 < bytes.count {
            if bytes[i] == 0 && bytes[i+1] == 0 {
                if bytes[i+2] == 1 { starts.append((i,3)); i += 3; continue }
                if i + 3 < bytes.count && bytes[i+2] == 0 && bytes[i+3] == 1 { starts.append((i,4)); i += 4; continue }
            }
            i += 1
        }
        guard !starts.isEmpty else { return [] }
        return starts.enumerated().compactMap { index, value in
            let end = index+1 < starts.count ? starts[index+1].0 : bytes.count
            guard value.0+value.1 < end else { return nil }
            return Data(bytes[value.0+value.1..<end])
        }
    }
    func setup() throws {
        guard !sps.isEmpty, !pps.isEmpty else { return }
        var created: CMFormatDescription?
        let status = sps.withUnsafeBytes { a in pps.withUnsafeBytes { b in
            let pointers: [UnsafePointer<UInt8>] = [a.bindMemory(to: UInt8.self).baseAddress!, b.bindMemory(to: UInt8.self).baseAddress!]
            let sizes = [sps.count, pps.count]
            return pointers.withUnsafeBufferPointer { ptr in sizes.withUnsafeBufferPointer { sizes in
                CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: ptr.baseAddress!, parameterSetSizes: sizes.baseAddress!, nalUnitHeaderLength: 4, formatDescriptionOut: &created)
            }}
        }}
        guard status == noErr, let created else { throw BridgeError(message: "H.264 格式错误：\(status)") }
        if let decoder { VTDecompressionSessionWaitForAsynchronousFrames(decoder); VTDecompressionSessionInvalidate(decoder) }
        format = created
        var callback = VTDecompressionOutputCallbackRecord(decompressionOutputCallback: { ref, _, status, _, image, _, _ in
            guard let ref else { return }
            let receiver = Unmanaged<VideoReceiver>.fromOpaque(ref).takeUnretainedValue()
            if status != noErr { receiver.report("硬件解码失败：\(status)"); return }
            if let image { receiver.deliver(image) }
        }, decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque())
        let specification = [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true] as CFDictionary
        let attributes = [kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary
        let result = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: created, decoderSpecification: specification, imageBufferAttributes: attributes, outputCallback: &callback, decompressionSessionOut: &decoder)
        guard result == noErr else { throw BridgeError(message: "无法创建 Mac 硬件解码器：\(result)") }
        if let decoder { VTSessionSetProperty(decoder, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue) }
    }
    func decode(_ data: Data) {
        do {
            let units = nals(data)
            var access = Data(), changed = false, hasPicture = false
            for unit in units {
                guard let first = unit.first else { continue }
                let type = first & 31
                if type == 7 { changed = changed || sps != unit; sps = unit; continue }
                if type == 8 { changed = changed || pps != unit; pps = unit; continue }
                if type == 1 || type == 5 { hasPicture = true }
                var length = UInt32(unit.count).bigEndian
                withUnsafeBytes(of: &length) { access.append(contentsOf: $0) }; access.append(unit)
            }
            if changed || decoder == nil { try setup() }
            guard hasPicture, let decoder, let format, !access.isEmpty else { return }
            var block: CMBlockBuffer?
            var result = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: access.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: access.count, flags: 0, blockBufferOut: &block)
            guard result == noErr, let block else { return }
            result = access.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: access.count) }
            guard result == noErr else { return }
            var sample: CMSampleBuffer?, size = access.count
            result = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
            guard result == noErr, let sample else { return }
            result = VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: sample, flags: [._EnableAsynchronousDecompression, ._1xRealTimePlayback], frameRefcon: nil, infoFlagsOut: nil)
            if result != noErr { report("视频解码输入失败：\(result)") }
        } catch { report(error.localizedDescription) }
    }
    func deliver(_ image: CVPixelBuffer) {
        lock.lock(); decoded += 1; lock.unlock()
        if onFrame?(image) == true { lock.lock(); submitted += 1; lock.unlock() }
    }
}
