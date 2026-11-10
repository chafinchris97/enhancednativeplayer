import Foundation

/// fMP4 for an HLS I-frame playlist of JPEG stills (`CODECS="mjpg"`, ISO/IEC 23008-12): one init
/// with a single `mjpg` video track, then one `moof`+`mdat` per still whose sample is the JPEG as is.
///
/// Written by hand rather than through movenc, which files MJPEG in an `mp4` as an MPEG-4 Visual
/// (`mp4v` + `esds`) track instead of an `mjpg` sample entry.
enum MotionJPEGFragments {
    /// Milliseconds.
    static let timescale: UInt32 = 1000
    private static let trackID: UInt32 = 1

    /// `ftyp` + `moov`.
    static func initSegment(width: Int, height: Int) -> Data {
        var file = BoxWriter()
        file.box("ftyp") { b in
            b.fourCC("iso6")
            b.u32(0)
            for brand in ["iso6", "mp41"] { b.fourCC(brand) }
        }
        file.box("moov") { moov in
            moov.fullBox("mvhd", version: 0, flags: 0) { b in
                b.u32(0); b.u32(0) // creation, modification
                b.u32(timescale)
                b.u32(0) // duration: fragmented
                b.u32(0x0001_0000) // rate 1.0
                b.u16(0x0100) // volume 1.0
                b.zeros(10)
                b.matrix()
                b.zeros(24)
                b.u32(trackID + 1) // next_track_ID
            }
            moov.box("trak") { trak in
                trak.fullBox("tkhd", version: 0, flags: 0x3) { b in // enabled, in movie
                    b.u32(0); b.u32(0)
                    b.u32(trackID)
                    b.u32(0)
                    b.u32(0) // duration
                    b.zeros(8)
                    b.zeros(8) // layer, alternate_group, volume, reserved
                    b.matrix()
                    b.u32(UInt32(width) << 16)
                    b.u32(UInt32(height) << 16)
                }
                trak.box("mdia") { mdia in
                    mdia.fullBox("mdhd", version: 0, flags: 0) { b in
                        b.u32(0); b.u32(0)
                        b.u32(timescale)
                        b.u32(0)
                        b.u16(0x55C4) // "und"
                        b.u16(0)
                    }
                    mdia.fullBox("hdlr", version: 0, flags: 0) { b in
                        b.u32(0)
                        b.fourCC("vide")
                        b.zeros(12)
                        b.bytes(Array("Trickplay".utf8) + [0])
                    }
                    mdia.box("minf") { minf in
                        minf.fullBox("vmhd", version: 0, flags: 1) { $0.zeros(8) }
                        minf.box("dinf") { dinf in
                            dinf.fullBox("dref", version: 0, flags: 0) { dref in
                                dref.u32(1)
                                dref.fullBox("url ", version: 0, flags: 1) { _ in } // media in this file
                            }
                        }
                        minf.box("stbl") { stbl in
                            stbl.fullBox("stsd", version: 0, flags: 0) { stsd in
                                stsd.u32(1)
                                stsd.box("mjpg") { entry in
                                    // VisualSampleEntry
                                    entry.zeros(6)
                                    entry.u16(1) // data_reference_index
                                    entry.zeros(16)
                                    entry.u16(UInt16(width))
                                    entry.u16(UInt16(height))
                                    entry.u32(0x0048_0000); entry.u32(0x0048_0000) // 72 dpi
                                    entry.u32(0)
                                    entry.u16(1) // frame_count
                                    entry.zeros(32) // compressorname
                                    entry.u16(0x0018) // depth
                                    entry.u16(0xFFFF) // pre_defined = -1
                                    entry.box("pasp") { $0.u32(1); $0.u32(1) }
                                }
                            }
                            stbl.fullBox("stts", version: 0, flags: 0) { $0.u32(0) }
                            stbl.fullBox("stsc", version: 0, flags: 0) { $0.u32(0) }
                            stbl.fullBox("stsz", version: 0, flags: 0) { $0.u32(0); $0.u32(0) }
                            stbl.fullBox("stco", version: 0, flags: 0) { $0.u32(0) }
                        }
                    }
                }
            }
            moov.box("mvex") { mvex in
                mvex.fullBox("trex", version: 0, flags: 0) { b in
                    b.u32(trackID)
                    b.u32(1) // default_sample_description_index
                    b.u32(0); b.u32(0); b.u32(0)
                }
            }
        }
        return file.data
    }

    /// One `moof`+`mdat` holding `jpeg` as a sync sample that starts at `start` and lasts
    /// `duration`, both in `timescale` units.
    static func fragment(jpeg: Data, sequence: UInt32, start: UInt64, duration: UInt32) -> Data {
        // trun: data-offset, sample-duration, sample-size, sample-flags present.
        func moof(dataOffset: Int32) -> Data {
            var writer = BoxWriter()
            writer.box("moof") { moof in
                moof.fullBox("mfhd", version: 0, flags: 0) { $0.u32(sequence) }
                moof.box("traf") { traf in
                    traf.fullBox("tfhd", version: 0, flags: 0x02_0000) { $0.u32(trackID) } // default-base-is-moof
                    traf.fullBox("tfdt", version: 1, flags: 0) { $0.u64(start) }
                    traf.fullBox("trun", version: 0, flags: 0x00_0701) { b in
                        b.u32(1)
                        b.u32(UInt32(bitPattern: dataOffset))
                        b.u32(duration)
                        b.u32(UInt32(jpeg.count))
                        b.u32(0x0200_0000) // depends on no other sample, sync
                    }
                }
            }
            return writer.data
        }
        let size = moof(dataOffset: 0).count
        var out = moof(dataOffset: Int32(size + 8))
        var mdat = BoxWriter()
        mdat.box("mdat") { $0.bytes(jpeg) }
        out.append(mdat.data)
        return out
    }
}

/// Big-endian ISO BMFF box serialization. A box's size is patched in once its body is written.
struct BoxWriter {
    private(set) var data = Data()

    mutating func box(_ type: String, _ body: (inout BoxWriter) -> Void) {
        let start = data.count
        u32(0)
        fourCC(type)
        body(&self)
        let size = UInt32(data.count - start)
        data.replaceSubrange(start..<start + 4, with: withUnsafeBytes(of: size.bigEndian) { Data($0) })
    }

    mutating func fullBox(_ type: String, version: UInt8, flags: UInt32, _ body: (inout BoxWriter) -> Void) {
        box(type) { b in
            b.u32(UInt32(version) << 24 | flags & 0x00FF_FFFF)
            body(&b)
        }
    }

    mutating func u16(_ value: UInt16) { withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) } }
    mutating func u32(_ value: UInt32) { withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) } }
    mutating func u64(_ value: UInt64) { withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) } }
    mutating func zeros(_ count: Int) { data.append(Data(count: count)) }
    mutating func bytes(_ bytes: some Sequence<UInt8>) { data.append(contentsOf: bytes) }

    mutating func fourCC(_ code: String) {
        precondition(code.utf8.count == 4)
        data.append(contentsOf: Array(code.utf8))
    }

    /// The identity transformation matrix of `mvhd` / `tkhd`.
    mutating func matrix() {
        for value: UInt32 in [0x0001_0000, 0, 0, 0, 0x0001_0000, 0, 0, 0, 0x4000_0000] { u32(value) }
    }
}
