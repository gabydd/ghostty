const std = @import("std");
const builtin = @import("builtin");

impl: Impl = .{},

/// Tries to acquire the mutex without blocking the caller's thread.
/// Returns `false` if the calling thread would have to block to acquire it.
/// Otherwise, returns `true` and the caller should `unlock()` the Mutex to release it.
pub fn tryLock(self: *@This()) bool {
    return self.impl.tryLock();
}

/// Acquires the mutex, blocking the caller's thread until it can.
/// It is undefined behavior if the mutex is already held by the caller's thread.
/// Once acquired, call `unlock()` on the Mutex to release it.
pub fn lock(self: *@This()) void {
    self.impl.lock();
}

/// Releases the mutex which was previously acquired with `lock()` or `tryLock()`.
/// It is undefined behavior if the mutex is unlocked from a different thread that it was locked from.
pub fn unlock(self: *@This()) void {
    self.impl.unlock();
}

const Impl = if (builtin.cpu.arch != .wasm32) std.Thread.Mutex else if (builtin.mode == .Debug and !builtin.single_threaded)
    DebugImpl
else
    ReleaseImpl;

const DebugImpl = struct {
    locking_thread: std.atomic.Value(std.Thread.Id) = std.atomic.Value(std.Thread.Id).init(0), // 0 means it's not locked.
    impl: ReleaseImpl = .{},

    inline fn tryLock(self: *@This()) bool {
        const locking = self.impl.tryLock();
        if (locking) {
            self.locking_thread.store(std.Thread.getCurrentId(), .unordered);
        }
        return locking;
    }

    inline fn lock(self: *@This()) void {
        const current_id = std.Thread.getCurrentId();
        if (self.locking_thread.load(.unordered) == current_id and current_id != 0) {
            @panic("Deadlock detected");
        }
        self.impl.lock();
        self.locking_thread.store(current_id, .unordered);
    }

    inline fn unlock(self: *@This()) void {
        std.debug.assert(self.locking_thread.load(.unordered) == std.Thread.getCurrentId());
        self.locking_thread.store(0, .unordered);
        self.impl.unlock();
    }
};
const ReleaseImpl = struct {
    state: std.atomic.Value(u32) = std.atomic.Value(u32).init(unlocked),

    const unlocked: u32 = 0b00;
    const locked: u32 = 0b01;
    const contended: u32 = 0b11; // must contain the `locked` bit for x86 optimization below

    fn lock(self: *@This()) void {
        if (!self.tryLock())
            self.lockSlow();
    }

    fn tryLock(self: *@This()) bool {
        // On x86, use `lock bts` instead of `lock cmpxchg` as:
        // - they both seem to mark the cache-line as modified regardless: https://stackoverflow.com/a/63350048
        // - `lock bts` is smaller instruction-wise which makes it better for inlining
        if (comptime builtin.target.cpu.arch.isX86()) {
            const locked_bit = @ctz(locked);
            return self.state.bitSet(locked_bit, .acquire) == 0;
        }

        // Acquire barrier ensures grabbing the lock happens before the critical section
        // and that the previous lock holder's critical section happens before we grab the lock.
        return self.state.cmpxchgWeak(unlocked, locked, .acquire, .monotonic) == null;
    }

    fn lockSlow(self: *@This()) void {
        @setCold(true);

        // Avoid doing an atomic swap below if we already know the state is contended.
        // An atomic swap unconditionally stores which marks the cache-line as modified unnecessarily.
        if (self.state.load(.monotonic) == contended) {
            Futex.wait(&self.state, contended);
        }

        // Try to acquire the lock while also telling the existing lock holder that there are threads waiting.
        //
        // Once we sleep on the Futex, we must acquire the mutex using `contended` rather than `locked`.
        // If not, threads sleeping on the Futex wouldn't see the state change in unlock and potentially deadlock.
        // The downside is that the last mutex unlocker will see `contended` and do an unnecessary Futex wake
        // but this is better than having to wake all waiting threads on mutex unlock.
        //
        // Acquire barrier ensures grabbing the lock happens before the critical section
        // and that the previous lock holder's critical section happens before we grab the lock.
        while (self.state.swap(contended, .acquire) != unlocked) {
            Futex.wait(&self.state, contended);
        }
    }

    fn unlock(self: *@This()) void {
        // Unlock the mutex and wake up a waiting thread if any.
        //
        // A waiting thread will acquire with `contended` instead of `locked`
        // which ensures that it wakes up another thread on the next unlock().
        //
        // Release barrier ensures the critical section happens before we let go of the lock
        // and that our critical section happens before the next lock holder grabs the lock.
        const state = self.state.swap(unlocked, .release);
        std.debug.assert(state != unlocked);

        if (state == contended) {
            Futex.wake(&self.state, 1);
        }
    }
};
const WasmImpl = struct {
    fn wait(ptr: *const std.atomic.Value(u32), expect: u32, timeout: ?u64) error{Timeout}!void {
        if (!comptime std.Target.wasm.featureSetHas(builtin.target.cpu.features, .atomics)) {
            @compileError("WASI target missing cpu feature 'atomics'");
        }
        const to: i64 = if (timeout) |to| @intCast(to) else -1;
        const result = asm volatile (
            \\local.get %[ptr]
            \\local.get %[expected]
            \\local.get %[timeout]
            \\memory.atomic.wait32 0
            \\local.set %[ret]
            : [ret] "=r" (-> u32),
            : [ptr] "r" (&ptr.raw),
              [expected] "r" (@as(i32, @bitCast(expect))),
              [timeout] "r" (to),
        );
        switch (result) {
            0 => {}, // ok
            1 => {}, // expected =! loaded
            2 => return error.Timeout,
            else => unreachable,
        }
    }

    fn wake(ptr: *const std.atomic.Value(u32), max_waiters: u32) void {
        if (!comptime std.Target.wasm.featureSetHas(builtin.target.cpu.features, .atomics)) {
            @compileError("WASI target missing cpu feature 'atomics'");
        }
        std.debug.assert(max_waiters != 0);
        const woken_count = asm volatile (
            \\local.get %[ptr]
            \\local.get %[waiters]
            \\memory.atomic.notify 0
            \\local.set %[ret]
            : [ret] "=r" (-> u32),
            : [ptr] "r" (&ptr.raw),
              [waiters] "r" (max_waiters),
        );
        _ = woken_count; // can be 0 when linker flag 'shared-memory' is not enabled
    }
};

