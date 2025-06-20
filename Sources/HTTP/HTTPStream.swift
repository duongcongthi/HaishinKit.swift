import AVFoundation

/// The HTTPStream class represents an HLS playlist and .ts files.
open class HTTPStream: NetStream {
    /// For appendSampleBuffer, specifies whether media contains types .video or .audio.
    public var expectedMedias: Set<AVMediaType> {
        get {
            tsWriter.expectedMedias
        }
        set {
            tsWriter.expectedMedias = newValue
        }
    }

    /// The name of stream.
    private(set) var name: String?
    private lazy var tsWriter = TSFileWriter()

    open func publish(_ name: String?) {
        lockQueue.async {
            if name == nil {
                print("[HTTPStream] Stopping publish")
                self.name = name
                self.mixer.stopEncoding()
                self.tsWriter.stopRunning()
                return
            }
            print("[HTTPStream] Starting publish with name: \(name!)")
            print("[HTTPStream] Expected medias: \(self.expectedMedias)")
            self.name = name
            self.mixer.startEncoding(self.tsWriter)
            self.mixer.startRunning()
            self.tsWriter.startRunning()
            print("[HTTPStream] Publish started - mixer encoding, mixer running, tsWriter running")
        }
    }

    #if os(iOS) || os(macOS)
    override open func attachCamera(_ device: AVCaptureDevice?, onError: ((any Error) -> Void)? = nil) {
        if device == nil {
            tsWriter.expectedMedias.remove(.video)
        } else {
            tsWriter.expectedMedias.insert(.video)
        }
        super.attachCamera(device, onError: onError)
    }

    override open func attachAudio(_ device: AVCaptureDevice?, automaticallyConfiguresApplicationAudioSession: Bool = true, onError: ((any Error) -> Void)? = nil) {
        if device == nil {
            tsWriter.expectedMedias.remove(.audio)
        } else {
            tsWriter.expectedMedias.insert(.audio)
        }
        super.attachAudio(device, automaticallyConfiguresApplicationAudioSession: automaticallyConfiguresApplicationAudioSession, onError: onError)
    }
    #endif

    func getResource(_ resourceName: String) -> (MIME, String)? {
        let url = URL(fileURLWithPath: resourceName)
        guard let name: String = name, 2 <= url.pathComponents.count && url.pathComponents[1] == name else {
            return nil
        }
        let fileName: String = url.pathComponents.last!
        switch true {
        case fileName == "playlist.m3u8":
            return (.applicationXMpegURL, tsWriter.playlist)
        case fileName.contains(".ts"):
            if let mediaFile: String = tsWriter.getFilePath(fileName) {
                return (.videoMP2T, mediaFile)
            }
            return nil
        default:
            return nil
        }
    }
}
