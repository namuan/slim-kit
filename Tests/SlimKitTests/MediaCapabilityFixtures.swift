import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

extension MediaCapabilityInspectorTests {
    func createNoisyVideo(at url: URL, frameCount: Int = 60) async throws {
        let width = 320
        let height = 180
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 20_000_000,
                    AVVideoExpectedSourceFrameRateKey: 30,
                    AVVideoMaxKeyFrameIntervalKey: 30,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
                ],
                AVVideoColorPropertiesKey: [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
                ]
            ]
        )
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        guard writer.canAdd(input) else { throw MediaFixtureError.writerUnavailable }
        writer.add(input)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: attributes
        )
        guard writer.startWriting() else { throw writer.error ?? MediaFixtureError.writerUnavailable }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<frameCount {
            guard input.isReadyForMoreMediaData else { throw MediaFixtureError.writerUnavailable }
            let pixelBuffer = try noisyPixelBuffer(attributes: attributes, seed: UInt32(frame + 1))
            let time = CMTime(value: Int64(frame), timescale: 30)
            guard adaptor.append(pixelBuffer, withPresentationTime: time) else {
                throw writer.error ?? MediaFixtureError.writerUnavailable
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? MediaFixtureError.writerUnavailable }
    }

    func createVideo(
        at url: URL,
        videoTrackCount: Int = 1,
        colorPrimaries: String = AVVideoColorPrimaries_ITU_R_709_2,
        transferFunction: String = AVVideoTransferFunction_ITU_R_709_2
    ) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let inputs = (0..<videoTrackCount).map { _ in
            AVAssetWriterInput(
                mediaType: .video,
                outputSettings: [
                    AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoWidthKey: 16,
                    AVVideoHeightKey: 16,
                    AVVideoColorPropertiesKey: [
                        AVVideoColorPrimariesKey: colorPrimaries,
                        AVVideoTransferFunctionKey: transferFunction,
                        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
                    ]
                ]
            )
        }
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 16,
            kCVPixelBufferHeightKey as String: 16,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        guard inputs.allSatisfy(writer.canAdd) else { throw MediaFixtureError.writerUnavailable }
        inputs.forEach(writer.add)
        let adaptors = inputs.map {
            AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: $0,
                sourcePixelBufferAttributes: attributes
            )
        }
        guard writer.startWriting() else { throw writer.error ?? MediaFixtureError.writerUnavailable }
        writer.startSession(atSourceTime: .zero)
        let pixelBuffer = try makePixelBuffer(attributes: attributes)
        for frame in 0..<2 {
            let presentationTime = CMTime(value: Int64(frame), timescale: 30)
            for (input, adaptor) in zip(inputs, adaptors) {
                guard input.isReadyForMoreMediaData,
                      adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
                    throw writer.error ?? MediaFixtureError.writerUnavailable
                }
            }
        }
        inputs.forEach { $0.markAsFinished() }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? MediaFixtureError.writerUnavailable }
    }

    private func noisyPixelBuffer(attributes: [String: Any], seed: UInt32) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let result = CVPixelBufferCreate(
            kCFAllocatorDefault,
            320,
            180,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )
        guard result == kCVReturnSuccess, let pixelBuffer else { throw MediaFixtureError.pixelBufferUnavailable }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer)?.assumingMemoryBound(to: UInt8.self) else {
            throw MediaFixtureError.pixelBufferUnavailable
        }
        var state = seed
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        for row in 0..<180 {
            for column in 0..<320 {
                state = state &* 1_664_525 &+ 1_013_904_223
                let offset = row * bytesPerRow + column * 4
                baseAddress[offset] = UInt8(truncatingIfNeeded: state >> 24)
                state = state &* 1_664_525 &+ 1_013_904_223
                baseAddress[offset + 1] = UInt8(truncatingIfNeeded: state >> 24)
                state = state &* 1_664_525 &+ 1_013_904_223
                baseAddress[offset + 2] = UInt8(truncatingIfNeeded: state >> 24)
                baseAddress[offset + 3] = 255
            }
        }
        return pixelBuffer
    }

    private func makePixelBuffer(attributes: [String: Any]) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let result = CVPixelBufferCreate(
            kCFAllocatorDefault,
            16,
            16,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )
        guard result == kCVReturnSuccess, let pixelBuffer else { throw MediaFixtureError.pixelBufferUnavailable }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: 16,
            height: 16,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { throw MediaFixtureError.pixelBufferUnavailable }
        context.setFillColor(CGColor(red: 0.4, green: 0.5, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        return pixelBuffer
    }

    func createSRGBJPEG(at url: URL) throws {
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(
            CGContext(
                data: nil,
                width: 2,
                height: 2,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
        )
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.jpeg.identifier as CFString,
                1,
                nil
            )
        )
        let properties: [String: Any] = [
            kCGImagePropertyExifDictionary as String: [
                kCGImagePropertyExifColorSpace as String: 1
            ]
        ]
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    func createNoisySRGBJPEG(at url: URL) throws {
        let width = 512
        var pixels = [UInt8](repeating: 255, count: width * width * 4)
        var state: UInt32 = 1
        for pixelIndex in 0..<(width * width) {
            state = state &* 1_664_525 &+ 1_013_904_223
            let red = UInt8(truncatingIfNeeded: state >> 24)
            state = state &* 1_664_525 &+ 1_013_904_223
            let green = UInt8(truncatingIfNeeded: state >> 24)
            state = state &* 1_664_525 &+ 1_013_904_223
            let blue = UInt8(truncatingIfNeeded: state >> 24)
            let offset = pixelIndex * 4
            pixels[offset] = red
            pixels[offset + 1] = green
            pixels[offset + 2] = blue
            pixels[offset + 3] = 255
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let image = try XCTUnwrap(
            CGImage(
                width: width,
                height: width,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        )
        let destination = try imageDestination(at: url, type: UTType.jpeg.identifier, imageCount: 1)
        let properties: [String: Any] = [
            kCGImageDestinationLossyCompressionQuality as String: 1.0,
            kCGImagePropertyOrientation as String: 6,
            kCGImagePropertyExifDictionary as String: [
                kCGImagePropertyExifColorSpace as String: 1
            ]
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    func createAlphaPNG(at url: URL) throws {
        let destination = try imageDestination(at: url, type: UTType.png.identifier, imageCount: 1)
        CGImageDestinationAddImage(destination, try fixtureImage(alpha: true), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    func createDepthJPEG(at url: URL) throws {
        let destination = try imageDestination(at: url, type: UTType.jpeg.identifier, imageCount: 1)
        CGImageDestinationAddImage(destination, try fixtureImage(alpha: false), nil)
        let depthValues: [Float] = [0.5, 1.0, 1.5, 2.0]
        let depthData = depthValues.withUnsafeBytes { Data($0) }
        let description: [String: Any] = [
            kCGImagePropertyWidth as String: 2,
            kCGImagePropertyHeight as String: 2,
            kCGImagePropertyBytesPerRow as String: 2 * MemoryLayout<Float>.stride,
            kCGImagePropertyPixelFormat as String: Int(kCVPixelFormatType_DepthFloat32)
        ]
        let metadata = CGImageMetadataCreateMutable()
        let auxiliaryData: [String: Any] = [
            kCGImageAuxiliaryDataInfoData as String: depthData,
            kCGImageAuxiliaryDataInfoDataDescription as String: description,
            kCGImageAuxiliaryDataInfoMetadata as String: metadata
        ]
        CGImageDestinationAddAuxiliaryDataInfo(
            destination,
            kCGImageAuxiliaryDataTypeDepth,
            auxiliaryData as CFDictionary
        )
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    func createAnimatedGIF(at url: URL) throws {
        let destination = try imageDestination(at: url, type: UTType.gif.identifier, imageCount: 2)
        let firstImage = try fixtureImage(alpha: false, gray: 0.25)
        let secondImage = try fixtureImage(alpha: false, gray: 0.75)
        let frameProperties: [String: Any] = [
            kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFDelayTime as String: 0.1
            ]
        ]
        CGImageDestinationAddImage(destination, firstImage, frameProperties as CFDictionary)
        CGImageDestinationAddImage(destination, secondImage, frameProperties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func imageDestination(at url: URL, type: String, imageCount: Int) throws -> CGImageDestination {
        try XCTUnwrap(
            CGImageDestinationCreateWithURL(url as CFURL, type as CFString, imageCount, nil)
        )
    }

    private func fixtureImage(alpha: Bool, gray: CGFloat = 0.5) throws -> CGImage {
        let bitmapInfo = alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        let context = try XCTUnwrap(
            CGContext(
                data: nil,
                width: 2,
                height: 2,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                bitmapInfo: bitmapInfo
            )
        )
        context.setFillColor(CGColor(gray: gray, alpha: alpha ? 0.5 : 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        return try XCTUnwrap(context.makeImage())
    }
}

private enum MediaFixtureError: Error {
    case writerUnavailable
    case pixelBufferUnavailable
}
