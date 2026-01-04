import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Metal
import VideoToolbox

// MARK: - ProRes Video Reader

/// Video reader class for reading ProRes frames
class ProResVideoReader {
    private var asset: AVAsset?
    private var assetReader: AVAssetReader?
    private var videoOutput: AVAssetReaderTrackOutput?
    private var textureCache: CVMetalTextureCache?
    private var metalDevice: MTLDevice?
    private var currentCVTexture: CVMetalTexture?  // Keep texture alive

    var width: Int32 = 0
    var height: Int32 = 0
    var duration: Double = 0.0
    var frameRate: Double = 0.0

    init?(filepath: String, metalDevice: MTLDevice) {
        self.metalDevice = metalDevice

        // Create texture cache for converting CVPixelBuffer to Metal texture
        var cache: CVMetalTextureCache?
        let result = CVMetalTextureCacheCreate(nil, nil, metalDevice, nil, &cache)
        guard result == kCVReturnSuccess, let textureCache = cache else {
            print("[VideoReader] Failed to create texture cache")
            return nil
        }
        self.textureCache = textureCache

        // Load video file
        let url = URL(fileURLWithPath: filepath)
        let asset = AVAsset(url: url)
        self.asset = asset

        // Get video track
        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            print("[VideoReader] No video track found")
            return nil
        }

        // Get video properties
        self.width = Int32(videoTrack.naturalSize.width)
        self.height = Int32(videoTrack.naturalSize.height)
        self.duration = asset.duration.seconds
        self.frameRate = Double(videoTrack.nominalFrameRate)

        print("[VideoReader] Loaded: \(filepath)")
        print("[VideoReader]   Size: \(width)x\(height)")
        print("[VideoReader]   Duration: \(duration)s")
        print("[VideoReader]   FPS: \(frameRate)")

        // Create asset reader
        guard let reader = try? AVAssetReader(asset: asset) else {
            print("[VideoReader] Failed to create asset reader")
            return nil
        }
        self.assetReader = reader

        // Configure output settings (decompress to BGRA for Metal)
        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]

        let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false

        if reader.canAdd(output) {
            reader.add(output)
            self.videoOutput = output
        } else {
            print("[VideoReader] Cannot add output")
            return nil
        }

        // Start reading
        if !reader.startReading() {
            print("[VideoReader] Failed to start reading")
            return nil
        }
    }

    /// Read next frame and convert to Metal texture
    func getNextFrame() -> MTLTexture? {
        guard let videoOutput = videoOutput,
            let assetReader = assetReader
        else { return nil }

        // Check reader status
        guard assetReader.status == .reading else {
            if assetReader.status == .completed {
                print("[VideoReader] Reached end of file")
            } else if assetReader.status == .failed {
                print("[VideoReader] Reader failed: \(String(describing: assetReader.error))")
            }
            return nil
        }

        // Get next sample buffer
        guard let sampleBuffer = videoOutput.copyNextSampleBuffer() else {
            return nil
        }

        // Get pixel buffer from sample
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return nil
        }

        // Convert CVPixelBuffer to Metal texture
        return pixelBufferToMetalTexture(pixelBuffer)
    }

    private func pixelBufferToMetalTexture(_ pixelBuffer: CVPixelBuffer) -> MTLTexture? {
        guard let textureCache = textureCache else { return nil }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var cvTexture: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(
            nil,
            textureCache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &cvTexture
        )

        guard result == kCVReturnSuccess,
            let cvTexture = cvTexture
        else {
            print("[VideoReader] Failed to create texture from pixel buffer")
            return nil
        }

        // Keep CVTexture alive by storing it - otherwise the MTLTexture becomes invalid
        self.currentCVTexture = cvTexture

        return CVMetalTextureGetTexture(cvTexture)
    }

    /// Seek to beginning and restart reading
    func restart() {
        guard let asset = asset,
            let videoTrack = asset.tracks(withMediaType: .video).first
        else { return }

        // Create new reader
        guard let reader = try? AVAssetReader(asset: asset) else { return }

        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]

        let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false

        if reader.canAdd(output) {
            reader.add(output)
            self.videoOutput = output
            self.assetReader = reader
            reader.startReading()
        }
    }
}

// MARK: - C Bridge Functions

@_cdecl("video_reader_create")
public func video_reader_create(
    _ filepath: UnsafePointer<CChar>, _ devicePtr: UnsafeMutableRawPointer
) -> UnsafeMutableRawPointer? {
    let path = String(cString: filepath)
    let device = Unmanaged<MTLDevice>.fromOpaque(devicePtr).takeUnretainedValue()

    guard let reader = ProResVideoReader(filepath: path, metalDevice: device) else {
        return nil
    }

    return Unmanaged.passRetained(reader).toOpaque()
}

@_cdecl("video_reader_get_next_frame")
public func video_reader_get_next_frame(_ readerPtr: UnsafeMutableRawPointer)
    -> UnsafeMutableRawPointer?
{
    let reader = Unmanaged<ProResVideoReader>.fromOpaque(readerPtr).takeUnretainedValue()

    guard let texture = reader.getNextFrame() else {
        return nil
    }

    // Return unretained - Metal will keep it alive while GPU uses it
    return Unmanaged.passUnretained(texture).toOpaque()
}

@_cdecl("video_reader_restart")
public func video_reader_restart(_ readerPtr: UnsafeMutableRawPointer) {
    let reader = Unmanaged<ProResVideoReader>.fromOpaque(readerPtr).takeUnretainedValue()
    reader.restart()
}

@_cdecl("video_reader_get_info")
public func video_reader_get_info(
    _ readerPtr: UnsafeMutableRawPointer,
    _ outWidth: UnsafeMutablePointer<Int32>,
    _ outHeight: UnsafeMutablePointer<Int32>,
    _ outDuration: UnsafeMutablePointer<Double>,
    _ outFrameRate: UnsafeMutablePointer<Double>
) {
    let reader = Unmanaged<ProResVideoReader>.fromOpaque(readerPtr).takeUnretainedValue()
    outWidth.pointee = reader.width
    outHeight.pointee = reader.height
    outDuration.pointee = reader.duration
    outFrameRate.pointee = reader.frameRate
}

@_cdecl("video_reader_release")
public func video_reader_release(_ readerPtr: UnsafeMutableRawPointer) {
    let _ = Unmanaged<ProResVideoReader>.fromOpaque(readerPtr).takeRetainedValue()
}

@_cdecl("video_texture_release")
public func video_texture_release(_ texturePtr: UnsafeMutableRawPointer) {
    let _ = Unmanaged<MTLTexture>.fromOpaque(texturePtr).takeRetainedValue()
}
