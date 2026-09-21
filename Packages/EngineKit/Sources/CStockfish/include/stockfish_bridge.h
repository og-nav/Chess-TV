/*
  stockfish_bridge.h — Chess TV

  A minimal C surface over the Stockfish 19 UCI loop so it can be driven from a
  Swift actor inside a tvOS app process. Stockfish keeps its `main()`-shaped
  design: it reads UCI commands from stdin and writes them to stdout. The bridge
  redirects the process' descriptors 0 and 1 onto a pair of caller-owned pipes
  (the approach ChessKitEngine's EngineMessenger.mm uses) and runs
  `Stockfish::UCIEngine::loop()` on a heap-owned std::thread.

  Process exit is safe even when nobody calls sf_stop(): the first sf_start()
  registers an atexit handler that forces the loop to return (see
  sf_shutdown_now) and, failing that within two seconds, detaches the thread.
  Nothing at static-destruction time ever touches a joinable std::thread, which
  is what used to abort the process with std::terminate().

  Stockfish 19 is GPLv3; see Vendor/stockfish/Copying.txt.
*/

#ifndef STOCKFISH_BRIDGE_H
#define STOCKFISH_BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

/*
  Starts the Stockfish UCI loop on a background thread.

  `in_fd`  — read end of the host -> engine pipe, duplicated onto STDIN_FILENO.
  `out_fd` — write end of the engine -> host pipe, duplicated onto STDOUT_FILENO.

  The bridge duplicates both descriptors onto 0/1 and does not take ownership of
  the ones passed in; the caller closes them after sf_stop() returns.

  Returns 0 on success, -1 if an engine is already running, -2 if dup2 failed.
  Only one engine may run per process at a time.
*/
int sf_start(int in_fd, int out_fd);

/*
  Waits for the UCI loop to return and restores the original stdin/stdout.

  The caller is expected to have written "quit\n" to the engine (and/or closed
  the write end of the host -> engine pipe) before calling this: the loop exits
  on `quit` or on end of file. Safe to call when no engine is running.
*/
void sf_stop(void);

/*
  Stops the engine when the host cannot send "quit" — at process exit, or from a
  test that wants to prove the exit path works.

  The bridge holds only the read end of the host -> engine pipe, so it closes
  descriptor 0 and signals the loop thread, which turns the loop's read into a
  failure; Stockfish treats that as `quit`. Waits up to `timeout_ms` for the
  loop to return.

  Returns 1 if the loop returned (the thread is joined and the original
  stdin/stdout are restored, as after sf_stop), 0 if it was still running when
  the deadline passed — in which case the engine is left alone and the caller
  may try again. Returns 1 immediately when no engine has been started.
*/
int sf_shutdown_now(int timeout_ms);

/* 1 while an engine thread is running, 0 otherwise. */
int sf_is_running(void);

#ifdef __cplusplus
}
#endif

#endif /* STOCKFISH_BRIDGE_H */
