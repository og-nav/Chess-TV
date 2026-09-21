/*
  stockfish_bridge.cpp — Chess TV

  Replicates Stockfish 19's src/main.cpp without a main() symbol, with stdin and
  stdout redirected onto caller-supplied pipe descriptors.

  Stockfish 19 is GPLv3; see Vendor/stockfish/Copying.txt.
*/

#include "include/stockfish_bridge.h"

#include <atomic>
#include <chrono>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <initializer_list>
#include <iostream>
#include <memory>
#include <mutex>
#include <thread>
#include <utility>

#include <fcntl.h>
#include <pthread.h>
#include <unistd.h>

#include "attacks.h"
#include "misc.h"
#include "position.h"
#include "tune.h"
#include "uci.h"

namespace {

std::mutex g_mutex;
// The UCI thread lives on the heap on purpose. A namespace-scope std::thread
// would be destroyed during static destruction at process exit, and ~thread on
// a still-joinable thread calls std::terminate() — which is exactly what an app
// that never shut the engine down used to abort on. A pointer has a trivial
// destructor, so exit() can only reach the thread through the atexit handler
// below.
std::thread*      g_thread = nullptr;
std::atomic<bool> g_running{false};
std::atomic<bool> g_atexit_registered{false};
int               g_saved_stdin  = -1;
int               g_saved_stdout = -1;
// A forced shutdown swaps /dev/null in for the engine's stdin but keeps this
// duplicate of the pipe's read end open, so a host that writes to the other end
// afterwards gets a harmless short write instead of SIGPIPE. Closed by the next
// sf_start() or sf_stop().
int               g_kept_stdin = -1;

// Stockfish's UCI loop is a straight transcription of main(): the one-shot
// command-line path is not used, so argc must be 1 and argv[0] only supplies a
// binary directory for relative EvalFile lookups. The host always passes an
// absolute EvalFile path, so "." is enough.
char  g_arg0[] = "stockfish";
char* g_argv[] = {g_arg0, nullptr};

void run_engine() {
    Stockfish::Attacks::init();
    Stockfish::Position::init();

    auto cli = Stockfish::CommandLine(1, g_argv);
    auto uci = std::make_unique<Stockfish::UCIEngine>(std::move(cli));

    Stockfish::Tune::init(uci->engine_options());

    uci->loop();

    std::cout.flush();
}

// Installed only for the moment it takes to interrupt a blocked read; the
// handler itself does nothing, the EINTR is the point.
void wake_handler(int) {}

/// Waits for the UCI loop to clear `g_running`, polling for at most
/// `timeout_ms`. Returns true if the loop returned in time.
bool wait_for_loop(int timeout_ms) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout_ms);
    while (g_running.load(std::memory_order_acquire)) {
        if (std::chrono::steady_clock::now() >= deadline)
            return false;
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
    return true;
}

/// Makes the UCI loop return without the host having sent `quit`.
///
/// The bridge only holds the *read* end of the host -> engine pipe (on
/// descriptor 0), so it cannot write `quit` itself. Two things together make
/// the loop's `getline(std::cin, ...)` fail, which Stockfish treats as `quit`:
/// descriptor 0 is replaced by /dev/null, which reads as end of file, and the
/// loop thread is signalled so a read it is already blocked in comes back
/// EINTR. The pipe's read end is kept open on another descriptor so the host
/// never writes into a pipe with no reader.
///
/// Must be called with `g_mutex` held (or during exit, when nothing else runs).
bool force_quit_locked(int timeout_ms) {
    if (g_thread == nullptr || !g_running.load(std::memory_order_acquire))
        return true;

    const int devnull = ::open("/dev/null", O_RDONLY);
    if (devnull != -1) {
        if (g_kept_stdin == -1)
            g_kept_stdin = ::dup(STDIN_FILENO);
        ::dup2(devnull, STDIN_FILENO);
        ::close(devnull);
    } else {
        ::close(STDIN_FILENO);
    }

    struct sigaction wake = {};
    struct sigaction previous = {};
    wake.sa_handler = wake_handler;
    sigemptyset(&wake.sa_mask);
    wake.sa_flags = 0;  // no SA_RESTART: the blocked read must come back EINTR
    const bool installed = ::sigaction(SIGURG, &wake, &previous) == 0;

    // The thread may be between commands rather than inside the read, so the
    // nudge is repeated a couple of times before settling into the wait.
    bool stopped = false;
    for (int pause : {0, 100, 250}) {
        if (pause > 0 && wait_for_loop(pause)) {
            stopped = true;
            break;
        }
        if (installed)
            ::pthread_kill(g_thread->native_handle(), SIGURG);
    }

    if (!stopped)
        stopped = wait_for_loop(timeout_ms);

    if (installed)
        ::sigaction(SIGURG, &previous, nullptr);

    return stopped;
}

