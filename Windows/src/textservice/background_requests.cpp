#include "background_requests.h"

#include <mutex>
#include <new>

#include "ime_windows.h"

namespace azookey::tsf {
namespace {

constexpr wchar_t kWindowClassName[] = L"azooKeyTreeBackgroundReplies";
constexpr UINT kReplyMessage = WM_APP + 1;

struct Delivery {
    std::optional<std::string> reply;
    BackgroundRequests::ReplyHandler onReply;
};

}  // namespace

// Where a finished request leaves its reply. The window disappears with the
// text service; a thread finishing later finds no window and drops the reply.
struct BackgroundRequests::Mailbox {
    std::mutex mutex;
    HWND window = nullptr;
};

namespace {

struct Job {
    HMODULE module = nullptr;  // a reference to this DLL, released as the thread ends
    std::string line;
    channel::HostConnection::Options options;
    std::shared_ptr<BackgroundRequests::Mailbox> mailbox;
    BackgroundRequests::ReplyHandler onReply;
};

DWORD WINAPI RunJob(void* parameter) {
    std::unique_ptr<Job> job(static_cast<Job*>(parameter));
    channel::HostConnection connection(job->options);
    auto* delivery = new (std::nothrow) Delivery{connection.Request(job->line), std::move(job->onReply)};
    if (delivery) {
        std::lock_guard<std::mutex> lock(job->mailbox->mutex);
        if (!job->mailbox->window || !PostMessageW(job->mailbox->window, kReplyMessage, 0, reinterpret_cast<LPARAM>(delivery))) {
            delete delivery;
        }
    }
    HMODULE module = job->module;
    job.reset();
    // The thread holds a reference to this DLL so that it cannot unload under it.
    if (module) FreeLibraryAndExitThread(module, 0);
    return 0;
}

}  // namespace

BackgroundRequests::BackgroundRequests(channel::HostConnection::Options options)
    : options_(std::move(options)), mailbox_(std::make_shared<Mailbox>()) {
    mailbox_->window = CreateImeMessageWindow({kWindowClassName, WindowProcedure}, nullptr);
}

BackgroundRequests::~BackgroundRequests() {
    HWND window = nullptr;
    {
        std::lock_guard<std::mutex> lock(mailbox_->mutex);
        window = mailbox_->window;
        mailbox_->window = nullptr;
    }
    if (!window) return;
    // Replies already posted would be discarded with the window; free them first.
    MSG message;
    while (PeekMessageW(&message, window, kReplyMessage, kReplyMessage, PM_REMOVE)) {
        if (message.message == WM_QUIT) {
            // PeekMessage hands out WM_QUIT whatever the filter. The text service
            // is often torn down while the application's main window is being
            // destroyed, after it has called PostQuitMessage; without the quit
            // message its loop would wait forever.
            PostQuitMessage(static_cast<int>(message.wParam));
            break;
        }
        delete reinterpret_cast<Delivery*>(message.lParam);
    }
    DestroyWindow(window);
}

void BackgroundRequests::Start(std::string line, ReplyHandler onReply) {
    auto job = std::make_unique<Job>(Job{nullptr, std::move(line), options_, mailbox_, std::move(onReply)});
    GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS, reinterpret_cast<LPCWSTR>(&RunJob), &job->module);
    HANDLE thread = CreateThread(nullptr, 0, RunJob, job.get(), 0, nullptr);
    if (!thread) {
        if (job->module) FreeLibrary(job->module);
        auto handler = std::move(job->onReply);
        handler(std::nullopt);
        return;
    }
    job.release();
    CloseHandle(thread);
}

LRESULT CALLBACK BackgroundRequests::WindowProcedure(HWND window, UINT message, WPARAM wParam, LPARAM lParam) {
    if (message != kReplyMessage) return DefWindowProcW(window, message, wParam, lParam);
    std::unique_ptr<Delivery> delivery(reinterpret_cast<Delivery*>(lParam));
    if (delivery->onReply) delivery->onReply(std::move(delivery->reply));
    return 0;
}

}  // namespace azookey::tsf
