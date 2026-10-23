#include "layered_window_surface.h"

#include <algorithm>

namespace azookey::tsf {
namespace {

// A target lost to a device change is made again once; painting twice is harmless.
constexpr int kPaintAttempts = 2;

}  // namespace

LayeredWindowSurface::LayeredWindowSurface(ID2D1Factory* factory) : factory_(factory) {}

LayeredWindowSurface::~LayeredWindowSurface() { ReleaseResources(); }

bool LayeredWindowSurface::EnsureBitmap(SIZE size) {
    if (bitmap_ && bitmapSize_.cx >= size.cx && bitmapSize_.cy >= size.cy) return true;
    if (!memoryDC_) memoryDC_ = CreateCompatibleDC(nullptr);
    if (!memoryDC_) return false;
    // The bitmap only grows, so a panel that changes size while typing does not
    // allocate on every key; Present uses its top-left part.
    SIZE grown{std::max(size.cx, bitmapSize_.cx), std::max(size.cy, bitmapSize_.cy)};
    BITMAPINFO info{};
    info.bmiHeader.biSize = sizeof(info.bmiHeader);
    info.bmiHeader.biWidth = grown.cx;
    info.bmiHeader.biHeight = -grown.cy;  // top-down rows, as Direct2D writes them
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    info.bmiHeader.biCompression = BI_RGB;
    void* pixels = nullptr;
    HBITMAP bitmap = CreateDIBSection(memoryDC_, &info, DIB_RGB_COLORS, &pixels, nullptr, 0);
    if (!bitmap) return false;
    HGDIOBJ previous = SelectObject(memoryDC_, bitmap);
    if (bitmap_) {
        DeleteObject(bitmap_);
    } else {
        originalBitmap_ = previous;
    }
    bitmap_ = bitmap;
    bitmapSize_ = grown;
    return true;
}

bool LayeredWindowSurface::EnsureTarget() {
    if (target_) return true;
    // Software rendering: the picture ends up in a bitmap in memory anyway, and
    // the DLL then needs no GPU device in every application it is loaded into.
    // UpdateLayeredWindow takes premultiplied BGRA, which is this pixel format.
    D2D1_RENDER_TARGET_PROPERTIES properties = D2D1::RenderTargetProperties(
        D2D1_RENDER_TARGET_TYPE_SOFTWARE, D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED));
    return SUCCEEDED(factory_->CreateDCRenderTarget(&properties, &target_));
}

bool LayeredWindowSurface::Present(HWND window, const LayeredWindowPlacement& placement, const Painter& paint) {
    SIZE size = placement.size;
    if (size.cx <= 0 || size.cy <= 0 || !EnsureBitmap(size)) return false;
    for (int attempt = 0; attempt < kPaintAttempts; ++attempt) {
        if (!EnsureTarget()) return false;
        RECT area{0, 0, size.cx, size.cy};
        if (FAILED(target_->BindDC(memoryDC_, &area))) return false;
        float dpi = static_cast<float>(placement.dpi);
        target_->SetDpi(dpi, dpi);
        target_->BeginDraw();
        target_->SetTransform(D2D1::Matrix3x2F::Identity());
        target_->Clear(D2D1::ColorF(0, 0, 0, 0));
        paint(target_);
        HRESULT drawn = target_->EndDraw();
        if (drawn == D2DERR_RECREATE_TARGET) {
            target_->Release();
            target_ = nullptr;
            continue;
        }
        if (FAILED(drawn)) return false;
        // Direct2D copies the picture into the DC through GDI, which may still hold it in its batch.
        GdiFlush();
        POINT position = placement.position;
        POINT source{0, 0};
        BLENDFUNCTION blend{AC_SRC_OVER, 0, 255, AC_SRC_ALPHA};
        return UpdateLayeredWindow(window, nullptr, &position, &size, memoryDC_, &source, 0, &blend, ULW_ALPHA) != FALSE;
    }
    return false;
}

void LayeredWindowSurface::ReleaseResources() {
    if (target_) {
        target_->Release();
        target_ = nullptr;
    }
    if (memoryDC_ && originalBitmap_) SelectObject(memoryDC_, originalBitmap_);
    if (bitmap_) DeleteObject(bitmap_);
    if (memoryDC_) DeleteDC(memoryDC_);
    memoryDC_ = nullptr;
    bitmap_ = nullptr;
    originalBitmap_ = nullptr;
    bitmapSize_ = {};
}

}  // namespace azookey::tsf
