/// Unified Out of Memory handler
pub fn oom() noreturn {
    @panic("Out of memory!");
}
