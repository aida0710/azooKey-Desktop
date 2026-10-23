// The picture of a layered window (WS_EX_LAYERED). Direct2D draws it into a
// bitmap in memory, and UpdateLayeredWindow hands the picture, the window's
// position and its size to the system in one call, so the window never shows
// its new size with its old picture. A window drawn through an
// ID2D1HwndRenderTarget is resized first and repainted afterwards, which shows
// for one frame when the candidate panel grows.
#pragma once

#include <windows.h>
#include <d2d1.h>

#include <functional>

namespace azookey::tsf {

struct LayeredWindowPlacement {
    POINT position{};  // top-left corner in physical screen pixels
    SIZE size{};       // physical pixels
    UINT dpi = 96;     // the picture is drawn in DIPs at this DPI
};

class LayeredWindowSurface {
public:
    // Paints the whole picture onto a transparent target, in DIPs.
    using Painter = std::function<void(ID2D1RenderTarget* target)>;

    explicit LayeredWindowSurface(ID2D1Factory* factory);
    ~LayeredWindowSurface();
    LayeredWindowSurface(const LayeredWindowSurface&) = delete;
    LayeredWindowSurface& operator=(const LayeredWindowSurface&) = delete;

    // Shows what `paint` draws in `window`, at `placement`. false when nothing
    // could be shown; the window then keeps its previous picture and place.
    bool Present(HWND window, const LayeredWindowPlacement& placement, const Painter& paint);
    // Frees the bitmap and the render target; the next Present makes them again.
    void ReleaseResources();

private:
    bool EnsureBitmap(SIZE size);
    bool EnsureTarget();

    ID2D1Factory* factory_;
    HDC memoryDC_ = nullptr;
    HBITMAP bitmap_ = nullptr;
    HGDIOBJ originalBitmap_ = nullptr;  // selected back before the DC is deleted
    SIZE bitmapSize_{};
    ID2D1DCRenderTarget* target_ = nullptr;
};

}  // namespace azookey::tsf
