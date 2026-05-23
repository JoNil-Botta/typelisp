//! Reference runtime semantics for TypeLisp programs.
//!
//! IMPORTANT: these functions are compiled **into the `typelisp` compiler
//! binary** and are **not** linked into compiled `.tl` programs. The runtime
//! that actually ships in a compiled program is emitted as **self-contained
//! x86_64 assembly text** by the backend (see `src/backend/mod.rs`):
//! `tl_print_i64`/`tl_print_bool` via the `write(2)` syscall and the bump
//! allocator `tl_alloc` over backend-tracked `mmap`'d arenas — zero libc
//! dependency (issue #13).
//!
//! This module is retained only as an executable reference for those
//! semantics (allocation, printing, error handling); do not assume a compiled
//! program calls into it.
use std::alloc::{Layout, alloc, dealloc};
use std::ffi::c_void;

/// Allocate memory
#[unsafe(no_mangle)]
pub extern "C" fn tl_alloc(size: usize) -> *mut c_void {
    unsafe {
        let layout = Layout::from_size_align(size, 8).unwrap();
        alloc(layout) as *mut c_void
    }
}

/// Free memory
#[unsafe(no_mangle)]
pub extern "C" fn tl_free(ptr: *mut c_void, size: usize) {
    unsafe {
        let layout = Layout::from_size_align(size, 8).unwrap();
        dealloc(ptr as *mut u8, layout);
    }
}

/// Print an integer
#[unsafe(no_mangle)]
pub extern "C" fn tl_print_i64(n: i64) {
    println!("{}", n);
}

/// Print a boolean
#[unsafe(no_mangle)]
pub extern "C" fn tl_print_bool(b: bool) {
    println!("{}", b);
}

/// Print a float
#[unsafe(no_mangle)]
pub extern "C" fn tl_print_f64(n: f64) {
    println!("{}", n);
}

/// Print a character
#[unsafe(no_mangle)]
pub extern "C" fn tl_print_char(c: u8) {
    print!("{}", c as char);
}

/// Print a newline
#[unsafe(no_mangle)]
pub extern "C" fn tl_print_newline() {
    println!();
}

/// Abort with error
#[unsafe(no_mangle)]
pub extern "C" fn tl_panic() -> ! {
    panic!("TypeLisp runtime panic");
}
