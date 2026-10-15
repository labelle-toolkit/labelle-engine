const worker = @import("worker");
var executor = worker.SnapshotExecutor{};
var value: usize = 0;
fn work(raw: *anyopaque, start: usize, end: usize) void {
    _ = raw;
    _ = start;
    _ = end;
}
export fn checkWorker() bool {
    const used = executor.run(&value, 2, work);
    executor.deinit();
    return used;
}
