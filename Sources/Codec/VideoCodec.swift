import AVFoundation
import CoreFoundation
import VideoToolbox

#if os(iOS)
import UIKit
#endif

/**
 * The interface a VideoCodec uses to inform its delegate.
 */
public protocol VideoCodecDelegate: AnyObject {
    /// Tells the receiver to set a formatDescription.
    func videoCodec(_ codec: VideoCodec, didOutput formatDescription: CMFormatDescription?)
    /// Tells the receiver to output an encoded or decoded sampleBuffer.
    func videoCodec(_ codec: VideoCodec, didOutput sampleBuffer: CMSampleBuffer)
    /// Tells the receiver to occured an error.
    func videoCodec(_ codec: VideoCodec, errorOccurred error: VideoCodec.Error)
    /// Tells the receiver to drop frame.
    func videoCodecWillDropFame(_ codec: VideoCodec) -> Bool
}

// MARK: -
/**
 * The VideoCodec class provides methods for encode or decode for video.
 */
public class VideoCodec {
    /**
     * The VideoCodec error domain codes.
     */
    public enum Error: Swift.Error {
        /// The VideoCodec failed to create the VTSession.
        case failedToCreate(status: OSStatus)
        /// The VideoCodec failed to prepare the VTSession.
        case failedToPrepare(status: OSStatus)
        /// The VideoCodec failed to encode or decode a flame.
        case failedToFlame(status: OSStatus)
        /// The VideoCodec failed to set an option.
        case failedToSetOption(status: OSStatus, option: VTSessionOption)
    }

    /// The videoCodec's attributes value. 
    public static var defaultAttributes: [NSString: AnyObject]? = nil // Disable tất cả attributes để test

    /// Specifies the settings for a VideoCodec.
    public var settings: VideoCodecSettings = .default {
        didSet {
            let invalidateSession = settings.invalidateSession(oldValue)
            if invalidateSession {
                self.invalidateSession = invalidateSession
            } else {
                settings.apply(self, rhs: oldValue)
            }
        }
    }

    /// The running value indicating whether the VideoCodec is running.
    public private(set) var isRunning: Atomic<Bool> = .init(false)

    var lockQueue = DispatchQueue(label: "com.haishinkit.HaishinKit.VideoCodec.lock")
    var expectedFrameRate = IOMixer.defaultFrameRate
    var formatDescription: CMFormatDescription? {
        didSet {
            guard !CMFormatDescriptionEqual(formatDescription, otherFormatDescription: oldValue) else {
                return
            }
            delegate?.videoCodec(self, didOutput: formatDescription)
        }
    }
    var needsSync: Atomic<Bool> = .init(true)
    var attributes: [NSString: AnyObject]? {
        guard VideoCodec.defaultAttributes != nil else {
            print("[VideoCodec] No default attributes")
            return nil
        }
        var attributes: [NSString: AnyObject] = [:]
        for (key, value) in VideoCodec.defaultAttributes ?? [:] {
            attributes[key] = value
        }
        attributes[kCVPixelBufferWidthKey] = NSNumber(value: settings.videoSize.width)
        attributes[kCVPixelBufferHeightKey] = NSNumber(value: settings.videoSize.height)
        print("[VideoCodec] Pixel buffer attributes: \(attributes)")
        return attributes
    }
    weak var delegate: (any VideoCodecDelegate)?
    private(set) var session: (any VTSessionConvertible)? {
        didSet {
            oldValue?.invalidate()
            invalidateSession = false
        }
    }
    private var invalidateSession = true

    func appendImageBuffer(_ imageBuffer: CVImageBuffer, presentationTimeStamp: CMTime, duration: CMTime) {
        guard isRunning.value, !(delegate?.videoCodecWillDropFame(self) ?? false) else {
            print("[VideoCodec] appendImageBuffer skipped - codec not running or frame should be dropped")
            return
        }
        let pixelFormat = CVPixelBufferGetPixelFormatType(imageBuffer)
        let width = CVPixelBufferGetWidth(imageBuffer)
        let height = CVPixelBufferGetHeight(imageBuffer)
        print("[VideoCodec] Received image buffer - size: \(width)x\(height), format: \(pixelFormat)")
        if invalidateSession {
            print("[VideoCodec] Creating compression session")
            session = VTSessionMode.compression.makeSession(self)
        }
        guard let session = session else {
            print("[VideoCodec] No compression session available for encoding")
            return
        }
        print("[VideoCodec] Encoding frame with session")
        _ = session.encodeFrame(
            imageBuffer,
            presentationTimeStamp: presentationTimeStamp,
            duration: duration
        ) { [unowned self] status, _, sampleBuffer in
            guard let sampleBuffer, status == noErr else {
                print("[VideoCodec] Encode frame failed with status: \(status)")
                delegate?.videoCodec(self, errorOccurred: .failedToFlame(status: status))
                return
            }
            print("[VideoCodec] Successfully encoded frame, setting format description")
            formatDescription = sampleBuffer.formatDescription
            delegate?.videoCodec(self, didOutput: sampleBuffer)
        }
    }

