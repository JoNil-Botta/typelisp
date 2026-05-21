/// Runtime support for TypeLisp programs
/// 
/// This module provides the minimal runtime needed for compiled programs:
/// - Memory allocation
/// - Garbage collection (future)
/// - Print functions
/// - Error handling

use std::alloc::{alloc, dealloc, Layout};
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
