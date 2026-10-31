import Foundation

/// Feeds packets (already on the output clock, in the writer's time base) to the
/// fMP4 writer and cuts a segment whenever the segment index changes.
///
/// Packets are held back by one so each one's duration is the distance to the next
/// packet's dts. The last sample of a segment therefore ends exactly where the first
/// sample of the next segment starts, instead of relying on container durations.
final class SegmentEmitter {
    private let writer: FragmentedMP4Writer
    private let run: RemuxRun
    private var pending: (packet: Packet, segment: Int)?
    private var lastDTS = Int64.min
    private var wroteInit = false
    private var lastPublished: Int?

    init(writer: FragmentedMP4Writer, run: RemuxRun) {
        self.writer = writer
        self.run = run
    }

    var timeBase: Rational { writer.timeBase }

    func push(_ packet: Packet, segment: Int) throws {
        if packet.dts == FF.noPTS { packet.dts = packet.pts }
        if packet.dts <= lastDTS { packet.dts = lastDTS + 1 }
        if packet.pts == FF.noPTS || packet.pts < packet.dts { packet.pts = packet.dts }
        lastDTS = packet.dts

        if let (previous, previousSegment) = pending {
            previous.duration = packet.dts - previous.dts
            try write(previous)
            if segment != previousSegment {
                try finish(previousSegment, next: segment)
                try run.waitForWindow(before: segment)
            }
        }
        pending = (packet, segment)
    }

    /// End of input: the last packet keeps its own duration, or `fallbackDuration`.
    func finish(fallbackDuration: Int64) throws {
        guard let (previous, segment) = pending else { return }
        pending = nil
        if previous.duration <= 0 { previous.duration = max(1, fallbackDuration) }
        try write(previous)
        try finish(segment, next: nil)
    }

    private func write(_ packet: Packet) throws {
        try writer.write(packet)
        if !wroteInit {
            // The first flush with delay_moov emits ftyp+moov only. The init segment is
            // served from InitSegmentBuilder, so this copy is dropped.
            _ = try writer.flush()
            wroteInit = true
        }
    }

    private func finish(_ segment: Int, next: Int?) throws {
        var fragment = try writer.flush()
        Self.setSequenceNumber(&fragment, UInt32(segment + 1))
        var data = FragmentedMP4Writer.styp
        data.append(fragment)
        try run.publish(segment: segment, data: data)
        lastPublished = segment
        // A gap in the input longer than a segment leaves segments without samples.
        // Publish them empty so requests for them do not hang.
        if let next, next > segment + 1 {
            for empty in (segment + 1)..<next {
                try run.waitForWindow(before: empty)
                try run.publish(segment: empty, data: FragmentedMP4Writer.styp)
            }
        }
    }

    /// movenc numbers fragments from 1 in each muxer, so a run that started at segment k
    /// would restart the count. Pin `mfhd.sequence_number` to the segment number instead,
    /// which is what a run from the start writes and keeps it increasing across restarts.
    static func setSequenceNumber(_ fragment: inout Data, _ number: UInt32) {
        // moof header (8) → mfhd header (8) + version/flags (4) → sequence_number
        guard fragment.count >= 24,
              fragment[fragment.startIndex + 4..<fragment.startIndex + 8] == Data("moof".utf8),
              fragment[fragment.startIndex + 12..<fragment.startIndex + 16] == Data("mfhd".utf8) else { return }
        let offset = fragment.startIndex + 20
        fragment[offset] = UInt8(number >> 24)
        fragment[offset + 1] = UInt8(truncatingIfNeeded: number >> 16)
        fragment[offset + 2] = UInt8(truncatingIfNeeded: number >> 8)
        fragment[offset + 3] = UInt8(truncatingIfNeeded: number)
    }

}