    func appendSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard isRunning.value else {
            print("[VideoCodec] appendSampleBuffer skipped - codec not running")
            return
        }
        print("[VideoCodec] Received sample buffer for processing")
        if invalidateSession {
            print("[VideoCodec] Creating decompression session")
            session = VTSessionMode.decompression.makeSession(self)
            needsSync.mutate { $0 = true }
        }
        if !sampleBuffer.isNotSync {
            needsSync.mutate { $0 = false }
        }
        _ = session?.decodeFrame(sampleBuffer) { [unowned self] status, _, imageBuffer, presentationTimeStamp, duration in
            guard let imageBuffer, status == noErr else {
                print("[VideoCodec] Decode frame failed with status: \(status)")
                self.delegate?.videoCodec(self, errorOccurred: .failedToFlame(status: status))
                return
            }
            print("[VideoCodec] Successfully decoded frame")
            var timingInfo = CMSampleTimingInfo(
                duration: duration,
                presentationTimeStamp: presentationTimeStamp,
                decodeTimeStamp: sampleBuffer.decodeTimeStamp
            )
            var videoFormatDescription: CMVideoFormatDescription?
            var status = CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: imageBuffer,
                formatDescriptionOut: &videoFormatDescription
            )
            guard status == noErr else {
                print("[VideoCodec] Create format description failed with status: \(status)")
                delegate?.videoCodec(self, errorOccurred: .failedToFlame(status: status))
                return
            }
            var sampleBuffer: CMSampleBuffer?
            status = CMSampleBufferCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: imageBuffer,
                dataReady: true,
                makeDataReadyCallback: nil,
                refcon: nil,
                formatDescription: videoFormatDescription!,
                sampleTiming: &timingInfo,
                sampleBufferOut: &sampleBuffer
            )
            guard let buffer = sampleBuffer, status == noErr else {
                print("[VideoCodec] Create sample buffer failed with status: \(status)")
                delegate?.videoCodec(self, errorOccurred: .failedToFlame(status: status))
                return
            }
            print("[VideoCodec] Outputting decoded sample buffer")
            delegate?.videoCodec(self, didOutput: buffer)
        }
    }

    #if os(iOS)
    @objc
    private func applicationWillEnterForeground(_ notification: Notification) {
        invalidateSession = true
    }

    @objc
    private func didAudioSessionInterruption(_ notification: Notification) {
        guard
            let userInfo: [AnyHashable: Any] = notification.userInfo,
            let value: NSNumber = userInfo[AVAudioSessionInterruptionTypeKey] as? NSNumber,
            let type = AVAudioSession.InterruptionType(rawValue: value.uintValue) else {
            return
        }
        switch type {
        case .ended:
            invalidateSession = true
        default:
            break
        }
    }
    #endif
}

extension VideoCodec: Running {
    // MARK: Running
    public func startRunning() {
        lockQueue.async {
            self.isRunning.mutate { $0 = true }
            #if os(iOS)
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(self.didAudioSessionInterruption),
                name: AVAudioSession.interruptionNotification,
                object: nil
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(self.applicationWillEnterForeground),
                name: UIApplication.willEnterForegroundNotification,
                object: nil
            )
            #endif
        }
    }

    public func stopRunning() {
        lockQueue.async {
            self.session = nil
            self.invalidateSession = true
            self.needsSync.mutate { $0 = true }
            self.formatDescription = nil
            #if os(iOS)
            NotificationCenter.default.removeObserver(self, name: AVAudioSession.interruptionNotification, object: nil)
            NotificationCenter.default.removeObserver(self, name: UIApplication.willEnterForegroundNotification, object: nil)
            #endif
            self.isRunning.mutate { $0 = false }
        }
    }
}