/// Puts the process' real descriptors back and leaves the streams usable.
void restore_streams_locked() {
    std::cout.flush();
    ::clearerr(stdin);
    ::clearerr(stdout);
    if (g_saved_stdin != -1)
        ::dup2(g_saved_stdin, STDIN_FILENO);
    if (g_saved_stdout != -1)
        ::dup2(g_saved_stdout, STDOUT_FILENO);

    std::cin.clear();
    std::cout.clear();
}

/// Registered with atexit() on the first sf_start(). Runs before the static
/// destructors of everything constructed at load time, so it is the last chance
/// to leave the engine thread in a state exit() can survive.
void shutdown_at_exit() {
    // A lock is only needed against a concurrent sf_start/sf_stop; if one is in
    // flight while the process exits, carry on rather than deadlock exit().
    std::unique_lock<std::mutex> lock(g_mutex, std::try_to_lock);

    std::thread* thread = g_thread;
    if (thread == nullptr)
        return;

    if (g_running.load(std::memory_order_acquire))
        force_quit_locked(2000);

    if (thread->joinable()) {
        if (g_running.load(std::memory_order_acquire))
            thread->detach();  // give up rather than hang the process' exit
        else
            thread->join();
    }

    delete thread;  // non-joinable by now, so ~thread cannot terminate()
    g_thread = nullptr;
}

}  // namespace

extern "C" int sf_start(int in_fd, int out_fd) {
    std::lock_guard<std::mutex> lock(g_mutex);

    if (g_running.load(std::memory_order_acquire))
        return -1;

    if (g_kept_stdin != -1) {
        ::close(g_kept_stdin);
        g_kept_stdin = -1;
    }

    // A thread object can survive a run: sf_stop() joins and deletes it, but a
    // forced shutdown may have left one behind.
    if (g_thread != nullptr) {
        if (g_thread->joinable())
            g_thread->join();
        delete g_thread;
        g_thread = nullptr;
    }

    // Keep the process' real descriptors so sf_stop() can put them back; a
    // tvOS app shares stdout with the unified log and must not lose it.
    if (g_saved_stdin == -1)
        g_saved_stdin = ::dup(STDIN_FILENO);
    if (g_saved_stdout == -1)
        g_saved_stdout = ::dup(STDOUT_FILENO);

    if (::dup2(in_fd, STDIN_FILENO) == -1 || ::dup2(out_fd, STDOUT_FILENO) == -1)
        return -2;

    // A previous run left std::cin at end of file and both streams may hold a
    // partially consumed buffer from the descriptors that were just replaced.
    // The C streams under them keep their own flags: a run that ended on end of
    // file (which is how a forced shutdown stops the loop) leaves stdin's EOF
    // flag set, and the next getline would fail before reading a byte.
    ::clearerr(stdin);
    ::clearerr(stdout);
    std::cin.clear();
    std::cout.clear();
    std::cout.flush();
    ::setvbuf(stdout, nullptr, _IOLBF, 0);

    if (!g_atexit_registered.exchange(true, std::memory_order_acq_rel))
        std::atexit(shutdown_at_exit);

    g_running.store(true, std::memory_order_release);
    g_thread = new std::thread([] {
        run_engine();
        g_running.store(false, std::memory_order_release);
    });

    return 0;
}

extern "C" void sf_stop(void) {
    std::lock_guard<std::mutex> lock(g_mutex);

    if (g_thread != nullptr) {
        if (g_thread->joinable())
            g_thread->join();
        delete g_thread;
        g_thread = nullptr;
    }

    g_running.store(false, std::memory_order_release);

    if (g_kept_stdin != -1) {
        ::close(g_kept_stdin);
        g_kept_stdin = -1;
    }

    restore_streams_locked();
}

extern "C" int sf_shutdown_now(int timeout_ms) {
    std::lock_guard<std::mutex> lock(g_mutex);

    if (g_thread == nullptr) {
        g_running.store(false, std::memory_order_release);
        return 1;
    }

    const bool stopped = force_quit_locked(timeout_ms < 0 ? 0 : timeout_ms);
    if (!stopped)
        return 0;

    if (g_thread->joinable())
        g_thread->join();
    delete g_thread;
    g_thread = nullptr;
    g_running.store(false, std::memory_order_release);

    restore_streams_locked();
    return 1;
}

extern "C" int sf_is_running(void) { return g_running.load(std::memory_order_acquire) ? 1 : 0; }
