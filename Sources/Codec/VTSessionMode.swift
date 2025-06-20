import Foundation
import VideoToolbox

enum VTSessionMode {
    case compression
    case decompression

    func makeSession(_ videoCodec: VideoCodec) -> (any VTSessionConvertible)? {
        switch self {
        case .compression:
            print("[VTSessionMode] Creating compression session - size: \(videoCodec.settings.videoSize), codecType: \(videoCodec.settings.format.codecType)")
            var session: VTCompressionSession?
            var status = VTCompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                width: Int32(videoCodec.settings.videoSize.width),
                height: Int32(videoCodec.settings.videoSize.height),
                codecType: videoCodec.settings.format.codecType,
                encoderSpecification: nil,
                imageBufferAttributes: videoCodec.attributes as CFDictionary?,
                compressedDataAllocator: nil,
                outputCallback: nil,
                refcon: nil,
                compressionSessionOut: &session
            )
            guard status == noErr, let session else {
                print("[VTSessionMode] VTCompressionSessionCreate failed with status: \(status)")
                videoCodec.delegate?.videoCodec(videoCodec, errorOccurred: .failedToCreate(status: status))
                return nil
            }
            print("[VTSessionMode] Compression session created successfully, setting options")
            status = session.setOptions(videoCodec.settings.options(videoCodec))
            guard status == noErr else {
                print("[VTSessionMode] setOptions failed with status: \(status)")
                videoCodec.delegate?.videoCodec(videoCodec, errorOccurred: .failedToPrepare(status: status))
                return nil
            }
            print("[VTSessionMode] Options set successfully, preparing to encode frames")
            status = session.prepareToEncodeFrames()
            guard status == noErr else {
                print("[VTSessionMode] prepareToEncodeFrames failed with status: \(status)")
                videoCodec.delegate?.videoCodec(videoCodec, errorOccurred: .failedToPrepare(status: status))
                return nil
            }
            print("[VTSessionMode] Compression session fully initialized")
            return session
        case .decompression:
            guard let formatDescription = videoCodec.formatDescription else {
                videoCodec.delegate?.videoCodec(videoCodec, errorOccurred: .failedToCreate(status: kVTParameterErr))
                return nil
            }
            var attributes = videoCodec.attributes
            attributes?.removeValue(forKey: kCVPixelBufferWidthKey)
            attributes?.removeValue(forKey: kCVPixelBufferHeightKey)
            var session: VTDecompressionSession?
            let status = VTDecompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                formatDescription: formatDescription,
                decoderSpecification: nil,
                imageBufferAttributes: attributes as CFDictionary?,
                outputCallback: nil,
                decompressionSessionOut: &session
            )
            guard status == noErr else {
                videoCodec.delegate?.videoCodec(videoCodec, errorOccurred: .failedToCreate(status: status))
                return nil
            }
            return session
        }
    }
}
