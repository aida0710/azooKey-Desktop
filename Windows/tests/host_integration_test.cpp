// Starts azookey-windows-host.exe on a private pipe and converts through it the
// way the text service does. Needs the built bridge; no desktop session.
//
//   azookey-host-integration-test.exe <host exe> <bridge exe>
#include <windows.h>

#include <chrono>
#include <cstdio>
#include <optional>
#include <string>

#include "../src/shared/bridge_protocol.h"
#include "../src/shared/host_channel.h"
#include "../src/shared/key_translation.h"
#include "../src/shared/text_encoding.h"

namespace {

int failures = 0;

void Check(bool condition, const char* description) {
    if (!condition) {
        ++failures;
        std::printf("FAIL: %s\n", description);
    } else {
        std::printf("ok: %s\n", description);
    }
}

std::optional<azookey::protocol::Snapshot> Ask(azookey::channel::HostConnection& connection, const std::string& request) {
    auto reply = connection.Request(request);
    return reply ? azookey::protocol::ParseSnapshot(*reply) : std::nullopt;
}

// An empty field between "前" and "後", with the caret 10 units into the document.
azookey::protocol::DocumentContext FieldWithCaret() {
    azookey::protocol::ReconversionContext field;
    field.before = L"前";
    field.after = L"後";
    field.cursorUTF16 = field.anchorUTF16 = 10;
    field.canReplace = true;
    return {L"前", false, field};
}

azookey::protocol::DocumentContext FieldWithSelection(const std::wstring& selected) {
    azookey::protocol::DocumentContext document = FieldWithCaret();
    document.reconversion->selected = selected;
    document.reconversion->cursorUTF16 = 10 + static_cast<int>(selected.size());
    return document;
}

void TypeRomaji(azookey::channel::HostConnection& connection, const azookey::protocol::RequestContext& context,
                const std::wstring& romaji, bool reading) {
    for (wchar_t c : romaji) {
        auto event = azookey::keys::Translate(towupper(c), {}, std::wstring(1, c));
        connection.Request(reading ? azookey::protocol::ReconversionReadingRequest(context, event)
                                   : azookey::protocol::KeyRequest(context, event));
    }
}

// The exchange the text service has with Core to undo a commit: the field
// advances past the commit, Core names the text to take back, and once the
// document no longer holds it the composition comes back.
void TestUndoingACommit(azookey::channel::HostConnection& connection) {
    azookey::protocol::RequestContext context{"undo", FieldWithCaret()};
    TypeRomaji(connection, context, L"nihongo", false);
    auto committed = Ask(connection, azookey::protocol::KeyRequest(context, azookey::keys::Translate(0x0D, {}, L"")));
    Check(committed && committed->commits.size() == 1, "Enter commits the composition");
    if (!committed || committed->commits.empty()) return;
    std::wstring text = committed->commits[0];

    context.document = azookey::protocol::AdvancedPastCommit(context.document, text);
    auto undo = Ask(connection, azookey::protocol::UndoCommitRequest(context));
    Check(undo && undo->reconversion && undo->reconversion->text == text &&
              undo->reconversion->offset == -static_cast<int>(azookey::text::ScalarCount(text)),
          "Core asks for the committed text right before the caret");
    if (!undo || !undo->reconversion) return;

    context.document = FieldWithCaret();
    auto restored = Ask(connection, azookey::protocol::ConfirmReconversionRequest(context, undo->reconversion->token));
    Check(restored && restored->reconversionError.empty() && !restored->preedit.empty() && restored->commits.empty(),
          "the commit comes back as a composition once the text is gone");
    auto cancelled = Ask(connection, azookey::protocol::ResetRequest(context, false));
    Check(cancelled && cancelled->commits.size() == 1 && cancelled->commits[0] == text,
          "cancelling the restored composition gives the original text back");
}

// Kanji Core cannot read back on its own: the user types the reading first.
void TestReconvertingASelectionWithItsReading(azookey::channel::HostConnection& connection) {
    azookey::protocol::RequestContext context{"reading", FieldWithSelection(L"日本語")};
    auto asked = Ask(connection, azookey::protocol::ReconvertRequest(context));
    Check(asked && asked->reconversionReading == L"" && asked->reconversionError == "reading_required",
          "Core asks for the reading of kanji it cannot read");
    TypeRomaji(connection, context, L"nihongo", true);
    auto submitted = Ask(connection, azookey::protocol::ReconversionReadingRequest(context, azookey::keys::Translate(0x0D, {}, L"")));
    Check(submitted && submitted->reconversion && submitted->reconversion->text == L"日本語",
          "Enter submits the reading and Core names the selection");
    if (!submitted || !submitted->reconversion) return;
    context.document = FieldWithCaret();
    auto restored = Ask(connection, azookey::protocol::ConfirmReconversionRequest(context, submitted->reconversion->token));
    bool offersOriginal = false;
    if (restored) {
        for (const auto& candidate : restored->candidates) offersOriginal = offersOriginal || candidate.text == L"日本語";
    }
    Check(restored && restored->reconversionError.empty() && offersOriginal,
          "the selection becomes a composition that offers 日本語 again");
    Ask(connection, azookey::protocol::ResetRequest(context, false));
}

std::wstring TemporaryDirectory(const std::wstring& name) {
    wchar_t base[MAX_PATH];
    GetTempPathW(MAX_PATH, base);
    std::wstring directory = std::wstring(base) + name;
    CreateDirectoryW(directory.c_str(), nullptr);
    return directory;
}

}  // namespace

