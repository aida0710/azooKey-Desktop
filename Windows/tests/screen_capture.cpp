#include "screen_capture.h"

#include <wincodec.h>

#include <cstring>

namespace azookey::tests {

ScreenImage CaptureScreenRegion(const RECT& region) {
    ScreenImage image;
    int width = region.right - region.left, height = region.bottom - region.top;
    if (width <= 0 || height <= 0) return image;
    HDC screen = GetDC(nullptr);
    HDC memory = CreateCompatibleDC(screen);
    BITMAPINFO info{};
    info.bmiHeader.biSize = sizeof(info.bmiHeader);
    info.bmiHeader.biWidth = width;
    info.bmiHeader.biHeight = -height;  // top-down rows
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    info.bmiHeader.biCompression = BI_RGB;
    void* pixels = nullptr;
    HBITMAP bitmap = CreateDIBSection(screen, &info, DIB_RGB_COLORS, &pixels, nullptr, 0);
    if (bitmap && pixels) {
        HGDIOBJ previous = SelectObject(memory, bitmap);
        // CAPTUREBLT includes layered windows such as the candidate panel.
        BitBlt(memory, 0, 0, width, height, screen, region.left, region.top, SRCCOPY | CAPTUREBLT);
        SelectObject(memory, previous);
        image.width = width;
        image.height = height;
        image.pixels.resize(static_cast<size_t>(width) * height * 4);
        std::memcpy(image.pixels.data(), pixels, image.pixels.size());
        // GDI leaves the alpha byte 0; PNG keeps BGRA as is, so make every pixel opaque.
        for (size_t i = 3; i < image.pixels.size(); i += 4) image.pixels[i] = 0xFF;
    }
    if (bitmap) DeleteObject(bitmap);
    DeleteDC(memory);
    ReleaseDC(nullptr, screen);
    return image;
}

bool SavePng(const std::wstring& path, const ScreenImage& image) {
    if (image.pixels.empty()) return false;
    bool saved = false;
    IWICImagingFactory* factory = nullptr;
    IWICStream* stream = nullptr;
    IWICBitmapEncoder* encoder = nullptr;
    IWICBitmapFrameEncode* frame = nullptr;
    UINT stride = static_cast<UINT>(image.width) * 4;
    if (SUCCEEDED(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory))) &&
        SUCCEEDED(factory->CreateStream(&stream)) && SUCCEEDED(stream->InitializeFromFilename(path.c_str(), GENERIC_WRITE)) &&
        SUCCEEDED(factory->CreateEncoder(GUID_ContainerFormatPng, nullptr, &encoder)) &&
        SUCCEEDED(encoder->Initialize(stream, WICBitmapEncoderNoCache)) &&
        SUCCEEDED(encoder->CreateNewFrame(&frame, nullptr)) && SUCCEEDED(frame->Initialize(nullptr)) &&
        SUCCEEDED(frame->SetSize(image.width, image.height))) {
        // The encoder may answer with a different format; only write when it kept ours.
        WICPixelFormatGUID format = GUID_WICPixelFormat32bppBGRA;
        saved = SUCCEEDED(frame->SetPixelFormat(&format)) && IsEqualGUID(format, GUID_WICPixelFormat32bppBGRA) &&
                SUCCEEDED(frame->WritePixels(image.height, stride, static_cast<UINT>(image.pixels.size()),
                                             const_cast<BYTE*>(image.pixels.data()))) &&
                SUCCEEDED(frame->Commit()) && SUCCEEDED(encoder->Commit());
    }
    if (frame) frame->Release();
    if (encoder) encoder->Release();
    if (stream) stream->Release();
    if (factory) factory->Release();
    return saved;
}

bool SaveScreenRegionPng(const std::wstring& path, const RECT& region) {
    return SavePng(path, CaptureScreenRegion(region));
}

bool SaveScreenPng(const std::wstring& path) {
    int left = GetSystemMetrics(SM_XVIRTUALSCREEN), top = GetSystemMetrics(SM_YVIRTUALSCREEN);
    RECT screen{left, top, left + GetSystemMetrics(SM_CXVIRTUALSCREEN), top + GetSystemMetrics(SM_CYVIRTUALSCREEN)};
    return SaveScreenRegionPng(path, screen);
}

}  // namespace azookey::tests