const Futex = struct {
    /// Checks if `ptr` still contains the value `expect` and, if so, blocks the caller until either:
    /// - The value at `ptr` is no longer equal to `expect`.
    /// - The caller is unblocked by a matching `wake()`.
    /// - The caller is unblocked spuriously ("at random").
    ///
    /// The checking of `ptr` and `expect`, along with blocking the caller, is done atomically
    /// and totally ordered (sequentially consistent) with respect to other wait()/wake() calls on the same `ptr`.
    pub fn wait(ptr: *const std.atomic.Value(u32), expect: u32) void {
        @setCold(true);

        WasmImpl.wait(ptr, expect, null) catch |err| switch (err) {
            error.Timeout => unreachable, // null timeout meant to wait forever
        };
    }

    /// Checks if `ptr` still contains the value `expect` and, if so, blocks the caller until either:
    /// - The value at `ptr` is no longer equal to `expect`.
    /// - The caller is unblocked by a matching `wake()`.
    /// - The caller is unblocked spuriously ("at random").
    /// - The caller blocks for longer than the given timeout. In which case, `error.Timeout` is returned.
    ///
    /// The checking of `ptr` and `expect`, along with blocking the caller, is done atomically
    /// and totally ordered (sequentially consistent) with respect to other wait()/wake() calls on the same `ptr`.
    pub fn timedWait(ptr: *const std.atomic.Value(u32), expect: u32, timeout_ns: u64) error{Timeout}!void {
        @setCold(true);

        // Avoid calling into the OS for no-op timeouts.
        if (timeout_ns == 0) {
            if (ptr.load(.seq_cst) != expect) return;
            return error.Timeout;
        }

        return WasmImpl.wait(ptr, expect, timeout_ns);
    }

    /// Unblocks at most `max_waiters` callers blocked in a `wait()` call on `ptr`.
    pub fn wake(ptr: *const std.atomic.Value(u32), max_waiters: u32) void {
        @setCold(true);

        // Avoid calling into the OS if there's nothing to wake up.
        if (max_waiters == 0) {
            return;
        }

        WasmImpl.wake(ptr, max_waiters);
    }
};
