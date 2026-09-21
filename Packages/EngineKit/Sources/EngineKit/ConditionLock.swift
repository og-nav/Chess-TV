// A pthread mutex + condition variable.
//
// NSCondition's `lock()`/`unlock()` are marked unavailable from asynchronous
// contexts, and EngineChannel has to take the lock either side of an `await`
// inside `waitForBestmove`. The raw pthread primitives carry no such annotation
// and are what NSCondition wraps anyway.

import Foundation

final class ConditionLock: @unchecked Sendable {
    private let mutex = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)
    private let condition = UnsafeMutablePointer<pthread_cond_t>.allocate(capacity: 1)

    init() {
        pthread_mutex_init(mutex, nil)
        pthread_cond_init(condition, nil)
    }

    deinit {
        pthread_cond_destroy(condition)
        pthread_mutex_destroy(mutex)
        condition.deallocate()
        mutex.deallocate()
    }

    func lock() { pthread_mutex_lock(mutex) }
    func unlock() { pthread_mutex_unlock(mutex) }
    func broadcast() { pthread_cond_broadcast(condition) }

    /// Waits until `broadcast()` or `deadline`. Returns `false` on timeout.
    /// The lock must be held.
    func wait(until deadline: Date) -> Bool {
        let interval = deadline.timeIntervalSince1970
        var timespec = timespec(tv_sec: Int(interval),
                                tv_nsec: Int((interval - Double(Int(interval))) * 1_000_000_000))
        return pthread_cond_timedwait(condition, mutex, &timespec) == 0
    }
}
