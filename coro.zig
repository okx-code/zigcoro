const std = @import("std");
const builtin = @import("builtin");
const base = @import("coro_base.zig");

// libcoro mutable state:
// * ThreadState
//   * current_coro: set in ThreadState.switchTo
//   * next_coro_id: set in ThreadState.nextCoroId
// * Coro
//   * parent: set in ThreadState.switchTo
//   * status:
//     * Active, Suspended: set in ThreadState.switchTo
//     * Done, Error: set in runcoro
//   * id.invocation: incremented in ThreadState.switchTo

// Public API
// ============================================================================
pub const Error = @import("errors.zig").Error;
pub const StackT = []align(base.stack_align) u8;
pub const stack_align = base.stack_align;
pub const default_stack_size = 1024 * 4;

// Coroutine status
pub const CoroStatus = enum {
    Suspended,
    Active,
    Done,
};

// Allocate a stack suitable for coroutine usage.
// Caller is responsible for freeing memory.
pub fn stackAlloc(allocator: std.mem.Allocator, size: usize) !StackT {
    return try allocator.alignedAlloc(u8, stack_align, size);
}

// Returns the currently running coroutine
pub fn xcurrent() *Coro {
    return thread_state.current_coro.?;
}

// Resume the passed coroutine, suspending the current coroutine.
// When the resumed coroutine yields, this call will return.
pub fn xresume(coro: *Coro) void {
    thread_state.switchIn(coro);
}

// Suspend the current coroutine, yielding control back to the parent.
// Returns when the coroutine is resumed.
pub fn xsuspend() void {
    xsuspendSafe() catch unreachable;
}
pub fn xsuspendSafe() Error!void {
    if (thread_state.current_coro == null) return Error.SuspendFromMain;
    const coro = thread_state.current_coro.?;
    try checkStackOverflow(coro);
    thread_state.switchOut(coro.parent);
}

pub const Coro = struct {
    // Function to run in the coroutine
    func: *const fn () void,
    // Coroutine stack
    // The top of this memory is typically reserved for some user-defined
    // storage (e.g. function arguments, return/yield values).
    stack: StackT,
    // Architecture-specific implementation
    impl: base.Coro,
    // The coroutine that will be yielded to upon suspend
    parent: *Coro = undefined,
    // Current status, starts suspended
    status: CoroStatus = .Suspended,
    // Coro id, {thread, coro id, invocation id}
    id: CoroInvocationId,

    pub fn init(func: *const fn () void, stack: StackT) !@This() {
        try setMagicNumber(stack);
        const base_coro = try base.Coro.init(&runcoro, stack);
        return .{
            .func = func,
            .impl = base_coro,
            .stack = stack,
            .id = CoroInvocationId.init(),
        };
    }
};

// Estimates the remaining stack size in the currently running coroutine
pub noinline fn remainingStackSize() usize {
    var dummy: usize = 0;
    dummy += 1;
    const current = xcurrent();
    const addr = @intFromPtr(&dummy);
    const bottom = @intFromPtr(current.stack.ptr);
    const top = @intFromPtr(current.stack.ptr + current.stack.len);
    if (addr > bottom) {
        std.debug.assert(addr < top); // should never have popped beyond the top
        return addr - bottom;
    }
    return 0;
}

// ============================================================================

// Thread-local coroutine runtime
threadlocal var thread_state: ThreadState = .{};
const ThreadState = struct {
    root_coro: Coro = .{
        .func = undefined,
        .stack = undefined,
        .impl = undefined,
        .id = CoroInvocationId.root(),
    },
    current_coro: ?*Coro = null,
    next_coro_id: usize = 1,

    // Called from resume
    fn switchIn(self: *@This(), target: *Coro) void {
        self.switchTo(target, true);
    }

    // Called from suspend
    fn switchOut(self: *@This(), target: *Coro) void {
        self.switchTo(target, false);
    }

    fn switchTo(self: *@This(), target: *Coro, set_parent: bool) void {
        const suspender = self.current();
        if (suspender.status != .Done) suspender.status = .Suspended;
        if (set_parent) target.parent = suspender;
        target.status = .Active;
        target.id.incr();
        self.current_coro = target;
        target.impl.resumeFrom(&suspender.impl);
    }

    fn nextCoroId(self: *@This()) CoroId {
        const out = .{
            .thread = std.Thread.getCurrentId(),
            .coro = self.next_coro_id,
        };
        self.next_coro_id += 1;
        return out;
    }

    fn current(self: *@This()) *Coro {
        return self.current_coro orelse &self.root_coro;
    }
};

fn runcoro(from: *base.Coro, target: *base.Coro) callconv(.C) noreturn {
    _ = from;
    const target_coro = @fieldParentPtr(Coro, "impl", target);
    @call(.auto, target_coro.func, .{});
    target_coro.status = .Done;
    thread_state.switchOut(target_coro.parent);

    // Never returns
    const err_msg = "Cannot resume an already completed coroutine {any}";
    @panic(std.fmt.allocPrint(
        std.heap.c_allocator,
        err_msg,
        .{target_coro.id},
    ) catch {
        @panic(err_msg);
    });
}

const CoroId = struct {
    thread: std.Thread.Id,
    coro: usize,
};

const CoroInvocationId = struct {
    id: CoroId,
    invocation: i64 = -1,

    fn init() @This() {
        return .{ .id = thread_state.nextCoroId() };
    }

    fn root() @This() {
        return .{ .id = .{ .thread = 0, .coro = 0 } };
    }

    fn incr(self: *@This()) void {
        self.invocation += 1;
    }
};

const magic_number: usize = 0x5E574D6D;

fn checkStackOverflow(coro: *Coro) !void {
    const stack = coro.stack.ptr;
    const sp = coro.impl.stack_pointer;
    const magic_number_ptr: *usize = @ptrCast(stack);
    if (magic_number_ptr.* != magic_number or //
        @intFromPtr(sp) < @intFromPtr(stack))
    {
        return Error.StackOverflow;
    }
}

fn setMagicNumber(stack: StackT) !void {
    if (stack.len <= @sizeOf(usize)) return Error.StackTooSmall;
    const magic_number_ptr: *usize = @ptrCast(stack.ptr);
    magic_number_ptr.* = magic_number;
}