int wmain(int argc, wchar_t** argv) {
    if (argc < 3) {
        std::fprintf(stderr, "usage: azookey-host-integration-test <host exe> <bridge exe>\n");
        return 64;
    }
    std::wstring pipe = L"\\\\.\\pipe\\azooKeyTree-test-" + std::to_wstring(GetCurrentProcessId());
    std::wstring data = TemporaryDirectory(L"azookey-host-test-" + std::to_wstring(GetCurrentProcessId()));
    std::wstring commandLine = L"\"" + std::wstring(argv[1]) + L"\" --pipe " + pipe + L" --bridge \"" + argv[2] +
                               L"\" --data \"" + data + L"\"";
    STARTUPINFOW startup{sizeof(startup)};
    PROCESS_INFORMATION host{};
    if (!CreateProcessW(argv[1], commandLine.data(), nullptr, nullptr, FALSE, CREATE_NO_WINDOW, nullptr, nullptr,
                        &startup, &host)) {
        std::printf("FAIL: could not start the host (%lu)\n", GetLastError());
        return 1;
    }

    azookey::channel::HostConnection::Options options;
    options.pipeName = pipe;
    // The first request loads the dictionary.
    options.requestTimeoutMilliseconds = 15000;
    azookey::channel::HostConnection connection(options);
    azookey::protocol::RequestContext context{"integration", {}};

    std::optional<azookey::protocol::Snapshot> last;
    double slowestMilliseconds = 0;
    for (wchar_t c : std::wstring(L"nihongo")) {
        auto event = azookey::keys::Translate(towupper(c), {}, std::wstring(1, c));
        auto started = std::chrono::steady_clock::now();
        auto reply = connection.Request(azookey::protocol::KeyRequest(context, event));
        double elapsed = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - started).count();
        if (c != L'n' || last) slowestMilliseconds = std::max(slowestMilliseconds, elapsed);
        last = reply ? azookey::protocol::ParseSnapshot(*reply) : std::nullopt;
        if (!last) break;
    }
    Check(last && last->preedit == L"日本語", "typing nihongo composes 日本語");
    std::printf("slowest key after the first: %.1f ms\n", slowestMilliseconds);

    auto space = connection.Request(azookey::protocol::KeyRequest(context, azookey::keys::Translate(0x20, {}, L" ")));
    auto converting = space ? azookey::protocol::ParseSnapshot(*space) : std::nullopt;
    Check(converting && converting->selection.has_value() && !converting->candidates.empty(), "Space opens candidates");

    // A second client (another application) gets its own composition.
    azookey::channel::HostConnection other(options);
    auto otherReply = other.Request(azookey::protocol::KeyRequest({"other", {}},
                                                                  azookey::keys::Translate('K', {}, L"k")));
    auto otherSnapshot = otherReply ? azookey::protocol::ParseSnapshot(*otherReply) : std::nullopt;
    Check(otherSnapshot && otherSnapshot->preedit == L"k", "a second application composes independently");

    auto enter = connection.Request(azookey::protocol::KeyRequest(context, azookey::keys::Translate(0x0D, {}, L"")));
    auto committed = enter ? azookey::protocol::ParseSnapshot(*enter) : std::nullopt;
    Check(committed && committed->commits.size() == 1 && committed->commits[0] == L"日本語" && committed->preedit.empty(),
          "Enter commits 日本語 and clears the preedit");

    TestUndoingACommit(connection);
    TestReconvertingASelectionWithItsReading(connection);

    connection.Disconnect();
    other.Disconnect();
    TerminateProcess(host.hProcess, 0);
    WaitForSingleObject(host.hProcess, 5000);
    CloseHandle(host.hThread);
    CloseHandle(host.hProcess);
    std::printf("%s\n", failures == 0 ? "PASS" : "FAIL");
    return failures == 0 ? 0 : 1;
}
