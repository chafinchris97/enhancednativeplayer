import AetherLibavcodec
import AetherLibavutil
import CoreMedia
import CoreVideo
import Foundation
import PixelInterleave

/// Turns decoded frames into the sample buffers `AVSampleBufferDisplayLayer` shows: 4:2:0 at
/// 8 bits becomes NV12 (`420v` / `420f`), at 10 bits P010 (`x420` / `xf20`), in IOSurface
/// buffers from a pool. The frame's colour description goes on the buffer, which is what makes
/// the layer show PQ and HLG as HDR.
final class PixelBufferConverter {
    private struct Shape: Equatable {
        var width: Int32
        var height: Int32
        var pixelFormat: OSType
    }

    private let source: RenderedVideoSource
    private var pool: CVPixelBufferPool?
    private var shape: Shape?
    private var formatDescription: CMVideoFormatDescription?

    init(source: RenderedVideoSource) {
        self.source = source
    }

    /// The frame as a sample shown from `start` to `end` (100 ns ticks), nil for a pixel
    /// format it doesn't handle.
    func sample(for frame: UnsafePointer<AVFrame>, start: Int64, end: Int64) -> CMSampleBuffer? {
        guard let buffer = pixelBuffer(for: frame) else { return nil }
        if formatDescription.map({ !CMVideoFormatDescriptionMatchesImageBuffer($0, imageBuffer: buffer) }) ?? true {
            var description: CMVideoFormatDescription?
            guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &description) == noErr else { return nil }
            formatDescription = description
        }
        guard let formatDescription else { return nil }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: max(1, end - start), timescale: 10_000_000),
            presentationTimeStamp: CMTime(value: start, timescale: 10_000_000),
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer, formatDescription: formatDescription, sampleTiming: &timing, sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }

    /// Bytes of one converted frame, for sizing how many may wait in the layer's queue.
    static func bytesPerFrame(width: Int, height: Int, pixelFormat: Int32) -> Int {
        let bytesPerSample = AVPixelFormat(rawValue: pixelFormat) == AV_PIX_FMT_YUV420P10LE ? 2 : 1
        return width * height * 3 / 2 * bytesPerSample
    }

    private func pixelBuffer(for frame: UnsafePointer<AVFrame>) -> CVPixelBuffer? {
        let format = AVPixelFormat(rawValue: frame.pointee.format)
        let fullRange = format == AV_PIX_FMT_YUVJ420P || frame.pointee.color_range == AVCOL_RANGE_JPEG
        let tenBit: Bool
        switch format {
        case AV_PIX_FMT_YUV420P, AV_PIX_FMT_YUVJ420P: tenBit = false
        case AV_PIX_FMT_YUV420P10LE: tenBit = true
        default: return nil
        }
        let pixelFormat: OSType = tenBit
            ? (fullRange ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
            : (fullRange ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        let shape = Shape(width: frame.pointee.width, height: frame.pointee.height, pixelFormat: pixelFormat)
        guard shape.width > 0, shape.height > 0, let pool = pool(for: shape) else { return nil }
        var created: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &created) == kCVReturnSuccess, let buffer = created else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        let width = Int(shape.width)
        let height = Int(shape.height)
        let chromaWidth = (width + 1) / 2
        let chromaHeight = (height + 1) / 2
        let lumaOut = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let chromaOut = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        let planes = frame.pointee.data
        let strides = frame.pointee.linesize
        if tenBit {
            pi_shift_16(
                UnsafeRawPointer(planes.0!).assumingMemoryBound(to: UInt16.self), Int(strides.0),
                lumaOut.assumingMemoryBound(to: UInt16.self), lumaStride,
                width, height, 10
            )
            pi_interleave_16(
                UnsafeRawPointer(planes.1!).assumingMemoryBound(to: UInt16.self), Int(strides.1),
                UnsafeRawPointer(planes.2!).assumingMemoryBound(to: UInt16.self), Int(strides.2),
                chromaOut.assumingMemoryBound(to: UInt16.self), chromaStride,
                chromaWidth, chromaHeight, 10
            )
        } else {
            pi_copy_8(planes.0!, Int(strides.0), lumaOut.assumingMemoryBound(to: UInt8.self), lumaStride, width, height)
            pi_interleave_8(
                planes.1!, Int(strides.1),
                planes.2!, Int(strides.2),
                chromaOut.assumingMemoryBound(to: UInt8.self), chromaStride,
                chromaWidth, chromaHeight
            )
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        attachColor(to: buffer, frame: frame)
        return buffer
    }

    private func pool(for shape: Shape) -> CVPixelBufferPool? {
        if shape == self.shape, let pool { return pool }
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: shape.pixelFormat,
            kCVPixelBufferWidthKey: Int(shape.width),
            kCVPixelBufferHeightKey: Int(shape.height),
            kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
        ]
        var created: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &created)
        pool = created
        self.shape = created == nil ? nil : shape
        formatDescription = nil
        return created
    }

    /// Primaries, transfer function, matrix and pixel aspect, from the frame where the
    /// bitstream says, else the container, else what is usual for the size (BT.601 up to 576 lines).
    private func attachColor(to buffer: CVPixelBuffer, frame: UnsafePointer<AVFrame>) {
        let standardDefinition = frame.pointee.height <= 576
        func codePoint(_ frameValue: Int32, _ sourceValue: Int32, standard: Int32, highDefinition: Int32) -> Int32 {
            for value in [frameValue, sourceValue] where value != 2 && value > 0 { return value } // 2: unspecified
            return standardDefinition ? standard : highDefinition
        }
        // ISO/IEC 23091-2 code points, which FFmpeg's enums and CoreVideo share.
        let primaries = codePoint(Int32(frame.pointee.color_primaries.rawValue), source.colorPrimaries, standard: 6, highDefinition: 1)
        let transfer = codePoint(Int32(frame.pointee.color_trc.rawValue), source.colorTransfer, standard: 1, highDefinition: 1)
        let matrix = codePoint(Int32(frame.pointee.colorspace.rawValue), source.colorSpace, standard: 6, highDefinition: 1)
        if let value = CVColorPrimariesGetStringForIntegerCodePoint(primaries)?.takeUnretainedValue() {
            CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, value, .shouldPropagate)
        }
        if let value = CVTransferFunctionGetStringForIntegerCodePoint(transfer)?.takeUnretainedValue() {
            CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, value, .shouldPropagate)
        }
        if let value = CVYCbCrMatrixGetStringForIntegerCodePoint(matrix)?.takeUnretainedValue() {
            CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, value, .shouldPropagate)
        }
        CVBufferSetAttachment(buffer, kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_Left, .shouldPropagate)
        let frameAspect = Rational(frame.pointee.sample_aspect_ratio)
        let aspect = frameAspect.isValid ? frameAspect : source.sampleAspect
        if aspect.isValid, aspect.num != aspect.den {
            let spacing: [CFString: Any] = [
                kCVImageBufferPixelAspectRatioHorizontalSpacingKey: Int(aspect.num),
                kCVImageBufferPixelAspectRatioVerticalSpacingKey: Int(aspect.den),
            ]
            CVBufferSetAttachment(buffer, kCVImageBufferPixelAspectRatioKey, spacing as CFDictionary, .shouldPropagate)
        } else {
            CVBufferRemoveAttachment(buffer, kCVImageBufferPixelAspectRatioKey)
        }
    }
}
