// Regression tests for the production VTF parser: exact solid-colour detection
// and size checks that reject malformed dimensions before anything is allocated.
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <vector>

// The parser predates /W4 (its DXT helpers narrow ints into bytes); hold it to
// the level the module build uses, and keep /W4 for this file.
#pragma warning(push, 3)
#include "../../source/vtf_parser.cpp"
#pragma warning(pop)

using namespace VTFParser;

namespace {

void Check(bool condition, const char* message) {
    if (!condition) {
        std::cerr << "FAIL: " << message << '\n';
        std::exit(1);
    }
}

std::vector<uint8_t> UniformRGBA(uint32_t width, uint32_t height) {
    std::vector<uint8_t> pixels(static_cast<size_t>(width) * height * 4);
    for (size_t i = 0; i < pixels.size(); i += 4) {
        pixels[i + 0] = 10;
        pixels[i + 1] = 20;
        pixels[i + 2] = 30;
        pixels[i + 3] = 255;
    }
    return pixels;
}

std::vector<uint8_t> MakeVTF(uint16_t width, uint16_t height, VTFImageFormat format,
                             uint8_t mipmapCount, const std::vector<uint8_t>& payload) {
    VTFFileHeader header = {};
    std::memcpy(header.signature, "VTF\0", 4);
    header.version[0] = 7;
    header.version[1] = 2;
    header.headerSize = sizeof(VTFFileHeader);
    header.width = width;
    header.height = height;
    header.frames = 1;
    header.imageFormat = static_cast<uint32_t>(format);
    header.mipmapCount = mipmapCount;
    header.lowResImageFormat = 0xFFFFFFFF;

    std::vector<uint8_t> file(sizeof(header));
    std::memcpy(file.data(), &header, sizeof(header));
    file.insert(file.end(), payload.begin(), payload.end());
    return file;
}

void SolidColourIsExact() {
    uint8_t r = 0, g = 0, b = 0, a = 0;
    // 65x65 used to be checked every 4th pixel and 512x512 every 256th; pixel
    // (1, 1) falls between those samples and off the fixed probe positions.
    for (uint32_t size : {4u, 65u, 512u}) {
        std::vector<uint8_t> pixels = UniformRGBA(size, size);
        Check(IsSolidColorRGBA(pixels, size, size, r, g, b, a), "uniform image is solid");
        Check(r == 10 && g == 20 && b == 30 && a == 255, "solid colour is reported");

        pixels[(static_cast<size_t>(size) + 1) * 4] = 11;
        Check(!IsSolidColorRGBA(pixels, size, size, r, g, b, a),
              "one differing pixel makes the image non-solid");
    }

    std::vector<uint8_t> shortData(4 * 4 * 4 - 1);
    Check(!IsSolidColorRGBA(shortData, 4, 4, r, g, b, a), "too little pixel data is not solid");
}

void SizesDoNotWrap() {
    Check(GetImageDataSize(65535, 65535, IMAGE_FORMAT_DXT5) == 4294967296ull,
          "65535x65535 DXT5 is 4 GiB, not 0");
    Check(GetImageDataSize(65535, 65535, IMAGE_FORMAT_RGBA8888) == 65535ull * 65535ull * 4ull,
          "RGBA8888 size uses 64-bit math");
    Check(GetImageDataSize(4, 4, IMAGE_FORMAT_DXT1) == 8, "one DXT1 block");
}

void HeaderBoundsAreEnforced() {
    VTFFileHeader header = {};
    Check(ParseVTFHeader(MakeVTF(16, 16, IMAGE_FORMAT_DXT1, 5, {}), header), "16x16 with 5 mips is valid");
    Check(!ParseVTFHeader(MakeVTF(16, 16, IMAGE_FORMAT_DXT1, 6, {}), header), "16x16 cannot have 6 mips");
    Check(!ParseVTFHeader(MakeVTF(65535, 65535, IMAGE_FORMAT_DXT5, 1, {}), header),
          "65535x65535 is rejected");
    Check(!ParseVTFHeader(MakeVTF(0, 16, IMAGE_FORMAT_DXT1, 1, {}), header), "zero width is rejected");
    Check(!ParseVTFHeader(MakeVTF(16, 255, IMAGE_FORMAT_DXT1, 255, {}), header),
          "a mip count beyond any shift of the size is rejected");
}

void PayloadMustCoverTheImage() {
    // A real 4x4 DXT1 block: both endpoints pure red, every index 0.
    const std::vector<uint8_t> redBlock = {0x00, 0xF8, 0x00, 0xF8, 0, 0, 0, 0};
    std::vector<uint8_t> file = MakeVTF(4, 4, IMAGE_FORMAT_DXT1, 1, redBlock);
    VTFFileHeader header = {};
    TextureInfo texture;
    Check(ParseVTFHeader(file, header) && ExtractPixelData(file, header, texture), "valid DXT1 extracts");
    uint8_t r = 0, g = 0, b = 0, a = 0;
    Check(texture.valid && IsSolidColorRGBA(texture.pixelData, 4, 4, r, g, b, a) &&
              r == 255 && g == 0 && b == 0 && a == 255,
          "DXT1 block decodes to solid red");

    // Large declared images with a few bytes of payload fail before any allocation.
    for (VTFImageFormat format : {IMAGE_FORMAT_DXT5, IMAGE_FORMAT_RGBA8888}) {
        std::vector<uint8_t> tiny = MakeVTF(16384, 16384, format, 1, std::vector<uint8_t>(16));
        TextureInfo bogus;
        Check(ParseVTFHeader(tiny, header), "16384x16384 header parses");
        Check(!ExtractPixelData(tiny, header, bogus) && bogus.pixelData.empty(),
              "16384x16384 with a 16-byte payload is rejected");
    }

    std::vector<uint8_t> rgba;
    Check(!DecompressDXT1(redBlock.data(), redBlock.size() - 1, 4, 4, rgba), "DXT1 needs a whole block");
    Check(DecompressDXT1(redBlock.data(), redBlock.size(), 4, 4, rgba), "DXT1 decodes a whole block");
    const std::vector<uint8_t> dxt5Block(15);
    Check(!DecompressDXT5(dxt5Block.data(), dxt5Block.size(), 4, 4, rgba), "DXT5 needs 16 bytes per block");
}

}  // namespace

int main() {
    SolidColourIsExact();
    SizesDoNotWrap();
    HeaderBoundsAreEnforced();
    PayloadMustCoverTheImage();
    std::cout << "vtf_parser tests passed\n";
    return 0;
}
