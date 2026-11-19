import EPLibavutil
import Testing
@testable import EnhancedNativePlayer

struct HDRStaticMetadataTests {
    /// P3-D65 at 1000 / 0.0001 cd/m², as most HDR10 masters, with MaxCLL 1000 and MaxFALL 400.
    @Test func bytesFollowTheSEILayout() throws {
        var mastering = AVMasteringDisplayMetadata()
        func q(_ value: Int32) -> AVRational { AVRational(num: value, den: 50_000) }
        // FFmpeg's order: red, green, blue.
        mastering.display_primaries = ((q(34_000), q(16_000)), (q(13_250), q(34_500)), (q(7_500), q(3_000)))
        mastering.white_point = (q(15_635), q(16_450))
        mastering.max_luminance = AVRational(num: 1_000, den: 1)
        mastering.min_luminance = AVRational(num: 1, den: 10_000)
        mastering.has_primaries = 1
        mastering.has_luminance = 1
        var light = AVContentLightMetadata()
        light.MaxCLL = 1_000
        light.MaxFALL = 400

        let metadata = try #require(HDRStaticMetadata(mastering: mastering, light: light))
        // Green, blue, red, white point; then max and min luminance.
        #expect(metadata.masteringDisplay == [
            0x33, 0xC2, 0x86, 0xC4,
            0x1D, 0x4C, 0x0B, 0xB8,
            0x84, 0xD0, 0x3E, 0x80,
            0x3D, 0x13, 0x40, 0x42,
            0x00, 0x98, 0x96, 0x80,
            0x00, 0x00, 0x00, 0x01,
        ])
        #expect(metadata.contentLightLevel == [0x03, 0xE8, 0x01, 0x90])
    }

    @Test func incompleteMetadataIsLeftOut() {
        var mastering = AVMasteringDisplayMetadata()
        mastering.has_luminance = 1
        mastering.max_luminance = AVRational(num: 1_000, den: 1)
        #expect(HDRStaticMetadata(mastering: mastering, light: AVContentLightMetadata()) == nil)
    }
}
