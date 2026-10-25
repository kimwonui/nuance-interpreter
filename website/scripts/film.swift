// Web derivatives of the NUA concept film, made with Apple AVFoundation only (no ffmpeg).
// The source film is only read; every output is a new file.
//   swiftc -O scripts/film.swift -o film
//   film loop   <src> <out.mp4> <t0> <t1> <cropX> <cropY> <cropW> <cropH> <outW> <outH> <bitrate>   (silent, ping-pong)
//   film still  <src> <out.jpg> <t> <cropX> <cropY> <cropW> <cropH> <outW> <outH> <quality>
//   film film   <src> <out.mp4> <outW> <outH> <bitrate>     (re-encoded video, original AAC copied as-is)
//   film remux  <src> <out.mp4>                             (passthrough, moov first, metadata dropped)
// The files in assets/film/ were made from nua-explainer-v2-music-B.mp4 (1920×1080, 44 s) with:
//   film loop  SRC hero-loop-740.mp4 33.10 35.60 960 0 740 1080 740 1080 900000
//   film loop  SRC hero-loop-480.mp4 33.10 35.60 960 0 740 1080 480 700 420000
//   film still SRC hero-poster-740.jpg 33.10 960 0 740 1080 740 1080 0.74
//   film still SRC hero-poster-480.jpg 33.10 960 0 740 1080 480 700 0.74
//   film still SRC film-poster.jpg 2.4 0 0 1920 1080 1280 720 0.72
//   film remux SRC film-1080.mp4
//   film film  SRC film-720.mp4 1280 720 850000
import AVFoundation
import CoreImage
import AppKit

let args = CommandLine.arguments
let ci = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
func fail(_ s: String) -> Never { FileHandle.standardError.write((s + "\n").data(using: .utf8)!); exit(1) }

func cropScale(_ img: CIImage, _ crop: CGRect, _ outW: Int, _ outH: Int, srcH: CGFloat) -> CIImage {
  // CoreImage origin is bottom-left; crop rects are given top-left.
  let r = CGRect(x: crop.minX, y: srcH - crop.maxY, width: crop.width, height: crop.height)
  var im = img.cropped(to: r).transformed(by: CGAffineTransform(translationX: -r.minX, y: -r.minY))
  let s = CGFloat(outW) / crop.width
  if abs(s - 1) > 0.001 {
    im = im.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: s, kCIInputAspectRatioKey: (CGFloat(outH) / crop.height) / s])
  }
  return im.cropped(to: CGRect(x: 0, y: 0, width: outW, height: outH))
}

func videoSettings(_ w: Int, _ h: Int, _ br: Int) -> [String: Any] {
  [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
   AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                               AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                               AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
   AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: br,
                                     AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                                     AVVideoMaxKeyFrameIntervalKey: 60,
                                     AVVideoExpectedSourceFrameRateKey: 30]]
}

func newBuffer(_ w: Int, _ h: Int) -> CVPixelBuffer {
  var pb: CVPixelBuffer?
  CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
  return pb!
}

func videoTrack(_ asset: AVAsset) async throws -> AVAssetTrack {
  guard let t = try await asset.loadTracks(withMediaType: .video).first else { fail("no video track") }
  return t
}

func writeAll(_ writer: AVAssetWriter, _ frames: [CVPixelBuffer], _ input: AVAssetWriterInput, _ ad: AVAssetWriterInputPixelBufferAdaptor) {
  writer.startWriting(); writer.startSession(atSourceTime: .zero)
  for (i, pb) in frames.enumerated() {
    while !input.isReadyForMoreMediaData { usleep(2000) }
    ad.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
  }
  input.markAsFinished()
  let sem = DispatchSemaphore(value: 0)
  writer.finishWriting { sem.signal() }
  sem.wait()
  if writer.status != .completed { fail("writer: \(String(describing: writer.error))") }
}

