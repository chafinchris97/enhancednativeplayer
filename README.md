<img src="assets/icon.svg" width="64" height="64" alt="">

# EnhancedNativePlayer

A tvOS video engine that plays any remote MKV / MP4 through `AVPlayer` by losslessly remuxing it into HLS (fMP4) on the fly, served from a local [Hummingbird](https://github.com/hummingbird-project/hummingbird) server. FFmpeg comes from [FFmpegBuild](https://github.com/superuser404notfound/FFmpegBuild), the slim build AetherEngine uses.

```swift
import EnhancedNativePlayer

let player = EnhancedPlayerViewController(url: URL(string: "https://server/movie.mkv")!)
player.modalPresentationStyle = .fullScreen
present(player, animated: true)   // dismissing it resets the display mode, stops the server and deletes the cache
```

Or drive `AVPlayer` yourself:

```swift
let session = try await EnhancedPlaybackSession.start(url: remoteURL)
let player = AVPlayer(url: session.masterPlaylistURL)
// …
await session.stop()
```

`EnhancedPlayerConfiguration` sets the segment duration (`hls_time`, default 6), the look-ahead (default 3 segments), HTTP headers for the source, the cache directory and the source cache budget.

Requirements: tvOS 17 / iOS 17 / macOS 14 (Hummingbird 2), and a source server that answers range requests.

## How it works

1. **Keyframes without scanning.** The file is read through HTTP range requests in 1 MB blocks (`RemoteFile`). libavformat loads the container's own keyframe index, Matroska Cues or the MP4 `stss`, into the stream's index entries. That costs the header, the index and the first cluster: a few requests, typically ~150 ms, instead of a full-file ffprobe pass.
2. **The segment plan.** `SegmentPlan` applies hlsenc's cut rule verbatim. A segment ends at the first keyframe with `pts − start_pts ≥ hls_time × n`, where n counts segments, using an exact `av_compare_ts` comparison. The playlists' EXTINF values match `ffmpeg -f hls -hls_time 6` exactly; the tests check this against real ffmpeg output.
3. **Playlists** are rendered per request: `master.m3u8`, `video.m3u8`, and `audio_{n}.m3u8` (which shares every EXTINF with the video). Each segment URI carries `?runtimeTicks=` (100 ns) for its start.
4. **Remux.** Video is a stream copy into fMP4: `hvc1` for HEVC; `dvh1` (with dvcC/dvvC, `-strict unofficial`) for Dolby Vision profiles 5 and 8; `hvc1` and plain HDR for profile 7. Audio is copied for AAC, AC-3, E-AC-3 (Atmos/JOC kept, `CHANNELS="16/JOC"`) and FLAC. Anything else (DTS, TrueHD, Opus, …) is decoded and re-encoded to FLAC (16- or 24-bit, up to 7.1).
5. **Audio follows the video cuts.** Audio segment k starts with the first audio frame at or after video segment k's first keyframe, for copied packets and FLAC blocks alike.
6. **Window.** Video and audio each have their own pipeline. A run pauses once it is 3 segments ahead of the newest request and resumes as requests advance. A served segment is deleted from disk. A request beyond the window (a seek), for a segment already sent, or for another audio track stops the run, deletes its segments and starts a new run at that segment.
7. **Display mode (tvOS).** `EnhancedPlayerViewController` turns off `appliesPreferredDisplayCriteriaAutomatically` and sets the `preferredDisplayCriteria` of the master playlist's asset itself. It then waits for `isDisplayModeSwitchInProgress` to go true and false again, plus 0.5 s, or for 10 s if no switch starts. The wait is skipped when "Match Content" is off in Settings. Only then does the player get a URL.
8. **SDR displays.** tvOS cannot report the display's mode, so an HDR file is always offered its HDR master first. If AVPlayer refuses it for the display (`-11868`, `-11848` or `-1002`, within about 60 ms and before any segment is fetched), the player gets `master_sdr.m3u8` instead. Its video is the same stream without a transcode: `SDRBitstreamRewriter` sets the SPS colour description and the `colr` box to Rec. 709 and removes SEI, Dolby Vision RPU / enhancement layer NAL units and the mastering metadata. Audio renditions are shared.
9. **Stop.** `stop()` / dismissing the controller resets the display criteria, shuts the server down and deletes every segment and cached block.

### Why restarts produce identical segments

A run that starts at segment k must emit exactly what a run from the beginning would, or segment durations and timestamps drift after every seek. The tests check this byte for byte.

- **Cuts come from the plan, not the run.** Every run cuts at the precomputed keyframe timestamps, so the pattern never depends on where the run started.
- **Exact seek.** A restart seeks to the segment's keyframe timestamp from the index with `AVSEEK_FLAG_BACKWARD`, and drops anything before it. The demuxer can only land on that entry or an earlier one, so the "+0.5 s" nudge isn't needed. A nudge could also land on the next keyframe when keyframes are under 0.5 s apart.
- **One absolute clock.** Packets keep their source timestamps plus one fixed offset (the first keyframe lands at 10 s, like Apple's segmenter). movenc runs with `frag_discont` and `use_editlist=0`, so `tfdt` is the true decode time in every run, and `mfhd` is pinned to the segment number.
- **Segments end where the next begins.** Each packet's duration is the distance to the next packet's DTS, so the last sample of a segment ends exactly at the first sample of the next.
- **Matroska DTS.** Matroska stores PTS only. Decode timestamps are assigned per segment: the segment's sorted PTS minus the reorder depth, the same in every run.
- **FLAC.** Transcoded audio uses one encoder per run on a fixed block grid anchored at the track start. Frame numbers are rewritten to their absolute grid position (with CRCs recomputed). The stream is therefore what a single encode of the whole track would produce, which is also the only shape Apple's FLAC decoder accepts.

## Notes and limits

- **Audio labels.** AVFoundation derives an option's `displayName`, which the AVPlayerViewController audio menu shows, from `LANGUAGE` and ignores `NAME`. The `{Language} - {Title} - {Codec}` label is therefore written to both. As a result, AVPlayer does not auto-select by the user's preferred language; the container's default track is marked `DEFAULT=YES`.
- **Enhance Dialogue** needs the audio session in `.playback` / `.moviePlayback`. `EnhancedPlayerViewController` sets that itself and deactivates the session when it stops; an app using `EnhancedPlaybackSession` with its own player has to do the same.
- **Dolby Vision profile 8** gets a second variant with a plain `hvc1` `CODECS` string as an HDR10/HLG fallback.
- **Parameter sets only in-band.** Some HEVC files have an empty `hvcC` and carry VPS / SPS / PPS at each keyframe. AVPlayer fails on such a sample entry with CoreMedia `-19601`, so the probe fills the record from the first video packet.
- **Lossy sources in FLAC.** For DTS core, Opus, MP3 and other lossy sources transcoded to FLAC, a restarted run has identical timing. The PCM can differ in the lowest bits, because lossy decoder state never re-converges bit-exactly after a seek. Lossless sources (DTS-HD MA, TrueHD, PCM) are bit-identical.
- **Codecs.** Video must be H.264 or HEVC. TrueHD Atmos and DTS:X objects are lost in the FLAC path; only the bed is kept.
- **Keyframe index required.** A file without a keyframe index (Matroska without Cues) is rejected rather than downloaded in full.
- **Subtitles** are not handled yet.
- **`master_sdr.m3u8` is a relabel, not a tone map.** The pixels are still PQ / HLG, so the picture looks washed out, and Dolby Vision profile 5 has wrong colours, since its base layer only makes sense with the RPU.
- **The 10 s wait** also applies when the display already matches the stream, because no switch ever starts.

## Tests

Unit tests cover the cut rule, exact arithmetic, FLAC frame renumbering and routing. The end-to-end suite is opt-in, and runs on macOS and on the tvOS Simulator:

```sh
ENP_E2E_URL=http://127.0.0.1:8080/movie.mkv \
ENP_E2E_TRUTH=/path/to/ffmpeg-hls/video.m3u8 \
swift test
```

The end-to-end suite checks:

- probe speed and EXTINF parity with ffmpeg
- byte-identical segments between a continuous run and restarted runs, for video and every audio track
- a seek reads only the file around its target, for video and every audio track
- the 3-segment window and delete-after-send
- cleanup on stop
- real AVPlayer playback, seeking and audio-track switching
