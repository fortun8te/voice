// WAVHeaderRepair.swift
// ============================================================
// Rewrite a valid RIFF/WAVE header onto a .wav file that was
// truncated mid-write (Voice killed during a meeting). The data
// section is intact; only the size fields in the header are
// stale (still zero or wrong). Without this fix, AVFoundation
// refuses to decode the file → "Couldn't transcribe" forever.
//
// WAV file format (canonical PCM):
//   "RIFF"            (4 bytes)
//   <chunkSize>       (4 bytes, little-endian)   = fileSize - 8
//   "WAVE"            (4 bytes)
//   "fmt "            (4 bytes)
//   <fmtChunkSize>    (4 bytes)                   = 16 for PCM
//   <audioFormat>     (2 bytes)                   = 1 for PCM, 3 for Float32
//   <numChannels>     (2 bytes)
//   <sampleRate>      (4 bytes)
//   <byteRate>        (4 bytes)                   = sampleRate * blockAlign
//   <blockAlign>      (2 bytes)                   = numChannels * bitsPerSample/8
//   <bitsPerSample>   (2 bytes)
//   "data"            (4 bytes)
//   <dataSize>        (4 bytes)                   = fileSize - 44
//   <audio samples>   (...)
//
// We only need to fix the two size fields at offset 4 (RIFF chunk
// size) and offset 40 (data chunk size). Everything else was
// written correctly when the file was opened.
// ============================================================

import Foundation

enum WAVHeaderRepair {

    enum Error: Swift.Error {
        case tooSmall
        case notRIFF
        case notWAVE
        case dataChunkNotFound
        case ioFailed(String)
    }

    /// Inspect the WAV at `url`. If its RIFF chunk size is 0 (or grossly
    /// less than the file size on disk), rewrite the header's two size
    /// fields to match reality. No-op if the header already looks valid.
    /// Thread-safe — opens its own file handle.
    ///
    /// Handles two header layouts:
    ///   1. Canonical PCM (44-byte header, "data" magic at offset 36)
    ///   2. JUNK-padded growing-WAV (4KB header, "data" magic somewhere
    ///      in the first 4KB) — this is what Voice's writer uses so it
    ///      can finalize chunk sizes in place without rewriting the file.
    static func repairIfNeeded(at url: URL) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let fileSizeNum = attrs[.size] as? NSNumber else {
            throw Error.ioFailed("no size attribute")
        }
        let fileSize = fileSizeNum.uint64Value

        guard fileSize >= 44 else { throw Error.tooSmall }

        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }

        // Read up to the first 4KB to handle BOTH canonical 44-byte headers
        // AND JUNK-padded 4KB headers (used by AVAudioFile growing-WAV writer).
        let headerScanSize = min(fileSize, 4096)
        try handle.seek(toOffset: 0)
        guard let header = try handle.read(upToCount: Int(headerScanSize)),
              header.count == Int(headerScanSize) else {
            throw Error.ioFailed("short read")
        }

        guard header[0..<4] == Data([0x52, 0x49, 0x46, 0x46]) else { throw Error.notRIFF }  // "RIFF"
        guard header[8..<12] == Data([0x57, 0x41, 0x56, 0x45]) else { throw Error.notWAVE } // "WAVE"

        // Current RIFF chunk size (bytes 4..<8, little-endian uint32).
        let currentChunkSize = header.subdata(in: 4..<8).withUnsafeBytes { $0.load(as: UInt32.self) }

        // Locate the "data" chunk header. For canonical PCM headers it's at
        // offset 36. For JUNK-padded headers (Voice's writer), it sits
        // somewhere in the first 4KB, typically near offset 4084. Use the
        // LAST occurrence of "data" in the scan window because earlier
        // occurrences could be coincidental byte patterns in the junk
        // padding.
        let dataMagic = Data([0x64, 0x61, 0x74, 0x61]) // "data"
        guard let dataTagRange = header.range(of: dataMagic, options: .backwards) else {
            throw Error.dataChunkNotFound
        }
        let dataTagOffset = dataTagRange.lowerBound
        let dataSizeOffset = dataTagOffset + 4
        let dataPayloadOffset = dataTagOffset + 8

        // Current data size (4 bytes after the "data" tag).
        let currentDataSize = header.subdata(in: dataSizeOffset..<dataSizeOffset + 4)
            .withUnsafeBytes { $0.load(as: UInt32.self) }

        // Expected sizes: RIFF chunk = whole file minus 8.
        // Data chunk = file size minus the offset of the audio payload.
        let expectedChunkSize = UInt32(min(fileSize - 8, UInt64(UInt32.max)))
        let expectedDataSize  = UInt32(min(fileSize - UInt64(dataPayloadOffset),
                                           UInt64(UInt32.max)))

        // No-op shortcut: header is already within 1 KB of correct.
        if abs(Int64(currentChunkSize) - Int64(expectedChunkSize)) < 1024,
           abs(Int64(currentDataSize) - Int64(expectedDataSize)) < 1024 {
            return
        }

        // Rewrite the two size fields in place.
        var chunkSizeLE = expectedChunkSize.littleEndian
        var dataSizeLE  = expectedDataSize.littleEndian
        try handle.seek(toOffset: 4)
        try handle.write(contentsOf: Data(bytes: &chunkSizeLE, count: 4))
        try handle.seek(toOffset: UInt64(dataSizeOffset))
        try handle.write(contentsOf: Data(bytes: &dataSizeLE, count: 4))
        try handle.synchronize()

        print("[VOICE-WAV-REPAIR] \(url.lastPathComponent): chunkSize \(currentChunkSize)→\(expectedChunkSize), dataSize \(currentDataSize)→\(expectedDataSize) (data@offset \(dataTagOffset))")
    }
}