func run() async throws {
  guard args.count > 3 else { fail("usage: see header") }
  let mode = args[1]
  let asset = AVURLAsset(url: URL(fileURLWithPath: args[2]))
  let out = URL(fileURLWithPath: args[3])
  try? FileManager.default.removeItem(at: out)

  switch mode {
  case "loop":
    let t0 = Double(args[4])!, t1 = Double(args[5])!
    let crop = CGRect(x: Double(args[6])!, y: Double(args[7])!, width: Double(args[8])!, height: Double(args[9])!)
    let w = Int(args[10])!, h = Int(args[11])!, br = Int(args[12])!
    let track = try await videoTrack(asset)
    let srcH = try await track.load(.naturalSize).height
    let reader = try AVAssetReader(asset: asset)
    reader.timeRange = CMTimeRange(start: CMTime(seconds: t0, preferredTimescale: 600), end: CMTime(seconds: t1, preferredTimescale: 600))
    let ro = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    reader.add(ro); reader.startReading()
    var frames: [CVPixelBuffer] = []
    while let sb = ro.copyNextSampleBuffer() {
      guard let src = CMSampleBufferGetImageBuffer(sb) else { continue }
      let pb = newBuffer(w, h)
      ci.render(cropScale(CIImage(cvPixelBuffer: src), crop, w, h, srcH: srcH), to: pb)
      frames.append(pb)
    }
    if frames.count < 3 { fail("too few frames: \(frames.count)") }
    // Ping-pong so the loop has no seam: forward, then backward without repeating the end frames.
    let seq = frames + frames.dropFirst().dropLast().reversed()
    let writer = try AVAssetWriter(outputURL: out, fileType: .mp4)
    writer.shouldOptimizeForNetworkUse = true
    writer.metadata = []
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings(w, h, br))
    input.expectsMediaDataInRealTime = false
    let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
    writer.add(input)
    writeAll(writer, Array(seq), input, ad)
    print("loop frames \(frames.count) -> \(seq.count)")

  case "still":
    let t = Double(args[4])!
    let crop = CGRect(x: Double(args[5])!, y: Double(args[6])!, width: Double(args[7])!, height: Double(args[8])!)
    let w = Int(args[9])!, h = Int(args[10])!, q = Double(args[11])!
    let gen = AVAssetImageGenerator(asset: asset)
    gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
    let (cg, _) = try await gen.image(at: CMTime(seconds: t, preferredTimescale: 600))
    let im = cropScale(CIImage(cgImage: cg), crop, w, h, srcH: CGFloat(cg.height))
    guard let outCG = ci.createCGImage(im, from: CGRect(x: 0, y: 0, width: w, height: h)) else { fail("render") }
    let rep = NSBitmapImageRep(cgImage: outCG)
    try rep.representation(using: .jpeg, properties: [.compressionFactor: q])!.write(to: out)

  case "film":
    let w = Int(args[4])!, h = Int(args[5])!, br = Int(args[6])!
    let vt = try await videoTrack(asset)
    let srcSize = try await vt.load(.naturalSize)
    guard let at = try await asset.loadTracks(withMediaType: .audio).first else { fail("no audio") }
    let audioFmt = try await at.load(.formatDescriptions).first
    let reader = try AVAssetReader(asset: asset)
    let vo = AVAssetReaderTrackOutput(track: vt, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    let ao = AVAssetReaderTrackOutput(track: at, outputSettings: nil) // compressed AAC, untouched
    reader.add(vo); reader.add(ao)
    let writer = try AVAssetWriter(outputURL: out, fileType: .mp4)
    writer.shouldOptimizeForNetworkUse = true
    writer.metadata = []
    let vi = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings(w, h, br))
    let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audioFmt)
    vi.expectsMediaDataInRealTime = false; ai.expectsMediaDataInRealTime = false
    let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vi, sourcePixelBufferAttributes: nil)
    writer.add(vi); writer.add(ai)
    reader.startReading(); writer.startWriting(); writer.startSession(atSourceTime: .zero)
    let group = DispatchGroup()
    let crop = CGRect(origin: .zero, size: srcSize)
    group.enter()
    vi.requestMediaDataWhenReady(on: DispatchQueue(label: "v")) {
      while vi.isReadyForMoreMediaData {
        guard let sb = vo.copyNextSampleBuffer(), let src = CMSampleBufferGetImageBuffer(sb) else { vi.markAsFinished(); group.leave(); return }
        let pb = newBuffer(w, h)
        ci.render(cropScale(CIImage(cvPixelBuffer: src), crop, w, h, srcH: srcSize.height), to: pb)
        ad.append(pb, withPresentationTime: CMSampleBufferGetPresentationTimeStamp(sb))
      }
    }
    group.enter()
    ai.requestMediaDataWhenReady(on: DispatchQueue(label: "a")) {
      while ai.isReadyForMoreMediaData {
        guard let sb = ao.copyNextSampleBuffer() else { ai.markAsFinished(); group.leave(); return }
        ai.append(sb)
      }
    }
    group.wait()
    let sem = DispatchSemaphore(value: 0)
    writer.finishWriting { sem.signal() }
    sem.wait()
    if writer.status != .completed { fail("writer: \(String(describing: writer.error))") }
    print("film written")

  case "remux":
    guard let ex = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { fail("export") }
    ex.shouldOptimizeForNetworkUse = true
    ex.metadata = []
    ex.metadataItemFilter = .forSharing()
    try await ex.export(to: out, as: .mp4)
    print("remux done")

  default: fail("unknown mode")
  }
}

let done = DispatchSemaphore(value: 0)
Task { do { try await run() } catch { fail("error: \(error)") }; done.signal() }
done.wait()
