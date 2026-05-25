use crate::diagnostic::Diagnostic;
use crate::ir::{
    BasicBlock, BinOp as IrBinOp, Function, Instruction, Label, Program, SourceSpans,
    UnOp as IrUnOp, Value, VarId, VectorReduceOp,
};
use crate::span::Span;
use crate::types::{DYN_ARRAY_PTR_OFFSET, Type};
use std::collections::{BTreeSet, HashMap, HashSet};
use std::fmt;

#[allow(dead_code)]
pub(crate) mod liveness;
#[allow(dead_code)]
pub(crate) mod regalloc;

const ABORT_RUNTIME_SYMBOL: &str = ".L_tl_abort";
const ARG_COUNT_RUNTIME_SYMBOL: &str = ".L_tl_arg_count";
const ARG_RUNTIME_SYMBOL: &str = ".L_tl_arg";
const READ_FILE_RUNTIME_SYMBOL: &str = ".L_tl_read_file";
const WRITE_FILE_RUNTIME_SYMBOL: &str = ".L_tl_write_file";
const FILE_EXISTS_RUNTIME_SYMBOL: &str = ".L_tl_file_exists";
const READ_FILE_STATUS_RUNTIME_SYMBOL: &str = ".L_tl_read_file_status";
const WRITE_FILE_STATUS_RUNTIME_SYMBOL: &str = ".L_tl_write_file_status";
const FILE_EXISTS_STATUS_RUNTIME_SYMBOL: &str = ".L_tl_file_exists_status";
const FS_MKDIR_STATUS_RUNTIME_SYMBOL: &str = ".L_tl_fs_mkdir_status";
const FS_REMOVE_FILE_STATUS_RUNTIME_SYMBOL: &str = ".L_tl_fs_remove_file_status";
const FS_REMOVE_DIR_STATUS_RUNTIME_SYMBOL: &str = ".L_tl_fs_remove_dir_status";
const FS_PROCESS_ID_RUNTIME_SYMBOL: &str = ".L_tl_fs_process_id";
const ENV_VAR_EXISTS_RUNTIME_SYMBOL: &str = ".L_tl_env_var_exists";
const ENV_VAR_VALUE_RUNTIME_SYMBOL: &str = ".L_tl_env_var_value";
const ENV_PATH_SEPARATOR_RUNTIME_SYMBOL: &str = ".L_tl_env_path_separator";
const PROCESS_OUTPUT_RUNTIME_SYMBOL: &str = "tl_process_output";
const READ_STDIN_LINE_RUNTIME_SYMBOL: &str = ".L_tl_read_stdin_line";
const READ_STDIN_BYTES_RUNTIME_SYMBOL: &str = ".L_tl_read_stdin_bytes";
const STDIN_EOF_RUNTIME_SYMBOL: &str = ".L_tl_stdin_eof";
const FLUSH_STDOUT_RUNTIME_SYMBOL: &str = ".L_tl_flush_stdout";
const REGION_MARK_RUNTIME_SYMBOL: &str = "tl_region_mark";
const REGION_RESET_RUNTIME_SYMBOL: &str = "tl_region_reset";

const SYSV_INTEGER_ARG_REGS: [&str; 6] = ["%rdi", "%rsi", "%rdx", "%rcx", "%r8", "%r9"];
const SYSV_FLOAT_ARG_REGS: [&str; 8] = [
    "%xmm0", "%xmm1", "%xmm2", "%xmm3", "%xmm4", "%xmm5", "%xmm6", "%xmm7",
];
const WIN64_INTEGER_ARG_REGS: [&str; 4] = ["%rcx", "%rdx", "%r8", "%r9"];
const WIN64_FLOAT_ARG_REGS: [&str; 4] = ["%xmm0", "%xmm1", "%xmm2", "%xmm3"];
const LINUX_LINK_LIBS: [&str; 1] = ["-lc"];
const WINDOWS_LINK_LIBS: [&str; 2] = ["msvcrt.lib", "legacy_stdio_definitions.lib"];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BackendArch {
    X86_64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BackendOs {
    Linux,
    #[allow(dead_code)]
    Windows,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BackendAbi {
    SystemV,
    #[allow(dead_code)]
    WindowsX64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BackendMode {
    Scalar,
    Avx2,
    Avx512,
}

impl BackendMode {
    pub const fn as_str(self) -> &'static str {
        match self {
            BackendMode::Scalar => "scalar",
            BackendMode::Avx2 => "avx2",
            BackendMode::Avx512 => "avx512",
        }
    }

    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "scalar" => Some(BackendMode::Scalar),
            "avx2" => Some(BackendMode::Avx2),
            "avx512" => Some(BackendMode::Avx512),
            _ => None,
        }
    }
}

impl fmt::Display for BackendMode {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// Concrete backend target. Today only Linux x86_64 System V scalar codegen is
/// emitted, but codegen policy is kept explicit so later targets and SIMD modes
/// do not have to rediscover assumptions embedded in instruction selection.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BackendTarget {
    pub arch: BackendArch,
    pub os: BackendOs,
    pub abi: BackendAbi,
    pub mode: BackendMode,
}

impl BackendTarget {
    pub const LINUX_X86_64_SYSTEM_V: Self = Self {
        arch: BackendArch::X86_64,
        os: BackendOs::Linux,
        abi: BackendAbi::SystemV,
        mode: BackendMode::Scalar,
    };
    #[allow(dead_code)]
    pub const WINDOWS_X86_64: Self = Self {
        arch: BackendArch::X86_64,
        os: BackendOs::Windows,
        abi: BackendAbi::WindowsX64,
        mode: BackendMode::Scalar,
    };

    pub const fn linux_x86_64_system_v() -> Self {
        Self::LINUX_X86_64_SYSTEM_V
    }

    #[allow(dead_code)]
    pub const fn windows_x86_64() -> Self {
        Self::WINDOWS_X86_64
    }

    pub const fn with_mode(self, mode: BackendMode) -> Self {
        Self { mode, ..self }
    }

    /// Whether this target provides the `tl_region_mark`/`tl_region_reset`
    /// runtime helpers. They exist only for linux-x86_64 System V today, so on
    /// other targets `(with-region ...)` lowers without a reset (SPEC §7.6).
    pub const fn supports_region_runtime(self) -> bool {
        matches!(
            (self.arch, self.os, self.abi),
            (BackendArch::X86_64, BackendOs::Linux, BackendAbi::SystemV)
        )
    }

    pub const fn as_str(self) -> &'static str {
        match (self.arch, self.os, self.abi) {
            (BackendArch::X86_64, BackendOs::Linux, BackendAbi::SystemV) => "linux-x86_64",
            (BackendArch::X86_64, BackendOs::Windows, BackendAbi::WindowsX64) => "windows-x86_64",
            _ => "unknown",
        }
    }

    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "linux-x86_64" | "linux_x86_64" => Some(Self::linux_x86_64_system_v()),
            "windows-x86_64" | "windows_x86_64" => Some(Self::windows_x86_64()),
            _ => None,
        }
    }

    pub const fn object_extension(self) -> &'static str {
        match self.os {
            BackendOs::Linux => "o",
            BackendOs::Windows => "obj",
        }
    }

    pub const fn executable_extension(self) -> Option<&'static str> {
        match self.os {
            BackendOs::Linux => None,
            BackendOs::Windows => Some("exe"),
        }
    }

    fn validate_mode(self) -> Result<(), String> {
        match self.mode {
            BackendMode::Scalar | BackendMode::Avx2 | BackendMode::Avx512 => Ok(()),
        }
    }

    fn calling_convention(self) -> CallingConvention {
        match (self.arch, self.os, self.abi) {
            (BackendArch::X86_64, BackendOs::Linux, BackendAbi::SystemV) => CallingConvention {
                integer_arg_regs: &SYSV_INTEGER_ARG_REGS,
                float_arg_regs: &SYSV_FLOAT_ARG_REGS,
                shared_arg_register_slots: None,
                incoming_stack_base_offset: 16,
                outgoing_shadow_space: 0,
                outgoing_stack_base_offset: 0,
                stack_arg_size: 8,
                return_gpr: "%rax",
                return_float_reg: "%xmm0",
            },
            (BackendArch::X86_64, BackendOs::Windows, BackendAbi::WindowsX64) => {
                CallingConvention {
                    integer_arg_regs: &WIN64_INTEGER_ARG_REGS,
                    float_arg_regs: &WIN64_FLOAT_ARG_REGS,
                    shared_arg_register_slots: Some(4),
                    incoming_stack_base_offset: 48,
                    outgoing_shadow_space: 32,
                    outgoing_stack_base_offset: 32,
                    stack_arg_size: 8,
                    return_gpr: "%rax",
                    return_float_reg: "%xmm0",
                }
            }
            _ => panic!("unsupported backend target: {:?}", self),
        }
    }

    fn entry_policy(self) -> EntryPolicy {
        match (self.arch, self.os, self.abi) {
            (BackendArch::X86_64, BackendOs::Linux, BackendAbi::SystemV) => EntryPolicy {
                symbol: Some("_start"),
                exit_syscall_number: Some(60),
                exit_status_reg: "%rdi",
            },
            (BackendArch::X86_64, BackendOs::Windows, BackendAbi::WindowsX64) => EntryPolicy {
                symbol: None,
                exit_syscall_number: None,
                exit_status_reg: "%rcx",
            },
            _ => panic!("unsupported backend target: {:?}", self),
        }
    }

    fn runtime_policy(self) -> RuntimePolicy {
        match (self.arch, self.os, self.abi) {
            (BackendArch::X86_64, BackendOs::Linux, BackendAbi::SystemV) => RuntimePolicy {
                emits_linux_syscall_helpers: true,
                emits_windows_runtime_helpers: false,
                uses_libc_print_runtime: true,
            },
            (BackendArch::X86_64, BackendOs::Windows, BackendAbi::WindowsX64) => RuntimePolicy {
                emits_linux_syscall_helpers: false,
                emits_windows_runtime_helpers: true,
                uses_libc_print_runtime: true,
            },
            _ => panic!("unsupported backend target: {:?}", self),
        }
    }

    pub fn toolchain(self) -> BackendToolchain {
        match (self.arch, self.os, self.abi) {
            (BackendArch::X86_64, BackendOs::Linux, BackendAbi::SystemV) => BackendToolchain {
                assembler: "as",
                linker: "ld",
                dynamic_linker: Some("/lib64/ld-linux-x86-64.so.2"),
                libraries: &LINUX_LINK_LIBS,
            },
            (BackendArch::X86_64, BackendOs::Windows, BackendAbi::WindowsX64) => BackendToolchain {
                assembler: "clang",
                linker: "lld-link",
                dynamic_linker: None,
                libraries: &WINDOWS_LINK_LIBS,
            },
            _ => panic!("unsupported backend target: {:?}", self),
        }
    }
}

impl Default for BackendTarget {
    fn default() -> Self {
        Self::linux_x86_64_system_v()
    }
}

impl fmt::Display for BackendTarget {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BackendToolchain {
    pub assembler: &'static str,
    pub linker: &'static str,
    pub dynamic_linker: Option<&'static str>,
    pub libraries: &'static [&'static str],
}

#[derive(Debug, Clone, Copy)]
struct CallingConvention {
    integer_arg_regs: &'static [&'static str],
    float_arg_regs: &'static [&'static str],
    shared_arg_register_slots: Option<usize>,
    incoming_stack_base_offset: i32,
    outgoing_shadow_space: i32,
    outgoing_stack_base_offset: i32,
    stack_arg_size: i32,
    return_gpr: &'static str,
    return_float_reg: &'static str,
}

impl CallingConvention {
    fn incoming_stack_arg_offset(self, stack_arg: i32) -> i32 {
        self.incoming_stack_base_offset + stack_arg * self.stack_arg_size
    }

    fn outgoing_stack_arg_offset(self, stack_arg: i32) -> i32 {
        self.outgoing_stack_base_offset + stack_arg * self.stack_arg_size
    }

    fn outgoing_stack_arg_space(self, stack_arg_count: usize) -> i32 {
        (self.outgoing_shadow_space + (stack_arg_count as i32 * self.stack_arg_size) + 15) & !15
    }
}

#[derive(Debug, Clone, Copy)]
struct EntryPolicy {
    symbol: Option<&'static str>,
    exit_syscall_number: Option<i64>,
    exit_status_reg: &'static str,
}

#[derive(Debug, Clone, Copy)]
struct RuntimePolicy {
    emits_linux_syscall_helpers: bool,
    emits_windows_runtime_helpers: bool,
    uses_libc_print_runtime: bool,
}

/// Backend validation error with optional source provenance. The existing
/// `generate_assembly` API still exposes plain strings for tests and library
/// callers; CLI paths use this richer form to render diagnostics with snippets.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BackendError {
    pub message: String,
    pub span: Option<Span>,
}

impl BackendError {
    fn unspanned(message: impl Into<String>) -> Self {
        BackendError {
            message: message.into(),
            span: None,
        }
    }

    fn at(message: impl Into<String>, span: Option<Span>) -> Self {
        BackendError {
            message: message.into(),
            span,
        }
    }

    pub fn to_diagnostic(&self) -> Option<Diagnostic> {
        self.span
            .map(|span| Diagnostic::error(self.message.clone(), span).with_code("E0300"))
    }
}

impl fmt::Display for BackendError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.message)
    }
}

impl std::error::Error for BackendError {}

/// x86_64 assembly code generator.
pub struct X86_64Backend {
    target: BackendTarget,
    output: String,
    stack_size: i32,
    var_offsets: HashMap<VarId, i32>,
    var_types: HashMap<VarId, Type>,
    global_types: HashMap<String, Type>,
    function_sigs: HashMap<String, (Vec<Type>, Type)>,
    closure_descriptor_names: BTreeSet<String>,
    address_vars: HashSet<VarId>,
    reg_plan: Option<regalloc::RegPlan>,
    callee_saved_offsets: HashMap<&'static str, i32>,
    extern_names: HashSet<String>,
    runtime_print_names: HashSet<String>,
    /// Whether the program references the bump allocator `tl_alloc` and the
    /// backend must therefore emit the self-contained allocator runtime
    /// (tracked mmap arenas + bump pointers) into the program's `.s`.
    needs_alloc_runtime: bool,
    /// Whether the program references the low-level region mark/reset helpers.
    /// These are extern-only runtime hooks layered over the tracked arena
    /// records. Mark reads `tl_current_arena`; reset may unmap newer arenas.
    needs_region_mark_runtime: bool,
    needs_region_reset_runtime: bool,
    /// Whether the backend must emit the raw `tl_alloc` runtime body. This is
    /// true when IR calls resolve to the allocator runtime, or when another
    /// backend runtime helper calls raw `tl_alloc` internally.
    emits_alloc_runtime: bool,
    /// Whether the program references the out-of-bounds abort `tl_oob_abort`
    /// (emitted by array bounds checks) and the backend must emit the
    /// self-contained abort runtime (write to fd 2 + `exit`) into the `.s`.
    needs_oob_runtime: bool,
    /// Whether the program references the division abort `tl_div_abort`
    /// (emitted by guarded integer division/remainder) and the backend must
    /// emit the self-contained abort runtime into the `.s`.
    needs_div_runtime: bool,
    needs_shift_runtime: bool,
    /// Whether the program references the string-equality helper
    /// `tl_string_eq` and the backend must therefore emit the self-contained
    /// (libc-free, syscall-free) byte-comparison runtime into the program's
    /// `.s`. Set when `(string-eq a b)` / `(string=? a b)` is lowered.
    needs_string_eq_runtime: bool,
    /// Whether the program references the decimal-parse helper
    /// `tl_string_to_int` and the backend must therefore emit the self-contained
    /// (libc-free, syscall-free) parse runtime into the program's `.s`. Set when
    /// `(string->int s)` is lowered.
    needs_string_to_int_runtime: bool,
    /// Whether the program references the integer-to-string helper
    /// `tl_int_to_string` and the backend must therefore emit the
    /// self-contained (libc-free) decimal-formatting runtime into the
    /// program's `.s`. Set when `(int->string n)` is lowered. The runtime
    /// itself calls `tl_alloc`, so its presence also forces the bump-allocator
    /// runtime to be emitted.
    needs_int_to_string_runtime: bool,
    /// Whether the program references the substring helper `tl_substring` and
    /// the backend must therefore emit the self-contained (libc-free) byte-slice
    /// runtime into the program's `.s`. Set when `(substring s start len)` /
    /// `(string-slice ...)` is lowered. Like `tl_int_to_string` the runtime
    /// `tl_alloc`s both the slice buffer and the 16-byte fat value, so its
    /// presence also forces the bump-allocator runtime to be emitted.
    needs_substring_runtime: bool,
    /// Whether the program references the concatenation helper `tl_string_concat`
    /// and the backend must therefore emit the self-contained (libc-free)
    /// byte-append runtime into the program's `.s`. Set when `(string-append a b)`
    /// / `(string-concat a b)` is lowered. Like `tl_substring` the runtime
    /// `tl_alloc`s both the joined data buffer and the 16-byte fat value, so its
    /// presence also forces the bump-allocator runtime to be emitted.
    needs_string_concat_runtime: bool,
    /// Whether the program references the message-abort helper `tl_abort` and
    /// the backend must therefore emit the self-contained abort runtime (write
    /// the caller-supplied message to fd 2 + `exit`) into the program's `.s`.
    /// Set when `(panic msg)` / `(error msg)` is lowered. Unlike the fixed-text
    /// `tl_oob_abort`, `tl_abort` takes a `(ptr, len)` message argument.
    needs_abort_runtime: bool,
    /// Whether the program references the print-string helper `tl_print_str` and
    /// the backend must therefore emit the self-contained (libc-free) runtime
    /// that writes a String's bytes to fd 1 (stdout) via a single `write(2)`
    /// syscall. Set when `(print-string s)` / `(print-str s)` is lowered. Like
    /// `tl_abort` it takes a `(ptr, len)` argument, but unlike `tl_abort` it
    /// returns rather than terminating the process.
    needs_print_str_runtime: bool,
    needs_print_err_runtime: bool,
    /// Whether the program references the private argc helper emitted for
    /// `(arg-count)`.
    needs_arg_count_runtime: bool,
    /// Whether the program references the private argv helper emitted for
    /// `(arg i)`. The helper heap-allocates the returned String and aborts on
    /// out-of-bounds indexes.
    needs_arg_runtime: bool,
    /// Whether the program references the private read-file helper emitted for
    /// `(read-file path)`. The helper uses Linux syscalls, `tl_alloc`, and the
    /// panic/abort runtime.
    needs_read_file_runtime: bool,
    /// Whether the program references the private write-file helper emitted for
    /// `(write-file path contents)`. The helper uses Linux syscalls, `tl_alloc`,
    /// and the panic/abort runtime.
    needs_write_file_runtime: bool,
    /// Whether the program references the private file-exists helper emitted for
    /// `(file-exists? path)`. The helper uses Linux syscalls, `tl_alloc`, and the
    /// panic/abort runtime for unexpected errors.
    needs_file_exists_runtime: bool,
    /// Whether the program references raw environment helpers emitted for
    /// stdlib/env.tl. Lookups read process environment data and allocate
    /// returned strings through `tl_alloc`.
    needs_fs_runtime: bool,
    needs_env_var_exists_runtime: bool,
    needs_env_var_value_runtime: bool,
    needs_env_path_separator_runtime: bool,
    /// Whether the program references stdlib/process.tl's backend execution
    /// hook. Linux emits a direct fork/exec/capture helper; Windows returns a
    /// structured unsupported result for this slice.
    needs_process_output_runtime: bool,
    /// Whether the program references stdin helpers. The read helpers allocate
    /// heap Strings and update a backend-owned EOF flag; `stdin-eof?` reads that
    /// flag; `flush-stdout` is a target-specific stdout flush/no-op helper.
    needs_read_stdin_line_runtime: bool,
    needs_read_stdin_bytes_runtime: bool,
    needs_stdin_eof_runtime: bool,
    needs_flush_stdout_runtime: bool,
    return_ty: Type,
    /// VarIds that are function parameters of the function currently being
    /// generated. Their `Alloc` instructions are no-ops because the parameter
    /// stack slot is materialized by the prologue.
    param_vars: HashSet<VarId>,
    /// Mangled symbol name of the function currently being generated. Used to
    /// build the per-block GAS labels (`{fn}.{block}`) that `Branch`/`Jump`
    /// target — the IR carries bare block labels (e.g. `then.0`) which must be
    /// qualified with the function symbol to resolve.
    current_fn: String,
    /// Bare IR entry label of the function currently being generated. Self-tail
    /// calls jump here after rewriting parameter slots, bypassing the prologue.
    current_entry_label: String,
    /// Ordered parameters for the function currently being generated.
    current_params: Vec<(VarId, Type)>,
    /// String-literal bytes interned into `.rodata`, mapped to their emitted
    /// label. A `Value::ConstStr` materializes as the address of its label.
    /// Built in a pre-pass over the program so the bytes are emitted once and
    /// referenced by `leaq`.
    interned_strings: HashMap<String, String>,
}

/// Validate that an IR program only uses constructs the backend can faithfully
/// lower. The backend currently supports scalar arithmetic, unary/binary ops,
/// comparisons, direct calls, `return`, control flow (`if`/`while` via
/// `Branch`/`Jump`/`Phi`) and scalar `let`/`set!` locals (`Alloc`/`Store`/`Load`
/// against a local's stack slot) over integer/bool/char/f64 scalars.
///
/// Constructs that are lowered but NOT yet selected to assembly (f32 values,
/// pointer dereferences through computed addresses and `Global` operands)
/// are rejected here with a clear message instead of being silently
/// miscompiled (they would otherwise fall through to a `# TODO` comment and
/// produce wrong code).
#[allow(dead_code)]
pub fn validate_program(program: &Program) -> Result<(), String> {
    validate_program_for_target(program, BackendTarget::default())
}

fn validate_program_for_target(program: &Program, target: BackendTarget) -> Result<(), String> {
    if program.functions.is_empty() {
        return Err("backend: program defines no functions to compile".into());
    }
    let global_types: HashMap<String, Type> = program
        .globals
        .iter()
        .map(|(name, ty, _)| (name.clone(), ty.clone()))
        .collect();
    for (name, ty, init) in &program.globals {
        validate_global(name, ty, init.as_ref())?;
    }
    for (name, ty) in &program.externs {
        validate_extern(name, ty)?;
    }
    for func in &program.functions {
        validate_function(func, &global_types, target.mode)?;
    }
    Ok(())
}

fn unsupported_function_message(func_name: &str, what: &str) -> String {
    format!(
        "backend: function '{}' uses an unsupported construct ({}). \
         The x86_64 backend currently supports scalar arithmetic, comparisons, \
         unary/binary operators, direct function calls, recursion, control flow \
         (if/while), indirect calls through function-pointer values and scalar \
         let/set! locals. F32 values and by-value tuple/fixed-array ABI are \
         not yet wired.",
        func_name, what
    )
}

fn validate_program_source_spans(
    program: &Program,
    source_spans: &SourceSpans,
    target: BackendTarget,
) -> Result<(), BackendError> {
    for func in &program.functions {
        let span = source_spans.functions.get(&func.name).copied();
        if !is_backend_abi_value_type(&func.ret) {
            return Err(BackendError::at(
                unsupported_function_message(&func.name, &format!("return type {}", func.ret)),
                span,
            ));
        }
        for (var, ty) in &func.params {
            if !is_backend_abi_value_type(ty) {
                return Err(BackendError::at(
                    unsupported_function_message(
                        &func.name,
                        &format!("parameter %{} has type {}", var, ty),
                    ),
                    span,
                ));
            }
        }
        for (var, ty) in &func.locals {
            if !is_backend_local_type_for_mode(ty, target.mode) {
                return Err(BackendError::at(
                    unsupported_function_message(
                        &func.name,
                        &format!("local %{} has type {}", var, ty),
                    ),
                    span,
                ));
            }
        }
    }
    Ok(())
}

fn validate_global(name: &str, ty: &Type, init: Option<&Value>) -> Result<(), String> {
    if !is_global_data_type(ty) {
        return Err(format!(
            "backend: global '{}' has unsupported type {}. \
             The x86_64 backend currently supports scalar integer, bool, char, f64, f32, \
             unit, and pointer-sized String, enum, struct, and dynamic-array globals.",
            name, ty
        ));
    }

    if let Some(init) = init {
        if global_initializer_matches_type(init, ty) {
            Ok(())
        } else {
            Err(format!(
                "backend: global '{}' has unsupported initializer {:?} for type {}",
                name, init, ty
            ))
        }
    } else {
        // Non-constant initializer: the global is zero-initialized in .bss
        // and a __global_init_<name> function computes and stores the value
        // at startup before main.
        Ok(())
    }
}

fn validate_extern(name: &str, ty: &Type) -> Result<(), String> {
    let Type::Func(args, ret) = ty else {
        return Err(format!(
            "backend: extern '{}' has unsupported type {}. \
             Extern declarations must use function types.",
            name, ty
        ));
    };

    for arg in args {
        if !is_backend_abi_value_type(arg) {
            return Err(format!(
                "backend: extern '{}' has unsupported argument type {}. \
                 The x86_64 backend cannot lower that ABI yet.",
                name, arg
            ));
        }
    }
    if !is_backend_abi_value_type(ret) {
        return Err(format!(
            "backend: extern '{}' has unsupported return type {}. \
             The x86_64 backend cannot lower that ABI yet.",
            name, ret
        ));
    }

    Ok(())
}

fn validate_function(
    func: &Function,
    global_types: &HashMap<String, Type>,
    mode: BackendMode,
) -> Result<(), String> {
    let var_types: HashMap<VarId, Type> = func
        .params
        .iter()
        .chain(func.locals.iter())
        .map(|(var, ty)| (*var, ty.clone()))
        .collect();

    let unsupported = |what: &str| Err(unsupported_function_message(&func.name, what));

    if !is_backend_abi_value_type(&func.ret) {
        return unsupported(&format!("return type {}", func.ret));
    }
    for (var, ty) in &func.params {
        if !is_backend_abi_value_type(ty) {
            return unsupported(&format!("parameter %{} has type {}", var, ty));
        }
    }
    for (var, ty) in &func.locals {
        if !is_backend_local_type_for_mode(ty, mode) {
            return unsupported(&format!("local %{} has type {}", var, ty));
        }
    }

    for block in &func.blocks {
        for instr in &block.instructions {
            match instr {
                // Fully supported scalar instructions.
                Instruction::BinOp {
                    op, lhs, rhs, ty, ..
                } => {
                    check_operand(lhs, global_types)
                        .map_err(|w| unsupported_value(&func.name, &w))?;
                    check_operand(rhs, global_types)
                        .map_err(|w| unsupported_value(&func.name, &w))?;
                    let lhs_ty = validate_value_type(lhs, &var_types, global_types)
                        .unwrap_or_else(|| ty.clone());
                    let rhs_ty = validate_value_type(rhs, &var_types, global_types)
                        .unwrap_or_else(|| ty.clone());
                    if (lhs_ty.is_float() || rhs_ty.is_float() || ty.is_float())
                        && matches!(
                            *op,
                            IrBinOp::Mod
                                | IrBinOp::And
                                | IrBinOp::Or
                                | IrBinOp::BitAnd
                                | IrBinOp::BitOr
                                | IrBinOp::BitXor
                                | IrBinOp::Shl
                                | IrBinOp::Shr
                        )
                    {
                        return unsupported("unsupported float binary operator");
                    }
                }
                Instruction::UnOp { op, src, ty, .. } => {
                    check_operand(src, global_types)
                        .map_err(|w| unsupported_value(&func.name, &w))?;
                    let src_ty = validate_value_type(src, &var_types, global_types)
                        .unwrap_or_else(|| ty.clone());
                    if src_ty.is_float() && matches!(*op, IrUnOp::Not | IrUnOp::BitNot) {
                        return unsupported("unsupported float unary operator");
                    }
                }
                Instruction::Mov { src, ty, .. } => {
                    if *ty == Type::Unit {
                        validate_unit_value(src, &var_types, global_types)
                            .map_err(|w| unsupported_value(&func.name, &w))?;
                    } else {
                        check_operand(src, global_types)
                            .map_err(|w| unsupported_value(&func.name, &w))?;
                    }
                }
                Instruction::Cast {
                    src,
                    from_ty,
                    to_ty,
                    ..
                } => {
                    check_operand(src, global_types)
                        .map_err(|w| unsupported_value(&func.name, &w))?;
                    // `f64 <-> f32` precision conversions are supported. Any
                    // other cast touching a float (int <-> float) is not.
                    let float_to_float = from_ty.is_float() && to_ty.is_float();
                    if (from_ty.is_float() || to_ty.is_float()) && !float_to_float {
                        return unsupported("floating-point cast");
                    }
                }
                Instruction::Call { args, .. } => {
                    for arg in args {
                        check_operand(arg, global_types)
                            .map_err(|w| unsupported_value(&func.name, &w))?;
                    }
                }
                Instruction::TailCall {
                    func: target,
                    args,
                    ty,
                } => {
                    validate_tail_call(func, target, args, ty, &var_types, global_types)
                        .map_err(|w| unsupported_function_message(&func.name, &w))?;
                }
                Instruction::Return(Some(v)) => {
                    if func.ret == Type::Unit {
                        validate_unit_value(v, &var_types, global_types)
                            .map_err(|w| unsupported_value(&func.name, &w))?;
                    } else {
                        check_operand(v, global_types)
                            .map_err(|w| unsupported_value(&func.name, &w))?;
                    }
                }
                Instruction::Return(None) => {
                    if func.ret != Type::Unit {
                        return unsupported("missing return value for non-unit function");
                    }
                }
                Instruction::Jump(_) => {}
                // `if`/`while` control flow — now codegen'd.
                Instruction::Branch { cond, .. } => {
                    check_operand(cond, global_types)
                        .map_err(|w| unsupported_value(&func.name, &w))?;
                }
                // `if` result selection — eliminated to predecessor copies before
                // codegen (see `eliminate_phis`).
                Instruction::Phi { incoming, ty, .. } => {
                    for (val, _) in incoming {
                        if *ty == Type::Unit {
                            validate_unit_value(val, &var_types, global_types)
                                .map_err(|w| unsupported_value(&func.name, &w))?;
                        } else {
                            check_operand(val, global_types)
                                .map_err(|w| unsupported_value(&func.name, &w))?;
                        }
                    }
                }
                // `let`/`set!` scalar locals/globals and pointer values
                // materialized by AddrOf/Gep.
                Instruction::Alloc { .. } => {}
                Instruction::Load { src, ty, .. } => {
                    match src {
                        Value::Var(_) => {}
                        _ => return unsupported("load through a non-local address"),
                    }
                    if *ty == Type::Unit {
                        validate_unit_value(src, &var_types, global_types)
                            .map_err(|w| unsupported_value(&func.name, &w))?;
                    } else {
                        check_operand(src, global_types)
                            .map_err(|w| unsupported_value(&func.name, &w))?;
                    }
                }
                Instruction::Store { dst, src, ty } => {
                    match dst {
                        Value::Var(_) => {}
                        Value::Global(name) => match global_types.get(name) {
                            Some(global_ty) if global_ty == ty && is_loadable_global_type(ty) => {}
                            Some(global_ty) => {
                                return unsupported(&format!(
                                    "store to global '{}' of type {} using {}",
                                    name, global_ty, ty
                                ));
                            }
                            None => {
                                return unsupported(&format!("store to unknown global '{}'", name));
                            }
                        },
                        _ => return unsupported("store through a non-local address"),
                    }
                    if *ty == Type::Unit {
                        validate_unit_value(src, &var_types, global_types)
                            .map_err(|w| unsupported_value(&func.name, &w))?;
                    } else {
                        check_operand(src, global_types)
                            .map_err(|w| unsupported_value(&func.name, &w))?;
                    }
                }
                Instruction::CallIndirect {
                    func: target, args, ..
                } => {
                    match target {
                        Value::Var(var) => {
                            if !matches!(var_types.get(var), Some(Type::Func(_, _))) {
                                return unsupported("indirect call through a non-function value");
                            }
                        }
                        Value::Function(_) => {}
                        _ => return unsupported("indirect call through a non-local value"),
                    }
                    for arg in args {
                        check_operand(arg, global_types)
                            .map_err(|w| unsupported_value(&func.name, &w))?;
                    }
                }
                Instruction::AddrOf { dst, src } => {
                    if !var_types.contains_key(src) {
                        return unsupported("address-of unknown local");
                    }
                    let Some(dst_ty) = var_types.get(dst) else {
                        return unsupported("address-of destination has no stack slot");
                    };
                    if !is_pointer_sized_type(dst_ty) {
                        return unsupported("address-of destination is not pointer-sized");
                    }
                }
                Instruction::Gep {
                    dst,
                    base,
                    offset,
                    elem_ty,
                } => {
                    let Some(dst_ty) = var_types.get(dst) else {
                        return unsupported("gep destination has no stack slot");
                    };
                    if !is_pointer_sized_type(dst_ty) {
                        return unsupported("gep destination is not pointer-sized");
                    }
                    let Some(base_ty) = validate_value_type(base, &var_types, global_types) else {
                        return unsupported("gep base has unknown type");
                    };
                    if !is_pointer_sized_type(&base_ty) {
                        return unsupported("gep base is not pointer-sized");
                    }
                    let Some(offset_ty) = validate_value_type(offset, &var_types, global_types)
                    else {
                        return unsupported("gep offset has unknown type");
                    };
                    if !offset_ty.is_integer() {
                        return unsupported("gep offset is not an integer");
                    }
                    if !is_sized_backend_type(elem_ty) {
                        return unsupported("gep element type has unsupported size");
                    }
                    check_operand(base, global_types)
                        .map_err(|w| unsupported_value(&func.name, &w))?;
                    check_operand(offset, global_types)
                        .map_err(|w| unsupported_value(&func.name, &w))?;
                }
                Instruction::VectorBinOp {
                    dst,
                    op,
                    lhs,
                    rhs,
                    lanes,
                    elem_ty,
                } => {
                    if mode != BackendMode::Avx2 && mode != BackendMode::Avx512 {
                        return unsupported("vector/mask IR requires a SIMD backend target");
                    }
                    if let Err(what) = validate_vector_binop(
                        *dst,
                        *op,
                        lhs,
                        rhs,
                        *lanes,
                        elem_ty,
                        mode,
                        ValidationTypes {
                            var_types: &var_types,
                            global_types,
                        },
                    ) {
                        return unsupported(&what);
                    }
                }
                Instruction::VectorReduce {
                    dst,
                    op,
                    src,
                    lanes,
                    elem_ty,
                } => {
                    if mode == BackendMode::Scalar {
                        return unsupported("vector/mask IR requires a SIMD backend target");
                    }
                    if mode != BackendMode::Avx2 {
                        return unsupported("vector reduce IR requires the AVX2 backend target");
                    }
                    if let Err(what) = validate_vector_reduce(
                        *dst,
                        *op,
                        src,
                        *lanes,
                        elem_ty,
                        ValidationTypes {
                            var_types: &var_types,
                            global_types,
                        },
                    ) {
                        return unsupported(&what);
                    }
                }
                Instruction::VectorLoad {
                    dst,
                    base,
                    index,
                    lanes,
                    elem_ty,
                } => {
                    if mode != BackendMode::Avx2 && mode != BackendMode::Avx512 {
                        return unsupported("vector/mask IR requires a SIMD backend target");
                    }
                    if let Err(what) = validate_vector_load(
                        *dst,
                        base,
                        index,
                        *lanes,
                        elem_ty,
                        mode,
                        &var_types,
                        global_types,
                    ) {
                        return unsupported(&what);
                    }
                }
                Instruction::VectorStore {
                    base,
                    index,
                    value,
                    lanes,
                    elem_ty,
                } => {
                    if mode != BackendMode::Avx2 && mode != BackendMode::Avx512 {
                        return unsupported("vector/mask IR requires a SIMD backend target");
                    }
                    if let Err(what) = validate_vector_store(
                        base,
                        index,
                        value,
                        *lanes,
                        elem_ty,
                        mode,
                        &var_types,
                        global_types,
                    ) {
                        return unsupported(&what);
                    }
                }
                Instruction::PredicatedStore {
                    base,
                    index,
                    value,
                    mask,
                    lanes,
                    elem_ty,
                } => {
                    if mode != BackendMode::Avx512 {
                        return unsupported(
                            "predicated vector memory IR requires the AVX-512 backend target",
                        );
                    }
                    if let Err(what) = validate_predicated_store(
                        base,
                        index,
                        value,
                        mask,
                        *lanes,
                        elem_ty,
                        mode,
                        &var_types,
                        global_types,
                    ) {
                        return unsupported(&what);
                    }
                }
                Instruction::PredicatedLoad {
                    dst,
                    base,
                    index,
                    mask,
                    lanes,
                    elem_ty,
                } => {
                    if mode != BackendMode::Avx512 {
                        return unsupported(
                            "predicated vector memory IR requires the AVX-512 backend target",
                        );
                    }
                    if let Err(what) = validate_predicated_load(
                        *dst,
                        base,
                        index,
                        mask,
                        *lanes,
                        elem_ty,
                        mode,
                        &var_types,
                        global_types,
                    ) {
                        return unsupported(&what);
                    }
                }
                Instruction::TailMask {
                    dst,
                    index,
                    len,
                    lanes,
                } => {
                    if mode != BackendMode::Avx512 {
                        return unsupported("tail-mask IR requires the AVX-512 backend target");
                    }
                    if let Err(what) =
                        validate_tail_mask(*dst, index, len, *lanes, &var_types, global_types)
                    {
                        return unsupported(&what);
                    }
                }
                Instruction::LaneId { .. }
                | Instruction::Splat { .. }
                | Instruction::VectorCompare { .. }
                | Instruction::MaskBinOp { .. }
                | Instruction::MaskNot { .. }
                | Instruction::MaskReduce { .. }
                | Instruction::Select { .. } => {
                    if mode == BackendMode::Avx2 || mode == BackendMode::Avx512 {
                        return unsupported("unsupported vector/mask IR for this backend mode");
                    }
                    return unsupported("vector/mask IR requires a SIMD backend target");
                }
            }
        }
    }
    Ok(())
}

fn validate_tail_call(
    current: &Function,
    target: &str,
    args: &[Value],
    ty: &Type,
    var_types: &HashMap<VarId, Type>,
    global_types: &HashMap<String, Type>,
) -> Result<(), String> {
    if target != current.name {
        return Err(format!(
            "tail call target '{}' is not the current function '{}'",
            target, current.name
        ));
    }
    if ty != &current.ret {
        return Err(format!(
            "tail call result type {} does not match return type {}",
            ty, current.ret
        ));
    }
    if args.len() != current.params.len() {
        return Err(format!(
            "tail call to '{}' has {} args but function has {} params",
            target,
            args.len(),
            current.params.len()
        ));
    }

    for ((param_var, param_ty), arg) in current.params.iter().zip(args.iter()) {
        if *param_ty == Type::Unit {
            validate_unit_value(arg, var_types, global_types).map_err(|err| {
                format!(
                    "tail call argument for unit parameter %{}: {}",
                    param_var, err
                )
            })?;
            continue;
        }

        check_operand(arg, global_types)
            .map_err(|err| format!("tail call argument for parameter %{}: {}", param_var, err))?;
        if !tail_call_arg_matches_param(arg, param_ty, var_types, global_types) {
            let actual = validate_value_type(arg, var_types, global_types)
                .map_or_else(|| "unknown".to_string(), |ty| ty.to_string());
            return Err(format!(
                "tail call argument for parameter %{} has type {}, expected {}",
                param_var, actual, param_ty
            ));
        }
    }

    Ok(())
}

fn tail_call_arg_matches_param(
    arg: &Value,
    param_ty: &Type,
    var_types: &HashMap<VarId, Type>,
    global_types: &HashMap<String, Type>,
) -> bool {
    match (
        arg,
        param_ty,
        validate_value_type(arg, var_types, global_types),
    ) {
        (_, expected, Some(actual)) if &actual == expected => true,
        (Value::Function(_), Type::Func(_, _), _) => true,
        (Value::ConstI64(_) | Value::ConstI32(_) | Value::ConstI8(_), ty, _)
            if ty.is_integer() || matches!(ty, Type::Char) =>
        {
            true
        }
        _ => false,
    }
}

#[derive(Clone, Copy)]
struct ValidationTypes<'a> {
    var_types: &'a HashMap<VarId, Type>,
    global_types: &'a HashMap<String, Type>,
}

#[allow(clippy::too_many_arguments)]
fn validate_vector_binop(
    dst: VarId,
    op: IrBinOp,
    lhs: &Value,
    rhs: &Value,
    lanes: usize,
    elem_ty: &Type,
    mode: BackendMode,
    types: ValidationTypes<'_>,
) -> Result<(), String> {
    validate_vector_shape(elem_ty, lanes, mode)?;
    if op != IrBinOp::Add {
        return Err(format!(
            "{:?} vector operator {:?} is not implemented",
            mode, op
        ));
    }
    validate_vector_var(
        dst,
        elem_ty,
        lanes,
        types.var_types,
        "vector binop destination",
    )?;
    validate_vector_value(
        lhs,
        elem_ty,
        lanes,
        types.var_types,
        types.global_types,
        "vector binop lhs",
    )?;
    validate_vector_value(
        rhs,
        elem_ty,
        lanes,
        types.var_types,
        types.global_types,
        "vector binop rhs",
    )?;
    Ok(())
}

fn validate_vector_reduce(
    dst: VarId,
    op: VectorReduceOp,
    src: &Value,
    lanes: usize,
    elem_ty: &Type,
    types: ValidationTypes<'_>,
) -> Result<(), String> {
    validate_vector_shape(elem_ty, lanes, BackendMode::Avx2)?;
    if op != VectorReduceOp::Sum {
        return Err(format!("AVX2 vector reduction {:?} is not implemented", op));
    }
    if !matches!(elem_ty, Type::I64 | Type::I32) {
        return Err(format!(
            "AVX2 vector sum reduction over {} is not implemented",
            elem_ty
        ));
    }
    match types.var_types.get(&dst) {
        Some(ty) if ty == elem_ty => {}
        Some(ty) => {
            return Err(format!(
                "vector reduce destination %{} has type {}, expected {}",
                dst, ty, elem_ty
            ));
        }
        None => {
            return Err(format!(
                "vector reduce destination %{} has no recorded type",
                dst
            ));
        }
    }
    validate_vector_value(
        src,
        elem_ty,
        lanes,
        types.var_types,
        types.global_types,
        "vector reduce source",
    )?;
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn validate_vector_load(
    dst: VarId,
    base: &Value,
    index: &Value,
    lanes: usize,
    elem_ty: &Type,
    mode: BackendMode,
    var_types: &HashMap<VarId, Type>,
    global_types: &HashMap<String, Type>,
) -> Result<(), String> {
    validate_vector_shape(elem_ty, lanes, mode)?;
    validate_vector_var(dst, elem_ty, lanes, var_types, "vector load destination")?;
    validate_dyn_array_base(base, elem_ty, var_types, global_types, "vector load base")?;
    validate_integer_index(index, var_types, global_types, "vector load index")?;
    check_operand(base, global_types)?;
    check_operand(index, global_types)?;
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn validate_vector_store(
    base: &Value,
    index: &Value,
    value: &Value,
    lanes: usize,
    elem_ty: &Type,
    mode: BackendMode,
    var_types: &HashMap<VarId, Type>,
    global_types: &HashMap<String, Type>,
) -> Result<(), String> {
    validate_vector_shape(elem_ty, lanes, mode)?;
    validate_dyn_array_base(base, elem_ty, var_types, global_types, "vector store base")?;
    validate_integer_index(index, var_types, global_types, "vector store index")?;
    validate_vector_value(
        value,
        elem_ty,
        lanes,
        var_types,
        global_types,
        "vector store value",
    )?;
    check_operand(base, global_types)?;
    check_operand(index, global_types)?;
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn validate_predicated_store(
    base: &Value,
    index: &Value,
    value: &Value,
    mask: &Value,
    lanes: usize,
    elem_ty: &Type,
    mode: BackendMode,
    var_types: &HashMap<VarId, Type>,
    global_types: &HashMap<String, Type>,
) -> Result<(), String> {
    validate_vector_shape(elem_ty, lanes, mode)?;
    validate_dyn_array_base(
        base,
        elem_ty,
        var_types,
        global_types,
        "predicated store base",
    )?;
    validate_integer_index(index, var_types, global_types, "predicated store index")?;
    validate_vector_value(
        value,
        elem_ty,
        lanes,
        var_types,
        global_types,
        "predicated store value",
    )?;
    validate_mask_value(
        mask,
        lanes,
        var_types,
        global_types,
        "predicated store mask",
    )?;
    check_operand(base, global_types)?;
    check_operand(index, global_types)?;
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn validate_predicated_load(
    dst: VarId,
    base: &Value,
    index: &Value,
    mask: &Value,
    lanes: usize,
    elem_ty: &Type,
    mode: BackendMode,
    var_types: &HashMap<VarId, Type>,
    global_types: &HashMap<String, Type>,
) -> Result<(), String> {
    validate_vector_shape(elem_ty, lanes, mode)?;
    validate_vector_var(
        dst,
        elem_ty,
        lanes,
        var_types,
        "predicated load destination",
    )?;
    validate_dyn_array_base(
        base,
        elem_ty,
        var_types,
        global_types,
        "predicated load base",
    )?;
    validate_integer_index(index, var_types, global_types, "predicated load index")?;
    validate_mask_value(mask, lanes, var_types, global_types, "predicated load mask")?;
    check_operand(base, global_types)?;
    check_operand(index, global_types)?;
    Ok(())
}

fn validate_tail_mask(
    dst: VarId,
    index: &Value,
    len: &Value,
    lanes: usize,
    var_types: &HashMap<VarId, Type>,
    global_types: &HashMap<String, Type>,
) -> Result<(), String> {
    validate_mask_lanes(lanes)?;
    validate_mask_var(dst, lanes, var_types, "tail mask destination")?;
    validate_integer_index(index, var_types, global_types, "tail mask index")?;
    validate_integer_index(len, var_types, global_types, "tail mask length")?;
    check_operand(index, global_types)?;
    check_operand(len, global_types)?;
    Ok(())
}

/// AVX-512 lane masks are valid for the supported vector shapes only.
fn validate_mask_lanes(lanes: usize) -> Result<(), String> {
    match lanes {
        8 | 16 => Ok(()),
        _ => Err(format!("unsupported AVX-512 mask lane count {}", lanes)),
    }
}

fn validate_mask_var(
    var: VarId,
    lanes: usize,
    var_types: &HashMap<VarId, Type>,
    role: &str,
) -> Result<(), String> {
    let expected = Type::Mask(lanes);
    match var_types.get(&var) {
        Some(ty) if *ty == expected => Ok(()),
        Some(ty) => Err(format!(
            "{role} %{} has type {}, expected {}",
            var, ty, expected
        )),
        None => Err(format!("{role} %{} has no recorded type", var)),
    }
}

fn validate_mask_value(
    value: &Value,
    lanes: usize,
    var_types: &HashMap<VarId, Type>,
    global_types: &HashMap<String, Type>,
    role: &str,
) -> Result<(), String> {
    let expected = Type::Mask(lanes);
    match validate_value_type(value, var_types, global_types) {
        Some(ty) if ty == expected => Ok(()),
        Some(ty) => Err(format!("{role} has type {}, expected {}", ty, expected)),
        None => Err(format!("{role} has unknown type")),
    }
}

fn validate_vector_shape(elem_ty: &Type, lanes: usize, mode: BackendMode) -> Result<(), String> {
    match mode {
        BackendMode::Avx2 => match (elem_ty, lanes) {
            (Type::I64 | Type::U64 | Type::F64, 4) | (Type::I32 | Type::U32, 8) => Ok(()),
            _ => Err(format!(
                "unsupported AVX2 vector shape {} x {}",
                lanes, elem_ty
            )),
        },
        BackendMode::Avx512 => match (elem_ty, lanes) {
            (Type::I64 | Type::U64 | Type::F64, 8) | (Type::I32 | Type::U32, 16) => Ok(()),
            _ => Err(format!(
                "unsupported AVX-512 vector shape {} x {}",
                lanes, elem_ty
            )),
        },
        _ => Err(format!(
            "unsupported backend mode {:?} for vector shape {} x {}",
            mode, lanes, elem_ty
        )),
    }
}

fn validate_vector_var(
    var: VarId,
    elem_ty: &Type,
    lanes: usize,
    var_types: &HashMap<VarId, Type>,
    role: &str,
) -> Result<(), String> {
    let expected = Type::Vector(Box::new(elem_ty.clone()), lanes);
    match var_types.get(&var) {
        Some(ty) if *ty == expected => Ok(()),
        Some(ty) => Err(format!(
            "{role} %{} has type {}, expected {}",
            var, ty, expected
        )),
        None => Err(format!("{role} %{} has no recorded type", var)),
    }
}

fn validate_vector_value(
    value: &Value,
    elem_ty: &Type,
    lanes: usize,
    var_types: &HashMap<VarId, Type>,
    global_types: &HashMap<String, Type>,
    role: &str,
) -> Result<(), String> {
    let expected = Type::Vector(Box::new(elem_ty.clone()), lanes);
    match validate_value_type(value, var_types, global_types) {
        Some(ty) if ty == expected => Ok(()),
        Some(ty) => Err(format!("{role} has type {}, expected {}", ty, expected)),
        None => Err(format!("{role} has unknown type")),
    }
}

fn validate_dyn_array_base(
    value: &Value,
    elem_ty: &Type,
    var_types: &HashMap<VarId, Type>,
    global_types: &HashMap<String, Type>,
    role: &str,
) -> Result<(), String> {
    match validate_value_type(value, var_types, global_types) {
        Some(Type::DynArray(elem)) if *elem == *elem_ty => Ok(()),
        Some(ty) => Err(format!(
            "{role} has type {}, expected (Array {})",
            ty, elem_ty
        )),
        None => Err(format!("{role} has unknown type")),
    }
}

fn validate_integer_index(
    value: &Value,
    var_types: &HashMap<VarId, Type>,
    global_types: &HashMap<String, Type>,
    role: &str,
) -> Result<(), String> {
    match validate_value_type(value, var_types, global_types) {
        Some(ty) if ty.is_integer() => Ok(()),
        Some(ty) => Err(format!("{role} has type {}, expected integer", ty)),
        None => Err(format!("{role} has unknown type")),
    }
}

/// Reject operand kinds the code generator cannot materialize.
fn check_operand(val: &Value, global_types: &HashMap<String, Type>) -> Result<(), String> {
    match val {
        Value::ConstI64(_)
        | Value::ConstI32(_)
        | Value::ConstI8(_)
        | Value::ConstF64(_)
        | Value::ConstBool(_)
        | Value::ConstStr(_)
        | Value::Function(_)
        | Value::FunctionEntry(_)
        | Value::Var(_) => Ok(()),
        Value::ConstUnit => Err("unit value".into()),
        Value::Global(name) => match global_types.get(name) {
            Some(ty) if is_loadable_global_type(ty) => Ok(()),
            Some(ty) => Err(format!("global '{}' has unsupported type {}", name, ty)),
            None => Err(format!("global/unresolved reference '{}'", name)),
        },
    }
}

fn validate_value_type(
    val: &Value,
    var_types: &HashMap<VarId, Type>,
    global_types: &HashMap<String, Type>,
) -> Option<Type> {
    match val {
        Value::ConstI64(_) => Some(Type::I64),
        Value::ConstI32(_) => Some(Type::I32),
        Value::ConstI8(_) => Some(Type::I8),
        Value::ConstF64(_) => Some(Type::F64),
        Value::ConstBool(_) => Some(Type::Bool),
        Value::ConstUnit => Some(Type::Unit),
        // A `ConstStr` operand is the raw data pointer of a string literal.
        Value::ConstStr(_) => Some(Type::U64),
        Value::Function(_) | Value::FunctionEntry(_) => Some(Type::U64),
        Value::Var(var) => var_types.get(var).cloned(),
        Value::Global(name) => global_types.get(name).cloned(),
    }
}

fn validate_unit_value(
    val: &Value,
    var_types: &HashMap<VarId, Type>,
    global_types: &HashMap<String, Type>,
) -> Result<(), String> {
    match validate_value_type(val, var_types, global_types) {
        Some(Type::Unit) => Ok(()),
        Some(ty) => Err(format!("unit-typed value expected, got {}", ty)),
        None => Err("unit-typed value has unknown type".into()),
    }
}

fn is_pointer_sized_type(ty: &Type) -> bool {
    // An enum value is a pointer to its inline tagged storage; a struct or tuple
    // is a pointer to inline field storage; a string and a dynamic array are
    // pointers to their inline `{ptr,len}` storage. All are pointer-sized like
    // I64/U64/closure descriptor pointers.
    matches!(
        ty,
        Type::I64
            | Type::U64
            | Type::Func(_, _)
            | Type::Enum(_)
            | Type::Struct(_)
            | Type::Tuple(_)
            | Type::String
            | Type::DynArray(_)
    )
}

fn is_backend_abi_value_type(ty: &Type) -> bool {
    matches!(
        ty,
        Type::I64
            | Type::U64
            | Type::I32
            | Type::U32
            | Type::I16
            | Type::U16
            | Type::I8
            | Type::U8
            | Type::Bool
            | Type::Char
            | Type::F64
            | Type::F32
            | Type::String
            | Type::Unit
            | Type::Func(_, _)
            | Type::DynArray(_)
            | Type::Enum(_)
            | Type::Struct(_)
    )
}

fn is_backend_local_type_for_mode(ty: &Type, mode: BackendMode) -> bool {
    if mode == BackendMode::Avx2 && is_avx2_vector_local_type(ty) {
        return true;
    }
    if mode == BackendMode::Avx512 && is_avx512_vector_local_type(ty) {
        return true;
    }
    if mode == BackendMode::Avx512 && is_avx512_mask_local_type(ty) {
        return true;
    }
    *ty == Type::Unit || is_sized_backend_type(ty)
}

fn is_avx2_vector_local_type(ty: &Type) -> bool {
    match ty {
        Type::Vector(elem, lanes) => {
            matches!(
                (&**elem, *lanes),
                (Type::I64 | Type::U64 | Type::F64, 4) | (Type::I32 | Type::U32, 8)
            )
        }
        _ => false,
    }
}

fn is_avx512_vector_local_type(ty: &Type) -> bool {
    match ty {
        Type::Vector(elem, lanes) => {
            matches!(
                (&**elem, *lanes),
                (Type::I64 | Type::U64 | Type::F64, 8) | (Type::I32 | Type::U32, 16)
            )
        }
        _ => false,
    }
}

/// Lane masks live in their own stack slot as a small integer bitmask that is
/// loaded into a `k` register on demand. The lane counts mirror the supported
/// AVX-512 vector shapes (8 x 64-bit, 16 x 32-bit).
fn is_avx512_mask_local_type(ty: &Type) -> bool {
    matches!(ty, Type::Mask(8) | Type::Mask(16))
}

/// Whether `ty` is a scalar floating-point type the backend codegens in XMM
/// registers (`f32`/`f64`).
fn is_scalar_float(ty: &Type) -> bool {
    matches!(ty, Type::F32 | Type::F64)
}

/// Scalar XMM move mnemonic for a float type: `movss` for `f32` (4 bytes),
/// `movsd` for `f64` (8 bytes).
fn scalar_float_move(ty: &Type) -> &'static str {
    match ty {
        Type::F32 => "movss",
        _ => "movsd",
    }
}

/// Single-precision (`f32`) vs double-precision (`f64`) arithmetic mnemonic.
fn scalar_float_arith(op: &IrBinOp, ty: &Type) -> &'static str {
    let single = matches!(ty, Type::F32);
    match (op, single) {
        (IrBinOp::Add, false) => "addsd",
        (IrBinOp::Add, true) => "addss",
        (IrBinOp::Sub, false) => "subsd",
        (IrBinOp::Sub, true) => "subss",
        (IrBinOp::Mul, false) => "mulsd",
        (IrBinOp::Mul, true) => "mulss",
        (IrBinOp::Div, false) => "divsd",
        (IrBinOp::Div, true) => "divss",
        _ => "addsd",
    }
}

/// Ordered/unordered scalar float compare mnemonic: `ucomiss` for `f32`,
/// `ucomisd` for `f64`. Both share the same EFLAGS semantics, so the `setcc`
/// selection is identical across widths.
fn scalar_float_compare(ty: &Type) -> &'static str {
    match ty {
        Type::F32 => "ucomiss",
        _ => "ucomisd",
    }
}

fn is_sized_backend_type(ty: &Type) -> bool {
    match ty {
        Type::Vector(_, _) | Type::Mask(_) | Type::Var(_) | Type::Unit | Type::Never => false,
        Type::Tuple(elems) => elems.iter().all(is_sized_backend_type) && ty.size() > 0,
        Type::Array(elem, len) => *len > 0 && is_sized_backend_type(elem),
        _ => true,
    }
}

fn is_global_data_type(ty: &Type) -> bool {
    matches!(
        ty,
        Type::I64
            | Type::U64
            | Type::I32
            | Type::U32
            | Type::I16
            | Type::U16
            | Type::I8
            | Type::U8
            | Type::Bool
            | Type::Char
            | Type::F64
            | Type::F32
            | Type::Unit
            | Type::String
            | Type::DynArray(_)
            | Type::Enum(_)
            | Type::Struct(_)
    )
}

fn is_loadable_global_type(ty: &Type) -> bool {
    is_global_data_type(ty) && *ty != Type::Unit
}

fn global_initializer_matches_type(value: &Value, ty: &Type) -> bool {
    let integer_initializer = matches!(
        value,
        Value::ConstI64(_) | Value::ConstI32(_) | Value::ConstI8(_)
    );
    matches!(
        (value, ty),
        (Value::ConstBool(_), Type::Bool)
            | (Value::ConstF64(_), Type::F64)
            | (Value::ConstF64(_), Type::F32)
            | (Value::ConstUnit, Type::Unit)
    ) || (integer_initializer && (ty.is_integer() || matches!(ty, Type::Char)))
}

fn unsupported_value(func: &str, what: &str) -> String {
    format!(
        "backend: function '{}' uses an unsupported operand ({}). \
         The x86_64 backend currently supports integer, bool, char and f64 scalars only.",
        func, what
    )
}

/// The successor block labels of a basic block, derived from its terminator.
fn block_successors(block: &BasicBlock) -> Vec<Label> {
    match block.instructions.last() {
        Some(Instruction::Branch {
            true_label,
            false_label,
            ..
        }) => vec![true_label.clone(), false_label.clone()],
        Some(Instruction::Jump(l)) => vec![l.clone()],
        _ => Vec::new(),
    }
}

/// Eliminate SSA `Phi` nodes by converting them to copies in predecessor
/// blocks (the classic "phi → moves in predecessors" lowering).
///
/// A `Phi { dst, incoming: [(val, src_label), ..] }` at the head of a merge
/// block selects `val` when control arrives from the predecessor associated
/// with `src_label`. We materialize that by inserting `dst = mov val` at the
/// end of the predecessor block (immediately before its terminating
/// branch/jump), then deleting the `Phi`. `dst` already has a stack slot
/// reserved by the function frame (the lowerer records every phi result in
/// `func.locals`), so the copy is a plain slot write at codegen time. Multiple
/// phi copies from the same predecessor are parallel copies: if one copy's
/// source is another copy's destination, the source is first saved into a fresh
/// temporary stack slot so sequential instruction selection cannot clobber it.
///
/// The label recorded in a phi's incoming edge marks the *entry* of the
/// branch region, which for nested control flow is not necessarily the block
/// that actually jumps to the merge (e.g. an `if` whose arm is itself an
/// `if`). We therefore follow the successor edges from the recorded label to
/// the first reachable block that has the merge block as a successor — that is
/// the true predecessor where the copy must live.
fn eliminate_phis(func: &Function) -> Function {
    let mut func = func.clone();

    // label -> block index
    let label_idx: std::collections::HashMap<Label, usize> = func
        .blocks
        .iter()
        .enumerate()
        .map(|(i, b)| (b.label.clone(), i))
        .collect();

    // Successor labels per block index.
    let successors: Vec<Vec<Label>> = func.blocks.iter().map(block_successors).collect();

    // Planned copies: predecessor block index -> moves to insert before its
    // terminator, in source order.
    let mut inserts: std::collections::HashMap<usize, Vec<Instruction>> =
        std::collections::HashMap::new();
    let mut next_temp_var = next_available_var(&func);

    for merge_idx in 0..func.blocks.len() {
        let merge_label = func.blocks[merge_idx].label.clone();
        // Collect this block's phis (they sit at the head of the merge block).
        let phis: Vec<Instruction> = func.blocks[merge_idx]
            .instructions
            .iter()
            .filter(|i| matches!(i, Instruction::Phi { .. }))
            .cloned()
            .collect();

        for phi in &phis {
            let Instruction::Phi { dst, incoming, ty } = phi else {
                continue;
            };
            for (val, src_label) in incoming {
                let Some(pred_idx) =
                    find_predecessor(src_label, &merge_label, &label_idx, &successors)
                else {
                    // No reachable predecessor jumps to the merge (should not
                    // happen for well-formed lowering); skip rather than panic.
                    continue;
                };
                inserts.entry(pred_idx).or_default().push(Instruction::Mov {
                    dst: *dst,
                    src: val.clone(),
                    ty: ty.clone(),
                });
            }
        }
    }

    // Drop all phi instructions.
    for block in &mut func.blocks {
        block
            .instructions
            .retain(|i| !matches!(i, Instruction::Phi { .. }));
    }

    // Insert the planned copies immediately before each predecessor's
    // terminator (the last instruction, which is a Branch/Jump).
    let mut inserts: Vec<_> = inserts.into_iter().collect();
    inserts.sort_by_key(|(pred_idx, _)| *pred_idx);
    for (pred_idx, moves) in inserts {
        let moves = protect_parallel_phi_sources(moves, &mut func.locals, &mut next_temp_var);
        let block = &mut func.blocks[pred_idx];
        let insert_at = if block.instructions.is_empty() {
            0
        } else {
            // Before the terminating branch/jump.
            match block.instructions.last() {
                Some(Instruction::Branch { .. }) | Some(Instruction::Jump(_)) => {
                    block.instructions.len() - 1
                }
                _ => block.instructions.len(),
            }
        };
        for (offset, mv) in moves.into_iter().enumerate() {
            block.instructions.insert(insert_at + offset, mv);
        }
    }

    func
}

fn protect_parallel_phi_sources(
    moves: Vec<Instruction>,
    locals: &mut Vec<(VarId, Type)>,
    next_temp_var: &mut VarId,
) -> Vec<Instruction> {
    let phi_dsts: HashSet<VarId> = moves
        .iter()
        .filter_map(|instr| match instr {
            Instruction::Mov { dst, .. } => Some(*dst),
            _ => None,
        })
        .collect();

    let mut backups = Vec::new();
    let mut rewritten = Vec::new();

    for instr in moves {
        match instr {
            Instruction::Mov {
                dst,
                src: Value::Var(src_var),
                ty,
            } if src_var != dst && phi_dsts.contains(&src_var) => {
                let tmp = *next_temp_var;
                *next_temp_var = next_temp_var.saturating_add(1);
                locals.push((tmp, ty.clone()));
                backups.push(Instruction::Mov {
                    dst: tmp,
                    src: Value::Var(src_var),
                    ty: ty.clone(),
                });
                rewritten.push(Instruction::Mov {
                    dst,
                    src: Value::Var(tmp),
                    ty,
                });
            }
            other => rewritten.push(other),
        }
    }

    backups.extend(rewritten);
    backups
}

fn next_available_var(func: &Function) -> VarId {
    let mut next = 0;
    for (var, _) in func.params.iter().chain(func.locals.iter()) {
        next = next.max(var.saturating_add(1));
    }
    next
}

/// From the branch-region entry `start_label`, follow successor edges to the
/// first reachable block (including the start) whose successors include
/// `merge_label`. Returns that block's index — the true predecessor of the
/// merge block on this path.
fn find_predecessor(
    start_label: &str,
    merge_label: &str,
    label_idx: &std::collections::HashMap<Label, usize>,
    successors: &[Vec<Label>],
) -> Option<usize> {
    let start = *label_idx.get(start_label)?;
    let mut stack = vec![start];
    let mut seen = HashSet::new();
    while let Some(idx) = stack.pop() {
        if !seen.insert(idx) {
            continue;
        }
        if successors[idx].iter().any(|l| l == merge_label) {
            return Some(idx);
        }
        for succ in &successors[idx] {
            if let Some(&j) = label_idx.get(succ) {
                stack.push(j);
            }
        }
    }
    None
}

impl X86_64Backend {
    pub fn new() -> Self {
        X86_64Backend {
            target: BackendTarget::default(),
            output: String::new(),

            stack_size: 0,
            var_offsets: HashMap::new(),
            var_types: HashMap::new(),
            global_types: HashMap::new(),
            function_sigs: HashMap::new(),
            closure_descriptor_names: BTreeSet::new(),
            address_vars: HashSet::new(),
            reg_plan: None,
            callee_saved_offsets: HashMap::new(),
            extern_names: HashSet::new(),
            runtime_print_names: HashSet::new(),
            needs_alloc_runtime: false,
            needs_region_mark_runtime: false,
            needs_region_reset_runtime: false,
            emits_alloc_runtime: false,
            needs_oob_runtime: false,
            needs_div_runtime: false,
            needs_shift_runtime: false,
            needs_string_eq_runtime: false,
            needs_string_to_int_runtime: false,
            needs_int_to_string_runtime: false,
            needs_substring_runtime: false,
            needs_string_concat_runtime: false,
            needs_abort_runtime: false,
            needs_print_str_runtime: false,
            needs_print_err_runtime: false,
            needs_arg_count_runtime: false,
            needs_arg_runtime: false,
            needs_read_file_runtime: false,
            needs_write_file_runtime: false,
            needs_file_exists_runtime: false,
            needs_fs_runtime: false,
            needs_env_var_exists_runtime: false,
            needs_env_var_value_runtime: false,
            needs_env_path_separator_runtime: false,
            needs_process_output_runtime: false,
            needs_read_stdin_line_runtime: false,
            needs_read_stdin_bytes_runtime: false,
            needs_stdin_eof_runtime: false,
            needs_flush_stdout_runtime: false,
            return_ty: Type::Unit,
            param_vars: HashSet::new(),
            current_fn: String::new(),
            current_entry_label: String::new(),
            current_params: Vec::new(),
            interned_strings: HashMap::new(),
        }
    }

    pub fn with_target(target: BackendTarget) -> Self {
        let mut backend = Self::new();
        backend.target = target;
        backend
    }

    pub fn generate(&mut self, program: &Program) -> String {
        self.global_types.clear();
        for (name, ty, _) in &program.globals {
            self.global_types.insert(name.clone(), ty.clone());
        }
        self.extern_names.clear();
        for (name, _) in &program.externs {
            self.extern_names.insert(name.clone());
        }
        self.function_sigs.clear();
        for func in &program.functions {
            let args = func.params.iter().map(|(_, ty)| ty.clone()).collect();
            self.function_sigs
                .insert(func.name.clone(), (args, func.ret.clone()));
        }
        for (name, ty) in &program.externs {
            if let Type::Func(args, ret) = ty {
                self.function_sigs
                    .insert(name.clone(), (args.clone(), (**ret).clone()));
            }
        }
        self.closure_descriptor_names = Self::collect_closure_descriptor_names(program);
        self.emits_alloc_runtime = false;

        self.generate_globals(&program.globals);
        self.runtime_print_names = Self::runtime_print_names(program);
        self.needs_alloc_runtime = Self::needs_alloc_runtime(program);
        self.needs_region_mark_runtime = Self::needs_region_mark_runtime(program);
        self.needs_region_reset_runtime = Self::needs_region_reset_runtime(program);
        self.needs_oob_runtime = Self::needs_oob_runtime(program);
        self.needs_div_runtime = Self::needs_div_runtime(program);
        self.needs_shift_runtime = Self::needs_shift_runtime(program);
        self.needs_string_eq_runtime = Self::needs_string_eq_runtime(program);
        self.needs_string_to_int_runtime = Self::needs_string_to_int_runtime(program);
        self.needs_int_to_string_runtime = Self::needs_int_to_string_runtime(program);
        self.needs_substring_runtime = Self::needs_substring_runtime(program);
        self.needs_string_concat_runtime = Self::needs_string_concat_runtime(program);
        self.needs_print_str_runtime = Self::needs_print_str_runtime(program);
        self.needs_print_err_runtime = Self::needs_print_err_runtime(program);
        self.needs_arg_count_runtime = Self::needs_arg_count_runtime(program);
        self.needs_arg_runtime = Self::needs_arg_runtime(program);
        self.needs_read_file_runtime = Self::needs_read_file_runtime(program);
        self.needs_write_file_runtime = Self::needs_write_file_runtime(program);
        self.needs_file_exists_runtime = Self::needs_file_exists_runtime(program);
        self.needs_fs_runtime = Self::needs_fs_runtime(program);
        self.needs_env_var_exists_runtime = Self::needs_env_var_exists_runtime(program);
        self.needs_env_var_value_runtime = Self::needs_env_var_value_runtime(program);
        self.needs_env_path_separator_runtime = Self::needs_env_path_separator_runtime(program);
        self.needs_process_output_runtime = Self::needs_process_output_runtime(program);
        self.needs_read_stdin_line_runtime = Self::needs_read_stdin_line_runtime(program);
        self.needs_read_stdin_bytes_runtime = Self::needs_read_stdin_bytes_runtime(program);
        self.needs_stdin_eof_runtime = Self::needs_stdin_eof_runtime(program);
        self.needs_flush_stdout_runtime = Self::needs_flush_stdout_runtime(program);
        let runtime_policy = self.target.runtime_policy();
        let windows_flush_can_abort =
            self.needs_flush_stdout_runtime && runtime_policy.emits_windows_runtime_helpers;
        self.needs_abort_runtime = Self::needs_abort_runtime(program)
            || self.needs_arg_runtime
            || self.needs_read_file_runtime
            || self.needs_write_file_runtime
            || self.needs_file_exists_runtime
            || self.needs_read_stdin_line_runtime
            || self.needs_read_stdin_bytes_runtime
            || windows_flush_can_abort;
        // Several backend runtimes allocate their buffers and fat values via a
        // raw `tl_alloc` call, so their presence forces the raw allocator
        // runtime to be emitted even when IR calls to a user-defined TypeLisp
        // function named `tl_alloc` remain mangled to `_tl_tl_alloc`.
        self.emits_alloc_runtime = self.needs_alloc_runtime
            || self.needs_int_to_string_runtime
            || self.needs_substring_runtime
            || self.needs_string_concat_runtime
            || self.needs_arg_runtime
            || self.needs_read_file_runtime
            || self.needs_write_file_runtime
            || self.needs_file_exists_runtime
            || self.needs_fs_runtime
            || (self.needs_env_var_exists_runtime && runtime_policy.emits_windows_runtime_helpers)
            || self.needs_env_var_value_runtime
            || self.needs_env_path_separator_runtime
            || self.needs_process_output_runtime
            || self.needs_read_stdin_line_runtime
            || self.needs_read_stdin_bytes_runtime;
        let needs_print_runtime = !self.runtime_print_names.is_empty();
        let needs_argv_data = self.needs_arg_count_runtime || self.needs_arg_runtime;
        let needs_env_data = !runtime_policy.emits_windows_runtime_helpers
            && (self.needs_env_var_exists_runtime
                || self.needs_env_var_value_runtime
                || self.needs_process_output_runtime);
        let needs_stdin_data = self.needs_read_stdin_line_runtime
            || self.needs_read_stdin_bytes_runtime
            || self.needs_stdin_eof_runtime;
        let needs_region_runtime =
            self.needs_region_mark_runtime || self.needs_region_reset_runtime;
        let needs_linux_syscall_runtime = needs_print_runtime
            || self.emits_alloc_runtime
            || self.needs_region_reset_runtime
            || self.needs_oob_runtime
            || self.needs_div_runtime
            || self.needs_shift_runtime
            || self.needs_abort_runtime
            || self.needs_print_str_runtime
            || self.needs_print_err_runtime
            || self.needs_read_file_runtime
            || self.needs_write_file_runtime
            || self.needs_file_exists_runtime
            || self.needs_fs_runtime
            || self.needs_process_output_runtime
            || self.needs_read_stdin_line_runtime
            || self.needs_read_stdin_bytes_runtime
            || needs_argv_data;
        debug_assert!(
            runtime_policy.emits_linux_syscall_helpers
                || runtime_policy.emits_windows_runtime_helpers
                || !needs_linux_syscall_runtime,
            "target runtime policy cannot emit the requested runtime helpers"
        );
        if needs_print_runtime {
            self.generate_print_runtime_data();
        }
        if self.emits_alloc_runtime || needs_region_runtime {
            self.generate_alloc_runtime_data();
        }
        if self.emits_alloc_runtime {
            self.generate_alloc_failure_data();
        }
        if self.needs_region_reset_runtime {
            self.generate_region_reset_failure_data();
        }
        if needs_argv_data {
            self.generate_argv_runtime_data();
        }
        if needs_env_data {
            self.generate_env_runtime_data();
        }
        if needs_stdin_data {
            self.generate_stdin_runtime_data();
        }
        self.intern_strings(program);
        self.generate_string_rodata();
        if self.needs_oob_runtime {
            self.generate_oob_runtime_data();
        }
        if self.needs_div_runtime {
            self.generate_div_runtime_data();
        }
        if self.needs_shift_runtime {
            self.generate_shift_runtime_data();
        }
        if self.needs_read_file_runtime {
            self.generate_read_file_runtime_data();
        }
        if self.needs_write_file_runtime {
            self.generate_write_file_runtime_data();
        }
        if self.needs_file_exists_runtime {
            self.generate_file_exists_runtime_data();
        }
        if self.needs_flush_stdout_runtime {
            self.generate_flush_stdout_runtime_data();
        }
        if self.needs_process_output_runtime {
            self.generate_process_output_runtime_data();
        }
        self.generate_closure_descriptor_data();

        self.emit("    .text");
        self.emit("    .globl main");
        let entry_policy = self.target.entry_policy();
        if let Some(symbol) = entry_policy.symbol {
            self.emit(&format!("    .globl {}", symbol));
        }
        self.emit("");

        // Generate extern declarations
        for (name, _) in &program.externs {
            let symbol = self.call_symbol(name);
            // Runtime functions defined inline by the backend (the print
            // helpers and the bump allocator) must not also be declared
            // `.extern` — they are defined in this same translation unit.
            let defined_inline = Self::is_defined_print_runtime_symbol(&symbol)
                || (self.emits_alloc_runtime && symbol == "tl_alloc")
                || (self.needs_region_mark_runtime && symbol == REGION_MARK_RUNTIME_SYMBOL)
                || (self.needs_region_reset_runtime && symbol == REGION_RESET_RUNTIME_SYMBOL)
                || (self.needs_oob_runtime && symbol == "tl_oob_abort")
                || (self.needs_div_runtime && symbol == "tl_div_abort")
                || (self.needs_shift_runtime && symbol == "tl_shift_abort")
                || (self.needs_string_eq_runtime && symbol == "tl_string_eq")
                || (self.needs_string_to_int_runtime && symbol == "tl_string_to_int")
                || (self.needs_int_to_string_runtime && symbol == "tl_int_to_string")
                || (self.needs_substring_runtime && symbol == "tl_substring")
                || (self.needs_string_concat_runtime && symbol == "tl_string_concat")
                || (self.needs_abort_runtime && symbol == ABORT_RUNTIME_SYMBOL)
                || (self.needs_print_str_runtime && symbol == "tl_print_str")
                || (self.needs_print_err_runtime && symbol == "tl_print_err")
                || (self.needs_arg_count_runtime && symbol == ARG_COUNT_RUNTIME_SYMBOL)
                || (self.needs_arg_runtime && symbol == ARG_RUNTIME_SYMBOL)
                || (self.needs_read_file_runtime && symbol == READ_FILE_RUNTIME_SYMBOL)
                || (self.needs_write_file_runtime && symbol == WRITE_FILE_RUNTIME_SYMBOL)
                || (self.needs_file_exists_runtime && symbol == FILE_EXISTS_RUNTIME_SYMBOL)
                || (self.needs_read_file_runtime && symbol == READ_FILE_STATUS_RUNTIME_SYMBOL)
                || (self.needs_write_file_runtime && symbol == WRITE_FILE_STATUS_RUNTIME_SYMBOL)
                || (self.needs_file_exists_runtime && symbol == FILE_EXISTS_STATUS_RUNTIME_SYMBOL)
                || (self.needs_fs_runtime && symbol == FS_MKDIR_STATUS_RUNTIME_SYMBOL)
                || (self.needs_fs_runtime && symbol == FS_REMOVE_FILE_STATUS_RUNTIME_SYMBOL)
                || (self.needs_fs_runtime && symbol == FS_REMOVE_DIR_STATUS_RUNTIME_SYMBOL)
                || (self.needs_fs_runtime && symbol == FS_PROCESS_ID_RUNTIME_SYMBOL)
                || (self.needs_env_var_exists_runtime && symbol == ENV_VAR_EXISTS_RUNTIME_SYMBOL)
                || (self.needs_env_var_value_runtime && symbol == ENV_VAR_VALUE_RUNTIME_SYMBOL)
                || (self.needs_env_path_separator_runtime
                    && symbol == ENV_PATH_SEPARATOR_RUNTIME_SYMBOL)
                || (self.needs_process_output_runtime && symbol == PROCESS_OUTPUT_RUNTIME_SYMBOL)
                || (self.needs_read_stdin_line_runtime && symbol == READ_STDIN_LINE_RUNTIME_SYMBOL)
                || (self.needs_read_stdin_bytes_runtime
                    && symbol == READ_STDIN_BYTES_RUNTIME_SYMBOL)
                || (self.needs_stdin_eof_runtime && symbol == STDIN_EOF_RUNTIME_SYMBOL)
                || (self.needs_flush_stdout_runtime && symbol == FLUSH_STDOUT_RUNTIME_SYMBOL);
            if !defined_inline {
                self.emit(&format!("    .extern {}", symbol));
            }
        }
        if runtime_policy.emits_windows_runtime_helpers {
            self.generate_windows_runtime_externs(needs_print_runtime);
        } else if needs_print_runtime && runtime_policy.uses_libc_print_runtime {
            self.emit("    .extern printf");
            self.emit("    .extern fflush");
        }
        self.emit("");

        if needs_print_runtime {
            self.generate_print_runtime_functions();
        }
        if self.emits_alloc_runtime {
            self.generate_alloc_runtime_functions();
        }
        if self.needs_region_mark_runtime {
            self.generate_region_mark_runtime_function();
        }
        if self.needs_region_reset_runtime {
            self.generate_region_reset_runtime_function();
        }
        if self.needs_oob_runtime {
            self.generate_oob_runtime_functions();
        }
        if self.needs_div_runtime {
            self.generate_div_runtime_functions();
        }
        if self.needs_shift_runtime {
            self.generate_shift_runtime_functions();
        }
        if self.needs_string_eq_runtime {
            self.generate_string_eq_runtime_functions();
        }
        if self.needs_string_to_int_runtime {
            self.generate_string_to_int_runtime_functions();
        }
        if self.needs_int_to_string_runtime {
            self.generate_int_to_string_runtime_functions();
        }
        if self.needs_substring_runtime {
            self.generate_substring_runtime_functions();
        }
        if self.needs_string_concat_runtime {
            self.generate_string_concat_runtime_functions();
        }
        if self.needs_abort_runtime {
            self.generate_abort_runtime_functions();
        }
        if self.needs_print_str_runtime {
            self.generate_print_str_runtime_functions();
        }
        if self.needs_print_err_runtime {
            self.generate_print_err_runtime_functions();
        }
        if self.needs_arg_count_runtime {
            self.generate_arg_count_runtime_functions();
        }
        if self.needs_arg_runtime {
            self.generate_arg_runtime_functions();
        }
        if self.needs_read_file_runtime {
            self.generate_read_file_runtime_functions();
            self.generate_read_file_status_runtime_functions();
        }
        if self.needs_write_file_runtime {
            self.generate_write_file_runtime_functions();
            self.generate_write_file_status_runtime_functions();
        }
        if self.needs_file_exists_runtime {
            self.generate_file_exists_runtime_functions();
            self.generate_file_exists_status_runtime_functions();
        }
        if self.needs_fs_runtime {
            self.generate_fs_runtime_functions();
        }
        if self.needs_env_var_exists_runtime {
            self.generate_env_var_exists_runtime_functions();
        }
        if self.needs_env_var_value_runtime {
            self.generate_env_var_value_runtime_functions();
        }
        if self.needs_env_path_separator_runtime {
            self.generate_env_path_separator_runtime_functions();
        }
        if self.needs_process_output_runtime {
            self.generate_process_output_runtime_functions();
        }
        if self.needs_read_stdin_line_runtime {
            self.generate_read_stdin_line_runtime_functions();
        }
        if self.needs_read_stdin_bytes_runtime {
            self.generate_read_stdin_bytes_runtime_functions();
        }
        if self.needs_stdin_eof_runtime {
            self.generate_stdin_eof_runtime_functions();
        }
        if self.needs_flush_stdout_runtime {
            self.generate_flush_stdout_runtime_functions();
        }

        self.generate_closure_entry_adapters();

        // Generate functions
        for func in &program.functions {
            self.generate_function(func, program);
        }

        // Generate main if not present
        if !program.functions.iter().any(|f| f.name == "main") {
            self.emit("main:");
            self.emit("    xor %eax, %eax");
            self.emit("    ret");
        }

        let main_ret = program
            .functions
            .iter()
            .find(|f| f.name == "main")
            .map(|f| f.ret.clone())
            .unwrap_or(Type::I64);

        if let Some(entry_symbol) = entry_policy.symbol {
            self.emit("");
            self.emit(&format!("{}:", entry_symbol));
            if needs_argv_data || needs_env_data {
                self.emit("    movq (%rsp), %rax");
                if needs_argv_data {
                    self.emit("    movq %rax, .L_tl_argc(%rip)");
                    self.emit("    leaq 8(%rsp), %rax");
                    self.emit("    movq %rax, .L_tl_argv(%rip)");
                }
                if needs_env_data {
                    if needs_argv_data {
                        self.emit("    movq (%rsp), %rax");
                    }
                    self.emit("    leaq 16(%rsp,%rax,8), %rax");
                    self.emit("    movq %rax, .L_tl_envp(%rip)");
                }
            }
            self.emit_global_initializers(program);
            self.emit_call("main");
            if main_ret == Type::Unit {
                let status_reg = Self::gpr32(entry_policy.exit_status_reg);
                self.emit(&format!("    xor {}, {}", status_reg, status_reg));
            } else {
                self.emit(&format!("    movq %rax, {}", entry_policy.exit_status_reg));
            }
            if let Some(exit_syscall_number) = entry_policy.exit_syscall_number {
                self.emit(&format!("    movq ${}, %rax", exit_syscall_number));
                self.emit("    syscall");
            }
        }

        self.output.clone()
    }

    fn emit_global_initializers(&mut self, program: &Program) {
        // Initialize non-constant globals: call their __global_init_* function
        // and store the returned value (%rax for integer/pointer values, %xmm0
        // for f64).
        for (name, ty, init) in &program.globals {
            if init.is_some() {
                continue;
            }
            let init_fn = format!("__global_init_{}", name);
            if program.functions.iter().any(|f| f.name == init_fn) {
                self.emit_call(&Self::mangle_name(&init_fn));
                let symbol = Self::mangle_name(name);
                let calling_convention = self.target.calling_convention();
                match ty {
                    Type::F64 => {
                        self.emit(&format!(
                            "    movsd {}, {}(%rip)",
                            calling_convention.return_float_reg, symbol
                        ));
                    }
                    Type::F32 => {
                        self.emit(&format!(
                            "    movss {}, {}(%rip)",
                            calling_convention.return_float_reg, symbol
                        ));
                    }
                    Type::I64
                    | Type::U64
                    | Type::String
                    | Type::DynArray(_)
                    | Type::Enum(_)
                    | Type::Struct(_) => {
                        self.emit(&format!(
                            "    movq {}, {}(%rip)",
                            calling_convention.return_gpr, symbol
                        ));
                    }
                    Type::I32 | Type::U32 => {
                        self.emit(&format!(
                            "    movl {}, {}(%rip)",
                            Self::gpr32(calling_convention.return_gpr),
                            symbol
                        ));
                    }
                    Type::I16 | Type::U16 => {
                        self.emit(&format!(
                            "    movw {}, {}(%rip)",
                            Self::gpr16(calling_convention.return_gpr),
                            symbol
                        ));
                    }
                    Type::I8 | Type::U8 | Type::Bool | Type::Char => {
                        self.emit(&format!(
                            "    movb {}, {}(%rip)",
                            Self::gpr8(calling_convention.return_gpr),
                            symbol
                        ));
                    }
                    Type::Unit => {}
                    _ => {}
                }
            }
        }
    }

    fn generate_windows_runtime_externs(&mut self, needs_print_runtime: bool) {
        let mut externs = BTreeSet::new();

        if needs_print_runtime {
            externs.insert("_write");
            if self.runtime_print_names.contains("print-float") {
                externs.insert("printf");
                externs.insert("fflush");
            }
        }
        if self.emits_alloc_runtime {
            externs.insert("malloc");
            externs.insert("_write");
            externs.insert("exit");
        }
        if self.needs_oob_runtime
            || self.needs_div_runtime
            || self.needs_shift_runtime
            || self.needs_abort_runtime
            || self.needs_print_str_runtime
            || self.needs_print_err_runtime
        {
            externs.insert("_write");
        }
        if self.needs_oob_runtime
            || self.needs_div_runtime
            || self.needs_shift_runtime
            || self.needs_abort_runtime
        {
            externs.insert("exit");
        }
        if self.needs_read_file_runtime {
            externs.insert("_open");
            externs.insert("_lseeki64");
            externs.insert("_read");
            externs.insert("_close");
            externs.insert("_errno");
        }
        if self.needs_write_file_runtime {
            externs.insert("_open");
            externs.insert("_write");
            externs.insert("_close");
            externs.insert("_errno");
        }
        if self.needs_file_exists_runtime {
            externs.insert("_access");
            externs.insert("_errno");
        }
        if self.needs_fs_runtime {
            externs.insert("_mkdir");
            externs.insert("_errno");
        }
        if self.needs_env_var_exists_runtime || self.needs_env_var_value_runtime {
            externs.insert("getenv");
            externs.insert("strlen");
        }
        if self.needs_read_stdin_line_runtime || self.needs_read_stdin_bytes_runtime {
            externs.insert("_read");
        }
        if self.needs_flush_stdout_runtime {
            externs.insert("fflush");
        }
        if self.needs_process_output_runtime {
            for symbol in [
                "_close",
                "_dup",
                "_dup2",
                "_fileno",
                "_lseeki64",
                "_read",
                "_spawnv",
                "fclose",
                "fflush",
                "tmpfile",
            ] {
                externs.insert(symbol);
            }
        }

        for symbol in externs {
            self.emit(&format!("    .extern {}", symbol));
        }
    }

    fn runtime_print_names(program: &Program) -> HashSet<String> {
        let defined_functions: HashSet<&str> = program
            .functions
            .iter()
            .map(|func| func.name.as_str())
            .collect();
        let mut names = HashSet::new();

        for func in &program.functions {
            for block in &func.blocks {
                for instr in &block.instructions {
                    if let Instruction::Call { func, .. } = instr
                        && Self::runtime_symbol(func).is_some()
                        && !defined_functions.contains(func.as_str())
                    {
                        names.insert(func.clone());
                    }
                }
            }
        }

        for (name, _) in &program.externs {
            if Self::runtime_symbol(name).is_some() && !defined_functions.contains(name.as_str()) {
                names.insert(name.clone());
            }
        }

        names
    }

    /// Whether the program references the bump allocator `tl_alloc` (through a
    /// direct `Call` or an `extern` declaration) and does not define its own
    /// `tl_alloc`. When true the backend emits the self-contained allocator
    /// runtime (tracked `mmap`'d arenas plus bump pointers) into the program's `.s`
    /// so the symbol resolves without linking libc.
    fn needs_alloc_runtime(program: &Program) -> bool {
        let defines_own = program.functions.iter().any(|f| f.name == "tl_alloc");
        if defines_own {
            return false;
        }
        let referenced_in_calls = program.functions.iter().any(|func| {
            func.blocks.iter().any(|block| {
                block.instructions.iter().any(
                    |instr| matches!(instr, Instruction::Call { func, .. } if func == "tl_alloc"),
                )
            })
        });
        let referenced_in_externs = program.externs.iter().any(|(name, _)| name == "tl_alloc");
        referenced_in_calls || referenced_in_externs
    }

    fn needs_region_mark_runtime(program: &Program) -> bool {
        Self::needs_named_runtime(program, REGION_MARK_RUNTIME_SYMBOL)
    }

    fn needs_region_reset_runtime(program: &Program) -> bool {
        Self::needs_named_runtime(program, REGION_RESET_RUNTIME_SYMBOL)
    }

    fn needs_named_runtime(program: &Program, symbol: &str) -> bool {
        let defines_own = program.functions.iter().any(|f| f.name == symbol);
        if defines_own {
            return false;
        }
        let referenced_in_calls = program.functions.iter().any(|func| {
            func.blocks.iter().any(|block| {
                block
                    .instructions
                    .iter()
                    .any(|instr| matches!(instr, Instruction::Call { func, .. } if func == symbol))
            })
        });
        let referenced_in_externs = program.externs.iter().any(|(name, _)| name == symbol);
        referenced_in_calls || referenced_in_externs
    }

    /// Whether the program references the out-of-bounds abort `tl_oob_abort`
    /// (emitted by dynamic-array bounds checks) and does not define its own.
    /// When true the backend emits the self-contained abort runtime so the
    /// symbol resolves without linking libc.
    fn needs_oob_runtime(program: &Program) -> bool {
        let defines_own = program.functions.iter().any(|f| f.name == "tl_oob_abort");
        if defines_own {
            return false;
        }
        let referenced_in_calls = program.functions.iter().any(|func| {
            func.blocks.iter().any(|block| {
                block.instructions.iter().any(|instr| {
                    matches!(instr, Instruction::Call { func, .. } if func == "tl_oob_abort")
                })
            })
        });
        let referenced_in_externs = program
            .externs
            .iter()
            .any(|(name, _)| name == "tl_oob_abort");
        referenced_in_calls || referenced_in_externs
    }

    /// Whether the program references the integer-division abort `tl_div_abort`
    /// (emitted by guarded integer division/remainder) and does not define its
    /// own. When true the backend emits the self-contained abort runtime so the
    /// symbol resolves without linking libc.
    fn needs_div_runtime(program: &Program) -> bool {
        let defines_own = program.functions.iter().any(|f| f.name == "tl_div_abort");
        if defines_own {
            return false;
        }
        let referenced_in_calls = program.functions.iter().any(|func| {
            func.blocks.iter().any(|block| {
                block.instructions.iter().any(|instr| {
                    matches!(instr, Instruction::Call { func, .. } if func == "tl_div_abort")
                })
            })
        });
        let referenced_in_externs = program
            .externs
            .iter()
            .any(|(name, _)| name == "tl_div_abort");
        referenced_in_calls || referenced_in_externs
    }

    fn needs_shift_runtime(program: &Program) -> bool {
        let defines_own = program.functions.iter().any(|f| f.name == "tl_shift_abort");
        if defines_own {
            return false;
        }
        let referenced_in_calls = program.functions.iter().any(|func| {
            func.blocks.iter().any(|block| {
                block.instructions.iter().any(|instr| {
                    matches!(instr, Instruction::Call { func, .. } if func == "tl_shift_abort")
                })
            })
        });
        let referenced_in_externs = program
            .externs
            .iter()
            .any(|(name, _)| name == "tl_shift_abort");
        referenced_in_calls || referenced_in_externs
    }

    /// Whether the program references the string-equality helper `tl_string_eq`
    /// (through a direct `Call` or an `extern` declaration) and does not define
    /// its own `tl_string_eq`. When true the backend emits the self-contained
    /// byte-comparison runtime into the program's `.s` so the symbol resolves
    /// without linking libc.
    fn needs_string_eq_runtime(program: &Program) -> bool {
        let defines_own = program.functions.iter().any(|f| f.name == "tl_string_eq");
        if defines_own {
            return false;
        }
        let referenced_in_calls = program.functions.iter().any(|func| {
            func.blocks.iter().any(|block| {
                block.instructions.iter().any(|instr| {
                    matches!(instr, Instruction::Call { func, .. } if func == "tl_string_eq")
                })
            })
        });
        let referenced_in_externs = program
            .externs
            .iter()
            .any(|(name, _)| name == "tl_string_eq");
        referenced_in_calls || referenced_in_externs
    }

    /// Whether the program references the decimal-parse helper
    /// `tl_string_to_int` (through a direct `Call` or an `extern` declaration)
    /// and does not define its own. When true the backend emits the
    /// self-contained parse runtime into the program's `.s` so the symbol
    /// resolves without linking libc.
    fn needs_string_to_int_runtime(program: &Program) -> bool {
        let defines_own = program
            .functions
            .iter()
            .any(|f| f.name == "tl_string_to_int");
        if defines_own {
            return false;
        }
        let referenced_in_calls = program.functions.iter().any(|func| {
            func.blocks.iter().any(|block| {
                block.instructions.iter().any(|instr| {
                    matches!(instr, Instruction::Call { func, .. } if func == "tl_string_to_int")
                })
            })
        });
        let referenced_in_externs = program
            .externs
            .iter()
            .any(|(name, _)| name == "tl_string_to_int");
        referenced_in_calls || referenced_in_externs
    }

    /// Whether the program references the integer-to-string helper
    /// `tl_int_to_string` (through a direct `Call` or an `extern` declaration)
    /// and does not define its own. When true the backend emits the
    /// self-contained decimal-formatting runtime into the program's `.s` so the
    /// symbol resolves without linking libc.
    fn needs_int_to_string_runtime(program: &Program) -> bool {
        let defines_own = program
            .functions
            .iter()
            .any(|f| f.name == "tl_int_to_string");
        if defines_own {
            return false;
        }
        let referenced_in_calls = program.functions.iter().any(|func| {
            func.blocks.iter().any(|block| {
                block.instructions.iter().any(|instr| {
                    matches!(instr, Instruction::Call { func, .. } if func == "tl_int_to_string")
                })
            })
        });
        let referenced_in_externs = program
            .externs
            .iter()
            .any(|(name, _)| name == "tl_int_to_string");
        referenced_in_calls || referenced_in_externs
    }

    /// Whether the program references the substring helper `tl_substring`
    /// (through a direct `Call` or an `extern` declaration) and does not define
    /// its own. When true the backend emits the self-contained byte-slice runtime
    /// into the program's `.s` so the symbol resolves without linking libc.
    fn needs_substring_runtime(program: &Program) -> bool {
        let defines_own = program.functions.iter().any(|f| f.name == "tl_substring");
        if defines_own {
            return false;
        }
        let referenced_in_calls = program.functions.iter().any(|func| {
            func.blocks.iter().any(|block| {
                block.instructions.iter().any(|instr| {
                    matches!(instr, Instruction::Call { func, .. } if func == "tl_substring")
                })
            })
        });
        let referenced_in_externs = program
            .externs
            .iter()
            .any(|(name, _)| name == "tl_substring");
        referenced_in_calls || referenced_in_externs
    }

    /// Whether the program references the concatenation helper
    /// `tl_string_concat` (through a direct `Call` or an `extern` declaration) and
    /// does not define its own. When true the backend emits the self-contained
    /// byte-append runtime into the program's `.s` so the symbol resolves without
    /// linking libc.
    fn needs_string_concat_runtime(program: &Program) -> bool {
        let defines_own = program
            .functions
            .iter()
            .any(|f| f.name == "tl_string_concat");
        if defines_own {
            return false;
        }
        let referenced_in_calls = program.functions.iter().any(|func| {
            func.blocks.iter().any(|block| {
                block.instructions.iter().any(|instr| {
                    matches!(instr, Instruction::Call { func, .. } if func == "tl_string_concat")
                })
            })
        });
        let referenced_in_externs = program
            .externs
            .iter()
            .any(|(name, _)| name == "tl_string_concat");
        referenced_in_calls || referenced_in_externs
    }

    /// Whether the program references the message-abort helper emitted on
    /// demand by `(panic msg)` / `(error msg)`. The lowerer targets a private
    /// assembler label that cannot be written as a TypeLisp identifier, so it
    /// cannot collide with a user-defined `tl_abort` function.
    fn needs_abort_runtime(program: &Program) -> bool {
        program.functions.iter().any(|func| {
            func.blocks.iter().any(|block| {
                block.instructions.iter().any(|instr| {
                    matches!(instr, Instruction::Call { func, .. } if func == ABORT_RUNTIME_SYMBOL)
                })
            })
        })
    }

    /// Whether the program references the print-string helper `tl_print_str`
    /// (through a direct `Call` or an `extern` declaration) and does not define
    /// its own. When true the backend emits the self-contained write-syscall
    /// runtime into the program's `.s` so the symbol resolves without linking
    /// libc.
    fn needs_print_str_runtime(program: &Program) -> bool {
        let defines_own = program.functions.iter().any(|f| f.name == "tl_print_str");
        if defines_own {
            return false;
        }
        let referenced_in_calls = program.functions.iter().any(|func| {
            func.blocks.iter().any(|block| {
                block.instructions.iter().any(|instr| {
                    matches!(instr, Instruction::Call { func, .. } if func == "tl_print_str")
                })
            })
        });
        let referenced_in_externs = program
            .externs
            .iter()
            .any(|(name, _)| name == "tl_print_str");
        referenced_in_calls || referenced_in_externs
    }

    fn needs_print_err_runtime(program: &Program) -> bool {
        let defines_own = program.functions.iter().any(|f| f.name == "tl_print_err");
        if defines_own {
            return false;
        }
        let referenced_in_calls = program.functions.iter().any(|func| {
            func.blocks.iter().any(|block| {
                block.instructions.iter().any(|instr| {
                    matches!(instr, Instruction::Call { func, .. } if func == "tl_print_err")
                })
            })
        });
        let referenced_in_externs = program
            .externs
            .iter()
            .any(|(name, _)| name == "tl_print_err");
        referenced_in_calls || referenced_in_externs
    }

    fn needs_arg_count_runtime(program: &Program) -> bool {
        program.functions.iter().any(|func| {
            func.blocks.iter().any(|block| {
                block.instructions.iter().any(|instr| {
                    matches!(instr, Instruction::Call { func, .. } if func == ARG_COUNT_RUNTIME_SYMBOL)
                })
            })
        })
    }

    fn needs_arg_runtime(program: &Program) -> bool {
        program.functions.iter().any(|func| {
            func.blocks.iter().any(|block| {
                block.instructions.iter().any(|instr| {
                    matches!(instr, Instruction::Call { func, .. } if func == ARG_RUNTIME_SYMBOL)
                })
            })
        })
    }

    /// Whether the program references the private read-file helper emitted for
    /// `(read-file path)`. The lowerer targets a private assembler label, so it
    /// cannot collide with a user-defined TypeLisp function.
    fn needs_read_file_runtime(program: &Program) -> bool {
        program.functions.iter().any(|func| {
            func.blocks.iter().any(|block| {
                block.instructions.iter().any(|instr| {
                    matches!(
                        instr,
                        Instruction::Call { func, .. }
                            if func == READ_FILE_RUNTIME_SYMBOL
                                || func == READ_FILE_STATUS_RUNTIME_SYMBOL
                    )
                })
            })
        })
    }

    /// Whether the program references the private write-file helper emitted for
    /// `(write-file path contents)`. The lowerer targets a private assembler
    /// label, so it cannot collide with a user-defined TypeLisp function.
    fn needs_write_file_runtime(program: &Program) -> bool {
        program.functions.iter().any(|func| {
            func.blocks.iter().any(|block| {
                block.instructions.iter().any(|instr| {
                    matches!(
                        instr,
                        Instruction::Call { func, .. }
                            if func == WRITE_FILE_RUNTIME_SYMBOL
                                || func == WRITE_FILE_STATUS_RUNTIME_SYMBOL
                    )
                })
            })
        })
    }

    /// Whether the program references the private file-exists helper emitted for
    /// `(file-exists? path)`. The lowerer targets a private assembler label, so
    /// it cannot collide with a user-defined TypeLisp function.
    fn needs_file_exists_runtime(program: &Program) -> bool {
        program.functions.iter().any(|func| {
            func.blocks.iter().any(|block| {
                block.instructions.iter().any(|instr| {
                    matches!(
                        instr,
                        Instruction::Call { func, .. }
                            if func == FILE_EXISTS_RUNTIME_SYMBOL
                                || func == FILE_EXISTS_STATUS_RUNTIME_SYMBOL
                    )
                })
            })
        })
    }

    fn needs_fs_runtime(program: &Program) -> bool {
        [
            FS_MKDIR_STATUS_RUNTIME_SYMBOL,
            FS_REMOVE_FILE_STATUS_RUNTIME_SYMBOL,
            FS_REMOVE_DIR_STATUS_RUNTIME_SYMBOL,
            FS_PROCESS_ID_RUNTIME_SYMBOL,
        ]
        .iter()
        .any(|symbol| Self::needs_private_call_runtime(program, symbol))
    }

    fn needs_env_var_exists_runtime(program: &Program) -> bool {
        Self::needs_private_call_runtime(program, ENV_VAR_EXISTS_RUNTIME_SYMBOL)
    }

    fn needs_env_var_value_runtime(program: &Program) -> bool {
        Self::needs_private_call_runtime(program, ENV_VAR_VALUE_RUNTIME_SYMBOL)
    }

    fn needs_env_path_separator_runtime(program: &Program) -> bool {
        Self::needs_private_call_runtime(program, ENV_PATH_SEPARATOR_RUNTIME_SYMBOL)
    }

    fn needs_process_output_runtime(program: &Program) -> bool {
        Self::needs_named_runtime(program, PROCESS_OUTPUT_RUNTIME_SYMBOL)
    }

    fn needs_private_call_runtime(program: &Program, symbol: &str) -> bool {
        program.functions.iter().any(|func| {
            func.blocks.iter().any(|block| {
                block
                    .instructions
                    .iter()
                    .any(|instr| matches!(instr, Instruction::Call { func, .. } if func == symbol))
            })
        })
    }

    fn needs_read_stdin_line_runtime(program: &Program) -> bool {
        program.functions.iter().any(|func| {
            func.blocks.iter().any(|block| {
                block.instructions.iter().any(|instr| {
                    matches!(
                        instr,
                        Instruction::Call { func, .. } if func == READ_STDIN_LINE_RUNTIME_SYMBOL
                    )
                })
            })
        })
    }

    fn needs_read_stdin_bytes_runtime(program: &Program) -> bool {
        program.functions.iter().any(|func| {
            func.blocks.iter().any(|block| {
                block.instructions.iter().any(|instr| {
                    matches!(
                        instr,
                        Instruction::Call { func, .. } if func == READ_STDIN_BYTES_RUNTIME_SYMBOL
                    )
                })
            })
        })
    }

    fn needs_stdin_eof_runtime(program: &Program) -> bool {
        program.functions.iter().any(|func| {
            func.blocks.iter().any(|block| {
                block.instructions.iter().any(|instr| {
                    matches!(
                        instr,
                        Instruction::Call { func, .. } if func == STDIN_EOF_RUNTIME_SYMBOL
                    )
                })
            })
        })
    }

    fn needs_flush_stdout_runtime(program: &Program) -> bool {
        program.functions.iter().any(|func| {
            func.blocks.iter().any(|block| {
                block.instructions.iter().any(|instr| {
                    matches!(
                        instr,
                        Instruction::Call { func, .. } if func == FLUSH_STDOUT_RUNTIME_SYMBOL
                    )
                })
            })
        })
    }

    fn generate_print_runtime_data(&mut self) {
        self.emit("    .section .rodata");
        self.emit(".L_tl_bool_true:");
        self.emit("    .ascii \"true\\n\"");
        self.emit(".L_tl_bool_false:");
        self.emit("    .ascii \"false\\n\"");
        self.emit(".L_tl_fmt_f64:");
        self.emit("    .asciz \"%.17g\\n\"");
        self.emit("");
    }

    fn generate_print_runtime_functions(&mut self) {
        if self.target.runtime_policy().emits_windows_runtime_helpers {
            self.generate_windows_print_runtime_functions();
            return;
        }

        self.emit("    .globl tl_print_i64");
        self.emit("tl_print_i64:");
        self.emit("    push %rbp");
        self.emit("    mov %rsp, %rbp");
        self.emit("    sub $48, %rsp");
        self.emit("    leaq -1(%rbp), %rsi");
        self.emit("    movb $10, (%rsi)");
        self.emit("    movq $1, %rcx");
        self.emit("    movq %rdi, %rax");
        self.emit("    cmpq $0, %rax");
        self.emit("    jne .L_tl_print_i64_nonzero");
        self.emit("    movb $48, -2(%rbp)");
        self.emit("    leaq -2(%rbp), %rsi");
        self.emit("    movq $2, %rdx");
        self.emit("    jmp .L_tl_print_i64_write");
        self.emit(".L_tl_print_i64_nonzero:");
        self.emit("    movq $0, %r8");
        self.emit("    cmpq $0, %rax");
        self.emit("    jge .L_tl_print_i64_abs_ready");
        self.emit("    negq %rax");
        self.emit("    movq $1, %r8");
        self.emit(".L_tl_print_i64_abs_ready:");
        self.emit("    movq $10, %r9");
        self.emit(".L_tl_print_i64_digit_loop:");
        self.emit("    xorq %rdx, %rdx");
        self.emit("    divq %r9");
        self.emit("    addb $48, %dl");
        self.emit("    decq %rsi");
        self.emit("    movb %dl, (%rsi)");
        self.emit("    incq %rcx");
        self.emit("    testq %rax, %rax");
        self.emit("    jne .L_tl_print_i64_digit_loop");
        self.emit("    testq %r8, %r8");
        self.emit("    jz .L_tl_print_i64_len_ready");
        self.emit("    decq %rsi");
        self.emit("    movb $45, (%rsi)");
        self.emit("    incq %rcx");
        self.emit(".L_tl_print_i64_len_ready:");
        self.emit("    movq %rcx, %rdx");
        self.emit(".L_tl_print_i64_write:");
        self.emit("    movq $1, %rax");
        self.emit("    movq $1, %rdi");
        self.emit("    syscall");
        self.emit("    mov %rbp, %rsp");
        self.emit("    pop %rbp");
        self.emit("    ret");
        self.emit("");

        self.emit("    .globl tl_print_bool");
        self.emit("tl_print_bool:");
        self.emit("    testb %dil, %dil");
        self.emit("    jz .L_tl_print_bool_false");
        self.emit("    leaq .L_tl_bool_true(%rip), %rsi");
        self.emit("    movq $5, %rdx");
        self.emit("    jmp .L_tl_print_bool_write");
        self.emit(".L_tl_print_bool_false:");
        self.emit("    leaq .L_tl_bool_false(%rip), %rsi");
        self.emit("    movq $6, %rdx");
        self.emit(".L_tl_print_bool_write:");
        self.emit("    movq $1, %rax");
        self.emit("    movq $1, %rdi");
        self.emit("    syscall");
        self.emit("    ret");
        self.emit("");

        self.emit("    .globl tl_print_f64");
        self.emit("tl_print_f64:");
        self.emit("    push %rbp");
        self.emit("    mov %rsp, %rbp");
        self.emit("    leaq .L_tl_fmt_f64(%rip), %rdi");
        self.emit("    movb $1, %al");
        self.emit("    call printf");
        self.emit("    xor %edi, %edi");
        self.emit("    call fflush");
        self.emit("    mov %rbp, %rsp");
        self.emit("    pop %rbp");
        self.emit("    ret");
        self.emit("");

        self.emit("    .globl tl_print_char");
        self.emit("tl_print_char:");
        self.emit("    push %rbp");
        self.emit("    mov %rsp, %rbp");
        self.emit("    sub $16, %rsp");
        self.emit("    movb %dil, -1(%rbp)");
        self.emit("    leaq -1(%rbp), %rsi");
        self.emit("    movq $1, %rdx");
        self.emit("    movq $1, %rax");
        self.emit("    movq $1, %rdi");
        self.emit("    syscall");
        self.emit("    mov %rbp, %rsp");
        self.emit("    pop %rbp");
        self.emit("    ret");
        self.emit("");

        self.emit("    .globl tl_print_newline");
        self.emit("tl_print_newline:");
        self.emit("    push %rbp");
        self.emit("    mov %rsp, %rbp");
        self.emit("    sub $16, %rsp");
        self.emit("    movb $10, -1(%rbp)");
        self.emit("    leaq -1(%rbp), %rsi");
        self.emit("    movq $1, %rdx");
        self.emit("    movq $1, %rax");
        self.emit("    movq $1, %rdi");
        self.emit("    syscall");
        self.emit("    mov %rbp, %rsp");
        self.emit("    pop %rbp");
        self.emit("    ret");
        self.emit("");
    }

    fn generate_windows_print_runtime_functions(&mut self) {
        self.emit("    .globl tl_print_i64");
        self.emit("tl_print_i64:");
        self.emit("    push %rbp");
        self.emit("    mov %rsp, %rbp");
        self.emit("    sub $48, %rsp");
        self.emit("    leaq -1(%rbp), %r10");
        self.emit("    movb $10, (%r10)");
        self.emit("    movq %rcx, %rax");
        self.emit("    movq $1, %rcx");
        self.emit("    cmpq $0, %rax");
        self.emit("    jne .L_tl_print_i64_win_nonzero");
        self.emit("    movb $48, -2(%rbp)");
        self.emit("    leaq -2(%rbp), %r10");
        self.emit("    movq $2, %rdx");
        self.emit("    jmp .L_tl_print_i64_win_write");
        self.emit(".L_tl_print_i64_win_nonzero:");
        self.emit("    movq $0, %r8");
        self.emit("    cmpq $0, %rax");
        self.emit("    jge .L_tl_print_i64_win_abs_ready");
        self.emit("    negq %rax");
        self.emit("    movq $1, %r8");
        self.emit(".L_tl_print_i64_win_abs_ready:");
        self.emit("    movq $10, %r9");
        self.emit(".L_tl_print_i64_win_digit_loop:");
        self.emit("    xorq %rdx, %rdx");
        self.emit("    divq %r9");
        self.emit("    addb $48, %dl");
        self.emit("    decq %r10");
        self.emit("    movb %dl, (%r10)");
        self.emit("    incq %rcx");
        self.emit("    testq %rax, %rax");
        self.emit("    jne .L_tl_print_i64_win_digit_loop");
        self.emit("    testq %r8, %r8");
        self.emit("    jz .L_tl_print_i64_win_len_ready");
        self.emit("    decq %r10");
        self.emit("    movb $45, (%r10)");
        self.emit("    incq %rcx");
        self.emit(".L_tl_print_i64_win_len_ready:");
        self.emit("    movq %rcx, %rdx");
        self.emit(".L_tl_print_i64_win_write:");
        self.emit("    movq %rdx, %r8");
        self.emit("    movq %r10, %rdx");
        self.emit("    movq $1, %rcx");
        self.emit_call("_write");
        self.emit("    mov %rbp, %rsp");
        self.emit("    pop %rbp");
        self.emit("    ret");
        self.emit("");

        self.emit("    .globl tl_print_bool");
        self.emit("tl_print_bool:");
        self.emit("    push %rbp");
        self.emit("    mov %rsp, %rbp");
        self.emit("    testb %cl, %cl");
        self.emit("    jz .L_tl_print_bool_win_false");
        self.emit("    leaq .L_tl_bool_true(%rip), %rdx");
        self.emit("    movq $5, %r8");
        self.emit("    jmp .L_tl_print_bool_win_write");
        self.emit(".L_tl_print_bool_win_false:");
        self.emit("    leaq .L_tl_bool_false(%rip), %rdx");
        self.emit("    movq $6, %r8");
        self.emit(".L_tl_print_bool_win_write:");
        self.emit("    movq $1, %rcx");
        self.emit_call("_write");
        self.emit("    mov %rbp, %rsp");
        self.emit("    pop %rbp");
        self.emit("    ret");
        self.emit("");

        self.emit("    .globl tl_print_f64");
        self.emit("tl_print_f64:");
        self.emit("    push %rbp");
        self.emit("    mov %rsp, %rbp");
        self.emit("    movsd %xmm0, %xmm1");
        self.emit("    movq %xmm0, %rdx");
        self.emit("    leaq .L_tl_fmt_f64(%rip), %rcx");
        self.emit_call("printf");
        self.emit("    xorq %rcx, %rcx");
        self.emit_call("fflush");
        self.emit("    mov %rbp, %rsp");
        self.emit("    pop %rbp");
        self.emit("    ret");
        self.emit("");

        self.emit("    .globl tl_print_char");
        self.emit("tl_print_char:");
        self.emit("    push %rbp");
        self.emit("    mov %rsp, %rbp");
        self.emit("    sub $16, %rsp");
        self.emit("    movb %cl, -1(%rbp)");
        self.emit("    leaq -1(%rbp), %rdx");
        self.emit("    movq $1, %r8");
        self.emit("    movq $1, %rcx");
        self.emit_call("_write");
        self.emit("    mov %rbp, %rsp");
        self.emit("    pop %rbp");
        self.emit("    ret");
        self.emit("");

        self.emit("    .globl tl_print_newline");
        self.emit("tl_print_newline:");
        self.emit("    push %rbp");
        self.emit("    mov %rsp, %rbp");
        self.emit("    sub $16, %rsp");
        self.emit("    movb $10, -1(%rbp)");
        self.emit("    leaq -1(%rbp), %rdx");
        self.emit("    movq $1, %r8");
        self.emit("    movq $1, %rcx");
        self.emit_call("_write");
        self.emit("    mov %rbp, %rsp");
        self.emit("    pop %rbp");
        self.emit("    ret");
        self.emit("");
    }

    /// Emit the `.bss` storage backing the bump allocator: a pointer to the
    /// current arena record. Each mapped arena starts with a 32-byte header:
    /// previous arena, payload base, current bump pointer, and end pointer.
    /// A zero `tl_current_arena` signals "no arena yet" and triggers lazy
    /// `mmap` on the first allocation.
    fn generate_alloc_runtime_data(&mut self) {
        if self.target.runtime_policy().emits_windows_runtime_helpers {
            return;
        }

        self.emit("    .section .bss");
        self.emit("    .balign 8");
        self.emit("tl_current_arena:");
        self.emit("    .zero 8");
        self.emit("");
    }

    fn generate_argv_runtime_data(&mut self) {
        self.emit("    .data");
        self.emit("    .balign 8");
        self.emit(".L_tl_argc:");
        self.emit("    .quad 0");
        self.emit(".L_tl_argv:");
        self.emit("    .quad 0");
        if self.needs_arg_runtime {
            self.emit("    .section .rodata");
            self.emit(".L_tl_arg_oob_msg:");
            self.emit("    .ascii \"tl: argv index out of bounds\\n\"");
            self.emit("    .set .L_tl_arg_oob_msg_len, . - .L_tl_arg_oob_msg");
        }
        self.emit("");
    }

    fn generate_env_runtime_data(&mut self) {
        self.emit("    .data");
        self.emit("    .balign 8");
        self.emit(".L_tl_envp:");
        self.emit("    .quad 0");
        self.emit("");
    }

    /// Emit the fixed-text message consumed by `tl_alloc`'s self-contained
    /// failure trap. Kept separate so the `.rodata` label can be referenced
    /// from the allocator without depending on the generic `.L_tl_abort` path
    /// (which is only emitted when `needs_abort_runtime` is true).
    fn generate_alloc_failure_data(&mut self) {
        self.emit("    .section .rodata");
        self.emit(".L_tl_alloc_msg:");
        self.emit("    .ascii \"tl: allocation failed\\n\"");
        self.emit("    .set .L_tl_alloc_msg_len, . - .L_tl_alloc_msg");
        self.emit("");
    }

    fn generate_region_reset_failure_data(&mut self) {
        self.emit("    .section .rodata");
        self.emit(".L_tl_region_reset_msg:");
        self.emit("    .ascii \"tl: invalid region mark\\n\"");
        self.emit("    .set .L_tl_region_reset_msg_len, . - .L_tl_region_reset_msg");
        self.emit("");
    }

    /// Walk the whole program and assign each distinct string-literal value a
    /// stable `.rodata` label, so identical literals share one set of bytes and
    /// every `Value::ConstStr` can be materialized as `leaq label(%rip)`.
    fn intern_strings(&mut self, program: &Program) {
        let mut next = 0u32;
        for func in &program.functions {
            for block in &func.blocks {
                for instr in &block.instructions {
                    Self::collect_const_strs(instr, &mut self.interned_strings, &mut next);
                }
            }
        }
    }

    fn collect_const_strs(
        instr: &Instruction,
        table: &mut HashMap<String, String>,
        next: &mut u32,
    ) {
        let mut intern = |s: &String| {
            if !table.contains_key(s) {
                table.insert(s.clone(), format!(".L_tl_str_{}", *next));
                *next += 1;
            }
        };
        match instr {
            Instruction::Store { src, .. } | Instruction::Mov { src, .. } => {
                if let Value::ConstStr(s) = src {
                    intern(s);
                }
            }
            Instruction::Call { args, .. }
            | Instruction::CallIndirect { args, .. }
            | Instruction::TailCall { args, .. } => {
                for a in args {
                    if let Value::ConstStr(s) = a {
                        intern(s);
                    }
                }
            }
            Instruction::Return(Some(Value::ConstStr(s))) => intern(s),
            _ => {}
        }
    }

    /// Emit interned string-literal bytes into `.rodata`. Each literal is a NUL
    /// -terminated byte sequence; the language-level length is carried in the
    /// fat value's `len` field, so the terminator is incidental (it lets the
    /// bytes double as a C string for any future libc interop).
    fn generate_string_rodata(&mut self) {
        if self.interned_strings.is_empty() {
            return;
        }
        // Emit in label order so output is deterministic regardless of HashMap
        // iteration order.
        let mut entries: Vec<(String, String)> = self
            .interned_strings
            .iter()
            .map(|(s, l)| (l.clone(), s.clone()))
            .collect();
        entries.sort_by(|a, b| a.0.cmp(&b.0));

        self.emit("    .section .rodata");
        for (label, text) in entries {
            self.emit(&format!("{}:", label));
            self.emit(&format!("    .string {}", Self::escape_string_bytes(&text)));
        }
        self.emit("");
    }

    fn collect_closure_descriptor_names(program: &Program) -> BTreeSet<String> {
        let mut names = BTreeSet::new();
        for (_, _, init) in &program.globals {
            if let Some(value) = init {
                Self::collect_function_value(value, &mut names);
            }
        }
        for func in &program.functions {
            for block in &func.blocks {
                for instr in &block.instructions {
                    Self::collect_function_values_in_instruction(instr, &mut names);
                }
            }
        }
        names
    }

    fn collect_function_values_in_instruction(instr: &Instruction, names: &mut BTreeSet<String>) {
        match instr {
            Instruction::BinOp { lhs, rhs, .. }
            | Instruction::VectorBinOp { lhs, rhs, .. }
            | Instruction::VectorCompare { lhs, rhs, .. }
            | Instruction::MaskBinOp { lhs, rhs, .. } => {
                Self::collect_function_value(lhs, names);
                Self::collect_function_value(rhs, names);
            }
            Instruction::UnOp { src, .. }
            | Instruction::Mov { src, .. }
            | Instruction::Cast { src, .. }
            | Instruction::Load { src, .. }
            | Instruction::Branch { cond: src, .. }
            | Instruction::Splat { value: src, .. }
            | Instruction::VectorReduce { src, .. }
            | Instruction::MaskReduce { src, .. }
            | Instruction::MaskNot { src, .. } => {
                Self::collect_function_value(src, names);
            }
            Instruction::Store { dst, src, .. } => {
                Self::collect_function_value(dst, names);
                Self::collect_function_value(src, names);
            }
            Instruction::Call { args, .. } | Instruction::TailCall { args, .. } => {
                for arg in args {
                    Self::collect_function_value(arg, names);
                }
            }
            Instruction::CallIndirect { func, args, .. } => {
                Self::collect_function_value(func, names);
                for arg in args {
                    Self::collect_function_value(arg, names);
                }
            }
            Instruction::Return(Some(value)) => {
                Self::collect_function_value(value, names);
            }
            Instruction::Gep { base, offset, .. } => {
                Self::collect_function_value(base, names);
                Self::collect_function_value(offset, names);
            }
            Instruction::Select {
                mask,
                on_true,
                on_false,
                ..
            } => {
                Self::collect_function_value(mask, names);
                Self::collect_function_value(on_true, names);
                Self::collect_function_value(on_false, names);
            }
            Instruction::VectorLoad { base, index, .. } => {
                Self::collect_function_value(base, names);
                Self::collect_function_value(index, names);
            }
            Instruction::VectorStore {
                base, index, value, ..
            } => {
                Self::collect_function_value(base, names);
                Self::collect_function_value(index, names);
                Self::collect_function_value(value, names);
            }
            Instruction::PredicatedStore {
                base,
                index,
                value,
                mask,
                ..
            } => {
                Self::collect_function_value(base, names);
                Self::collect_function_value(index, names);
                Self::collect_function_value(value, names);
                Self::collect_function_value(mask, names);
            }
            Instruction::PredicatedLoad {
                base, index, mask, ..
            } => {
                Self::collect_function_value(base, names);
                Self::collect_function_value(index, names);
                Self::collect_function_value(mask, names);
            }
            Instruction::TailMask { index, len, .. } => {
                Self::collect_function_value(index, names);
                Self::collect_function_value(len, names);
            }
            Instruction::Phi { incoming, .. } => {
                for (value, _) in incoming {
                    Self::collect_function_value(value, names);
                }
            }
            Instruction::AddrOf { .. }
            | Instruction::Jump(_)
            | Instruction::Alloc { .. }
            | Instruction::LaneId { .. }
            | Instruction::Return(None) => {}
        }
    }

    fn collect_function_value(value: &Value, names: &mut BTreeSet<String>) {
        if let Value::Function(name) = value {
            names.insert(name.clone());
        }
    }

    fn generate_closure_descriptor_data(&mut self) {
        if self.closure_descriptor_names.is_empty() {
            return;
        }

        let names: Vec<String> = self.closure_descriptor_names.iter().cloned().collect();
        self.emit("    .section .rodata");
        self.emit("    .balign 8");
        for name in names {
            if !self.function_sigs.contains_key(&name) {
                continue;
            }
            self.emit(&format!("{}:", Self::closure_descriptor_label(&name)));
            self.emit(&format!("    .quad {}", Self::closure_entry_label(&name)));
            self.emit("    .quad 0");
        }
        self.emit("");
    }

    fn generate_closure_entry_adapters(&mut self) {
        if self.closure_descriptor_names.is_empty() {
            return;
        }

        let names: Vec<String> = self.closure_descriptor_names.iter().cloned().collect();
        for name in names {
            if let Some((arg_tys, ret_ty)) = self.function_sigs.get(&name).cloned() {
                self.generate_closure_entry_adapter(&name, &arg_tys, &ret_ty);
            }
        }
    }

    fn generate_closure_entry_adapter(&mut self, name: &str, arg_tys: &[Type], ret_ty: &Type) {
        let saved_stack_size = self.stack_size;
        let saved_var_offsets = std::mem::take(&mut self.var_offsets);
        let saved_var_types = std::mem::take(&mut self.var_types);
        let saved_address_vars = std::mem::take(&mut self.address_vars);
        let saved_return_ty = self.return_ty.clone();
        let saved_param_vars = std::mem::take(&mut self.param_vars);
        let saved_current_fn = std::mem::take(&mut self.current_fn);
        let saved_current_entry_label = std::mem::take(&mut self.current_entry_label);
        let saved_current_params = std::mem::take(&mut self.current_params);

        self.stack_size = 0;
        self.return_ty = ret_ty.clone();
        self.current_fn = Self::closure_entry_label(name);
        self.current_entry_label.clear();
        self.current_params.clear();
        self.emit(&format!("{}:", self.current_fn));
        self.emit("    push %rbp");
        self.emit("    mov %rsp, %rbp");

        for (idx, ty) in arg_tys.iter().enumerate() {
            let var = idx as VarId;
            self.var_types.insert(var, ty.clone());
            if *ty == Type::Unit {
                self.var_offsets.insert(var, 0);
                continue;
            }

            let size = ty.size() as i32;
            let align = ty.align() as i32;
            self.stack_size = (self.stack_size + align - 1) & !(align - 1);
            self.stack_size += size;
            self.var_offsets.insert(var, -self.stack_size);
        }

        self.stack_size = (self.stack_size + 15) & !15;
        if self.stack_size > 0 {
            self.emit(&format!("    sub ${}, %rsp", self.stack_size));
        }

        self.store_closure_entry_user_args(arg_tys);

        let call_args: Vec<Value> = (0..arg_tys.len())
            .map(|idx| Value::Var(idx as VarId))
            .collect();
        let stack_arg_space = self.load_call_args(&call_args);
        self.emit(&format!("    call {}", self.call_symbol(name)));
        self.release_call_args(stack_arg_space);
        self.emit("    mov %rbp, %rsp");
        self.emit("    pop %rbp");
        self.emit("    ret");
        self.emit("");

        self.stack_size = saved_stack_size;
        self.var_offsets = saved_var_offsets;
        self.var_types = saved_var_types;
        self.address_vars = saved_address_vars;
        self.return_ty = saved_return_ty;
        self.param_vars = saved_param_vars;
        self.current_fn = saved_current_fn;
        self.current_entry_label = saved_current_entry_label;
        self.current_params = saved_current_params;
    }

    fn store_closure_entry_user_args(&mut self, arg_tys: &[Type]) {
        let calling_convention = self.target.calling_convention();
        let param_regs = calling_convention.integer_arg_regs;
        let xmm_regs = calling_convention.float_arg_regs;
        let mut int_param = 1;
        let mut float_param = 0;
        let mut stack_param = 0;
        let mut arg_position = 1;

        for (idx, ty) in arg_tys.iter().enumerate() {
            if *ty == Type::Unit {
                continue;
            }
            let offset = self.var_offsets[&(idx as VarId)];
            if let Some(shared_slots) = calling_convention.shared_arg_register_slots {
                if arg_position < shared_slots {
                    let reg = if is_scalar_float(ty) {
                        xmm_regs[arg_position]
                    } else {
                        param_regs[arg_position]
                    };
                    self.store_incoming_register_param(reg, offset, ty);
                } else {
                    self.store_incoming_stack_param(stack_param, offset, ty);
                    stack_param += 1;
                }
                arg_position += 1;
                continue;
            }

            if is_scalar_float(ty) {
                if float_param < xmm_regs.len() {
                    self.store_incoming_register_param(xmm_regs[float_param], offset, ty);
                } else {
                    self.store_incoming_stack_param(stack_param, offset, ty);
                    stack_param += 1;
                }
                float_param += 1;
            } else {
                if int_param < param_regs.len() {
                    self.store_incoming_register_param(param_regs[int_param], offset, ty);
                } else {
                    self.store_incoming_stack_param(stack_param, offset, ty);
                    stack_param += 1;
                }
                int_param += 1;
            }
        }
    }

    /// Render `text` as a GAS string-literal token (`"..."`) with the bytes the
    /// language string holds escaped so the assembler reproduces them exactly.
    fn escape_string_bytes(text: &str) -> String {
        let mut out = String::with_capacity(text.len() + 2);
        out.push('"');
        for b in text.bytes() {
            match b {
                b'"' => out.push_str("\\\""),
                b'\\' => out.push_str("\\\\"),
                b'\n' => out.push_str("\\n"),
                b'\t' => out.push_str("\\t"),
                b'\r' => out.push_str("\\r"),
                0x20..=0x7e => out.push(b as char),
                // Non-printable / non-ASCII bytes as octal escapes.
                other => out.push_str(&format!("\\{:03o}", other)),
            }
        }
        out.push('"');
        out
    }

    /// Emit the self-contained bump allocator `tl_alloc(size) -> ptr`.
    ///
    /// ABI (System V): the byte count arrives in `%rdi`, the returned pointer
    /// leaves in `%rax`. The allocator rounds the request up to 8 bytes, then
    /// bumps the current arena record's bump pointer. When the arena is empty
    /// (lazy init) or exhausted it `mmap`s a fresh anonymous arena of at least
    /// `max(ARENA_SIZE, request + header)` bytes via the raw `mmap` syscall
    /// (no libc). Each arena records its previous arena so later region-reset
    /// work can restore or discard arenas without changing today's process-
    /// lifetime behavior.
    fn generate_alloc_runtime_functions(&mut self) {
        if self.target.runtime_policy().emits_windows_runtime_helpers {
            self.generate_windows_alloc_runtime_functions();
            return;
        }

        // Arena granule: 64 MiB. `mmap` syscall number is 9; PROT_READ|PROT_WRITE
        // = 3; MAP_PRIVATE|MAP_ANONYMOUS = 0x22; fd = -1; offset = 0. The 4th
        // syscall argument is passed in %r10 (not %rcx) per the syscall ABI.
        // Arena header layout:
        //   0: previous arena header pointer
        //   8: payload base pointer
        //  16: current bump pointer
        //  24: one-past-the-end pointer
        self.emit("    .globl tl_alloc");
        self.emit("tl_alloc:");
        // Round the requested size up to an 8-byte boundary: size = (size+7)&~7.
        self.emit("    addq $7, %rdi");
        self.emit("    jc .L_tl_alloc_abort"); // alignment-rounding overflow
        self.emit("    andq $-8, %rdi");
        // %rsi holds the (aligned) request size for the duration of the routine.
        self.emit("    movq %rdi, %rsi");
        // If no arena has been mapped yet, go map one.
        self.emit("    movq tl_current_arena(%rip), %r8");
        self.emit("    testq %r8, %r8");
        self.emit("    jz .L_tl_alloc_new_arena");
        self.emit("    movq 16(%r8), %rax");
        // Enough room left? new_ptr = ptr + size; if new_ptr <= end, bump.
        self.emit("    movq %rax, %rcx");
        self.emit("    addq %rsi, %rcx");
        self.emit("    jc .L_tl_alloc_abort"); // pointer overflow
        self.emit("    cmpq 24(%r8), %rcx");
        self.emit("    ja .L_tl_alloc_new_arena");
        // Fast path: commit the bump and return the old pointer (already in %rax).
        self.emit("    movq %rcx, 16(%r8)");
        self.emit("    ret");
        self.emit(".L_tl_alloc_new_arena:");
        // Choose arena length = max(ARENA_SIZE, aligned request + 32-byte header).
        self.emit("    movq $0x4000000, %rdx");
        self.emit("    movq %rsi, %rcx");
        self.emit("    addq $32, %rcx");
        self.emit("    jc .L_tl_alloc_abort"); // request + header overflow
        self.emit("    cmpq %rdx, %rcx");
        self.emit("    jbe .L_tl_alloc_len_ready");
        self.emit("    movq %rcx, %rdx");
        self.emit(".L_tl_alloc_len_ready:");
        // mmap(NULL, len, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0).
        // Preserve len and request size across the syscall (which clobbers
        // %rcx/%r11) on the stack.
        self.emit("    push %rdx");
        self.emit("    push %rsi");
        self.emit("    movq %rdx, %rsi");
        self.emit("    xorq %rdi, %rdi");
        self.emit("    movq $3, %rdx");
        self.emit("    movq $0x22, %r10");
        self.emit("    movq $-1, %r8");
        self.emit("    xorq %r9, %r9");
        self.emit("    movq $9, %rax");
        self.emit("    syscall");
        self.emit("    pop %rsi");
        self.emit("    pop %rdx");
        // %rax = arena base, or a negative errno on failure. Trap on failure.
        self.emit("    testq %rax, %rax");
        self.emit("    js .L_tl_alloc_abort");
        // Set end = base + len, ptr = base + size, return base. The end
        // carry check also proves base + size cannot wrap because size <= len.
        self.emit("    movq %rax, %rcx");
        self.emit("    addq %rdx, %rcx");
        self.emit("    jc .L_tl_alloc_abort"); // arena end overflow
        // Initialize the arena record at the start of the mapping and make it
        // current. Payload starts immediately after the 32-byte header.
        self.emit("    movq tl_current_arena(%rip), %r8");
        self.emit("    movq %r8, 0(%rax)");
        self.emit("    leaq 32(%rax), %r8");
        self.emit("    movq %r8, 8(%rax)");
        self.emit("    movq %rcx, 24(%rax)");
        self.emit("    movq %r8, %rcx");
        self.emit("    addq %rsi, %rcx");
        self.emit("    movq %rcx, 16(%rax)");
        self.emit("    movq %rax, tl_current_arena(%rip)");
        self.emit("    movq %r8, %rax");
        self.emit("    ret");
        self.emit(".L_tl_alloc_abort:");
        // Self-contained trap: write diagnostic to stderr, then exit(134).
        self.emit("    movq $1, %rax");
        self.emit("    movq $2, %rdi");
        self.emit("    leaq .L_tl_alloc_msg(%rip), %rsi");
        self.emit("    movq $.L_tl_alloc_msg_len, %rdx");
        self.emit("    syscall");
        self.emit("    movq $60, %rax");
        self.emit("    movq $134, %rdi");
        self.emit("    syscall");
        self.emit("");
    }

    fn generate_region_mark_runtime_function(&mut self) {
        self.emit(&format!("    .globl {}", REGION_MARK_RUNTIME_SYMBOL));
        self.emit(&format!("{}:", REGION_MARK_RUNTIME_SYMBOL));
        self.emit("    movq tl_current_arena(%rip), %rax");
        self.emit("    testq %rax, %rax");
        self.emit("    jz .L_tl_region_mark_zero");
        self.emit("    movq 16(%rax), %rax");
        self.emit("    ret");
        self.emit(".L_tl_region_mark_zero:");
        self.emit("    xorq %rax, %rax");
        self.emit("    ret");
        self.emit("");
    }

    fn generate_region_reset_runtime_function(&mut self) {
        self.emit(&format!("    .globl {}", REGION_RESET_RUNTIME_SYMBOL));
        self.emit(&format!("{}:", REGION_RESET_RUNTIME_SYMBOL));
        self.emit("    push %rbx");
        self.emit("    movq %rdi, %rbx");
        self.emit("    testq %rbx, %rbx");
        self.emit("    jz .L_tl_region_reset_all");

        // Find the arena whose payload range contains the mark.
        self.emit("    movq tl_current_arena(%rip), %r8");
        self.emit("    testq %r8, %r8");
        self.emit("    jz .L_tl_region_reset_invalid");
        self.emit(".L_tl_region_reset_find:");
        self.emit("    movq 8(%r8), %r9");
        self.emit("    cmpq %r9, %rbx");
        self.emit("    jb .L_tl_region_reset_next");
        self.emit("    movq 24(%r8), %r9");
        self.emit("    cmpq %r9, %rbx");
        self.emit("    jbe .L_tl_region_reset_found");
        self.emit(".L_tl_region_reset_next:");
        self.emit("    movq 0(%r8), %r8");
        self.emit("    testq %r8, %r8");
        self.emit("    jnz .L_tl_region_reset_find");
        self.emit("    jmp .L_tl_region_reset_invalid");

        // Drop arenas newer than the marked arena, then restore that arena's bump.
        self.emit(".L_tl_region_reset_found:");
        self.emit("    movq tl_current_arena(%rip), %r9");
        self.emit(".L_tl_region_reset_drop_newer:");
        self.emit("    cmpq %r8, %r9");
        self.emit("    je .L_tl_region_reset_restore");
        self.emit("    movq 0(%r9), %r10");
        self.emit("    movq 24(%r9), %rsi");
        self.emit("    subq %r9, %rsi");
        self.emit("    movq %r9, %rdi");
        self.emit("    push %r8");
        self.emit("    push %r10");
        self.emit("    movq $11, %rax");
        self.emit("    syscall");
        self.emit("    pop %r10");
        self.emit("    pop %r8");
        self.emit("    movq %r10, %r9");
        self.emit("    jmp .L_tl_region_reset_drop_newer");
        self.emit(".L_tl_region_reset_restore:");
        self.emit("    movq %rbx, 16(%r8)");
        self.emit("    movq %r8, tl_current_arena(%rip)");
        self.emit("    pop %rbx");
        self.emit("    ret");

        // A zero mark means discard every current arena and return to lazy-init.
        self.emit(".L_tl_region_reset_all:");
        self.emit("    movq tl_current_arena(%rip), %r8");
        self.emit("    movq $0, tl_current_arena(%rip)");
        self.emit(".L_tl_region_reset_all_loop:");
        self.emit("    testq %r8, %r8");
        self.emit("    jz .L_tl_region_reset_done");
        self.emit("    movq 0(%r8), %r9");
        self.emit("    movq 24(%r8), %rsi");
        self.emit("    subq %r8, %rsi");
        self.emit("    movq %r8, %rdi");
        self.emit("    push %r9");
        self.emit("    movq $11, %rax");
        self.emit("    syscall");
        self.emit("    pop %r8");
        self.emit("    jmp .L_tl_region_reset_all_loop");
        self.emit(".L_tl_region_reset_done:");
        self.emit("    pop %rbx");
        self.emit("    ret");

        self.emit(".L_tl_region_reset_invalid:");
        self.emit("    movq $1, %rax");
        self.emit("    movq $2, %rdi");
        self.emit("    leaq .L_tl_region_reset_msg(%rip), %rsi");
        self.emit("    movq $.L_tl_region_reset_msg_len, %rdx");
        self.emit("    syscall");
        self.emit("    movq $60, %rax");
        self.emit("    movq $134, %rdi");
        self.emit("    syscall");
        self.emit("");
    }

    fn generate_windows_alloc_runtime_functions(&mut self) {
        self.emit("    .globl tl_alloc");
        self.emit("tl_alloc:");
        self.emit("    push %rbp");
        self.emit("    mov %rsp, %rbp");
        self.emit("    testq %rcx, %rcx");
        self.emit("    jg .L_tl_alloc_win_size_ready");
        self.emit("    movq $1, %rcx");
        self.emit(".L_tl_alloc_win_size_ready:");
        self.emit_call("malloc");
        self.emit("    testq %rax, %rax");
        self.emit("    jz .L_tl_alloc_abort");
        self.emit("    mov %rbp, %rsp");
        self.emit("    pop %rbp");
        self.emit("    ret");
        self.emit(".L_tl_alloc_abort:");
        self.emit("    movq $2, %rcx");
        self.emit("    leaq .L_tl_alloc_msg(%rip), %rdx");
        self.emit("    movq $.L_tl_alloc_msg_len, %r8");
        self.emit_call("_write");
        self.emit("    movq $134, %rcx");
        self.emit_call("exit");
        self.emit("");
    }

    /// The abort message written to fd 2 (stderr) on an out-of-bounds access.
    fn generate_oob_runtime_data(&mut self) {
        self.emit("    .section .rodata");
        self.emit(".L_tl_oob_msg:");
        self.emit("    .ascii \"tl: array index out of bounds\\n\"");
        self.emit("    .set .L_tl_oob_msg_len, . - .L_tl_oob_msg");
        self.emit("");
    }

    fn generate_read_file_runtime_data(&mut self) {
        self.emit("    .section .rodata");
        self.emit(".L_tl_read_file_error_msg:");
        self.emit("    .ascii \"tl: read-file failed\\n\"");
        self.emit("    .set .L_tl_read_file_error_msg_len, . - .L_tl_read_file_error_msg");
        self.emit("");
    }

    fn generate_write_file_runtime_data(&mut self) {
        self.emit("    .section .rodata");
        self.emit(".L_tl_write_file_error_msg:");
        self.emit("    .ascii \"tl: write-file failed\\n\"");
        self.emit("    .set .L_tl_write_file_error_msg_len, . - .L_tl_write_file_error_msg");
        self.emit("");
    }

    fn generate_file_exists_runtime_data(&mut self) {
        self.emit("    .section .rodata");
        self.emit(".L_tl_file_exists_error_msg:");
        self.emit("    .ascii \"tl: file-exists? failed\\n\"");
        self.emit("    .set .L_tl_file_exists_error_msg_len, . - .L_tl_file_exists_error_msg");
        self.emit("");
    }

    fn generate_stdin_runtime_data(&mut self) {
        self.emit("    .data");
        self.emit("    .balign 8");
        self.emit(".L_tl_stdin_eof_flag:");
        self.emit("    .quad 0");
        if self.needs_read_stdin_line_runtime || self.needs_read_stdin_bytes_runtime {
            self.emit("    .section .rodata");
            self.emit(".L_tl_stdin_error_msg:");
            self.emit("    .ascii \"tl: stdin failed\\n\"");
            self.emit("    .set .L_tl_stdin_error_msg_len, . - .L_tl_stdin_error_msg");
        }
        self.emit("");
    }

    fn generate_flush_stdout_runtime_data(&mut self) {
        if !self.target.runtime_policy().emits_windows_runtime_helpers {
            return;
        }

        self.emit("    .section .rodata");
        self.emit(".L_tl_flush_stdout_error_msg:");
        self.emit("    .ascii \"tl: flush-stdout failed\\n\"");
        self.emit("    .set .L_tl_flush_stdout_error_msg_len, . - .L_tl_flush_stdout_error_msg");
        self.emit("");
    }

    fn generate_process_output_runtime_data(&mut self) {
        self.emit("    .section .rodata");
        self.emit(".L_tl_process_unsupported_msg:");
        self.emit("    .ascii \"process: runtime execution is not supported on this target\"");
        self.emit("    .set .L_tl_process_unsupported_msg_len, . - .L_tl_process_unsupported_msg");
        self.emit(".L_tl_process_spawn_msg:");
        self.emit("    .ascii \"process: spawn failed\"");
        self.emit("    .set .L_tl_process_spawn_msg_len, . - .L_tl_process_spawn_msg");
        self.emit(".L_tl_process_wait_msg:");
        self.emit("    .ascii \"process: wait failed\"");
        self.emit("    .set .L_tl_process_wait_msg_len, . - .L_tl_process_wait_msg");
        self.emit(".L_tl_process_exec_marker:");
        self.emit("    .ascii \"exec\"");
        self.emit("    .set .L_tl_process_exec_marker_len, . - .L_tl_process_exec_marker");
        self.emit(".L_tl_process_stdout_name:");
        self.emit("    .ascii \"typelisp-process-stdout\"");
        self.emit("    .byte 0");
        self.emit(".L_tl_process_stderr_name:");
        self.emit("    .ascii \"typelisp-process-stderr\"");
        self.emit("    .byte 0");
        self.emit(".L_tl_process_stdin_name:");
        self.emit("    .ascii \"typelisp-process-stdin\"");
        self.emit("    .byte 0");
        self.emit("");
    }

    /// The abort message written to fd 2 (stderr) on illegal integer division
    /// or remainder (divide-by-zero or signed overflow).
    fn generate_div_runtime_data(&mut self) {
        self.emit("    .section .rodata");
        self.emit(".L_tl_div_msg:");
        self.emit("    .ascii \"tl: integer division or remainder error\\n\"");
        self.emit("    .set .L_tl_div_msg_len, . - .L_tl_div_msg");
        self.emit("");
    }

    /// Emit the self-contained division abort `tl_div_abort()`. It writes a
    /// diagnostic to fd 2 via the `write(2)` syscall, then terminates the
    /// process with status 135 via the `exit(2)` syscall. Because it is a `Call`
    /// the optimizer cannot drop the guard.
    fn generate_div_runtime_functions(&mut self) {
        if self.target.runtime_policy().emits_windows_runtime_helpers {
            self.generate_windows_fixed_abort_runtime_function(
                "tl_div_abort",
                ".L_tl_div_msg",
                ".L_tl_div_msg_len",
                135,
            );
            return;
        }

        self.emit("    .globl tl_div_abort");
        self.emit("tl_div_abort:");
        self.emit("    movq $1, %rax");
        self.emit("    movq $2, %rdi");
        self.emit("    leaq .L_tl_div_msg(%rip), %rsi");
        self.emit("    movq $.L_tl_div_msg_len, %rdx");
        self.emit("    syscall");
        self.emit("    movq $60, %rax");
        self.emit("    movq $135, %rdi");
        self.emit("    syscall");
        self.emit("");
    }

    /// The abort message written to fd 2 (stderr) on illegal shift counts.
    fn generate_shift_runtime_data(&mut self) {
        self.emit("    .section .rodata");
        self.emit(".L_tl_shift_msg:");
        self.emit("    .ascii \"tl: shift count out of range\\n\"");
        self.emit("    .set .L_tl_shift_msg_len, . - .L_tl_shift_msg");
        self.emit("");
    }

    /// Emit the self-contained shift abort `tl_shift_abort()`. It writes a
    /// diagnostic to fd 2 via the `write(2)` syscall, then terminates the
    /// process with status 129 via the `exit(2)` syscall. Because it is a `Call`
    /// the optimizer cannot drop the guard.
    fn generate_shift_runtime_functions(&mut self) {
        if self.target.runtime_policy().emits_windows_runtime_helpers {
            self.generate_windows_fixed_abort_runtime_function(
                "tl_shift_abort",
                ".L_tl_shift_msg",
                ".L_tl_shift_msg_len",
                129,
            );
            return;
        }

        self.emit("    .globl tl_shift_abort");
        self.emit("tl_shift_abort:");
        self.emit("    movq $1, %rax");
        self.emit("    movq $2, %rdi");
        self.emit("    leaq .L_tl_shift_msg(%rip), %rsi");
        self.emit("    movq $.L_tl_shift_msg_len, %rdx");
        self.emit("    syscall");
        self.emit("    movq $60, %rax");
        self.emit("    movq $129, %rdi");
        self.emit("    syscall");
        self.emit("");
    }

    /// Emit the self-contained out-of-bounds abort `tl_oob_abort()`. It writes a
    /// diagnostic to fd 2 via the `write(2)` syscall, then terminates the process
    /// with the conventional "aborted" status 134 via the `exit(2)` syscall. It
    /// is zero-dependency (no libc) and never returns. Bounds-checked array
    /// accesses `Call` this symbol on the out-of-bounds path; because it is a
    /// `Call` the optimizer's dead-code elimination cannot drop the check.
    fn generate_oob_runtime_functions(&mut self) {
        if self.target.runtime_policy().emits_windows_runtime_helpers {
            self.generate_windows_fixed_abort_runtime_function(
                "tl_oob_abort",
                ".L_tl_oob_msg",
                ".L_tl_oob_msg_len",
                134,
            );
            return;
        }

        self.emit("    .globl tl_oob_abort");
        self.emit("tl_oob_abort:");
        // write(2 /*fd=stderr*/, msg, len). syscall number 1; args rdi/rsi/rdx.
        self.emit("    movq $1, %rax");
        self.emit("    movq $2, %rdi");
        self.emit("    leaq .L_tl_oob_msg(%rip), %rsi");
        self.emit("    movq $.L_tl_oob_msg_len, %rdx");
        self.emit("    syscall");
        // exit(134). syscall number 60; status in rdi. 134 = 128 + SIGABRT(6),
        // the conventional status for an aborted process.
        self.emit("    movq $60, %rax");
        self.emit("    movq $134, %rdi");
        self.emit("    syscall");
        self.emit("");
    }

    /// Emit the self-contained message-abort helper `(ptr, len)`. It
    /// writes the caller-supplied message buffer to fd 2 (stderr) via the
    /// `write(2)` syscall, then terminates the process with the conventional
    /// "aborted" status 134 via the `exit(2)` syscall. Unlike the fixed-text
    /// `tl_oob_abort`, the message comes from the operand `(ptr, len)`, so no
    /// rodata is emitted. It is zero-dependency (no libc) and never returns.
    /// `(panic msg)` / `(error msg)` `Call` this private symbol; because it is a
    /// `Call` the optimizer's dead-code elimination cannot drop it.
    ///
    /// ABI (System V): `ptr` in `%rdi`, `len` in `%rsi`. The `write(2)` syscall
    /// wants fd in `%rdi`, buf in `%rsi`, count in `%rdx`, so the operands are
    /// shuffled (`%rdx <- len`, `%rsi <- ptr`, `%rdi <- 2`) before the syscall.
    fn generate_abort_runtime_functions(&mut self) {
        if self.target.runtime_policy().emits_windows_runtime_helpers {
            self.generate_windows_abort_runtime_functions();
            return;
        }

        self.emit(&format!("{}:", ABORT_RUNTIME_SYMBOL));
        // write(2 /*fd=stderr*/, ptr, len). syscall number 1; args rdi/rsi/rdx.
        // Move len (rsi) -> rdx before clobbering rsi with ptr (rdi).
        self.emit("    movq %rsi, %rdx");
        self.emit("    movq %rdi, %rsi");
        self.emit("    movq $2, %rdi");
        self.emit("    movq $1, %rax");
        self.emit("    syscall");
        // exit(134). syscall number 60; status in rdi. 134 = 128 + SIGABRT(6),
        // the conventional status for an aborted process.
        self.emit("    movq $60, %rax");
        self.emit("    movq $134, %rdi");
        self.emit("    syscall");
        self.emit("");
    }

    /// Emit the self-contained print-string helper `tl_print_str(ptr, len)`.
    ///
    /// It writes the `len` bytes at `ptr` to fd 1 (stdout) via a single
    /// `write(2)` syscall, then returns. Unlike `tl_abort` it does not terminate
    /// the process. It is zero-dependency (no libc) and emits no rodata — the
    /// bytes come from the caller-supplied operand. `(print-string s)` /
    /// `(print-str s)` `Call` this symbol; because it is a `Call` the optimizer's
    /// dead-code elimination cannot drop it.
    ///
    /// ABI (System V): `ptr` in `%rdi`, `len` in `%rsi`. The `write(2)` syscall
    /// wants fd in `%rdi`, buf in `%rsi`, count in `%rdx`, so the operands are
    /// shuffled (`%rdx <- len`, `%rsi <- ptr`, `%rdi <- 1`) before the syscall.
    fn generate_print_str_runtime_functions(&mut self) {
        if self.target.runtime_policy().emits_windows_runtime_helpers {
            self.generate_windows_write_buffer_runtime_function("tl_print_str", 1);
            return;
        }

        self.emit("    .globl tl_print_str");
        self.emit("tl_print_str:");
        // write(1 /*fd=stdout*/, ptr, len). syscall number 1; args rdi/rsi/rdx.
        // Move len (rsi) -> rdx before clobbering rsi with ptr (rdi).
        self.emit("    movq %rsi, %rdx");
        self.emit("    movq %rdi, %rsi");
        self.emit("    movq $1, %rdi");
        self.emit("    movq $1, %rax");
        self.emit("    syscall");
        self.emit("    ret");
        self.emit("");
    }

    fn generate_print_err_runtime_functions(&mut self) {
        if self.target.runtime_policy().emits_windows_runtime_helpers {
            self.generate_windows_write_buffer_runtime_function("tl_print_err", 2);
            return;
        }

        self.emit("    .globl tl_print_err");
        self.emit("tl_print_err:");
        // write(2 /*fd=stderr*/, ptr, len). syscall number 1; args rdi/rsi/rdx.
        self.emit("    movq %rsi, %rdx");
        self.emit("    movq %rdi, %rsi");
        self.emit("    movq $2, %rdi");
        self.emit("    movq $1, %rax");
        self.emit("    syscall");
        self.emit("    ret");
        self.emit("");
    }

    fn generate_windows_fixed_abort_runtime_function(
        &mut self,
        symbol: &str,
        msg_label: &str,
        len_label: &str,
        status: i64,
    ) {
        self.emit(&format!("    .globl {}", symbol));
        self.emit(&format!("{}:", symbol));
        self.emit("    push %rbp");
        self.emit("    mov %rsp, %rbp");
        self.emit("    movq $2, %rcx");
        self.emit(&format!("    leaq {}(%rip), %rdx", msg_label));
        self.emit(&format!("    movq ${}, %r8", len_label));
        self.emit_call("_write");
        self.emit(&format!("    movq ${}, %rcx", status));
        self.emit_call("exit");
        self.emit("");
    }

    fn generate_windows_abort_runtime_functions(&mut self) {
        self.emit(&format!("{}:", ABORT_RUNTIME_SYMBOL));
        self.emit("    push %rbp");
        self.emit("    mov %rsp, %rbp");
        self.emit("    movq %rdx, %r8");
        self.emit("    movq %rcx, %rdx");
        self.emit("    movq $2, %rcx");
        self.emit_call("_write");
        self.emit("    movq $134, %rcx");
        self.emit_call("exit");
        self.emit("");
    }

    fn generate_windows_write_buffer_runtime_function(&mut self, symbol: &str, fd: i64) {
        self.emit(&format!("    .globl {}", symbol));
        self.emit(&format!("{}:", symbol));
        self.emit("    push %rbp");
        self.emit("    mov %rsp, %rbp");
        self.emit("    movq %rdx, %r8");
        self.emit("    movq %rcx, %rdx");
        self.emit(&format!("    movq ${}, %rcx", fd));
        self.emit_call("_write");
        self.emit("    mov %rbp, %rsp");
        self.emit("    pop %rbp");
        self.emit("    ret");
        self.emit("");
    }

    fn generate_arg_count_runtime_functions(&mut self) {
        self.emit(&format!("{}:", ARG_COUNT_RUNTIME_SYMBOL));
        self.emit("    movq .L_tl_argc(%rip), %rax");
        self.emit("    ret");
        self.emit("");
    }

    /// Emit `(arg i) -> String`. The helper reads argv metadata captured in
    /// `_start`, bounds-checks the signed index, copies the selected
    /// NUL-terminated argv byte string into a fresh heap buffer, then returns a
    /// heap fat-string `{ ptr, len }` pointer. Invalid indexes abort through the
    /// existing message-abort runtime.
    fn generate_arg_runtime_functions(&mut self) {
        let calling_convention = self.target.calling_convention();
        let arg0 = calling_convention.integer_arg_regs[0];
        let arg1 = calling_convention.integer_arg_regs[1];

        self.emit(&format!("{}:", ARG_RUNTIME_SYMBOL));
        self.emit("    push %rbp");
        self.emit("    mov %rsp, %rbp");
        self.emit("    push %rbx");
        self.emit("    push %r12");
        self.emit("    push %r13");
        self.emit("    sub $8, %rsp");
        self.emit(&format!("    movq {}, %rbx", arg0));
        self.emit("    cmpq $0, %rbx");
        self.emit("    jl .L_tl_arg_oob");
        self.emit("    movq .L_tl_argc(%rip), %rax");
        self.emit("    cmpq %rax, %rbx");
        self.emit("    jge .L_tl_arg_oob");
        self.emit("    movq .L_tl_argv(%rip), %rax");
        self.emit("    movq (%rax,%rbx,8), %rbx");
        self.emit("    xorq %r12, %r12");
        self.emit(".L_tl_arg_len_loop:");
        self.emit("    cmpb $0, (%rbx,%r12)");
        self.emit("    je .L_tl_arg_len_done");
        self.emit("    incq %r12");
        self.emit("    jmp .L_tl_arg_len_loop");
        self.emit(".L_tl_arg_len_done:");
        self.emit(&format!("    movq %r12, {}", arg0));
        self.emit_call("tl_alloc");
        self.emit("    movq %rax, %r13");
        self.emit("    xorq %rcx, %rcx");
        self.emit(".L_tl_arg_copy_loop:");
        self.emit("    cmpq %r12, %rcx");
        self.emit("    jge .L_tl_arg_copy_done");
        self.emit("    movzbl (%rbx,%rcx), %edx");
        self.emit("    movb %dl, (%r13,%rcx)");
        self.emit("    incq %rcx");
        self.emit("    jmp .L_tl_arg_copy_loop");
        self.emit(".L_tl_arg_copy_done:");
        self.emit(&format!("    movq $16, {}", arg0));
        self.emit_call("tl_alloc");
        self.emit("    movq %r13, 0(%rax)");
        self.emit("    movq %r12, 8(%rax)");
        self.emit("    add $8, %rsp");
        self.emit("    pop %r13");
        self.emit("    pop %r12");
        self.emit("    pop %rbx");
        self.emit("    pop %rbp");
        self.emit("    ret");
        self.emit(".L_tl_arg_oob:");
        self.emit(&format!("    leaq .L_tl_arg_oob_msg(%rip), {}", arg0));
        self.emit(&format!("    movq $.L_tl_arg_oob_msg_len, {}", arg1));
        self.emit_call(ABORT_RUNTIME_SYMBOL);
        self.emit("");
    }

    /// Emit the self-contained read-file helper
    /// `tl_read_file(path_ptr, path_len) -> {ptr, len}`.
    ///
    /// ABI (System V): `path_ptr` in `%rdi`, `path_len` in `%rsi`; the returned
    /// heap fat-value pointer leaves in `%rax`. The helper copies the TypeLisp
    /// path bytes into a fresh NUL-terminated buffer, opens the regular file
    /// read-only with Linux syscalls, sizes it with `lseek`, reads exactly that
    /// many bytes into a heap buffer, closes the fd, then returns a heap String
    /// fat value. V1 is compiler-driver oriented and aborts on any syscall,
    /// short-read, or path-length error until recoverable file errors exist.
    fn generate_read_file_runtime_functions(&mut self) {
        if self.target.runtime_policy().emits_windows_runtime_helpers {
            self.generate_windows_read_file_runtime_functions();
            return;
        }

        self.emit(&format!("{}:", READ_FILE_RUNTIME_SYMBOL));
        self.emit("    push %rbp");
        self.emit("    mov %rsp, %rbp");
        self.emit("    push %rbx");
        self.emit("    push %r12");
        self.emit("    push %r13");
        self.emit("    sub $8, %rsp");
        // %rbx = path_ptr, %r12 = path_len. Reject negative lengths, then
        // allocate path_len + 1 bytes for the NUL-terminated syscall path.
        self.emit("    movq %rdi, %rbx");
        self.emit("    movq %rsi, %r12");
        self.emit("    cmpq $0, %r12");
        self.emit("    jl .L_tl_read_file_error");
        self.emit("    movq %r12, %rdi");
        self.emit("    addq $1, %rdi");
        self.emit("    js .L_tl_read_file_error");
        self.emit("    call tl_alloc");
        self.emit("    movq %rax, %r13");
        // Copy path_len bytes and append a trailing NUL.
        self.emit("    xorq %rcx, %rcx");
        self.emit(".L_tl_read_file_path_copy_loop:");
        self.emit("    cmpq %r12, %rcx");
        self.emit("    jge .L_tl_read_file_path_copy_done");
        self.emit("    movzbl (%rbx,%rcx), %edx");
        self.emit("    movb %dl, (%r13,%rcx)");
        self.emit("    incq %rcx");
        self.emit("    jmp .L_tl_read_file_path_copy_loop");
        self.emit(".L_tl_read_file_path_copy_done:");
        self.emit("    movb $0, (%r13,%r12)");

        // fd = openat(AT_FDCWD, c_path, O_RDONLY, 0).
        self.emit("    movq $257, %rax");
        self.emit("    movq $-100, %rdi");
        self.emit("    movq %r13, %rsi");
        self.emit("    xorq %rdx, %rdx");
        self.emit("    xorq %r10, %r10");
        self.emit("    syscall");
        self.emit("    testq %rax, %rax");
        self.emit("    js .L_tl_read_file_error");
        self.emit("    movq %rax, %rbx");

        // file_len = lseek(fd, 0, SEEK_END), then rewind to the start.
        self.emit("    movq $8, %rax");
        self.emit("    movq %rbx, %rdi");
        self.emit("    xorq %rsi, %rsi");
        self.emit("    movq $2, %rdx");
        self.emit("    syscall");
        self.emit("    testq %rax, %rax");
        self.emit("    js .L_tl_read_file_close_error");
        self.emit("    movq %rax, %r12");
        self.emit("    movq $8, %rax");
        self.emit("    movq %rbx, %rdi");
        self.emit("    xorq %rsi, %rsi");
        self.emit("    xorq %rdx, %rdx");
        self.emit("    syscall");
        self.emit("    testq %rax, %rax");
        self.emit("    js .L_tl_read_file_close_error");

        // data = tl_alloc(file_len); read exactly file_len bytes into it.
        self.emit("    movq %r12, %rdi");
        self.emit("    call tl_alloc");
        self.emit("    movq %rax, %r13");
        self.emit("    xorq %rax, %rax");
        self.emit("    movq %rbx, %rdi");
        self.emit("    movq %r13, %rsi");
        self.emit("    movq %r12, %rdx");
        self.emit("    syscall");
        self.emit("    testq %rax, %rax");
        self.emit("    js .L_tl_read_file_close_error");
        self.emit("    cmpq %r12, %rax");
        self.emit("    jne .L_tl_read_file_close_error");

        // close(fd), then allocate and return the fat String value.
        self.emit("    movq $3, %rax");
        self.emit("    movq %rbx, %rdi");
        self.emit("    syscall");
        self.emit("    testq %rax, %rax");
        self.emit("    js .L_tl_read_file_error");
        self.emit("    movq $16, %rdi");
        self.emit("    call tl_alloc");
        self.emit("    movq %r13, 0(%rax)");
        self.emit("    movq %r12, 8(%rax)");
        self.emit("    add $8, %rsp");
        self.emit("    pop %r13");
        self.emit("    pop %r12");
        self.emit("    pop %rbx");
        self.emit("    pop %rbp");
        self.emit("    ret");

        self.emit(".L_tl_read_file_close_error:");
        self.emit("    movq $3, %rax");
        self.emit("    movq %rbx, %rdi");
        self.emit("    syscall");
        self.emit(".L_tl_read_file_error:");
        self.emit("    leaq .L_tl_read_file_error_msg(%rip), %rdi");
        self.emit("    movq $.L_tl_read_file_error_msg_len, %rsi");
        self.emit(&format!("    call {}", ABORT_RUNTIME_SYMBOL));
        self.emit("");
    }

    /// Emit the self-contained write-file helper
    /// `tl_write_file(path_ptr, path_len, contents_ptr, contents_len) -> unit`.
    ///
    /// ABI (System V): `path_ptr` in `%rdi`, `path_len` in `%rsi`,
    /// `contents_ptr` in `%rdx`, `contents_len` in `%rcx`. The helper copies
    /// the TypeLisp path bytes into a fresh NUL-terminated buffer, opens the
    /// file with Linux `openat(O_WRONLY|O_CREAT|O_TRUNC, 0666)`, writes exactly
    /// `contents_len` bytes, closes the fd, and returns. V1 is compiler-driver
    /// oriented and aborts on any syscall, partial-write, or length error until
    /// recoverable file errors exist.
    fn generate_write_file_runtime_functions(&mut self) {
        if self.target.runtime_policy().emits_windows_runtime_helpers {
            self.generate_windows_write_file_runtime_functions();
            return;
        }

        self.emit(&format!("{}:", WRITE_FILE_RUNTIME_SYMBOL));
        self.emit("    push %rbp");
        self.emit("    mov %rsp, %rbp");
        self.emit("    push %rbx");
        self.emit("    push %r12");
        self.emit("    push %r13");
        self.emit("    push %r14");
        self.emit("    push %r15");
        self.emit("    sub $8, %rsp");
        // %rbx = path_ptr, %r12 = path_len, %r13 = contents_ptr,
        // %r14 = contents_len. Reject negative lengths, then allocate
        // path_len + 1 bytes for the NUL-terminated syscall path.
        self.emit("    movq %rdi, %rbx");
        self.emit("    movq %rsi, %r12");
        self.emit("    movq %rdx, %r13");
        self.emit("    movq %rcx, %r14");
        self.emit("    cmpq $0, %r12");
        self.emit("    jl .L_tl_write_file_error");
        self.emit("    cmpq $0, %r14");
        self.emit("    jl .L_tl_write_file_error");
        self.emit("    movq %r12, %rdi");
        self.emit("    addq $1, %rdi");
        self.emit("    js .L_tl_write_file_error");
        self.emit("    call tl_alloc");
        self.emit("    movq %rax, %r15");
        // Copy path_len bytes and append a trailing NUL.
        self.emit("    xorq %rcx, %rcx");
        self.emit(".L_tl_write_file_path_copy_loop:");
        self.emit("    cmpq %r12, %rcx");
        self.emit("    jge .L_tl_write_file_path_copy_done");
        self.emit("    movzbl (%rbx,%rcx), %edx");
        self.emit("    movb %dl, (%r15,%rcx)");
        self.emit("    incq %rcx");
        self.emit("    jmp .L_tl_write_file_path_copy_loop");
        self.emit(".L_tl_write_file_path_copy_done:");
        self.emit("    movb $0, (%r15,%r12)");

        // fd = openat(AT_FDCWD, c_path, O_WRONLY|O_CREAT|O_TRUNC, 0666).
        self.emit("    movq $257, %rax");
        self.emit("    movq $-100, %rdi");
        self.emit("    movq %r15, %rsi");
        self.emit("    movq $577, %rdx");
        self.emit("    movq $438, %r10");
        self.emit("    syscall");
        self.emit("    testq %rax, %rax");
        self.emit("    js .L_tl_write_file_error");
        self.emit("    movq %rax, %r15");

        // write(fd, contents_ptr, contents_len). Treat short writes as errors.
        self.emit("    movq $1, %rax");
        self.emit("    movq %r15, %rdi");
        self.emit("    movq %r13, %rsi");
        self.emit("    movq %r14, %rdx");
        self.emit("    syscall");
        self.emit("    testq %rax, %rax");
        self.emit("    js .L_tl_write_file_close_error");
        self.emit("    cmpq %r14, %rax");
        self.emit("    jne .L_tl_write_file_close_error");

        // close(fd), then return unit.
        self.emit("    movq $3, %rax");
        self.emit("    movq %r15, %rdi");
        self.emit("    syscall");
        self.emit("    testq %rax, %rax");
        self.emit("    js .L_tl_write_file_error");
        self.emit("    xorq %rax, %rax");
        self.emit("    add $8, %rsp");
        self.emit("    pop %r15");
        self.emit("    pop %r14");
        self.emit("    pop %r13");
        self.emit("    pop %r12");
        self.emit("    pop %rbx");
        self.emit("    pop %rbp");
        self.emit("    ret");

        self.emit(".L_tl_write_file_close_error:");
        self.emit("    movq $3, %rax");
        self.emit("    movq %r15, %rdi");
        self.emit("    syscall");
        self.emit(".L_tl_write_file_error:");
        self.emit("    leaq .L_tl_write_file_error_msg(%rip), %rdi");
        self.emit("    movq $.L_tl_write_file_error_msg_len, %rsi");
        self.emit(&format!("    call {}", ABORT_RUNTIME_SYMBOL));
        self.emit("");
    }

    /// Emit the self-contained file-exists helper
    /// `tl_file_exists(path_ptr, path_len) -> bool`.
    ///
    /// ABI (System V): `path_ptr` in `%rdi`, `path_len` in `%rsi`; the 0/1 bool
    /// result leaves in `%rax`. The helper copies the TypeLisp path bytes into a
    /// fresh NUL-terminated buffer, probes with Linux `access(path, F_OK)`, and
    /// returns false for ENOENT. Other syscall/path failures abort until
    /// recoverable file errors exist.
    fn generate_file_exists_runtime_functions(&mut self) {
        if self.target.runtime_policy().emits_windows_runtime_helpers {
            self.generate_windows_file_exists_runtime_functions();
            return;
        }

        self.emit(&format!("{}:", FILE_EXISTS_RUNTIME_SYMBOL));
        self.emit("    push %rbp");
        self.emit("    mov %rsp, %rbp");
        self.emit("    push %rbx");
        self.emit("    push %r12");
        self.emit("    push %r13");
        self.emit("    sub $8, %rsp");
        // %rbx = path_ptr, %r12 = path_len. Reject negative lengths, then
        // allocate path_len + 1 bytes for the NUL-terminated syscall path.
        self.emit("    movq %rdi, %rbx");
        self.emit("    movq %rsi, %r12");
        self.emit("    cmpq $0, %r12");
        self.emit("    jl .L_tl_file_exists_error");
        self.emit("    movq %r12, %rdi");
        self.emit("    addq $1, %rdi");
        self.emit("    js .L_tl_file_exists_error");
        self.emit("    call tl_alloc");
        self.emit("    movq %rax, %r13");
        // Copy path_len bytes and append a trailing NUL.
        self.emit("    xorq %rcx, %rcx");
        self.emit(".L_tl_file_exists_path_copy_loop:");
        self.emit("    cmpq %r12, %rcx");
        self.emit("    jge .L_tl_file_exists_path_copy_done");
        self.emit("    movzbl (%rbx,%rcx), %edx");
        self.emit("    movb %dl, (%r13,%rcx)");
        self.emit("    incq %rcx");
        self.emit("    jmp .L_tl_file_exists_path_copy_loop");
        self.emit(".L_tl_file_exists_path_copy_done:");
        self.emit("    movb $0, (%r13,%r12)");

        // exists = access(c_path, F_OK) == 0. ENOENT is an ordinary false result.
        self.emit("    movq $21, %rax");
        self.emit("    movq %r13, %rdi");
        self.emit("    xorq %rsi, %rsi");
        self.emit("    syscall");
        self.emit("    testq %rax, %rax");
        self.emit("    jz .L_tl_file_exists_true");
        self.emit("    cmpq $-2, %rax");
        self.emit("    je .L_tl_file_exists_false");
        self.emit("    jmp .L_tl_file_exists_error");

        self.emit(".L_tl_file_exists_true:");
        self.emit("    movq $1, %rax");
        self.emit("    jmp .L_tl_file_exists_return");
        self.emit(".L_tl_file_exists_false:");
        self.emit("    xorq %rax, %rax");
        self.emit(".L_tl_file_exists_return:");
        self.emit("    add $8, %rsp");
        self.emit("    pop %r13");
        self.emit("    pop %r12");
        self.emit("    pop %rbx");
        self.emit("    pop %rbp");
        self.emit("    ret");

        self.emit(".L_tl_file_exists_error:");
        self.emit("    leaq .L_tl_file_exists_error_msg(%rip), %rdi");
        self.emit("    movq $.L_tl_file_exists_error_msg_len, %rsi");
        self.emit(&format!("    call {}", ABORT_RUNTIME_SYMBOL));
        self.emit("");
    }

    fn generate_read_file_status_runtime_functions(&mut self) {
        if self.target.runtime_policy().emits_windows_runtime_helpers {
            self.generate_windows_read_file_status_runtime_functions();
            return;
        }

        self.emit(&format!("{}:", READ_FILE_STATUS_RUNTIME_SYMBOL));
        self.emit("    push %rbp");
        self.emit("    mov %rsp, %rbp");
        self.emit("    push %rbx");
        self.emit("    push %r12");
        self.emit("    push %r13");
        self.emit("    sub $8, %rsp");
        self.emit("    movq %rdi, %rbx");
        self.emit("    movq %rsi, %r12");
        self.emit("    cmpq $0, %r12");
        self.emit("    jl .L_tl_read_file_status_invalid");
        self.emit("    movq %r12, %rdi");
        self.emit("    addq $1, %rdi");
        self.emit("    js .L_tl_read_file_status_invalid");
        self.emit("    call tl_alloc");
        self.emit("    movq %rax, %r13");
        self.emit("    xorq %rcx, %rcx");
        self.emit(".L_tl_read_file_status_path_copy_loop:");
        self.emit("    cmpq %r12, %rcx");
        self.emit("    jge .L_tl_read_file_status_path_copy_done");
        self.emit("    movzbl (%rbx,%rcx), %edx");
        self.emit("    movb %dl, (%r13,%rcx)");
        self.emit("    incq %rcx");
        self.emit("    jmp .L_tl_read_file_status_path_copy_loop");
        self.emit(".L_tl_read_file_status_path_copy_done:");
        self.emit("    movb $0, (%r13,%r12)");
        self.emit("    movq $257, %rax");
        self.emit("    movq $-100, %rdi");
        self.emit("    movq %r13, %rsi");
        self.emit("    xorq %rdx, %rdx");
        self.emit("    xorq %r10, %r10");
        self.emit("    syscall");
        self.emit("    testq %rax, %rax");
        self.emit("    js .L_tl_read_file_status_error_from_rax");
        self.emit("    movq %rax, %rbx");
        self.emit("    movq $8, %rax");
        self.emit("    movq %rbx, %rdi");
        self.emit("    xorq %rsi, %rsi");
        self.emit("    movq $2, %rdx");
        self.emit("    syscall");
        self.emit("    testq %rax, %rax");
        self.emit("    js .L_tl_read_file_status_close_error_from_rax");
        self.emit("    movq %rax, %r13");
        self.emit("    movq $8, %rax");
        self.emit("    movq %rbx, %rdi");
        self.emit("    xorq %rsi, %rsi");
        self.emit("    xorq %rdx, %rdx");
        self.emit("    syscall");
        self.emit("    testq %rax, %rax");
        self.emit("    js .L_tl_read_file_status_close_error_from_rax");
        self.emit("    cmpq $0, %r13");
        self.emit("    je .L_tl_read_file_status_close_success");
        self.emit("    xorq %rax, %rax");
        self.emit("    movq %rbx, %rdi");
        self.emit("    leaq -32(%rbp), %rsi");
        self.emit("    movq $1, %rdx");
        self.emit("    syscall");
        self.emit("    testq %rax, %rax");
        self.emit("    js .L_tl_read_file_status_close_error_from_rax");
        self.emit(".L_tl_read_file_status_close_success:");
        self.emit("    movq $3, %rax");
        self.emit("    movq %rbx, %rdi");
        self.emit("    syscall");
        self.emit("    testq %rax, %rax");
        self.emit("    js .L_tl_read_file_status_error_from_rax");
        self.emit("    xorq %rax, %rax");
        self.emit("    jmp .L_tl_read_file_status_return");
        self.emit(".L_tl_read_file_status_close_error_from_rax:");
        self.emit("    negq %rax");
        self.emit("    movq %rax, %r12");
        self.emit("    movq $3, %rax");
        self.emit("    movq %rbx, %rdi");
        self.emit("    syscall");
        self.emit("    movq %r12, %rax");
        self.emit("    jmp .L_tl_read_file_status_return");
        self.emit(".L_tl_read_file_status_error_from_rax:");
        self.emit("    negq %rax");
        self.emit("    jmp .L_tl_read_file_status_return");
        self.emit(".L_tl_read_file_status_invalid:");
        self.emit("    movq $22, %rax");
        self.emit(".L_tl_read_file_status_return:");
        self.emit("    add $8, %rsp");
        self.emit("    pop %r13");
        self.emit("    pop %r12");
        self.emit("    pop %rbx");
        self.emit("    pop %rbp");
        self.emit("    ret");
        self.emit("");
    }

    fn generate_write_file_status_runtime_functions(&mut self) {
        if self.target.runtime_policy().emits_windows_runtime_helpers {
            self.generate_windows_write_file_status_runtime_functions();
            return;
        }

        self.emit(&format!("{}:", WRITE_FILE_STATUS_RUNTIME_SYMBOL));
        self.emit("    push %rbp");
        self.emit("    mov %rsp, %rbp");
        self.emit("    push %rbx");
        self.emit("    push %r12");
        self.emit("    push %r13");
        self.emit("    push %r14");
        self.emit("    push %r15");
        self.emit("    sub $8, %rsp");
        self.emit("    movq %rdi, %rbx");
        self.emit("    movq %rsi, %r12");
        self.emit("    movq %rdx, %r13");
        self.emit("    movq %rcx, %r14");
        self.emit("    cmpq $0, %r12");
        self.emit("    jl .L_tl_write_file_status_invalid");
        self.emit("    cmpq $0, %r14");
        self.emit("    jl .L_tl_write_file_status_invalid");
        self.emit("    movq %r12, %rdi");
        self.emit("    addq $1, %rdi");
        self.emit("    js .L_tl_write_file_status_invalid");
        self.emit("    call tl_alloc");
        self.emit("    movq %rax, %r15");
        self.emit("    xorq %rcx, %rcx");
        self.emit(".L_tl_write_file_status_path_copy_loop:");
        self.emit("    cmpq %r12, %rcx");
        self.emit("    jge .L_tl_write_file_status_path_copy_done");
        self.emit("    movzbl (%rbx,%rcx), %edx");
        self.emit("    movb %dl, (%r15,%rcx)");
        self.emit("    incq %rcx");
        self.emit("    jmp .L_tl_write_file_status_path_copy_loop");
        self.emit(".L_tl_write_file_status_path_copy_done:");
        self.emit("    movb $0, (%r15,%r12)");
        self.emit("    movq $257, %rax");
        self.emit("    movq $-100, %rdi");
        self.emit("    movq %r15, %rsi");
        self.emit("    movq $577, %rdx");
        self.emit("    movq $438, %r10");
        self.emit("    syscall");
        self.emit("    testq %rax, %rax");
        self.emit("    js .L_tl_write_file_status_error_from_rax");
        self.emit("    movq %rax, %r15");
        self.emit("    movq $1, %rax");
        self.emit("    movq %r15, %rdi");
        self.emit("    movq %r13, %rsi");
        self.emit("    movq %r14, %rdx");
        self.emit("    syscall");
        self.emit("    testq %rax, %rax");
        self.emit("    js .L_tl_write_file_status_close_error_from_rax");
        self.emit("    cmpq %r14, %rax");
        self.emit("    jne .L_tl_write_file_status_short_write");
        self.emit("    movq $3, %rax");
        self.emit("    movq %r15, %rdi");
        self.emit("    syscall");
        self.emit("    testq %rax, %rax");
        self.emit("    js .L_tl_write_file_status_error_from_rax");
        self.emit("    xorq %rax, %rax");
        self.emit("    jmp .L_tl_write_file_status_return");
        self.emit(".L_tl_write_file_status_short_write:");
        self.emit("    movq $5, %r12");
        self.emit("    movq $3, %rax");
        self.emit("    movq %r15, %rdi");
        self.emit("    syscall");
        self.emit("    movq %r12, %rax");
        self.emit("    jmp .L_tl_write_file_status_return");
        self.emit(".L_tl_write_file_status_close_error_from_rax:");
        self.emit("    negq %rax");
        self.emit("    movq %rax, %r12");
        self.emit("    movq $3, %rax");
        self.emit("    movq %r15, %rdi");
        self.emit("    syscall");
        self.emit("    movq %r12, %rax");
        self.emit("    jmp .L_tl_write_file_status_return");
        self.emit(".L_tl_write_file_status_error_from_rax:");
        self.emit("    negq %rax");
        self.emit("    jmp .L_tl_write_file_status_return");
        self.emit(".L_tl_write_file_status_invalid:");
        self.emit("    movq $22, %rax");
        self.emit(".L_tl_write_file_status_return:");
        self.emit("    add $8, %rsp");
        self.emit("    pop %r15");
        self.emit("    pop %r14");
        self.emit("    pop %r13");
        self.emit("    pop %r12");
        self.emit("    pop %rbx");
        self.emit("    pop %rbp");
        self.emit("    ret");
        self.emit("");
    }

    fn generate_file_exists_status_runtime_functions(&mut self) {
        if self.target.runtime_policy().emits_windows_runtime_helpers {
            self.generate_windows_file_exists_status_runtime_functions();
            return;
        }

        self.emit(&format!("{}:", FILE_EXISTS_STATUS_RUNTIME_SYMBOL));
        self.emit("    push %rbp");
        self.emit("    mov %rsp, %rbp");
        self.emit("    push %rbx");
        self.emit("    push %r12");
        self.emit("    push %r13");
        self.emit("    sub $8, %rsp");
        self.emit("    movq %rdi, %rbx");
        self.emit("    movq %rsi, %r12");
        self.emit("    cmpq $0, %r12");
        self.emit("    jl .L_tl_file_exists_status_invalid");
        self.emit("    movq %r12, %rdi");
        self.emit("    addq $1, %rdi");
        self.emit("    js .L_tl_file_exists_status_invalid");
        self.emit("    call tl_alloc");
        self.emit("    movq %rax, %r13");
        self.emit("    xorq %rcx, %rcx");
        self.emit(".L_tl_file_exists_status_path_copy_loop:");
        self.emit("    cmpq %r12, %rcx");
        self.emit("    jge .L_tl_file_exists_status_path_copy_done");
        self.emit("    movzbl (%rbx,%rcx), %edx");
        self.emit("    movb %dl, (%r13,%rcx)");
        self.emit("    incq %rcx");
        self.emit("    jmp .L_tl_file_exists_status_path_copy_loop");
        self.emit(".L_tl_file_exists_status_path_copy_done:");
        self.emit("    movb $0, (%r13,%r12)");
        self.emit("    movq $21, %rax");
        self.emit("    movq %r13, %rdi");
        self.emit("    xorq %rsi, %rsi");
        self.emit("    syscall");
        self.emit("    testq %rax, %rax");
        self.emit("    jz .L_tl_file_exists_status_return");
        self.emit("    negq %rax");
        self.emit("    jmp .L_tl_file_exists_status_return");
        self.emit(".L_tl_file_exists_status_invalid:");
        self.emit("    movq $22, %rax");
        self.emit(".L_tl_file_exists_status_return:");
        self.emit("    add $8, %rsp");
        self.emit("    pop %r13");
        self.emit("    pop %r12");
        self.emit("    pop %rbx");
        self.emit("    pop %rbp");
        self.emit("    ret");
        self.emit("");
    }

    fn generate_fs_path_status_runtime_function(
        &mut self,
        symbol: &str,
        label: &str,
        syscall_number: i64,
        mkdir_mode: Option<i64>,
    ) {
        self.emit(&format!("{}:", symbol));
        self.emit("    push %rbp");
        self.emit("    mov %rsp, %rbp");
        self.emit("    push %rbx");
        self.emit("    push %r12");
        self.emit("    push %r13");
        self.emit("    sub $8, %rsp");
        self.emit("    movq %rdi, %rbx");
        self.emit("    movq %rsi, %r12");
        self.emit("    cmpq $0, %r12");
        self.emit(&format!("    jl .L_tl_{}_invalid", label));
        self.emit("    movq %r12, %rdi");
        self.emit("    addq $1, %rdi");
        self.emit(&format!("    js .L_tl_{}_invalid", label));
        self.emit("    call tl_alloc");
        self.emit("    movq %rax, %r13");
        self.emit("    xorq %rcx, %rcx");
        self.emit(&format!(".L_tl_{}_path_copy_loop:", label));
        self.emit("    cmpq %r12, %rcx");
        self.emit(&format!("    jge .L_tl_{}_path_copy_done", label));
        self.emit("    movzbl (%rbx,%rcx), %edx");
        self.emit("    movb %dl, (%r13,%rcx)");
        self.emit("    incq %rcx");
        self.emit(&format!("    jmp .L_tl_{}_path_copy_loop", label));
        self.emit(&format!(".L_tl_{}_path_copy_done:", label));
        self.emit("    movb $0, (%r13,%r12)");
        self.emit(&format!("    movq ${}, %rax", syscall_number));
        self.emit("    movq %r13, %rdi");
        if let Some(mode) = mkdir_mode {
            self.emit(&format!("    movq ${}, %rsi", mode));
        }
        self.emit("    syscall");
        self.emit("    testq %rax, %rax");
        self.emit(&format!("    js .L_tl_{}_error_from_rax", label));
        self.emit("    xorq %rax, %rax");
        self.emit(&format!("    jmp .L_tl_{}_return", label));
        self.emit(&format!(".L_tl_{}_error_from_rax:", label));
        self.emit("    negq %rax");
        self.emit(&format!("    jmp .L_tl_{}_return", label));
        self.emit(&format!(".L_tl_{}_invalid:", label));
        self.emit("    movq $22, %rax");
        self.emit(&format!(".L_tl_{}_return:", label));
        self.emit("    add $8, %rsp");
        self.emit("    pop %r13");
        self.emit("    pop %r12");
        self.emit("    pop %rbx");
        self.emit("    pop %rbp");
        self.emit("    ret");
        self.emit("");
    }

    fn generate_fs_runtime_functions(&mut self) {
        if self.target.runtime_policy().emits_windows_runtime_helpers {
            self.generate_windows_fs_mkdir_status_runtime_function();
            for symbol in [
                FS_REMOVE_FILE_STATUS_RUNTIME_SYMBOL,
                FS_REMOVE_DIR_STATUS_RUNTIME_SYMBOL,
            ] {
                self.emit(&format!("{}:", symbol));
                self.emit("    movq $38, %rax");
                self.emit("    ret");
                self.emit("");
            }
            self.emit(&format!("{}:", FS_PROCESS_ID_RUNTIME_SYMBOL));
            self.emit("    xorq %rax, %rax");
            self.emit("    ret");
            self.emit("");
            return;
        }

        self.generate_fs_path_status_runtime_function(
            FS_MKDIR_STATUS_RUNTIME_SYMBOL,
            "fs_mkdir_status",
            83,
            Some(448),
        );
        self.generate_fs_path_status_runtime_function(
            FS_REMOVE_FILE_STATUS_RUNTIME_SYMBOL,
            "fs_remove_file_status",
            87,
            None,
        );
        self.generate_fs_path_status_runtime_function(
            FS_REMOVE_DIR_STATUS_RUNTIME_SYMBOL,
            "fs_remove_dir_status",
            84,
            None,
        );
        self.emit(&format!("{}:", FS_PROCESS_ID_RUNTIME_SYMBOL));
        self.emit("    movq $39, %rax");
        self.emit("    syscall");
        self.emit("    ret");
        self.emit("");
    }

    fn generate_windows_fs_mkdir_status_runtime_function(&mut self) {
        self.emit(&format!("{}:", FS_MKDIR_STATUS_RUNTIME_SYMBOL));
        self.emit("    push %rbp");
        self.emit("    mov %rsp, %rbp");
        self.emit("    push %rbx");
        self.emit("    push %r12");
        self.emit("    push %r13");
        self.emit("    sub $8, %rsp");
        self.emit("    movq %rcx, %rbx");
        self.emit("    movq %rdx, %r12");
        self.emit("    cmpq $0, %r12");
        self.emit("    jl .L_tl_fs_mkdir_status_win_invalid");
        self.emit("    movq %r12, %rcx");
        self.emit("    addq $1, %rcx");
        self.emit("    js .L_tl_fs_mkdir_status_win_invalid");
        self.emit_call("tl_alloc");
        self.emit("    movq %rax, %r13");
        self.emit("    xorq %r10, %r10");
        self.emit(".L_tl_fs_mkdir_status_win_path_copy_loop:");
        self.emit("    cmpq %r12, %r10");
        self.emit("    jge .L_tl_fs_mkdir_status_win_path_copy_done");
        self.emit("    movzbl (%rbx,%r10), %edx");
        self.emit("    movb %dl, (%r13,%r10)");
        self.emit("    incq %r10");
        self.emit("    jmp .L_tl_fs_mkdir_status_win_path_copy_loop");
        self.emit(".L_tl_fs_mkdir_status_win_path_copy_done:");
        self.emit("    movb $0, (%r13,%r12)");
        self.emit("    movq %r13, %rcx");
        self.emit_call("_mkdir");
        self.emit("    testl %eax, %eax");
        self.emit("    js .L_tl_fs_mkdir_status_win_errno");
        self.emit("    xorq %rax, %rax");
        self.emit("    jmp .L_tl_fs_mkdir_status_win_return");
        self.emit(".L_tl_fs_mkdir_status_win_errno:");
        self.emit_call("_errno");
        self.emit("    movslq (%rax), %rax");
        self.emit("    testq %rax, %rax");
        self.emit("    jne .L_tl_fs_mkdir_status_win_return");
        self.emit("    movq $1, %rax");
        self.emit("    jmp .L_tl_fs_mkdir_status_win_return");
        self.emit(".L_tl_fs_mkdir_status_win_invalid:");
        self.emit("    movq $22, %rax");
        self.emit(".L_tl_fs_mkdir_status_win_return:");
        self.emit("    add $8, %rsp");
        self.emit("    pop %r13");
        self.emit("    pop %r12");
        self.emit("    pop %rbx");
        self.emit("    pop %rbp");
        self.emit("    ret");
        self.emit("");
    }

    fn generate_windows_read_file_runtime_functions(&mut self) {
        self.emit(&format!("{}:", READ_FILE_RUNTIME_SYMBOL));
        self.emit("    push %rbp");
        self.emit("    mov %rsp, %rbp");
        self.emit("    push %rbx");
        self.emit("    push %r12");
        self.emit("    push %r13");
        self.emit("    sub $8, %rsp");
        self.emit("    movq %rcx, %rbx");
        self.emit("    movq %rdx, %r12");
        self.emit("    cmpq $0, %r12");
        self.emit("    jl .L_tl_read_file_error");
        self.emit("    movq %r12, %rcx");
        self.emit("    addq $1, %rcx");
        self.emit("    js .L_tl_read_file_error");
        self.emit_call("tl_alloc");
        self.emit("    movq %rax, %r13");
        self.emit("    xorq %r10, %r10");
        self.emit(".L_tl_read_file_path_copy_loop:");
        self.emit("    cmpq %r12, %r10");
        self.emit("    jge .L_tl_read_file_path_copy_done");
        self.emit("    movzbl (%rbx,%r10), %edx");
        self.emit("    movb %dl, (%r13,%r10)");
        self.emit("    incq %r10");
        self.emit("    jmp .L_tl_read_file_path_copy_loop");
        self.emit(".L_tl_read_file_path_copy_done:");
        self.emit("    movb $0, (%r13,%r12)");

        // _open(c_path, _O_RDONLY | _O_BINARY, 0).
        self.emit("    movq %r13, %rcx");
        self.emit("    movq $0x8000, %rdx");
        self.emit("    xorq %r8, %r8");
        self.emit_call("_open");
        self.emit("    testl %eax, %eax");
        self.emit("    js .L_tl_read_file_error");
        self.emit("    movslq %eax, %rbx");

        // file_len = _lseeki64(fd, 0, SEEK_END), then rewind.
        self.emit("    movq %rbx, %rcx");
        self.emit("    xorq %rdx, %rdx");
        self.emit("    movq $2, %r8");
        self.emit_call("_lseeki64");
        self.emit("    cmpq $0, %rax");
        self.emit("    jl .L_tl_read_file_close_error");
        self.emit("    movq %rax, %r12");
        self.emit("    movq %rbx, %rcx");
        self.emit("    xorq %rdx, %rdx");
        self.emit("    xorq %r8, %r8");
        self.emit_call("_lseeki64");
        self.emit("    cmpq $0, %rax");
        self.emit("    jl .L_tl_read_file_close_error");

        self.emit("    movq %r12, %rcx");
        self.emit_call("tl_alloc");
        self.emit("    movq %rax, %r13");
        self.emit("    movq %rbx, %rcx");
        self.emit("    movq %r13, %rdx");
        self.emit("    movq %r12, %r8");
        self.emit_call("_read");
        self.emit("    movslq %eax, %rax");
        self.emit("    cmpq %r12, %rax");
        self.emit("    jne .L_tl_read_file_close_error");

        self.emit("    movq %rbx, %rcx");
        self.emit_call("_close");
        self.emit("    testl %eax, %eax");
        self.emit("    js .L_tl_read_file_error");
        self.emit("    movq $16, %rcx");
        self.emit_call("tl_alloc");
        self.emit("    movq %r13, 0(%rax)");
        self.emit("    movq %r12, 8(%rax)");
        self.emit("    add $8, %rsp");
        self.emit("    pop %r13");
        self.emit("    pop %r12");
        self.emit("    pop %rbx");
        self.emit("    pop %rbp");
        self.emit("    ret");

        self.emit(".L_tl_read_file_close_error:");
        self.emit("    movq %rbx, %rcx");
        self.emit_call("_close");
        self.emit(".L_tl_read_file_error:");
        self.emit("    leaq .L_tl_read_file_error_msg(%rip), %rcx");
        self.emit("    movq $.L_tl_read_file_error_msg_len, %rdx");
        self.emit_call(ABORT_RUNTIME_SYMBOL);
        self.emit("");
    }

    fn generate_windows_write_file_runtime_functions(&mut self) {
        self.emit(&format!("{}:", WRITE_FILE_RUNTIME_SYMBOL));
        self.emit("    push %rbp");
        self.emit("    mov %rsp, %rbp");
        self.emit("    push %rbx");
        self.emit("    push %r12");
        self.emit("    push %r13");
        self.emit("    push %r14");
        self.emit("    push %r15");
        self.emit("    sub $8, %rsp");
        self.emit("    movq %rcx, %rbx");
        self.emit("    movq %rdx, %r12");
        self.emit("    movq %r8, %r13");
        self.emit("    movq %r9, %r14");
        self.emit("    cmpq $0, %r12");
        self.emit("    jl .L_tl_write_file_error");
        self.emit("    cmpq $0, %r14");
        self.emit("    jl .L_tl_write_file_error");
        self.emit("    movq %r12, %rcx");
        self.emit("    addq $1, %rcx");
        self.emit("    js .L_tl_write_file_error");
        self.emit_call("tl_alloc");
        self.emit("    movq %rax, %r15");
        self.emit("    xorq %r10, %r10");
        self.emit(".L_tl_write_file_path_copy_loop:");
        self.emit("    cmpq %r12, %r10");
        self.emit("    jge .L_tl_write_file_path_copy_done");
        self.emit("    movzbl (%rbx,%r10), %edx");
        self.emit("    movb %dl, (%r15,%r10)");
        self.emit("    incq %r10");
        self.emit("    jmp .L_tl_write_file_path_copy_loop");
        self.emit(".L_tl_write_file_path_copy_done:");
        self.emit("    movb $0, (%r15,%r12)");

        // _open(c_path, _O_WRONLY | _O_CREAT | _O_TRUNC | _O_BINARY, 0600).
        self.emit("    movq %r15, %rcx");
        self.emit("    movq $0x8301, %rdx");
        self.emit("    movq $0x180, %r8");
        self.emit_call("_open");
        self.emit("    testl %eax, %eax");
        self.emit("    js .L_tl_write_file_error");
        self.emit("    movslq %eax, %r15");

        self.emit("    movq %r15, %rcx");
        self.emit("    movq %r13, %rdx");
        self.emit("    movq %r14, %r8");
        self.emit_call("_write");
        self.emit("    movslq %eax, %rax");
        self.emit("    cmpq %r14, %rax");
        self.emit("    jne .L_tl_write_file_close_error");

        self.emit("    movq %r15, %rcx");
        self.emit_call("_close");
        self.emit("    testl %eax, %eax");
        self.emit("    js .L_tl_write_file_error");
        self.emit("    xorq %rax, %rax");
        self.emit("    add $8, %rsp");
        self.emit("    pop %r15");
        self.emit("    pop %r14");
        self.emit("    pop %r13");
        self.emit("    pop %r12");
        self.emit("    pop %rbx");
        self.emit("    pop %rbp");
        self.emit("    ret");

        self.emit(".L_tl_write_file_close_error:");
        self.emit("    movq %r15, %rcx");
        self.emit_call("_close");
        self.emit(".L_tl_write_file_error:");
        self.emit("    leaq .L_tl_write_file_error_msg(%rip), %rcx");
        self.emit("    movq $.L_tl_write_file_error_msg_len, %rdx");
        self.emit_call(ABORT_RUNTIME_SYMBOL);
        self.emit("");
    }

    fn generate_windows_file_exists_runtime_functions(&mut self) {
        self.emit(&format!("{}:", FILE_EXISTS_RUNTIME_SYMBOL));
        self.emit("    push %rbp");
        self.emit("    mov %rsp, %rbp");
        self.emit("    push %rbx");
        self.emit("    push %r12");
        self.emit("    push %r13");
        self.emit("    sub $8, %rsp");
        self.emit("    movq %rcx, %rbx");
        self.emit("    movq %rdx, %r12");
        self.emit("    cmpq $0, %r12");
        self.emit("    jl .L_tl_file_exists_error");
        self.emit("    movq %r12, %rcx");
        self.emit("    addq $1, %rcx");
        self.emit("    js .L_tl_file_exists_error");
        self.emit_call("tl_alloc");
        self.emit("    movq %rax, %r13");
        self.emit("    xorq %r10, %r10");
        self.emit(".L_tl_file_exists_path_copy_loop:");
        self.emit("    cmpq %r12, %r10");
        self.emit("    jge .L_tl_file_exists_path_copy_done");
        self.emit("    movzbl (%rbx,%r10), %edx");
        self.emit("    movb %dl, (%r13,%r10)");
        self.emit("    incq %r10");
        self.emit("    jmp .L_tl_file_exists_path_copy_loop");
        self.emit(".L_tl_file_exists_path_copy_done:");
        self.emit("    movb $0, (%r13,%r12)");

        self.emit("    movq %r13, %rcx");
        self.emit("    xorq %rdx, %rdx");
        self.emit_call("_access");
        self.emit("    testl %eax, %eax");
        self.emit("    jz .L_tl_file_exists_true");
        self.emit("    xorq %rax, %rax");
        self.emit("    jmp .L_tl_file_exists_return");
        self.emit(".L_tl_file_exists_true:");
        self.emit("    movq $1, %rax");
        self.emit(".L_tl_file_exists_return:");
        self.emit("    add $8, %rsp");
        self.emit("    pop %r13");
        self.emit("    pop %r12");
        self.emit("    pop %rbx");
        self.emit("    pop %rbp");
        self.emit("    ret");

        self.emit(".L_tl_file_exists_error:");
        self.emit("    leaq .L_tl_file_exists_error_msg(%rip), %rcx");
        self.emit("    movq $.L_tl_file_exists_error_msg_len, %rdx");
        self.emit_call(ABORT_RUNTIME_SYMBOL);
        self.emit("");
    }

    fn generate_windows_read_file_status_runtime_functions(&mut self) {
        self.emit(&format!("{}:", READ_FILE_STATUS_RUNTIME_SYMBOL));
        self.emit("    push %rbp");
        self.emit("    mov %rsp, %rbp");
        self.emit("    push %rbx");
        self.emit("    push %r12");
        self.emit("    push %r13");
        self.emit("    sub $8, %rsp");
        self.emit("    movq %rcx, %rbx");
        self.emit("    movq %rdx, %r12");
        self.emit("    cmpq $0, %r12");
        self.emit("    jl .L_tl_read_file_status_win_invalid");
        self.emit("    movq %r12, %rcx");
        self.emit("    addq $1, %rcx");
        self.emit("    js .L_tl_read_file_status_win_invalid");
        self.emit_call("tl_alloc");
        self.emit("    movq %rax, %r13");
        self.emit("    xorq %r10, %r10");
        self.emit(".L_tl_read_file_status_win_path_copy_loop:");
        self.emit("    cmpq %r12, %r10");
        self.emit("    jge .L_tl_read_file_status_win_path_copy_done");
        self.emit("    movzbl (%rbx,%r10), %edx");
        self.emit("    movb %dl, (%r13,%r10)");
        self.emit("    incq %r10");
        self.emit("    jmp .L_tl_read_file_status_win_path_copy_loop");
        self.emit(".L_tl_read_file_status_win_path_copy_done:");
        self.emit("    movb $0, (%r13,%r12)");
        self.emit("    movq %r13, %rcx");
        self.emit("    movq $0x8000, %rdx");
        self.emit("    xorq %r8, %r8");
        self.emit_call("_open");
        self.emit("    testl %eax, %eax");
        self.emit("    js .L_tl_read_file_status_win_errno");
        self.emit("    movslq %eax, %rbx");
        self.emit("    movq %rbx, %rcx");
        self.emit("    leaq -32(%rbp), %rdx");
        self.emit("    movq $1, %r8");
        self.emit_call("_read");
        self.emit("    testl %eax, %eax");
        self.emit("    js .L_tl_read_file_status_win_close_errno");
        self.emit("    movq %rbx, %rcx");
        self.emit_call("_close");
        self.emit("    testl %eax, %eax");
        self.emit("    js .L_tl_read_file_status_win_errno");
        self.emit("    xorq %rax, %rax");
        self.emit("    jmp .L_tl_read_file_status_win_return");
        self.emit(".L_tl_read_file_status_win_close_errno:");
        self.emit_call("_errno");
        self.emit("    movslq (%rax), %r12");
        self.emit("    testq %r12, %r12");
        self.emit("    jne .L_tl_read_file_status_win_close_saved");
        self.emit("    movq $1, %r12");
        self.emit(".L_tl_read_file_status_win_close_saved:");
        self.emit("    movq %rbx, %rcx");
        self.emit_call("_close");
        self.emit("    movq %r12, %rax");
        self.emit("    jmp .L_tl_read_file_status_win_return");
        self.emit(".L_tl_read_file_status_win_errno:");
        self.emit_call("_errno");
        self.emit("    movslq (%rax), %rax");
        self.emit("    testq %rax, %rax");
        self.emit("    jne .L_tl_read_file_status_win_return");
        self.emit("    movq $1, %rax");
        self.emit("    jmp .L_tl_read_file_status_win_return");
        self.emit(".L_tl_read_file_status_win_invalid:");
        self.emit("    movq $22, %rax");
        self.emit(".L_tl_read_file_status_win_return:");
        self.emit("    add $8, %rsp");
        self.emit("    pop %r13");
        self.emit("    pop %r12");
        self.emit("    pop %rbx");
        self.emit("    pop %rbp");
        self.emit("    ret");
        self.emit("");
    }

    fn generate_windows_write_file_status_runtime_functions(&mut self) {
        self.emit(&format!("{}:", WRITE_FILE_STATUS_RUNTIME_SYMBOL));
        self.emit("    push %rbp");
        self.emit("    mov %rsp, %rbp");
        self.emit("    push %rbx");
        self.emit("    push %r12");
        self.emit("    push %r13");
        self.emit("    push %r14");
        self.emit("    push %r15");
        self.emit("    sub $8, %rsp");
        self.emit("    movq %rcx, %rbx");
        self.emit("    movq %rdx, %r12");
        self.emit("    movq %r8, %r13");
        self.emit("    movq %r9, %r14");
        self.emit("    cmpq $0, %r12");
        self.emit("    jl .L_tl_write_file_status_win_invalid");
        self.emit("    cmpq $0, %r14");
        self.emit("    jl .L_tl_write_file_status_win_invalid");
        self.emit("    movq %r12, %rcx");
        self.emit("    addq $1, %rcx");
        self.emit("    js .L_tl_write_file_status_win_invalid");
        self.emit_call("tl_alloc");
        self.emit("    movq %rax, %r15");
        self.emit("    xorq %r10, %r10");
        self.emit(".L_tl_write_file_status_win_path_copy_loop:");
        self.emit("    cmpq %r12, %r10");
        self.emit("    jge .L_tl_write_file_status_win_path_copy_done");
        self.emit("    movzbl (%rbx,%r10), %edx");
        self.emit("    movb %dl, (%r15,%r10)");
        self.emit("    incq %r10");
        self.emit("    jmp .L_tl_write_file_status_win_path_copy_loop");
        self.emit(".L_tl_write_file_status_win_path_copy_done:");
        self.emit("    movb $0, (%r15,%r12)");
        self.emit("    movq %r15, %rcx");
        self.emit("    movq $0x8301, %rdx");
        self.emit("    movq $0x180, %r8");
        self.emit_call("_open");
        self.emit("    testl %eax, %eax");
        self.emit("    js .L_tl_write_file_status_win_errno");
        self.emit("    movslq %eax, %r15");
        self.emit("    movq %r15, %rcx");
        self.emit("    movq %r13, %rdx");
        self.emit("    movq %r14, %r8");
        self.emit_call("_write");
        self.emit("    testl %eax, %eax");
        self.emit("    js .L_tl_write_file_status_win_close_errno");
        self.emit("    movslq %eax, %rax");
        self.emit("    cmpq %r14, %rax");
        self.emit("    jne .L_tl_write_file_status_win_short_write");
        self.emit("    movq %r15, %rcx");
        self.emit_call("_close");
        self.emit("    testl %eax, %eax");
        self.emit("    js .L_tl_write_file_status_win_errno");
        self.emit("    xorq %rax, %rax");
        self.emit("    jmp .L_tl_write_file_status_win_return");
        self.emit(".L_tl_write_file_status_win_short_write:");
        self.emit("    movq $5, %r12");
        self.emit("    movq %r15, %rcx");
        self.emit_call("_close");
        self.emit("    movq %r12, %rax");
        self.emit("    jmp .L_tl_write_file_status_win_return");
        self.emit(".L_tl_write_file_status_win_close_errno:");
        self.emit_call("_errno");
        self.emit("    movslq (%rax), %r12");
        self.emit("    testq %r12, %r12");
        self.emit("    jne .L_tl_write_file_status_win_close_saved");
        self.emit("    movq $1, %r12");
        self.emit(".L_tl_write_file_status_win_close_saved:");
        self.emit("    movq %r15, %rcx");
        self.emit_call("_close");
        self.emit("    movq %r12, %rax");
        self.emit("    jmp .L_tl_write_file_status_win_return");
        self.emit(".L_tl_write_file_status_win_errno:");
        self.emit_call("_errno");
        self.emit("    movslq (%rax), %rax");
        self.emit("    testq %rax, %rax");
        self.emit("    jne .L_tl_write_file_status_win_return");
        self.emit("    movq $1, %rax");
        self.emit("    jmp .L_tl_write_file_status_win_return");
        self.emit(".L_tl_write_file_status_win_invalid:");
        self.emit("    movq $22, %rax");
        self.emit(".L_tl_write_file_status_win_return:");
        self.emit("    add $8, %rsp");
        self.emit("    pop %r15");
        self.emit("    pop %r14");
        self.emit("    pop %r13");
        self.emit("    pop %r12");
        self.emit("    pop %rbx");
        self.emit("    pop %rbp");
        self.emit("    ret");
        self.emit("");
    }

    fn generate_windows_file_exists_status_runtime_functions(&mut self) {
        self.emit(&format!("{}:", FILE_EXISTS_STATUS_RUNTIME_SYMBOL));
        self.emit("    push %rbp");
        self.emit("    mov %rsp, %rbp");
        self.emit("    push %rbx");
        self.emit("    push %r12");
        self.emit("    push %r13");
        self.emit("    sub $8, %rsp");
        self.emit("    movq %rcx, %rbx");
        self.emit("    movq %rdx, %r12");
        self.emit("    cmpq $0, %r12");
        self.emit("    jl .L_tl_file_exists_status_win_invalid");
        self.emit("    movq %r12, %rcx");
        self.emit("    addq $1, %rcx");
        self.emit("    js .L_tl_file_exists_status_win_invalid");
        self.emit_call("tl_alloc");
        self.emit("    movq %rax, %r13");
        self.emit("    xorq %r10, %r10");
        self.emit(".L_tl_file_exists_status_win_path_copy_loop:");
        self.emit("    cmpq %r12, %r10");
        self.emit("    jge .L_tl_file_exists_status_win_path_copy_done");
        self.emit("    movzbl (%rbx,%r10), %edx");
        self.emit("    movb %dl, (%r13,%r10)");
        self.emit("    incq %r10");
        self.emit("    jmp .L_tl_file_exists_status_win_path_copy_loop");
        self.emit(".L_tl_file_exists_status_win_path_copy_done:");
        self.emit("    movb $0, (%r13,%r12)");
        self.emit("    movq %r13, %rcx");
        self.emit("    xorq %rdx, %rdx");
        self.emit_call("_access");
        self.emit("    testl %eax, %eax");
        self.emit("    jz .L_tl_file_exists_status_win_success");
        self.emit_call("_errno");
        self.emit("    movslq (%rax), %rax");
        self.emit("    testq %rax, %rax");
        self.emit("    jne .L_tl_file_exists_status_win_return");
        self.emit("    movq $1, %rax");
        self.emit("    jmp .L_tl_file_exists_status_win_return");
        self.emit(".L_tl_file_exists_status_win_success:");
        self.emit("    xorq %rax, %rax");
        self.emit("    jmp .L_tl_file_exists_status_win_return");
        self.emit(".L_tl_file_exists_status_win_invalid:");
        self.emit("    movq $22, %rax");
        self.emit(".L_tl_file_exists_status_win_return:");
        self.emit("    add $8, %rsp");
        self.emit("    pop %r13");
        self.emit("    pop %r12");
        self.emit("    pop %rbx");
        self.emit("    pop %rbp");
        self.emit("    ret");
        self.emit("");
    }

    fn generate_process_output_runtime_functions(&mut self) {
        if self.target.runtime_policy().emits_windows_runtime_helpers {
            self.generate_windows_process_output_runtime_functions();
            return;
        }

        self.emit_many(&[
            "tl_process_output:",
            "    push %rbp",
            "    movq %rsp, %rbp",
            "    push %rbx",
            "    push %r12",
            "    push %r13",
            "    push %r14",
            "    push %r15",
            "    subq $232, %rsp",
            "    movq %rdi, -8(%rbp)",
            "    movq 0(%rdi), %rdi",
            "    call .L_tl_process_cstring_from_string",
            "    movq %rax, -16(%rbp)",
            "    movq -8(%rbp), %rax",
            "    movq 8(%rax), %r12",
            "    xorq %r13, %r13",
            ".L_tl_process_count_args:",
            "    cmpq $0, 0(%r12)",
            "    je .L_tl_process_count_args_done",
            "    incq %r13",
            "    movq 16(%r12), %r12",
            "    jmp .L_tl_process_count_args",
            ".L_tl_process_count_args_done:",
            "    movq %r13, -24(%rbp)",
            "    leaq 2(%r13), %rdi",
            "    shlq $3, %rdi",
            "    call tl_alloc",
            "    movq %rax, -32(%rbp)",
            "    movq -16(%rbp), %r10",
            "    movq %r10, 0(%rax)",
            "    movq -8(%rbp), %r10",
            "    movq 8(%r10), %r12",
            "    movq -32(%rbp), %r14",
            "    movq $1, %r15",
            ".L_tl_process_fill_argv:",
            "    cmpq $0, 0(%r12)",
            "    je .L_tl_process_fill_argv_done",
            "    movq 8(%r12), %rdi",
            "    call .L_tl_process_cstring_from_string",
            "    movq %rax, (%r14,%r15,8)",
            "    incq %r15",
            "    movq 16(%r12), %r12",
            "    jmp .L_tl_process_fill_argv",
            ".L_tl_process_fill_argv_done:",
            "    movq $0, (%r14,%r15,8)",
            "    movq -8(%rbp), %rax",
            "    movq 16(%rax), %r12",
            "    cmpq $0, 0(%r12)",
            "    je .L_tl_process_no_cwd",
            "    movq 8(%r12), %rdi",
            "    call .L_tl_process_cstring_from_string",
            "    movq %rax, -120(%rbp)",
            "    jmp .L_tl_process_cwd_ready",
            ".L_tl_process_no_cwd:",
            "    movq $0, -120(%rbp)",
            ".L_tl_process_cwd_ready:",
            "    movq -8(%rbp), %rax",
            "    movq 24(%rax), %rdi",
            "    call .L_tl_process_envp_from_overrides",
            "    movq %rax, -128(%rbp)",
            "    movq $-1, -136(%rbp)",
            "    movq -8(%rbp), %rax",
            "    movq 32(%rax), %r12",
            "    cmpq $0, 0(%r12)",
            "    je .L_tl_process_stdin_ready",
            "    movq 8(%r12), %r12",
            "    movq 0(%r12), %rsi",
            "    movq 8(%r12), %rdx",
            "    movq %rsi, -144(%rbp)",
            "    movq %rdx, -152(%rbp)",
            "    leaq .L_tl_process_stdin_name(%rip), %rdi",
            "    xorq %rsi, %rsi",
            "    movq $319, %rax",
            "    syscall",
            "    testq %rax, %rax",
            "    js .L_tl_process_spawn_failed",
            "    movq %rax, -136(%rbp)",
            "    movq %rax, %rdi",
            "    movq -144(%rbp), %rsi",
            "    movq -152(%rbp), %rdx",
            "    call .L_tl_process_write_all_fd",
            "    testq %rax, %rax",
            "    js .L_tl_process_spawn_failed",
            "    movq -136(%rbp), %rdi",
            "    call .L_tl_process_seek_start",
            "    testq %rax, %rax",
            "    js .L_tl_process_spawn_failed",
            ".L_tl_process_stdin_ready:",
            "    leaq .L_tl_process_stdout_name(%rip), %rdi",
            "    xorq %rsi, %rsi",
            "    movq $319, %rax",
            "    syscall",
            "    testq %rax, %rax",
            "    js .L_tl_process_spawn_failed",
            "    movq %rax, -40(%rbp)",
            "    leaq .L_tl_process_stderr_name(%rip), %rdi",
            "    xorq %rsi, %rsi",
            "    movq $319, %rax",
            "    syscall",
            "    testq %rax, %rax",
            "    js .L_tl_process_spawn_failed",
            "    movq %rax, -56(%rbp)",
            "    leaq -176(%rbp), %rdi",
            "    movq $524288, %rsi",
            "    movq $293, %rax",
            "    syscall",
            "    testq %rax, %rax",
            "    js .L_tl_process_spawn_failed",
            "    movslq -176(%rbp), %rax",
            "    movq %rax, -72(%rbp)",
            "    movslq -172(%rbp), %rax",
            "    movq %rax, -80(%rbp)",
            "    movq $57, %rax",
            "    syscall",
            "    testq %rax, %rax",
            "    js .L_tl_process_spawn_failed",
            "    jz .L_tl_process_child",
            "    movq %rax, -88(%rbp)",
            "    movq -80(%rbp), %rdi",
            "    call .L_tl_process_close_fd",
            "    cmpq $0, -136(%rbp)",
            "    jl .L_tl_process_parent_stdin_closed",
            "    movq -136(%rbp), %rdi",
            "    call .L_tl_process_close_fd",
            ".L_tl_process_parent_stdin_closed:",
            "    movq -88(%rbp), %rdi",
            "    leaq -184(%rbp), %rsi",
            "    xorq %rdx, %rdx",
            "    xorq %r10, %r10",
            "    movq $61, %rax",
            "    syscall",
            "    testq %rax, %rax",
            "    js .L_tl_process_wait_failed",
            "    movq -72(%rbp), %rdi",
            "    call .L_tl_process_read_all",
            "    movq %rax, -112(%rbp)",
            "    movq -72(%rbp), %rdi",
            "    call .L_tl_process_close_fd",
            "    movq -112(%rbp), %rax",
            "    cmpq $0, 8(%rax)",
            "    jne .L_tl_process_spawn_failed",
            "    movq -40(%rbp), %rdi",
            "    call .L_tl_process_seek_start",
            "    testq %rax, %rax",
            "    js .L_tl_process_wait_failed",
            "    movq -40(%rbp), %rdi",
            "    call .L_tl_process_read_all",
            "    movq %rax, -96(%rbp)",
            "    movq -40(%rbp), %rdi",
            "    call .L_tl_process_close_fd",
            "    movq -56(%rbp), %rdi",
            "    call .L_tl_process_seek_start",
            "    testq %rax, %rax",
            "    js .L_tl_process_wait_failed",
            "    movq -56(%rbp), %rdi",
            "    call .L_tl_process_read_all",
            "    movq %rax, -104(%rbp)",
            "    movq -56(%rbp), %rdi",
            "    call .L_tl_process_close_fd",
            "    movl -184(%rbp), %eax",
            "    movl %eax, %ecx",
            "    andl $127, %ecx",
            "    cmpl $0, %ecx",
            "    jne .L_tl_process_status_signal",
            "    shrl $8, %eax",
            "    andl $255, %eax",
            "    jmp .L_tl_process_status_ready",
            ".L_tl_process_status_signal:",
            "    movl %ecx, %eax",
            "    addl $128, %eax",
            ".L_tl_process_status_ready:",
            "    movslq %eax, %rdi",
            "    movq -96(%rbp), %rsi",
            "    movq -104(%rbp), %rdx",
            "    call .L_tl_process_make_ok",
            "    jmp .L_tl_process_return",
            ".L_tl_process_child:",
            "    movq -72(%rbp), %rdi",
            "    call .L_tl_process_close_fd",
            "    cmpq $0, -136(%rbp)",
            "    jl .L_tl_process_child_stdin_ready",
            "    movq -136(%rbp), %rdi",
            "    xorq %rsi, %rsi",
            "    movq $33, %rax",
            "    syscall",
            "    testq %rax, %rax",
            "    js .L_tl_process_child_exec_failed",
            "    movq -136(%rbp), %rdi",
            "    call .L_tl_process_close_fd",
            ".L_tl_process_child_stdin_ready:",
            "    movq -40(%rbp), %rdi",
            "    movq $1, %rsi",
            "    movq $33, %rax",
            "    syscall",
            "    movq -56(%rbp), %rdi",
            "    movq $2, %rsi",
            "    movq $33, %rax",
            "    syscall",
            "    movq -40(%rbp), %rdi",
            "    call .L_tl_process_close_fd",
            "    movq -56(%rbp), %rdi",
            "    call .L_tl_process_close_fd",
            "    cmpq $0, -120(%rbp)",
            "    je .L_tl_process_child_cwd_ready",
            "    movq -120(%rbp), %rdi",
            "    movq $80, %rax",
            "    syscall",
            "    testq %rax, %rax",
            "    js .L_tl_process_child_exec_failed",
            ".L_tl_process_child_cwd_ready:",
            "    movq -16(%rbp), %rdi",
            "    movq -32(%rbp), %rsi",
            "    movq -128(%rbp), %rdx",
            "    movq $59, %rax",
            "    syscall",
            ".L_tl_process_child_exec_failed:",
            "    movq $1, %rax",
            "    movq -80(%rbp), %rdi",
            "    leaq .L_tl_process_exec_marker(%rip), %rsi",
            "    movq $.L_tl_process_exec_marker_len, %rdx",
            "    syscall",
            "    movq $60, %rax",
            "    movq $127, %rdi",
            "    syscall",
            ".L_tl_process_spawn_failed:",
            "    leaq .L_tl_process_spawn_msg(%rip), %rdi",
            "    movq $.L_tl_process_spawn_msg_len, %rsi",
            "    movq $1, %rdx",
            "    call .L_tl_process_make_error",
            "    jmp .L_tl_process_return",
            ".L_tl_process_wait_failed:",
            "    leaq .L_tl_process_wait_msg(%rip), %rdi",
            "    movq $.L_tl_process_wait_msg_len, %rsi",
            "    movq $2, %rdx",
            "    call .L_tl_process_make_error",
            ".L_tl_process_return:",
            "    addq $232, %rsp",
            "    pop %r15",
            "    pop %r14",
            "    pop %r13",
            "    pop %r12",
            "    pop %rbx",
            "    movq %rbp, %rsp",
            "    pop %rbp",
            "    ret",
            "",
            ".L_tl_process_close_fd:",
            "    movq $3, %rax",
            "    syscall",
            "    ret",
            "",
            ".L_tl_process_seek_start:",
            "    xorq %rsi, %rsi",
            "    xorq %rdx, %rdx",
            "    movq $8, %rax",
            "    syscall",
            "    ret",
            "",
            ".L_tl_process_cstring_from_string:",
            "    push %rbp",
            "    movq %rsp, %rbp",
            "    push %rbx",
            "    push %r12",
            "    push %r13",
            "    push %r14",
            "    movq %rdi, %r12",
            "    movq 0(%r12), %r13",
            "    movq 8(%r12), %rbx",
            "    leaq 1(%rbx), %rdi",
            "    call tl_alloc",
            "    movq %rax, %r14",
            "    xorq %rcx, %rcx",
            ".L_tl_process_cstring_copy:",
            "    cmpq %rbx, %rcx",
            "    jge .L_tl_process_cstring_done",
            "    movzbl (%r13,%rcx), %edx",
            "    movb %dl, (%r14,%rcx)",
            "    incq %rcx",
            "    jmp .L_tl_process_cstring_copy",
            ".L_tl_process_cstring_done:",
            "    movb $0, (%r14,%rbx)",
            "    movq %r14, %rax",
            "    pop %r14",
            "    pop %r13",
            "    pop %r12",
            "    pop %rbx",
            "    movq %rbp, %rsp",
            "    pop %rbp",
            "    ret",
            "",
            ".L_tl_process_write_all_fd:",
            "    push %rbp",
            "    movq %rsp, %rbp",
            "    push %rbx",
            "    push %r12",
            "    push %r13",
            "    push %r14",
            "    movq %rdi, %r12",
            "    movq %rsi, %r13",
            "    movq %rdx, %rbx",
            "    xorq %r14, %r14",
            ".L_tl_process_write_all_loop:",
            "    cmpq %rbx, %r14",
            "    jge .L_tl_process_write_all_ok",
            "    movq $1, %rax",
            "    movq %r12, %rdi",
            "    leaq (%r13,%r14), %rsi",
            "    movq %rbx, %rdx",
            "    subq %r14, %rdx",
            "    syscall",
            "    testq %rax, %rax",
            "    js .L_tl_process_write_all_fail",
            "    jz .L_tl_process_write_all_fail",
            "    addq %rax, %r14",
            "    jmp .L_tl_process_write_all_loop",
            ".L_tl_process_write_all_ok:",
            "    xorq %rax, %rax",
            "    jmp .L_tl_process_write_all_return",
            ".L_tl_process_write_all_fail:",
            "    movq $-1, %rax",
            ".L_tl_process_write_all_return:",
            "    pop %r14",
            "    pop %r13",
            "    pop %r12",
            "    pop %rbx",
            "    movq %rbp, %rsp",
            "    pop %rbp",
            "    ret",
            "",
            ".L_tl_process_env_entry_matches_name:",
            "    push %rbp",
            "    movq %rsp, %rbp",
            "    push %rbx",
            "    push %r12",
            "    push %r13",
            "    push %r14",
            "    movq %rdi, %rbx",
            "    movq 0(%rsi), %r12",
            "    movq 8(%rsi), %r13",
            "    xorq %r14, %r14",
            ".L_tl_process_env_name_loop:",
            "    cmpq %r13, %r14",
            "    jge .L_tl_process_env_name_done",
            "    movzbl (%r12,%r14), %eax",
            "    cmpb %al, (%rbx,%r14)",
            "    jne .L_tl_process_env_name_false",
            "    incq %r14",
            "    jmp .L_tl_process_env_name_loop",
            ".L_tl_process_env_name_done:",
            "    cmpb $61, (%rbx,%r13)",
            "    je .L_tl_process_env_name_true",
            ".L_tl_process_env_name_false:",
            "    xorq %rax, %rax",
            "    jmp .L_tl_process_env_name_return",
            ".L_tl_process_env_name_true:",
            "    movq $1, %rax",
            ".L_tl_process_env_name_return:",
            "    pop %r14",
            "    pop %r13",
            "    pop %r12",
            "    pop %rbx",
            "    movq %rbp, %rsp",
            "    pop %rbp",
            "    ret",
            "",
            ".L_tl_process_env_entry_matches_any:",
            "    push %rbp",
            "    movq %rsp, %rbp",
            "    push %rbx",
            "    push %r12",
            "    movq %rdi, %rbx",
            "    movq %rsi, %r12",
            ".L_tl_process_env_any_loop:",
            "    cmpq $0, 0(%r12)",
            "    je .L_tl_process_env_any_false",
            "    movq %rbx, %rdi",
            "    movq 8(%r12), %rsi",
            "    call .L_tl_process_env_entry_matches_name",
            "    testq %rax, %rax",
            "    jne .L_tl_process_env_any_true",
            "    movq 24(%r12), %r12",
            "    jmp .L_tl_process_env_any_loop",
            ".L_tl_process_env_any_false:",
            "    xorq %rax, %rax",
            "    jmp .L_tl_process_env_any_return",
            ".L_tl_process_env_any_true:",
            "    movq $1, %rax",
            ".L_tl_process_env_any_return:",
            "    pop %r12",
            "    pop %rbx",
            "    movq %rbp, %rsp",
            "    pop %rbp",
            "    ret",
            "",
            ".L_tl_process_env_cstring:",
            "    push %rbp",
            "    movq %rsp, %rbp",
            "    push %rbx",
            "    push %r12",
            "    push %r13",
            "    push %r14",
            "    push %r15",
            "    subq $8, %rsp",
            "    movq 0(%rdi), %r12",
            "    movq 8(%rdi), %rbx",
            "    movq 0(%rsi), %r14",
            "    movq 8(%rsi), %r13",
            "    movq %rbx, %rdi",
            "    addq %r13, %rdi",
            "    addq $2, %rdi",
            "    call tl_alloc",
            "    movq %rax, %r15",
            "    xorq %rcx, %rcx",
            ".L_tl_process_env_copy_name:",
            "    cmpq %rbx, %rcx",
            "    jge .L_tl_process_env_copy_name_done",
            "    movzbl (%r12,%rcx), %eax",
            "    movb %al, (%r15,%rcx)",
            "    incq %rcx",
            "    jmp .L_tl_process_env_copy_name",
            ".L_tl_process_env_copy_name_done:",
            "    movb $61, (%r15,%rbx)",
            "    xorq %rcx, %rcx",
            ".L_tl_process_env_copy_value:",
            "    cmpq %r13, %rcx",
            "    jge .L_tl_process_env_copy_value_done",
            "    movzbl (%r14,%rcx), %eax",
            "    leaq 1(%rbx,%rcx), %rdx",
            "    movb %al, (%r15,%rdx)",
            "    incq %rcx",
            "    jmp .L_tl_process_env_copy_value",
            ".L_tl_process_env_copy_value_done:",
            "    leaq 1(%rbx,%r13), %rdx",
            "    movb $0, (%r15,%rdx)",
            "    movq %r15, %rax",
            "    addq $8, %rsp",
            "    pop %r15",
            "    pop %r14",
            "    pop %r13",
            "    pop %r12",
            "    pop %rbx",
            "    movq %rbp, %rsp",
            "    pop %rbp",
            "    ret",
            "",
            ".L_tl_process_envp_from_overrides:",
            "    push %rbp",
            "    movq %rsp, %rbp",
            "    push %rbx",
            "    push %r12",
            "    push %r13",
            "    push %r14",
            "    push %r15",
            "    subq $8, %rsp",
            "    movq %rdi, %r12",
            "    cmpq $0, 0(%r12)",
            "    jne .L_tl_process_envp_build",
            "    movq .L_tl_envp(%rip), %rax",
            "    jmp .L_tl_process_envp_return",
            ".L_tl_process_envp_build:",
            "    movq .L_tl_envp(%rip), %rbx",
            "    xorq %r13, %r13",
            ".L_tl_process_envp_count_inherited:",
            "    movq (%rbx,%r13,8), %rax",
            "    testq %rax, %rax",
            "    jz .L_tl_process_envp_count_overrides_start",
            "    incq %r13",
            "    jmp .L_tl_process_envp_count_inherited",
            ".L_tl_process_envp_count_overrides_start:",
            "    xorq %r14, %r14",
            "    movq %r12, %r15",
            ".L_tl_process_envp_count_overrides:",
            "    cmpq $0, 0(%r15)",
            "    je .L_tl_process_envp_allocate",
            "    incq %r14",
            "    movq 24(%r15), %r15",
            "    jmp .L_tl_process_envp_count_overrides",
            ".L_tl_process_envp_allocate:",
            "    movq %r13, %rdi",
            "    addq %r14, %rdi",
            "    incq %rdi",
            "    shlq $3, %rdi",
            "    call tl_alloc",
            "    movq %rax, %r15",
            "    xorq %r14, %r14",
            "    movq .L_tl_envp(%rip), %rbx",
            ".L_tl_process_envp_copy_inherited:",
            "    movq (%rbx), %rdi",
            "    testq %rdi, %rdi",
            "    jz .L_tl_process_envp_copy_overrides_start",
            "    movq %r12, %rsi",
            "    call .L_tl_process_env_entry_matches_any",
            "    testq %rax, %rax",
            "    jne .L_tl_process_envp_skip_inherited",
            "    movq (%rbx), %rax",
            "    movq %rax, (%r15,%r14,8)",
            "    incq %r14",
            ".L_tl_process_envp_skip_inherited:",
            "    addq $8, %rbx",
            "    jmp .L_tl_process_envp_copy_inherited",
            ".L_tl_process_envp_copy_overrides_start:",
            "    movq %r12, %rbx",
            ".L_tl_process_envp_copy_overrides:",
            "    cmpq $0, 0(%rbx)",
            "    je .L_tl_process_envp_done",
            "    movq 8(%rbx), %rdi",
            "    movq 16(%rbx), %rsi",
            "    call .L_tl_process_env_cstring",
            "    movq %rax, (%r15,%r14,8)",
            "    incq %r14",
            "    movq 24(%rbx), %rbx",
            "    jmp .L_tl_process_envp_copy_overrides",
            ".L_tl_process_envp_done:",
            "    movq $0, (%r15,%r14,8)",
            "    movq %r15, %rax",
            ".L_tl_process_envp_return:",
            "    addq $8, %rsp",
            "    pop %r15",
            "    pop %r14",
            "    pop %r13",
            "    pop %r12",
            "    pop %rbx",
            "    movq %rbp, %rsp",
            "    pop %rbp",
            "    ret",
            "",
            ".L_tl_process_read_all:",
            "    push %rbp",
            "    movq %rsp, %rbp",
            "    push %rbx",
            "    push %r12",
            "    push %r13",
            "    push %r14",
            "    push %r15",
            "    subq $8, %rsp",
            "    movq %rdi, %r12",
            "    movq $4096, %r13",
            "    movq %r13, %rdi",
            "    call tl_alloc",
            "    movq %rax, %r14",
            "    xorq %r15, %r15",
            ".L_tl_process_read_loop:",
            "    movq %r13, %rdx",
            "    subq %r15, %rdx",
            "    cmpq $1024, %rdx",
            "    jl .L_tl_process_read_grow",
            "    movq $0, %rax",
            "    movq %r12, %rdi",
            "    leaq (%r14,%r15), %rsi",
            "    syscall",
            "    testq %rax, %rax",
            "    js .L_tl_process_read_done",
            "    jz .L_tl_process_read_done",
            "    addq %rax, %r15",
            "    jmp .L_tl_process_read_loop",
            ".L_tl_process_read_grow:",
            "    movq %r13, %rdi",
            "    shlq $1, %rdi",
            "    movq %rdi, %r13",
            "    call tl_alloc",
            "    movq %rax, %r10",
            "    xorq %rbx, %rbx",
            ".L_tl_process_read_copy:",
            "    cmpq %r15, %rbx",
            "    jge .L_tl_process_read_copy_done",
            "    movzbl (%r14,%rbx), %eax",
            "    movb %al, (%r10,%rbx)",
            "    incq %rbx",
            "    jmp .L_tl_process_read_copy",
            ".L_tl_process_read_copy_done:",
            "    movq %r10, %r14",
            "    jmp .L_tl_process_read_loop",
            ".L_tl_process_read_done:",
            "    movq $16, %rdi",
            "    call tl_alloc",
            "    movq %r14, 0(%rax)",
            "    movq %r15, 8(%rax)",
            "    addq $8, %rsp",
            "    pop %r15",
            "    pop %r14",
            "    pop %r13",
            "    pop %r12",
            "    pop %rbx",
            "    movq %rbp, %rsp",
            "    pop %rbp",
            "    ret",
            "",
            ".L_tl_process_make_ok:",
            "    push %rbp",
            "    movq %rsp, %rbp",
            "    push %rbx",
            "    push %r12",
            "    push %r13",
            "    subq $8, %rsp",
            "    movq %rdi, %rbx",
            "    movq %rsi, %r12",
            "    movq %rdx, %r13",
            "    movq $24, %rdi",
            "    call tl_alloc",
            "    movq %rbx, 0(%rax)",
            "    movq %r12, 8(%rax)",
            "    movq %r13, 16(%rax)",
            "    movq %rax, %r12",
            "    movq $16, %rdi",
            "    call tl_alloc",
            "    movq $0, 0(%rax)",
            "    movq %r12, 8(%rax)",
            "    addq $8, %rsp",
            "    pop %r13",
            "    pop %r12",
            "    pop %rbx",
            "    movq %rbp, %rsp",
            "    pop %rbp",
            "    ret",
            "",
            ".L_tl_process_make_error:",
            "    push %rbp",
            "    movq %rsp, %rbp",
            "    push %rbx",
            "    push %r12",
            "    push %r13",
            "    push %r14",
            "    movq %rdi, %r12",
            "    movq %rsi, %r13",
            "    movq %rdx, %r14",
            "    movq $16, %rdi",
            "    call tl_alloc",
            "    movq %r12, 0(%rax)",
            "    movq %r13, 8(%rax)",
            "    movq %rax, %r12",
            "    movq $16, %rdi",
            "    call tl_alloc",
            "    movq %r14, 0(%rax)",
            "    movq %r12, 8(%rax)",
            "    movq %rax, %r12",
            "    movq $16, %rdi",
            "    call tl_alloc",
            "    movq $1, 0(%rax)",
            "    movq %r12, 8(%rax)",
            "    pop %r14",
            "    pop %r13",
            "    pop %r12",
            "    pop %rbx",
            "    movq %rbp, %rsp",
            "    pop %rbp",
            "    ret",
            "",
        ]);
    }

    fn generate_windows_process_output_runtime_functions(&mut self) {
        self.emit(&format!("    .globl {}", PROCESS_OUTPUT_RUNTIME_SYMBOL));
        self.emit(&format!("{}:", PROCESS_OUTPUT_RUNTIME_SYMBOL));
        self.emit("    push %rbp");
        self.emit("    mov %rsp, %rbp");
        self.emit("    push %rbx");
        self.emit("    push %r12");
        self.emit("    push %r13");
        self.emit("    push %r14");
        self.emit("    push %r15");
        self.emit("    sub $104, %rsp");
        self.emit("    movq %rcx, %rbx");
        self.emit("    movq $0, -48(%rbp)");
        self.emit("    movq $0, -56(%rbp)");
        self.emit("    movq $0, -64(%rbp)");
        self.emit("    movq $0, -72(%rbp)");
        self.emit("    movq $-1, -80(%rbp)");
        self.emit("    movq $-1, -88(%rbp)");

        // Build a null-terminated executable path and argv array. argv[0] is the
        // executable, followed by the ProcessStringList entries, then NULL.
        self.emit("    movq 0(%rbx), %rcx");
        self.emit_call(".L_tl_process_copy_c_string");
        self.emit("    movq %rax, %r12");
        self.emit("    movq $1, %r13");
        self.emit("    movq 8(%rbx), %r14");
        self.emit(".L_tl_process_count_argv:");
        self.emit("    testq %r14, %r14");
        self.emit("    jz .L_tl_process_count_argv_done");
        self.emit("    cmpq $1, 0(%r14)");
        self.emit("    jne .L_tl_process_count_argv_done");
        self.emit("    incq %r13");
        self.emit("    movq 16(%r14), %r14");
        self.emit("    jmp .L_tl_process_count_argv");
        self.emit(".L_tl_process_count_argv_done:");
        self.emit("    movq %r13, %rcx");
        self.emit("    incq %rcx");
        self.emit("    shlq $3, %rcx");
        self.emit_call("tl_alloc");
        self.emit("    movq %rax, %r14");
        self.emit("    movq %r12, 0(%r14)");
        self.emit("    movq 8(%rbx), %r13");
        self.emit("    movq $1, %r15");
        self.emit(".L_tl_process_fill_argv:");
        self.emit("    testq %r13, %r13");
        self.emit("    jz .L_tl_process_fill_argv_done");
        self.emit("    cmpq $1, 0(%r13)");
        self.emit("    jne .L_tl_process_fill_argv_done");
        self.emit("    movq 8(%r13), %rcx");
        self.emit_call(".L_tl_process_copy_c_string");
        self.emit("    movq %rax, (%r14,%r15,8)");
        self.emit("    incq %r15");
        self.emit("    movq 16(%r13), %r13");
        self.emit("    jmp .L_tl_process_fill_argv");
        self.emit(".L_tl_process_fill_argv_done:");
        self.emit("    movq $0, (%r14,%r15,8)");

        // Capture stdout/stderr via temporary files, then restore this process's
        // descriptors immediately after the child exits.
        self.emit_call("tmpfile");
        self.emit("    testq %rax, %rax");
        self.emit("    jz .L_tl_process_output_wait_failed_close");
        self.emit("    movq %rax, -48(%rbp)");
        self.emit("    movq %rax, %rcx");
        self.emit_call("_fileno");
        self.emit("    testl %eax, %eax");
        self.emit("    js .L_tl_process_output_wait_failed_close");
        self.emit("    movslq %eax, %rax");
        self.emit("    movq %rax, -56(%rbp)");
        self.emit_call("tmpfile");
        self.emit("    testq %rax, %rax");
        self.emit("    jz .L_tl_process_output_wait_failed_close");
        self.emit("    movq %rax, -64(%rbp)");
        self.emit("    movq %rax, %rcx");
        self.emit_call("_fileno");
        self.emit("    testl %eax, %eax");
        self.emit("    js .L_tl_process_output_wait_failed_close");
        self.emit("    movslq %eax, %rax");
        self.emit("    movq %rax, -72(%rbp)");
        self.emit("    movq $1, %rcx");
        self.emit_call("_dup");
        self.emit("    testl %eax, %eax");
        self.emit("    js .L_tl_process_output_wait_failed_close");
        self.emit("    movslq %eax, %rax");
        self.emit("    movq %rax, -80(%rbp)");
        self.emit("    movq $2, %rcx");
        self.emit_call("_dup");
        self.emit("    testl %eax, %eax");
        self.emit("    js .L_tl_process_output_wait_failed_close");
        self.emit("    movslq %eax, %rax");
        self.emit("    movq %rax, -88(%rbp)");
        self.emit("    xorq %rcx, %rcx");
        self.emit_call("fflush");
        self.emit("    movq -56(%rbp), %rcx");
        self.emit("    movq $1, %rdx");
        self.emit_call("_dup2");
        self.emit("    testl %eax, %eax");
        self.emit("    js .L_tl_process_output_restore_wait_failed");
        self.emit("    movq -72(%rbp), %rcx");
        self.emit("    movq $2, %rdx");
        self.emit_call("_dup2");
        self.emit("    testl %eax, %eax");
        self.emit("    js .L_tl_process_output_restore_wait_failed");
        self.emit("    movq $0, %rcx");
        self.emit("    movq %r12, %rdx");
        self.emit("    movq %r14, %r8");
        self.emit_call("_spawnv");
        self.emit("    movslq %eax, %r15");
        self.emit("    jmp .L_tl_process_output_restore_after_spawn");

        self.emit(".L_tl_process_output_restore_wait_failed:");
        self.emit("    movq -80(%rbp), %rcx");
        self.emit("    cmpq $0, %rcx");
        self.emit("    jl .L_tl_process_output_restore_wait_stderr");
        self.emit("    movq $1, %rdx");
        self.emit_call("_dup2");
        self.emit("    movq -80(%rbp), %rcx");
        self.emit_call("_close");
        self.emit("    movq $-1, -80(%rbp)");
        self.emit(".L_tl_process_output_restore_wait_stderr:");
        self.emit("    movq -88(%rbp), %rcx");
        self.emit("    cmpq $0, %rcx");
        self.emit("    jl .L_tl_process_output_wait_failed_close");
        self.emit("    movq $2, %rdx");
        self.emit_call("_dup2");
        self.emit("    movq -88(%rbp), %rcx");
        self.emit_call("_close");
        self.emit("    movq $-1, -88(%rbp)");
        self.emit("    jmp .L_tl_process_output_wait_failed_close");

        self.emit(".L_tl_process_output_restore_after_spawn:");
        self.emit("    movq -80(%rbp), %rcx");
        self.emit("    movq $1, %rdx");
        self.emit_call("_dup2");
        self.emit("    movq -80(%rbp), %rcx");
        self.emit_call("_close");
        self.emit("    movq $-1, -80(%rbp)");
        self.emit("    movq -88(%rbp), %rcx");
        self.emit("    movq $2, %rdx");
        self.emit_call("_dup2");
        self.emit("    movq -88(%rbp), %rcx");
        self.emit_call("_close");
        self.emit("    movq $-1, -88(%rbp)");
        self.emit("    cmpq $0, %r15");
        self.emit("    jl .L_tl_process_output_spawn_failed_close");

        self.emit("    movq -56(%rbp), %rcx");
        self.emit_call(".L_tl_process_read_fd_to_string");
        self.emit("    testq %rax, %rax");
        self.emit("    jz .L_tl_process_output_wait_failed_close");
        self.emit("    movq %rax, -96(%rbp)");
        self.emit("    movq -72(%rbp), %rcx");
        self.emit_call(".L_tl_process_read_fd_to_string");
        self.emit("    testq %rax, %rax");
        self.emit("    jz .L_tl_process_output_wait_failed_close");
        self.emit("    movq %rax, -104(%rbp)");
        self.emit("    call .L_tl_process_close_temp_files");
        self.emit("    movq $24, %rcx");
        self.emit_call("tl_alloc");
        self.emit("    movq %r15, 0(%rax)");
        self.emit("    movq -96(%rbp), %rdx");
        self.emit("    movq %rdx, 8(%rax)");
        self.emit("    movq -104(%rbp), %rdx");
        self.emit("    movq %rdx, 16(%rax)");
        self.emit("    movq %rax, %r12");
        self.emit("    movq $16, %rcx");
        self.emit_call("tl_alloc");
        self.emit("    movq $0, 0(%rax)");
        self.emit("    movq %r12, 8(%rax)");
        self.emit("    jmp .L_tl_process_output_epilogue");

        self.emit(".L_tl_process_output_spawn_failed_close:");
        self.emit("    call .L_tl_process_close_temp_files");
        self.emit("    movq $1, %rcx");
        self.emit("    leaq .L_tl_process_spawn_msg(%rip), %rdx");
        self.emit("    movq $.L_tl_process_spawn_msg_len, %r8");
        self.emit_call(".L_tl_process_error_result");
        self.emit("    jmp .L_tl_process_output_epilogue");

        self.emit(".L_tl_process_output_wait_failed_close:");
        self.emit("    call .L_tl_process_close_temp_files");
        self.emit("    movq $2, %rcx");
        self.emit("    leaq .L_tl_process_wait_msg(%rip), %rdx");
        self.emit("    movq $.L_tl_process_wait_msg_len, %r8");
        self.emit_call(".L_tl_process_error_result");
        self.emit("    jmp .L_tl_process_output_epilogue");

        self.emit(".L_tl_process_output_epilogue:");
        self.emit("    add $104, %rsp");
        self.emit("    pop %r15");
        self.emit("    pop %r14");
        self.emit("    pop %r13");
        self.emit("    pop %r12");
        self.emit("    pop %rbx");
        self.emit("    pop %rbp");
        self.emit("    ret");
        self.emit("");

        self.generate_windows_process_copy_c_string_runtime_function();
        self.generate_windows_process_read_fd_to_string_runtime_function();
        self.generate_windows_process_error_result_runtime_function();
        self.generate_windows_process_close_temp_files_runtime_function();
    }

    fn generate_windows_process_copy_c_string_runtime_function(&mut self) {
        self.emit(".L_tl_process_copy_c_string:");
        self.emit("    push %rbp");
        self.emit("    mov %rsp, %rbp");
        self.emit("    push %rbx");
        self.emit("    push %r12");
        self.emit("    push %r13");
        self.emit("    sub $8, %rsp");
        self.emit("    movq 0(%rcx), %rbx");
        self.emit("    movq 8(%rcx), %r12");
        self.emit("    movq %r12, %rcx");
        self.emit("    incq %rcx");
        self.emit_call("tl_alloc");
        self.emit("    movq %rax, %r13");
        self.emit("    xorq %r10, %r10");
        self.emit(".L_tl_process_copy_c_string_loop:");
        self.emit("    cmpq %r12, %r10");
        self.emit("    jge .L_tl_process_copy_c_string_done");
        self.emit("    movzbl (%rbx,%r10), %edx");
        self.emit("    movb %dl, (%r13,%r10)");
        self.emit("    incq %r10");
        self.emit("    jmp .L_tl_process_copy_c_string_loop");
        self.emit(".L_tl_process_copy_c_string_done:");
        self.emit("    movb $0, (%r13,%r12)");
        self.emit("    movq %r13, %rax");
        self.emit("    add $8, %rsp");
        self.emit("    pop %r13");
        self.emit("    pop %r12");
        self.emit("    pop %rbx");
        self.emit("    pop %rbp");
        self.emit("    ret");
        self.emit("");
    }

    fn generate_windows_process_read_fd_to_string_runtime_function(&mut self) {
        self.emit(".L_tl_process_read_fd_to_string:");
        self.emit("    push %rbp");
        self.emit("    mov %rsp, %rbp");
        self.emit("    push %rbx");
        self.emit("    push %r12");
        self.emit("    push %r13");
        self.emit("    push %r14");
        self.emit("    movq %rcx, %rbx");
        self.emit("    movq %rbx, %rcx");
        self.emit("    xorq %rdx, %rdx");
        self.emit("    movq $2, %r8");
        self.emit_call("_lseeki64");
        self.emit("    cmpq $0, %rax");
        self.emit("    jl .L_tl_process_read_fd_to_string_error");
        self.emit("    movq %rax, %r12");
        self.emit("    movq %rbx, %rcx");
        self.emit("    xorq %rdx, %rdx");
        self.emit("    xorq %r8, %r8");
        self.emit_call("_lseeki64");
        self.emit("    cmpq $0, %rax");
        self.emit("    jl .L_tl_process_read_fd_to_string_error");
        self.emit("    movq %r12, %rcx");
        self.emit_call("tl_alloc");
        self.emit("    movq %rax, %r13");
        self.emit("    xorq %r14, %r14");
        self.emit(".L_tl_process_read_fd_to_string_loop:");
        self.emit("    cmpq %r12, %r14");
        self.emit("    jge .L_tl_process_read_fd_to_string_fat");
        self.emit("    movq %rbx, %rcx");
        self.emit("    leaq (%r13,%r14), %rdx");
        self.emit("    movq %r12, %r8");
        self.emit("    subq %r14, %r8");
        self.emit_call("_read");
        self.emit("    testl %eax, %eax");
        self.emit("    js .L_tl_process_read_fd_to_string_error");
        self.emit("    jz .L_tl_process_read_fd_to_string_fat");
        self.emit("    movslq %eax, %rax");
        self.emit("    addq %rax, %r14");
        self.emit("    jmp .L_tl_process_read_fd_to_string_loop");
        self.emit(".L_tl_process_read_fd_to_string_fat:");
        self.emit("    movq $16, %rcx");
        self.emit_call("tl_alloc");
        self.emit("    movq %r13, 0(%rax)");
        self.emit("    movq %r14, 8(%rax)");
        self.emit("    jmp .L_tl_process_read_fd_to_string_done");
        self.emit(".L_tl_process_read_fd_to_string_error:");
        self.emit("    xorq %rax, %rax");
        self.emit(".L_tl_process_read_fd_to_string_done:");
        self.emit("    pop %r14");
        self.emit("    pop %r13");
        self.emit("    pop %r12");
        self.emit("    pop %rbx");
        self.emit("    pop %rbp");
        self.emit("    ret");
        self.emit("");
    }

    fn generate_windows_process_error_result_runtime_function(&mut self) {
        self.emit(".L_tl_process_error_result:");
        self.emit("    push %rbp");
        self.emit("    mov %rsp, %rbp");
        self.emit("    push %rbx");
        self.emit("    push %r12");
        self.emit("    push %r13");
        self.emit("    push %r14");
        self.emit("    push %r15");
        self.emit("    sub $8, %rsp");
        self.emit("    movq %rcx, %rbx");
        self.emit("    movq %rdx, %r12");
        self.emit("    movq %r8, %r13");
        self.emit("    movq $16, %rcx");
        self.emit_call("tl_alloc");
        self.emit("    movq %r12, 0(%rax)");
        self.emit("    movq %r13, 8(%rax)");
        self.emit("    movq %rax, %r14");
        self.emit("    movq $16, %rcx");
        self.emit_call("tl_alloc");
        self.emit("    movq %rbx, 0(%rax)");
        self.emit("    movq %r14, 8(%rax)");
        self.emit("    movq %rax, %r15");
        self.emit("    movq $16, %rcx");
        self.emit_call("tl_alloc");
        self.emit("    movq $1, 0(%rax)");
        self.emit("    movq %r15, 8(%rax)");
        self.emit("    add $8, %rsp");
        self.emit("    pop %r15");
        self.emit("    pop %r14");
        self.emit("    pop %r13");
        self.emit("    pop %r12");
        self.emit("    pop %rbx");
        self.emit("    pop %rbp");
        self.emit("    ret");
        self.emit("");
    }

    fn generate_windows_process_close_temp_files_runtime_function(&mut self) {
        self.emit(".L_tl_process_close_temp_files:");
        self.emit("    sub $8, %rsp");
        self.emit("    movq -48(%rbp), %rcx");
        self.emit("    testq %rcx, %rcx");
        self.emit("    jz .L_tl_process_close_temp_stderr");
        self.emit_call("fclose");
        self.emit("    movq $0, -48(%rbp)");
        self.emit(".L_tl_process_close_temp_stderr:");
        self.emit("    movq -64(%rbp), %rcx");
        self.emit("    testq %rcx, %rcx");
        self.emit("    jz .L_tl_process_close_temp_done");
        self.emit_call("fclose");
        self.emit("    movq $0, -64(%rbp)");
        self.emit(".L_tl_process_close_temp_done:");
        self.emit("    movq -80(%rbp), %rcx");
        self.emit("    cmpq $0, %rcx");
        self.emit("    jl .L_tl_process_close_saved_stderr");
        self.emit_call("_close");
        self.emit("    movq $-1, -80(%rbp)");
        self.emit(".L_tl_process_close_saved_stderr:");
        self.emit("    movq -88(%rbp), %rcx");
        self.emit("    cmpq $0, %rcx");
        self.emit("    jl .L_tl_process_close_all_done");
        self.emit_call("_close");
        self.emit("    movq $-1, -88(%rbp)");
        self.emit(".L_tl_process_close_all_done:");
        self.emit("    add $8, %rsp");
        self.emit("    ret");
        self.emit("");
    }

    fn generate_env_var_exists_runtime_functions(&mut self) {
        if self.target.runtime_policy().emits_windows_runtime_helpers {
            self.generate_windows_env_var_exists_runtime_functions();
            return;
        }

        self.emit(&format!("{}:", ENV_VAR_EXISTS_RUNTIME_SYMBOL));
        self.emit("    push %rbp");
        self.emit("    mov %rsp, %rbp");
        self.emit("    push %rbx");
        self.emit("    push %r12");
        self.emit("    push %r13");
        self.emit("    push %r14");
        self.emit("    push %r15");
        self.emit("    movq %rdi, %rbx");
        self.emit("    movq %rsi, %r12");
        self.emit("    cmpq $0, %r12");
        self.emit("    jl .L_tl_env_var_exists_false");
        self.emit("    movq .L_tl_envp(%rip), %r13");
        self.emit(".L_tl_env_var_exists_next:");
        self.emit("    movq (%r13), %r14");
        self.emit("    testq %r14, %r14");
        self.emit("    jz .L_tl_env_var_exists_false");
        self.emit("    xorq %r15, %r15");
        self.emit(".L_tl_env_var_exists_name_loop:");
        self.emit("    cmpq %r12, %r15");
        self.emit("    jge .L_tl_env_var_exists_name_done");
        self.emit("    movzbl (%rbx,%r15), %eax");
        self.emit("    cmpb %al, (%r14,%r15)");
        self.emit("    jne .L_tl_env_var_exists_advance");
        self.emit("    incq %r15");
        self.emit("    jmp .L_tl_env_var_exists_name_loop");
        self.emit(".L_tl_env_var_exists_name_done:");
        self.emit("    cmpb $61, (%r14,%r12)");
        self.emit("    je .L_tl_env_var_exists_true");
        self.emit(".L_tl_env_var_exists_advance:");
        self.emit("    addq $8, %r13");
        self.emit("    jmp .L_tl_env_var_exists_next");
        self.emit(".L_tl_env_var_exists_true:");
        self.emit("    movq $1, %rax");
        self.emit("    jmp .L_tl_env_var_exists_return");
        self.emit(".L_tl_env_var_exists_false:");
        self.emit("    xorq %rax, %rax");
        self.emit(".L_tl_env_var_exists_return:");
        self.emit("    pop %r15");
        self.emit("    pop %r14");
        self.emit("    pop %r13");
        self.emit("    pop %r12");
        self.emit("    pop %rbx");
        self.emit("    pop %rbp");
        self.emit("    ret");
        self.emit("");
    }

    fn generate_env_var_value_runtime_functions(&mut self) {
        if self.target.runtime_policy().emits_windows_runtime_helpers {
            self.generate_windows_env_var_value_runtime_functions();
            return;
        }

        self.emit(&format!("{}:", ENV_VAR_VALUE_RUNTIME_SYMBOL));
        self.emit("    push %rbp");
        self.emit("    mov %rsp, %rbp");
        self.emit("    push %rbx");
        self.emit("    push %r12");
        self.emit("    push %r13");
        self.emit("    push %r14");
        self.emit("    push %r15");
        self.emit("    sub $8, %rsp");
        self.emit("    movq %rdi, %rbx");
        self.emit("    movq %rsi, %r12");
        self.emit("    cmpq $0, %r12");
        self.emit("    jl .L_tl_env_var_value_empty");
        self.emit("    movq .L_tl_envp(%rip), %r13");
        self.emit(".L_tl_env_var_value_next:");
        self.emit("    movq (%r13), %r14");
        self.emit("    testq %r14, %r14");
        self.emit("    jz .L_tl_env_var_value_empty");
        self.emit("    xorq %r15, %r15");
        self.emit(".L_tl_env_var_value_name_loop:");
        self.emit("    cmpq %r12, %r15");
        self.emit("    jge .L_tl_env_var_value_name_done");
        self.emit("    movzbl (%rbx,%r15), %eax");
        self.emit("    cmpb %al, (%r14,%r15)");
        self.emit("    jne .L_tl_env_var_value_advance");
        self.emit("    incq %r15");
        self.emit("    jmp .L_tl_env_var_value_name_loop");
        self.emit(".L_tl_env_var_value_name_done:");
        self.emit("    cmpb $61, (%r14,%r12)");
        self.emit("    je .L_tl_env_var_value_found");
        self.emit(".L_tl_env_var_value_advance:");
        self.emit("    addq $8, %r13");
        self.emit("    jmp .L_tl_env_var_value_next");
        self.emit(".L_tl_env_var_value_found:");
        self.emit("    leaq 1(%r14,%r12), %rbx");
        self.emit("    xorq %r12, %r12");
        self.emit(".L_tl_env_var_value_len_loop:");
        self.emit("    cmpb $0, (%rbx,%r12)");
        self.emit("    je .L_tl_env_var_value_len_done");
        self.emit("    incq %r12");
        self.emit("    jmp .L_tl_env_var_value_len_loop");
        self.emit(".L_tl_env_var_value_len_done:");
        self.emit("    movq %r12, %rdi");
        self.emit_call("tl_alloc");
        self.emit("    movq %rax, %r13");
        self.emit("    xorq %rcx, %rcx");
        self.emit(".L_tl_env_var_value_copy_loop:");
        self.emit("    cmpq %r12, %rcx");
        self.emit("    jge .L_tl_env_var_value_fat");
        self.emit("    movzbl (%rbx,%rcx), %edx");
        self.emit("    movb %dl, (%r13,%rcx)");
        self.emit("    incq %rcx");
        self.emit("    jmp .L_tl_env_var_value_copy_loop");
        self.emit(".L_tl_env_var_value_empty:");
        self.emit("    xorq %r12, %r12");
        self.emit("    xorq %r13, %r13");
        self.emit(".L_tl_env_var_value_fat:");
        self.emit("    movq $16, %rdi");
        self.emit_call("tl_alloc");
        self.emit("    movq %r13, 0(%rax)");
        self.emit("    movq %r12, 8(%rax)");
        self.emit("    add $8, %rsp");
        self.emit("    pop %r15");
        self.emit("    pop %r14");
        self.emit("    pop %r13");
        self.emit("    pop %r12");
        self.emit("    pop %rbx");
        self.emit("    pop %rbp");
        self.emit("    ret");
        self.emit("");
    }

    fn generate_windows_env_var_exists_runtime_functions(&mut self) {
        let calling_convention = self.target.calling_convention();
        let arg0 = calling_convention.integer_arg_regs[0];
        let arg1 = calling_convention.integer_arg_regs[1];

        self.emit(&format!("{}:", ENV_VAR_EXISTS_RUNTIME_SYMBOL));
        self.emit("    push %rbp");
        self.emit("    mov %rsp, %rbp");
        self.emit("    push %rbx");
        self.emit("    push %r12");
        self.emit("    push %r13");
        self.emit("    sub $8, %rsp");
        self.emit(&format!("    movq {}, %rbx", arg0));
        self.emit(&format!("    movq {}, %r12", arg1));
        self.emit("    cmpq $0, %r12");
        self.emit("    jl .L_tl_env_var_exists_false");
        self.emit("    movq %r12, %rax");
        self.emit("    addq $1, %rax");
        self.emit("    js .L_tl_env_var_exists_false");
        self.emit(&format!("    movq %rax, {}", arg0));
        self.emit_call("tl_alloc");
        self.emit("    movq %rax, %r13");
        self.emit("    xorq %rcx, %rcx");
        self.emit(".L_tl_env_var_exists_name_copy_loop:");
        self.emit("    cmpq %r12, %rcx");
        self.emit("    jge .L_tl_env_var_exists_name_copy_done");
        self.emit("    movzbl (%rbx,%rcx), %edx");
        self.emit("    movb %dl, (%r13,%rcx)");
        self.emit("    incq %rcx");
        self.emit("    jmp .L_tl_env_var_exists_name_copy_loop");
        self.emit(".L_tl_env_var_exists_name_copy_done:");
        self.emit("    movb $0, (%r13,%r12)");
        self.emit(&format!("    movq %r13, {}", arg0));
        self.emit_call("getenv");
        self.emit("    testq %rax, %rax");
        self.emit("    setne %al");
        self.emit("    movzbq %al, %rax");
        self.emit("    jmp .L_tl_env_var_exists_return");
        self.emit(".L_tl_env_var_exists_false:");
        self.emit("    xorq %rax, %rax");
        self.emit(".L_tl_env_var_exists_return:");
        self.emit("    add $8, %rsp");
        self.emit("    pop %r13");
        self.emit("    pop %r12");
        self.emit("    pop %rbx");
        self.emit("    pop %rbp");
        self.emit("    ret");
        self.emit("");
    }

    fn generate_windows_env_var_value_runtime_functions(&mut self) {
        let calling_convention = self.target.calling_convention();
        let arg0 = calling_convention.integer_arg_regs[0];
        let arg1 = calling_convention.integer_arg_regs[1];

        self.emit(&format!("{}:", ENV_VAR_VALUE_RUNTIME_SYMBOL));
        self.emit("    push %rbp");
        self.emit("    mov %rsp, %rbp");
        self.emit("    push %rbx");
        self.emit("    push %r12");
        self.emit("    push %r13");
        self.emit("    sub $8, %rsp");
        self.emit(&format!("    movq {}, %rbx", arg0));
        self.emit(&format!("    movq {}, %r12", arg1));
        self.emit("    cmpq $0, %r12");
        self.emit("    jl .L_tl_env_var_value_empty");
        self.emit("    movq %r12, %rax");
        self.emit("    addq $1, %rax");
        self.emit("    js .L_tl_env_var_value_empty");
        self.emit(&format!("    movq %rax, {}", arg0));
        self.emit_call("tl_alloc");
        self.emit("    movq %rax, %r13");
        self.emit("    xorq %rcx, %rcx");
        self.emit(".L_tl_env_var_value_name_copy_loop:");
        self.emit("    cmpq %r12, %rcx");
        self.emit("    jge .L_tl_env_var_value_name_copy_done");
        self.emit("    movzbl (%rbx,%rcx), %edx");
        self.emit("    movb %dl, (%r13,%rcx)");
        self.emit("    incq %rcx");
        self.emit("    jmp .L_tl_env_var_value_name_copy_loop");
        self.emit(".L_tl_env_var_value_name_copy_done:");
        self.emit("    movb $0, (%r13,%r12)");
        self.emit(&format!("    movq %r13, {}", arg0));
        self.emit_call("getenv");
        self.emit("    testq %rax, %rax");
        self.emit("    jz .L_tl_env_var_value_empty");
        self.emit("    movq %rax, %rbx");
        self.emit(&format!("    movq %rbx, {}", arg0));
        self.emit_call("strlen");
        self.emit("    movq %rax, %r12");
        self.emit(&format!("    movq %r12, {}", arg0));
        self.emit_call("tl_alloc");
        self.emit("    movq %rax, %r13");
        self.emit("    xorq %rcx, %rcx");
        self.emit(".L_tl_env_var_value_copy_loop:");
        self.emit("    cmpq %r12, %rcx");
        self.emit("    jge .L_tl_env_var_value_fat");
        self.emit("    movzbl (%rbx,%rcx), %edx");
        self.emit("    movb %dl, (%r13,%rcx)");
        self.emit("    incq %rcx");
        self.emit("    jmp .L_tl_env_var_value_copy_loop");
        self.emit(".L_tl_env_var_value_empty:");
        self.emit("    xorq %r12, %r12");
        self.emit("    xorq %r13, %r13");
        self.emit(".L_tl_env_var_value_fat:");
        self.emit(&format!("    movq $16, {}", arg0));
        self.emit_call("tl_alloc");
        self.emit("    movq %r13, 0(%rax)");
        self.emit("    movq %r12, 8(%rax)");
        self.emit("    add $8, %rsp");
        self.emit("    pop %r13");
        self.emit("    pop %r12");
        self.emit("    pop %rbx");
        self.emit("    pop %rbp");
        self.emit("    ret");
        self.emit("");
    }

    fn generate_env_path_separator_runtime_functions(&mut self) {
        let arg0 = self.target.calling_convention().integer_arg_regs[0];
        let separator = if matches!(self.target.os, BackendOs::Windows) {
            b';'
        } else {
            b':'
        };

        self.emit(&format!("{}:", ENV_PATH_SEPARATOR_RUNTIME_SYMBOL));
        self.emit("    push %rbp");
        self.emit("    mov %rsp, %rbp");
        self.emit("    push %r12");
        self.emit("    sub $8, %rsp");
        self.emit(&format!("    movq $1, {}", arg0));
        self.emit_call("tl_alloc");
        self.emit("    movq %rax, %r12");
        self.emit(&format!("    movb ${}, (%r12)", separator));
        self.emit(&format!("    movq $16, {}", arg0));
        self.emit_call("tl_alloc");
        self.emit("    movq %r12, 0(%rax)");
        self.emit("    movq $1, 8(%rax)");
        self.emit("    add $8, %rsp");
        self.emit("    pop %r12");
        self.emit("    pop %rbp");
        self.emit("    ret");
        self.emit("");
    }

    fn generate_read_stdin_line_runtime_functions(&mut self) {
        if self.target.runtime_policy().emits_windows_runtime_helpers {
            self.generate_windows_read_stdin_line_runtime_functions();
            return;
        }

        self.emit(&format!("{}:", READ_STDIN_LINE_RUNTIME_SYMBOL));
        self.emit("    push %rbp");
        self.emit("    mov %rsp, %rbp");
        self.emit("    push %rbx");
        self.emit("    push %r12");
        self.emit("    push %r13");
        self.emit("    push %r14");
        self.emit("    sub $16, %rsp");
        self.emit("    movq $64, %r13");
        self.emit("    movq %r13, %rdi");
        self.emit("    call tl_alloc");
        self.emit("    movq %rax, %rbx");
        self.emit("    xorq %r12, %r12");
        self.emit(".L_tl_read_stdin_line_loop:");
        self.emit("    xorq %rax, %rax");
        self.emit("    xorq %rdi, %rdi");
        self.emit("    leaq -40(%rbp), %rsi");
        self.emit("    movq $1, %rdx");
        self.emit("    syscall");
        self.emit("    testq %rax, %rax");
        self.emit("    js .L_tl_read_stdin_line_error");
        self.emit("    jz .L_tl_read_stdin_line_eof");
        self.emit("    cmpb $10, -40(%rbp)");
        self.emit("    je .L_tl_read_stdin_line_done");
        self.emit("    cmpq %r13, %r12");
        self.emit("    jb .L_tl_read_stdin_line_store");
        self.emit("    movq %r13, %rdi");
        self.emit("    addq %r13, %rdi");
        self.emit("    js .L_tl_read_stdin_line_error");
        self.emit("    movq %rdi, %r14");
        self.emit("    call tl_alloc");
        self.emit("    xorq %rcx, %rcx");
        self.emit(".L_tl_read_stdin_line_copy_loop:");
        self.emit("    cmpq %r12, %rcx");
        self.emit("    jge .L_tl_read_stdin_line_copy_done");
        self.emit("    movzbl (%rbx,%rcx), %edx");
        self.emit("    movb %dl, (%rax,%rcx)");
        self.emit("    incq %rcx");
        self.emit("    jmp .L_tl_read_stdin_line_copy_loop");
        self.emit(".L_tl_read_stdin_line_copy_done:");
        self.emit("    movq %rax, %rbx");
        self.emit("    movq %r14, %r13");
        self.emit(".L_tl_read_stdin_line_store:");
        self.emit("    movzbl -40(%rbp), %eax");
        self.emit("    movb %al, (%rbx,%r12)");
        self.emit("    incq %r12");
        self.emit("    jmp .L_tl_read_stdin_line_loop");
        self.emit(".L_tl_read_stdin_line_eof:");
        self.emit("    movq $1, .L_tl_stdin_eof_flag(%rip)");
        self.emit("    jmp .L_tl_read_stdin_line_return");
        self.emit(".L_tl_read_stdin_line_done:");
        self.emit("    movq $0, .L_tl_stdin_eof_flag(%rip)");
        self.emit(".L_tl_read_stdin_line_return:");
        self.emit("    movq $16, %rdi");
        self.emit("    call tl_alloc");
        self.emit("    movq %rbx, 0(%rax)");
        self.emit("    movq %r12, 8(%rax)");
        self.emit("    add $16, %rsp");
        self.emit("    pop %r14");
        self.emit("    pop %r13");
        self.emit("    pop %r12");
        self.emit("    pop %rbx");
        self.emit("    pop %rbp");
        self.emit("    ret");
        self.emit(".L_tl_read_stdin_line_error:");
        self.emit("    leaq .L_tl_stdin_error_msg(%rip), %rdi");
        self.emit("    movq $.L_tl_stdin_error_msg_len, %rsi");
        self.emit(&format!("    call {}", ABORT_RUNTIME_SYMBOL));
        self.emit("");
    }

    fn generate_read_stdin_bytes_runtime_functions(&mut self) {
        if self.target.runtime_policy().emits_windows_runtime_helpers {
            self.generate_windows_read_stdin_bytes_runtime_functions();
            return;
        }

        self.emit(&format!("{}:", READ_STDIN_BYTES_RUNTIME_SYMBOL));
        self.emit("    push %rbp");
        self.emit("    mov %rsp, %rbp");
        self.emit("    push %rbx");
        self.emit("    push %r12");
        self.emit("    push %r13");
        self.emit("    sub $8, %rsp");
        self.emit("    movq %rdi, %r12");
        self.emit("    cmpq $0, %r12");
        self.emit("    jl .L_tl_read_stdin_bytes_error");
        self.emit("    movq %r12, %rdi");
        self.emit("    cmpq $0, %rdi");
        self.emit("    jg .L_tl_read_stdin_bytes_alloc_ready");
        self.emit("    movq $1, %rdi");
        self.emit(".L_tl_read_stdin_bytes_alloc_ready:");
        self.emit("    call tl_alloc");
        self.emit("    movq %rax, %rbx");
        self.emit("    xorq %r13, %r13");
        self.emit("    testq %r12, %r12");
        self.emit("    jz .L_tl_read_stdin_bytes_return");
        self.emit(".L_tl_read_stdin_bytes_loop:");
        self.emit("    cmpq %r12, %r13");
        self.emit("    jge .L_tl_read_stdin_bytes_full");
        self.emit("    movq %r12, %rdx");
        self.emit("    subq %r13, %rdx");
        self.emit("    xorq %rax, %rax");
        self.emit("    xorq %rdi, %rdi");
        self.emit("    leaq (%rbx,%r13), %rsi");
        self.emit("    syscall");
        self.emit("    testq %rax, %rax");
        self.emit("    js .L_tl_read_stdin_bytes_error");
        self.emit("    jz .L_tl_read_stdin_bytes_eof");
        self.emit("    addq %rax, %r13");
        self.emit("    jmp .L_tl_read_stdin_bytes_loop");
        self.emit(".L_tl_read_stdin_bytes_full:");
        self.emit("    movq $0, .L_tl_stdin_eof_flag(%rip)");
        self.emit("    jmp .L_tl_read_stdin_bytes_return");
        self.emit(".L_tl_read_stdin_bytes_eof:");
        self.emit("    movq $1, .L_tl_stdin_eof_flag(%rip)");
        self.emit(".L_tl_read_stdin_bytes_return:");
        self.emit("    movq $16, %rdi");
        self.emit("    call tl_alloc");
        self.emit("    movq %rbx, 0(%rax)");
        self.emit("    movq %r13, 8(%rax)");
        self.emit("    add $8, %rsp");
        self.emit("    pop %r13");
        self.emit("    pop %r12");
        self.emit("    pop %rbx");
        self.emit("    pop %rbp");
        self.emit("    ret");
        self.emit(".L_tl_read_stdin_bytes_error:");
        self.emit("    leaq .L_tl_stdin_error_msg(%rip), %rdi");
        self.emit("    movq $.L_tl_stdin_error_msg_len, %rsi");
        self.emit(&format!("    call {}", ABORT_RUNTIME_SYMBOL));
        self.emit("");
    }

    fn generate_stdin_eof_runtime_functions(&mut self) {
        self.emit(&format!("{}:", STDIN_EOF_RUNTIME_SYMBOL));
        self.emit("    movq .L_tl_stdin_eof_flag(%rip), %rax");
        self.emit("    ret");
        self.emit("");
    }

    fn generate_flush_stdout_runtime_functions(&mut self) {
        if self.target.runtime_policy().emits_windows_runtime_helpers {
            self.generate_windows_flush_stdout_runtime_functions();
            return;
        }

        self.emit(&format!("{}:", FLUSH_STDOUT_RUNTIME_SYMBOL));
        self.emit("    ret");
        self.emit("");
    }

    fn generate_windows_read_stdin_line_runtime_functions(&mut self) {
        self.emit(&format!("{}:", READ_STDIN_LINE_RUNTIME_SYMBOL));
        self.emit("    push %rbp");
        self.emit("    mov %rsp, %rbp");
        self.emit("    push %rbx");
        self.emit("    push %r12");
        self.emit("    push %r13");
        self.emit("    push %r14");
        self.emit("    sub $16, %rsp");
        self.emit("    movq $64, %r13");
        self.emit("    movq %r13, %rcx");
        self.emit_call("tl_alloc");
        self.emit("    movq %rax, %rbx");
        self.emit("    xorq %r12, %r12");
        self.emit(".L_tl_read_stdin_line_loop:");
        self.emit("    xorq %rcx, %rcx");
        self.emit("    leaq -40(%rbp), %rdx");
        self.emit("    movq $1, %r8");
        self.emit_call("_read");
        self.emit("    movslq %eax, %rax");
        self.emit("    testq %rax, %rax");
        self.emit("    js .L_tl_read_stdin_line_error");
        self.emit("    jz .L_tl_read_stdin_line_eof");
        self.emit("    cmpb $10, -40(%rbp)");
        self.emit("    je .L_tl_read_stdin_line_done");
        self.emit("    cmpq %r13, %r12");
        self.emit("    jb .L_tl_read_stdin_line_store");
        self.emit("    movq %r13, %rcx");
        self.emit("    addq %r13, %rcx");
        self.emit("    js .L_tl_read_stdin_line_error");
        self.emit("    movq %rcx, %r14");
        self.emit_call("tl_alloc");
        self.emit("    xorq %r10, %r10");
        self.emit(".L_tl_read_stdin_line_copy_loop:");
        self.emit("    cmpq %r12, %r10");
        self.emit("    jge .L_tl_read_stdin_line_copy_done");
        self.emit("    movzbl (%rbx,%r10), %edx");
        self.emit("    movb %dl, (%rax,%r10)");
        self.emit("    incq %r10");
        self.emit("    jmp .L_tl_read_stdin_line_copy_loop");
        self.emit(".L_tl_read_stdin_line_copy_done:");
        self.emit("    movq %rax, %rbx");
        self.emit("    movq %r14, %r13");
        self.emit(".L_tl_read_stdin_line_store:");
        self.emit("    movzbl -40(%rbp), %eax");
        self.emit("    movb %al, (%rbx,%r12)");
        self.emit("    incq %r12");
        self.emit("    jmp .L_tl_read_stdin_line_loop");
        self.emit(".L_tl_read_stdin_line_eof:");
        self.emit("    movq $1, .L_tl_stdin_eof_flag(%rip)");
        self.emit("    jmp .L_tl_read_stdin_line_return");
        self.emit(".L_tl_read_stdin_line_done:");
        self.emit("    movq $0, .L_tl_stdin_eof_flag(%rip)");
        self.emit(".L_tl_read_stdin_line_return:");
        self.emit("    movq $16, %rcx");
        self.emit_call("tl_alloc");
        self.emit("    movq %rbx, 0(%rax)");
        self.emit("    movq %r12, 8(%rax)");
        self.emit("    add $16, %rsp");
        self.emit("    pop %r14");
        self.emit("    pop %r13");
        self.emit("    pop %r12");
        self.emit("    pop %rbx");
        self.emit("    pop %rbp");
        self.emit("    ret");
        self.emit(".L_tl_read_stdin_line_error:");
        self.emit("    leaq .L_tl_stdin_error_msg(%rip), %rcx");
        self.emit("    movq $.L_tl_stdin_error_msg_len, %rdx");
        self.emit_call(ABORT_RUNTIME_SYMBOL);
        self.emit("");
    }

    fn generate_windows_read_stdin_bytes_runtime_functions(&mut self) {
        self.emit(&format!("{}:", READ_STDIN_BYTES_RUNTIME_SYMBOL));
        self.emit("    push %rbp");
        self.emit("    mov %rsp, %rbp");
        self.emit("    push %rbx");
        self.emit("    push %r12");
        self.emit("    push %r13");
        self.emit("    sub $8, %rsp");
        self.emit("    movq %rcx, %r12");
        self.emit("    cmpq $0, %r12");
        self.emit("    jl .L_tl_read_stdin_bytes_error");
        self.emit("    movq %r12, %rcx");
        self.emit("    cmpq $0, %rcx");
        self.emit("    jg .L_tl_read_stdin_bytes_alloc_ready");
        self.emit("    movq $1, %rcx");
        self.emit(".L_tl_read_stdin_bytes_alloc_ready:");
        self.emit_call("tl_alloc");
        self.emit("    movq %rax, %rbx");
        self.emit("    xorq %r13, %r13");
        self.emit("    testq %r12, %r12");
        self.emit("    jz .L_tl_read_stdin_bytes_return");
        self.emit(".L_tl_read_stdin_bytes_loop:");
        self.emit("    cmpq %r12, %r13");
        self.emit("    jge .L_tl_read_stdin_bytes_full");
        self.emit("    xorq %rcx, %rcx");
        self.emit("    leaq (%rbx,%r13), %rdx");
        self.emit("    movq %r12, %r8");
        self.emit("    subq %r13, %r8");
        self.emit_call("_read");
        self.emit("    movslq %eax, %rax");
        self.emit("    testq %rax, %rax");
        self.emit("    js .L_tl_read_stdin_bytes_error");
        self.emit("    jz .L_tl_read_stdin_bytes_eof");
        self.emit("    addq %rax, %r13");
        self.emit("    jmp .L_tl_read_stdin_bytes_loop");
        self.emit(".L_tl_read_stdin_bytes_full:");
        self.emit("    movq $0, .L_tl_stdin_eof_flag(%rip)");
        self.emit("    jmp .L_tl_read_stdin_bytes_return");
        self.emit(".L_tl_read_stdin_bytes_eof:");
        self.emit("    movq $1, .L_tl_stdin_eof_flag(%rip)");
        self.emit(".L_tl_read_stdin_bytes_return:");
        self.emit("    movq $16, %rcx");
        self.emit_call("tl_alloc");
        self.emit("    movq %rbx, 0(%rax)");
        self.emit("    movq %r13, 8(%rax)");
        self.emit("    add $8, %rsp");
        self.emit("    pop %r13");
        self.emit("    pop %r12");
        self.emit("    pop %rbx");
        self.emit("    pop %rbp");
        self.emit("    ret");
        self.emit(".L_tl_read_stdin_bytes_error:");
        self.emit("    leaq .L_tl_stdin_error_msg(%rip), %rcx");
        self.emit("    movq $.L_tl_stdin_error_msg_len, %rdx");
        self.emit_call(ABORT_RUNTIME_SYMBOL);
        self.emit("");
    }

    fn generate_windows_flush_stdout_runtime_functions(&mut self) {
        self.emit(&format!("{}:", FLUSH_STDOUT_RUNTIME_SYMBOL));
        self.emit("    push %rbp");
        self.emit("    mov %rsp, %rbp");
        self.emit("    xorq %rcx, %rcx");
        self.emit_call("fflush");
        self.emit("    testl %eax, %eax");
        self.emit("    jne .L_tl_flush_stdout_error");
        self.emit("    mov %rbp, %rsp");
        self.emit("    pop %rbp");
        self.emit("    ret");
        self.emit(".L_tl_flush_stdout_error:");
        self.emit("    leaq .L_tl_flush_stdout_error_msg(%rip), %rcx");
        self.emit("    movq $.L_tl_flush_stdout_error_msg_len, %rdx");
        self.emit_call(ABORT_RUNTIME_SYMBOL);
        self.emit("");
    }

    /// Emit the self-contained string-equality helper
    /// `tl_string_eq(a_ptr, a_len, b_ptr, b_len) -> i64 (0/1)`.
    ///
    /// ABI (System V): `a_ptr` in `%rdi`, `a_len` in `%rsi`, `b_ptr` in `%rdx`,
    /// `b_len` in `%rcx`; the 0/1 result leaves in `%rax`. The routine first
    /// compares the two lengths — unequal lengths can never be equal, so it
    /// returns 0 immediately. Otherwise it byte-compares the two buffers in a
    /// loop, returning 0 on the first mismatch and 1 once `a_len` bytes match.
    /// It is pure: no `syscall`, no libc, no memory writes (it only reads the
    /// operand buffers), so it is safe to emit unconditionally when referenced.
    fn generate_string_eq_runtime_functions(&mut self) {
        if self.target.runtime_policy().emits_windows_runtime_helpers {
            self.generate_windows_string_eq_runtime_functions();
            return;
        }

        self.emit("    .globl tl_string_eq");
        self.emit("tl_string_eq:");
        // Lengths differ -> not equal.
        self.emit("    cmpq %rcx, %rsi");
        self.emit("    jne .L_tl_string_eq_false");
        // Equal lengths. %rsi = remaining byte count (the common length).
        // Walk both buffers in lockstep comparing one byte at a time.
        self.emit(".L_tl_string_eq_loop:");
        // No bytes left to compare -> the strings are equal.
        self.emit("    testq %rsi, %rsi");
        self.emit("    jz .L_tl_string_eq_true");
        // Load a byte from each buffer (zero-extended) and compare.
        self.emit("    movzbl (%rdi), %eax");
        self.emit("    movzbl (%rdx), %r8d");
        self.emit("    cmpb %r8b, %al");
        self.emit("    jne .L_tl_string_eq_false");
        // Advance both cursors, decrement the remaining count, repeat.
        self.emit("    incq %rdi");
        self.emit("    incq %rdx");
        self.emit("    decq %rsi");
        self.emit("    jmp .L_tl_string_eq_loop");
        self.emit(".L_tl_string_eq_true:");
        self.emit("    movq $1, %rax");
        self.emit("    ret");
        self.emit(".L_tl_string_eq_false:");
        self.emit("    xorq %rax, %rax");
        self.emit("    ret");
        self.emit("");
    }

    fn generate_windows_string_eq_runtime_functions(&mut self) {
        self.emit("    .globl tl_string_eq");
        self.emit("tl_string_eq:");
        // Windows x64: a_ptr=%rcx, a_len=%rdx, b_ptr=%r8, b_len=%r9.
        self.emit("    cmpq %r9, %rdx");
        self.emit("    jne .L_tl_string_eq_false");
        self.emit(".L_tl_string_eq_loop:");
        self.emit("    testq %rdx, %rdx");
        self.emit("    jz .L_tl_string_eq_true");
        self.emit("    movzbl (%rcx), %eax");
        self.emit("    movzbl (%r8), %r10d");
        self.emit("    cmpb %r10b, %al");
        self.emit("    jne .L_tl_string_eq_false");
        self.emit("    incq %rcx");
        self.emit("    incq %r8");
        self.emit("    decq %rdx");
        self.emit("    jmp .L_tl_string_eq_loop");
        self.emit(".L_tl_string_eq_true:");
        self.emit("    movq $1, %rax");
        self.emit("    ret");
        self.emit(".L_tl_string_eq_false:");
        self.emit("    xorq %rax, %rax");
        self.emit("    ret");
        self.emit("");
    }

    /// Emit the self-contained decimal-parse helper
    /// `tl_string_to_int(ptr, len) -> i64`.
    ///
    /// ABI (System V): `ptr` in `%rdi`, `len` in `%rsi`; the parsed i64 leaves
    /// in `%rax`. The routine skips a single optional leading `-` (recording the
    /// sign), then accumulates `acc = acc*10 + (byte - '0')` over the remaining
    /// bytes via an `imul`-by-10 loop (the inverse of `tl_print_i64`'s
    /// divide-by-10 digit loop) and negates the accumulator if a sign was seen.
    /// An empty string yields 0. Non-digit bytes and overflow are NOT validated
    /// (deferred): a stray byte contributes `(byte - 48)` to the running total,
    /// matching the documented best-effort decimal parse. It is pure (only reads
    /// the operand buffer; no `syscall`, no libc, no writes), so it is safe to
    /// emit unconditionally when referenced.
    fn generate_string_to_int_runtime_functions(&mut self) {
        if self.target.runtime_policy().emits_windows_runtime_helpers {
            self.generate_windows_string_to_int_runtime_functions();
            return;
        }

        self.emit("    .globl tl_string_to_int");
        self.emit("tl_string_to_int:");
        // acc = 0 (%rax accumulates the result), neg = 0 (%r8 records the sign).
        self.emit("    xorq %rax, %rax");
        self.emit("    xorq %r8, %r8");
        // Empty string -> 0.
        self.emit("    testq %rsi, %rsi");
        self.emit("    jz .L_tl_string_to_int_done");
        // Optional leading '-' (45): set neg, advance the cursor, drop one byte.
        self.emit("    movzbl (%rdi), %ecx");
        self.emit("    cmpb $45, %cl");
        self.emit("    jne .L_tl_string_to_int_loop");
        self.emit("    movq $1, %r8");
        self.emit("    incq %rdi");
        self.emit("    decq %rsi");
        self.emit(".L_tl_string_to_int_loop:");
        // No bytes left -> apply the sign and return.
        self.emit("    testq %rsi, %rsi");
        self.emit("    jz .L_tl_string_to_int_apply_sign");
        // acc = acc*10 + (byte - '0').
        self.emit("    imulq $10, %rax, %rax");
        self.emit("    movzbl (%rdi), %ecx");
        self.emit("    subq $48, %rcx");
        self.emit("    addq %rcx, %rax");
        // Advance the cursor, decrement the remaining count, repeat.
        self.emit("    incq %rdi");
        self.emit("    decq %rsi");
        self.emit("    jmp .L_tl_string_to_int_loop");
        self.emit(".L_tl_string_to_int_apply_sign:");
        self.emit("    testq %r8, %r8");
        self.emit("    jz .L_tl_string_to_int_done");
        self.emit("    negq %rax");
        self.emit(".L_tl_string_to_int_done:");
        self.emit("    ret");
        self.emit("");
    }

    fn generate_windows_string_to_int_runtime_functions(&mut self) {
        self.emit("    .globl tl_string_to_int");
        self.emit("tl_string_to_int:");
        // Windows x64: ptr=%rcx, len=%rdx. Keep the cursor in caller-saved %r10.
        self.emit("    movq %rcx, %r10");
        self.emit("    xorq %rax, %rax");
        self.emit("    xorq %r8, %r8");
        self.emit("    testq %rdx, %rdx");
        self.emit("    jz .L_tl_string_to_int_done");
        self.emit("    movzbl (%r10), %ecx");
        self.emit("    cmpb $45, %cl");
        self.emit("    jne .L_tl_string_to_int_loop");
        self.emit("    movq $1, %r8");
        self.emit("    incq %r10");
        self.emit("    decq %rdx");
        self.emit(".L_tl_string_to_int_loop:");
        self.emit("    testq %rdx, %rdx");
        self.emit("    jz .L_tl_string_to_int_apply_sign");
        self.emit("    imulq $10, %rax, %rax");
        self.emit("    movzbl (%r10), %ecx");
        self.emit("    subq $48, %rcx");
        self.emit("    addq %rcx, %rax");
        self.emit("    incq %r10");
        self.emit("    decq %rdx");
        self.emit("    jmp .L_tl_string_to_int_loop");
        self.emit(".L_tl_string_to_int_apply_sign:");
        self.emit("    testq %r8, %r8");
        self.emit("    jz .L_tl_string_to_int_done");
        self.emit("    negq %rax");
        self.emit(".L_tl_string_to_int_done:");
        self.emit("    ret");
        self.emit("");
    }

    /// Emit the self-contained integer-to-string helper
    /// `tl_int_to_string(n) -> ptr`.
    ///
    /// ABI (System V): the i64 `n` arrives in `%rdi`; the returned pointer (to a
    /// 16-byte heap fat `{ ptr, len }` String value) leaves in `%rax`. The
    /// routine formats `n` in decimal using the same divide-by-10 digit loop as
    /// `tl_print_i64` (handling zero and a leading `-` for negatives), but writes
    /// the digits into a stack scratch buffer. It then heap-allocates — via the
    /// bump allocator `tl_alloc` — a data buffer of exactly `len` bytes, copies
    /// the digits in, allocates the 16-byte fat value, stores the data pointer at
    /// offset 0 and the length at offset 8, and returns the fat pointer. Both
    /// allocations are on the heap so the returned String outlives the caller's
    /// frame (matching the heap-promotion rule for returned aggregates, #85).
    /// `n`'s digits/length and the data pointer are kept in callee-saved
    /// registers (`%rbx`/`%r12`/`%r13`) across the `tl_alloc` calls.
    fn generate_int_to_string_runtime_functions(&mut self) {
        let arg0 = self.target.calling_convention().integer_arg_regs[0];

        self.emit("    .globl tl_int_to_string");
        self.emit("tl_int_to_string:");
        self.emit("    push %rbp");
        self.emit("    mov %rsp, %rbp");
        // Preserve the callee-saved registers we use to carry state across the
        // two `tl_alloc` calls, then reserve a 72-byte scratch frame (keeps the
        // stack 16-byte aligned at the `call` sites; 64 bytes hold the digits —
        // far more than the 20-digit + sign maximum of an i64).
        self.emit("    push %rbx");
        self.emit("    push %r12");
        self.emit("    push %r13");
        self.emit("    sub $72, %rsp");
        // Digit generation (mirrors tl_print_i64). %r10 = descending write
        // cursor, starting one past the top of the scratch region; %rcx = digit
        // count. %rax holds the working magnitude.
        self.emit(&format!("    movq {}, %rax", arg0));
        self.emit("    leaq 72(%rsp), %r10");
        self.emit("    movq $0, %rcx");
        self.emit("    cmpq $0, %rax");
        self.emit("    jne .L_tl_int_to_string_nonzero");
        // Zero: a single '0' digit.
        self.emit("    decq %r10");
        self.emit("    movb $48, (%r10)");
        self.emit("    incq %rcx");
        self.emit("    jmp .L_tl_int_to_string_digits_done");
        self.emit(".L_tl_int_to_string_nonzero:");
        // %r8 = sign flag (1 if negative). Take the absolute value.
        self.emit("    movq $0, %r8");
        self.emit("    cmpq $0, %rax");
        self.emit("    jge .L_tl_int_to_string_abs_ready");
        self.emit("    negq %rax");
        self.emit("    movq $1, %r8");
        self.emit(".L_tl_int_to_string_abs_ready:");
        self.emit("    movq $10, %r9");
        self.emit(".L_tl_int_to_string_digit_loop:");
        self.emit("    xorq %rdx, %rdx");
        self.emit("    divq %r9");
        self.emit("    addb $48, %dl");
        self.emit("    decq %r10");
        self.emit("    movb %dl, (%r10)");
        self.emit("    incq %rcx");
        self.emit("    testq %rax, %rax");
        self.emit("    jne .L_tl_int_to_string_digit_loop");
        // Prepend the '-' sign for negatives.
        self.emit("    testq %r8, %r8");
        self.emit("    jz .L_tl_int_to_string_digits_done");
        self.emit("    decq %r10");
        self.emit("    movb $45, (%r10)");
        self.emit("    incq %rcx");
        self.emit(".L_tl_int_to_string_digits_done:");
        // %rbx = pointer to the first digit; %r12 = byte length. Both survive the
        // upcoming `tl_alloc` calls (callee-saved).
        self.emit("    movq %r10, %rbx");
        self.emit("    movq %rcx, %r12");
        // data = tl_alloc(len). The returned heap pointer is saved in %r13.
        self.emit(&format!("    movq %r12, {}", arg0));
        self.emit_call("tl_alloc");
        self.emit("    movq %rax, %r13");
        // Copy the `len` digit bytes from the scratch buffer (%rbx) into the heap
        // data buffer (%r13), front to back.
        self.emit("    movq $0, %rcx");
        self.emit(".L_tl_int_to_string_copy_loop:");
        self.emit("    cmpq %r12, %rcx");
        self.emit("    jge .L_tl_int_to_string_copy_done");
        self.emit("    movzbl (%rbx,%rcx), %edx");
        self.emit("    movb %dl, (%r13,%rcx)");
        self.emit("    incq %rcx");
        self.emit("    jmp .L_tl_int_to_string_copy_loop");
        self.emit(".L_tl_int_to_string_copy_done:");
        // fat = tl_alloc(16); store { data_ptr (offset 0), len (offset 8) }.
        self.emit(&format!("    movq $16, {}", arg0));
        self.emit_call("tl_alloc");
        self.emit("    movq %r13, 0(%rax)");
        self.emit("    movq %r12, 8(%rax)");
        // %rax already holds the fat pointer — the return value.
        self.emit("    add $72, %rsp");
        self.emit("    pop %r13");
        self.emit("    pop %r12");
        self.emit("    pop %rbx");
        self.emit("    pop %rbp");
        self.emit("    ret");
        self.emit("");
    }

    /// Emit the self-contained byte-slice helper
    /// `tl_substring(src_ptr, start, slice_len) -> {ptr, len}`.
    ///
    /// ABI (System V): `src_ptr` in `%rdi`, `start` in `%rsi`, `slice_len` in
    /// `%rdx`; the returned heap fat-value pointer leaves in `%rax`. The caller
    /// (the lowerer) has already UNSIGNED-bounds-checked the range against the
    /// source length, so this routine trusts `[start, start+slice_len)` to lie
    /// within the source buffer and performs no checks of its own. It mirrors
    /// `tl_int_to_string`'s two-`tl_alloc` shape: allocate a `slice_len`-byte
    /// heap buffer, copy the bytes from `src_ptr + start` front-to-back, then
    /// allocate the 16-byte fat value and store `{ data_ptr (offset 0), len
    /// (offset 8) }`. A `slice_len` of 0 still allocates (the bump allocator
    /// returns a valid pointer) and copies nothing, yielding a valid empty
    /// String. The slice length and copy source survive the two `tl_alloc` calls
    /// in callee-saved registers (`%rbx`/`%r12`/`%r13`). It heap-allocates so the
    /// result outlives the caller's frame; it is safe to emit when referenced.
    fn generate_substring_runtime_functions(&mut self) {
        let calling_convention = self.target.calling_convention();
        let arg0 = calling_convention.integer_arg_regs[0];
        let arg1 = calling_convention.integer_arg_regs[1];
        let arg2 = calling_convention.integer_arg_regs[2];

        self.emit("    .globl tl_substring");
        self.emit("tl_substring:");
        self.emit("    push %rbp");
        self.emit("    mov %rsp, %rbp");
        // Preserve the callee-saved registers carrying state across the two
        // `tl_alloc` calls. The extra push keeps %rsp 16-byte aligned at the
        // `call` sites (3 pushes after the saved %rbp -> even total).
        self.emit("    push %rbx");
        self.emit("    push %r12");
        self.emit("    push %r13");
        self.emit("    sub $8, %rsp");
        // %rbx = copy source = src_ptr + start; %r12 = slice_len. Both survive
        // the upcoming `tl_alloc` calls (callee-saved).
        self.emit(&format!("    movq {}, %rbx", arg0));
        self.emit(&format!("    addq {}, %rbx", arg1));
        self.emit(&format!("    movq {}, %r12", arg2));
        // data = tl_alloc(slice_len). The returned heap pointer is saved in %r13.
        self.emit(&format!("    movq %r12, {}", arg0));
        self.emit_call("tl_alloc");
        self.emit("    movq %rax, %r13");
        // Copy the `slice_len` bytes from the source (%rbx) into the heap data
        // buffer (%r13), front to back.
        self.emit("    movq $0, %rcx");
        self.emit(".L_tl_substring_copy_loop:");
        self.emit("    cmpq %r12, %rcx");
        self.emit("    jge .L_tl_substring_copy_done");
        self.emit("    movzbl (%rbx,%rcx), %edx");
        self.emit("    movb %dl, (%r13,%rcx)");
        self.emit("    incq %rcx");
        self.emit("    jmp .L_tl_substring_copy_loop");
        self.emit(".L_tl_substring_copy_done:");
        // fat = tl_alloc(16); store { data_ptr (offset 0), len (offset 8) }.
        self.emit(&format!("    movq $16, {}", arg0));
        self.emit_call("tl_alloc");
        self.emit("    movq %r13, 0(%rax)");
        self.emit("    movq %r12, 8(%rax)");
        // %rax already holds the fat pointer — the return value.
        self.emit("    add $8, %rsp");
        self.emit("    pop %r13");
        self.emit("    pop %r12");
        self.emit("    pop %rbx");
        self.emit("    pop %rbp");
        self.emit("    ret");
        self.emit("");
    }

    /// Emit the self-contained byte-append helper
    /// `tl_string_concat(a_ptr, a_len, b_ptr, b_len) -> {ptr, len}`.
    ///
    /// ABI (System V): `a_ptr` in `%rdi`, `a_len` in `%rsi`, `b_ptr` in `%rdx`,
    /// `b_len` in `%rcx`; the returned heap fat-value pointer leaves in `%rax`. It
    /// mirrors `tl_substring`'s two-`tl_alloc` shape: allocate a `a_len + b_len`
    /// byte heap buffer, copy `a`'s bytes then `b`'s bytes into it front-to-back,
    /// then allocate the 16-byte fat value and store `{ data_ptr (offset 0), len
    /// (offset 8) }`. Two empty operands still allocate (the bump allocator
    /// returns a valid pointer) and copy nothing, yielding a valid empty String.
    /// The four arguments and the data pointer survive the two `tl_alloc` calls in
    /// callee-saved registers (`%rbx`/`%r12`/`%r13`/`%r14`/`%r15`); the total
    /// length is recomputed as `%r12 + %r14` when storing the fat value. It
    /// heap-allocates so the result outlives the caller's frame; it is safe to
    /// emit when referenced.
    fn generate_string_concat_runtime_functions(&mut self) {
        let calling_convention = self.target.calling_convention();
        let arg0 = calling_convention.integer_arg_regs[0];
        let arg1 = calling_convention.integer_arg_regs[1];
        let arg2 = calling_convention.integer_arg_regs[2];
        let arg3 = calling_convention.integer_arg_regs[3];

        self.emit("    .globl tl_string_concat");
        self.emit("tl_string_concat:");
        self.emit("    push %rbp");
        self.emit("    mov %rsp, %rbp");
        // Preserve the callee-saved registers carrying the operands and the data
        // pointer across the two `tl_alloc` calls. Five pushes + the `sub $8`
        // padding keep %rsp 16-byte aligned at the `call` sites (after the saved
        // %rbp: 5 pushes -> %rsp at 16n-40; the `sub $8` brings it to 16n-48).
        self.emit("    push %rbx");
        self.emit("    push %r12");
        self.emit("    push %r13");
        self.emit("    push %r14");
        self.emit("    push %r15");
        self.emit("    sub $8, %rsp");
        // Stash the operands in callee-saved registers: %rbx = a_ptr, %r12 =
        // a_len, %r13 = b_ptr, %r14 = b_len. All survive the upcoming `tl_alloc`
        // calls.
        self.emit(&format!("    movq {}, %rbx", arg0));
        self.emit(&format!("    movq {}, %r12", arg1));
        self.emit(&format!("    movq {}, %r13", arg2));
        self.emit(&format!("    movq {}, %r14", arg3));
        // data = tl_alloc(a_len + b_len). The returned heap pointer is saved in
        // %r15.
        self.emit(&format!("    movq %r12, {}", arg0));
        self.emit(&format!("    addq %r14, {}", arg0));
        self.emit_call("tl_alloc");
        self.emit("    movq %rax, %r15");
        // Copy a_len bytes from a_ptr (%rbx) into the heap data buffer (%r15) at
        // offset 0, front to back.
        self.emit("    movq $0, %rcx");
        self.emit(".L_tl_string_concat_copy_a:");
        self.emit("    cmpq %r12, %rcx");
        self.emit("    jge .L_tl_string_concat_copy_a_done");
        self.emit("    movzbl (%rbx,%rcx), %edx");
        self.emit("    movb %dl, (%r15,%rcx)");
        self.emit("    incq %rcx");
        self.emit("    jmp .L_tl_string_concat_copy_a");
        self.emit(".L_tl_string_concat_copy_a_done:");
        // Copy b_len bytes from b_ptr (%r13) into the data buffer starting at
        // offset a_len. %rcx indexes b; the destination offset is a_len + %rcx.
        self.emit("    movq $0, %rcx");
        self.emit(".L_tl_string_concat_copy_b:");
        self.emit("    cmpq %r14, %rcx");
        self.emit("    jge .L_tl_string_concat_copy_b_done");
        self.emit("    movzbl (%r13,%rcx), %edx");
        // dest = %r15 + a_len + %rcx; compute the destination index in %rax.
        self.emit("    movq %r12, %rax");
        self.emit("    addq %rcx, %rax");
        self.emit("    movb %dl, (%r15,%rax)");
        self.emit("    incq %rcx");
        self.emit("    jmp .L_tl_string_concat_copy_b");
        self.emit(".L_tl_string_concat_copy_b_done:");
        // fat = tl_alloc(16); store { data_ptr (offset 0), total_len (offset 8) }.
        // total_len = a_len + b_len, recomputed from the preserved %r12/%r14.
        self.emit(&format!("    movq $16, {}", arg0));
        self.emit_call("tl_alloc");
        self.emit("    movq %r15, 0(%rax)");
        self.emit("    movq %r12, %rdx");
        self.emit("    addq %r14, %rdx");
        self.emit("    movq %rdx, 8(%rax)");
        // %rax already holds the fat pointer — the return value.
        self.emit("    add $8, %rsp");
        self.emit("    pop %r15");
        self.emit("    pop %r14");
        self.emit("    pop %r13");
        self.emit("    pop %r12");
        self.emit("    pop %rbx");
        self.emit("    pop %rbp");
        self.emit("    ret");
        self.emit("");
    }

    fn generate_globals(&mut self, globals: &[(String, Type, Option<Value>)]) {
        if globals.is_empty() {
            return;
        }

        let mut data_emitted = false;
        for (name, ty, init) in globals {
            let symbol = Self::mangle_name(name);
            self.emit(&format!("    .globl {}", symbol));
            if init.is_some() {
                if !data_emitted {
                    self.emit("    .data");
                    data_emitted = true;
                }
                self.emit(&format!("    .balign {}", ty.align().max(1)));
                self.emit(&format!("{}:", symbol));
                self.emit_global_initializer(ty, init.as_ref());
            } else {
                // Non-constant initializer: emit as common symbol (.bss)
                let align = ty.align().max(1);
                let common_align = match self.target.os {
                    BackendOs::Linux => align,
                    BackendOs::Windows => align.trailing_zeros() as usize,
                };
                self.emit(&format!(
                    "    .comm {}, {}, {}",
                    symbol,
                    ty.size(),
                    common_align
                ));
            }
        }
        self.emit("");
    }

    fn emit_global_initializer(&mut self, ty: &Type, init: Option<&Value>) {
        match init {
            Some(Value::ConstI64(n)) => self.emit_integer_global(ty, *n as i128),
            Some(Value::ConstI32(n)) => self.emit_integer_global(ty, *n as i128),
            Some(Value::ConstI8(n)) => self.emit_integer_global(ty, *n as i128),
            Some(Value::ConstBool(b)) => self.emit_integer_global(ty, if *b { 1 } else { 0 }),
            Some(Value::ConstF64(n)) if *ty == Type::F32 => {
                self.emit(&format!("    .long {:#x}", (*n as f32).to_bits()))
            }
            Some(Value::ConstF64(n)) => self.emit(&format!("    .quad {:#x}", n.to_bits())),
            Some(Value::ConstUnit) => {}
            // Validation rejects non-literal global initializers.
            Some(_) | None => self.emit_zero_global(ty),
        }
    }

    fn emit_integer_global(&mut self, ty: &Type, value: i128) {
        match ty.size() {
            8 => self.emit(&format!("    .quad {}", value)),
            4 => self.emit(&format!("    .long {}", value)),
            2 => self.emit(&format!("    .word {}", value)),
            1 => self.emit(&format!("    .byte {}", value)),
            _ => self.emit_zero_global(ty),
        }
    }

    fn emit_zero_global(&mut self, ty: &Type) {
        let size = ty.size();
        if size > 0 {
            self.emit(&format!("    .zero {}", size));
        }
    }

    fn generate_function(&mut self, func: &Function, program: &Program) {
        let name = Self::mangle_name(&func.name);
        self.current_fn = name.clone();
        self.emit(&format!("{}:", name));

        // Eliminate SSA `Phi` nodes by inserting copies into the Phi's stack
        // slot at the end of each predecessor block. After this pass the IR
        // contains no `Phi` instructions and can be selected directly.
        let func = eliminate_phis(func);
        let func = &func;
        let function_liveness = liveness::analyze(func);
        self.reg_plan = Some(regalloc::plan(func, &function_liveness, self.target));

        // Prologue
        self.emit("    push %rbp");
        self.emit("    mov %rsp, %rbp");

        // Calculate stack frame
        self.stack_size = 0;
        self.var_offsets.clear();
        self.var_types.clear();
        self.address_vars.clear();
        self.callee_saved_offsets.clear();
        self.return_ty = func.ret.clone();
        self.param_vars = func.params.iter().map(|(v, _)| *v).collect();
        self.current_entry_label = func.entry.clone();
        self.current_params = func.params.clone();

        // Allocate space for parameters (so their Alloc no-ops have a slot) and
        // locals.
        for (var, ty) in func.params.iter().chain(func.locals.iter()) {
            let size = ty.size() as i32;
            let align = ty.align() as i32;
            self.stack_size = (self.stack_size + align - 1) & !(align - 1);
            self.stack_size += size;
            self.var_offsets.insert(*var, -self.stack_size);
            self.var_types.insert(*var, ty.clone());
        }

        for block in &func.blocks {
            for instr in &block.instructions {
                match instr {
                    Instruction::AddrOf { dst, .. } | Instruction::Gep { dst, .. } => {
                        self.address_vars.insert(*dst);
                    }
                    _ => {}
                }
            }
        }

        let saved_home_regs = self.assigned_callee_saved_home_regs();
        for reg in &saved_home_regs {
            self.stack_size = (self.stack_size + 7) & !7;
            self.stack_size += 8;
            self.callee_saved_offsets.insert(*reg, -self.stack_size);
        }

        // Align stack to 16 bytes
        self.stack_size = (self.stack_size + 15) & !15;

        if self.stack_size > 0 {
            self.emit(&format!("    sub ${}, %rsp", self.stack_size));
        }

        for reg in &saved_home_regs {
            let offset = self.callee_saved_offsets[reg];
            self.emit(&format!("    movq {}, {}(%rbp)", reg, offset));
        }

        if self.target.runtime_policy().emits_windows_runtime_helpers
            && func.name == "main"
            && (self.needs_arg_count_runtime || self.needs_arg_runtime)
        {
            self.emit("    movq %rcx, .L_tl_argc(%rip)");
            self.emit("    movq %rdx, .L_tl_argv(%rip)");
        }
        if self.target.runtime_policy().emits_windows_runtime_helpers && func.name == "main" {
            self.emit_global_initializers(program);
        }

        // Move parameters to stack slots. Each argument register is written at
        // the width of its declared type, so a narrow parameter does not clobber
        // adjacent slots. The sub-register names differ per register
        // (`%rdi`->`%edi`/`%di`/`%dil`), so we look them up rather than string
        // -slicing the 64-bit name.
        let calling_convention = self.target.calling_convention();
        let param_regs = calling_convention.integer_arg_regs;
        let xmm_regs = calling_convention.float_arg_regs;
        // System V AMD64 consumes independent integer and floating-point
        // register sequences. Windows x64 consumes one shared four-argument
        // register window, choosing GPR or XMM by argument type.
        let mut int_param = 0;
        let mut float_param = 0;
        let mut stack_param = 0;
        let mut arg_position = 0;
        for (var, ty) in &func.params {
            if *ty == Type::Unit {
                continue;
            }
            let offset = self.var_offsets[var];
            if let Some(shared_slots) = calling_convention.shared_arg_register_slots {
                if arg_position < shared_slots {
                    let reg = if is_scalar_float(ty) {
                        xmm_regs[arg_position]
                    } else {
                        param_regs[arg_position]
                    };
                    self.store_incoming_register_param(reg, offset, ty);
                } else {
                    self.store_incoming_stack_param(stack_param, offset, ty);
                    stack_param += 1;
                }
                arg_position += 1;
                continue;
            }
            match ty {
                Type::I64
                | Type::U64
                | Type::Func(_, _)
                | Type::Enum(_)
                | Type::Struct(_)
                | Type::String
                | Type::DynArray(_) => {
                    if int_param < param_regs.len() {
                        self.store_incoming_register_param(param_regs[int_param], offset, ty);
                    } else {
                        self.store_incoming_stack_param(stack_param, offset, ty);
                        stack_param += 1;
                    }
                    int_param += 1;
                }
                Type::I32 | Type::U32 => {
                    if int_param < param_regs.len() {
                        self.store_incoming_register_param(param_regs[int_param], offset, ty);
                    } else {
                        self.store_incoming_stack_param(stack_param, offset, ty);
                        stack_param += 1;
                    }
                    int_param += 1;
                }
                Type::I16 | Type::U16 => {
                    if int_param < param_regs.len() {
                        self.store_incoming_register_param(param_regs[int_param], offset, ty);
                    } else {
                        self.store_incoming_stack_param(stack_param, offset, ty);
                        stack_param += 1;
                    }
                    int_param += 1;
                }
                Type::I8 | Type::U8 | Type::Bool | Type::Char => {
                    if int_param < param_regs.len() {
                        self.store_incoming_register_param(param_regs[int_param], offset, ty);
                    } else {
                        self.store_incoming_stack_param(stack_param, offset, ty);
                        stack_param += 1;
                    }
                    int_param += 1;
                }
                Type::F64 | Type::F32 => {
                    if float_param < xmm_regs.len() {
                        self.store_incoming_register_param(xmm_regs[float_param], offset, ty);
                    } else {
                        self.store_incoming_stack_param(stack_param, offset, ty);
                        stack_param += 1;
                    }
                    float_param += 1;
                }
                _ => {}
            }
        }

        // Generate basic blocks
        for block in &func.blocks {
            self.emit(&format!("{}.{}:", name, block.label));
            for instr in &block.instructions {
                self.generate_instruction(instr);
            }
        }
        self.reg_plan = None;
        self.callee_saved_offsets.clear();
    }

    fn generate_instruction(&mut self, instr: &Instruction) {
        match instr {
            // Parameter slots are materialized by the prologue; their Alloc is a
            // no-op here. (Non-parameter Allocs are rejected by validation.)
            Instruction::Alloc { .. } => {}
            Instruction::Mov { dst, src, ty } => {
                if is_scalar_float(ty) {
                    self.load_value(src, "%xmm0", ty);
                    self.store_xmm_value_to_var(*dst, "%xmm0", ty);
                    return;
                }

                match (src, ty) {
                    (Value::ConstI64(n), _) => {
                        self.store_integer_immediate_to_var(*dst, *n as i128, ty);
                    }
                    (Value::ConstI32(n), _) => {
                        self.store_integer_immediate_to_var(*dst, *n as i128, ty);
                    }
                    (Value::ConstI8(n), _) => {
                        self.store_integer_immediate_to_var(*dst, *n as i128, ty);
                    }
                    (Value::ConstBool(b), _) => {
                        let n = if *b { 1 } else { 0 };
                        self.store_integer_immediate_to_var(*dst, n, ty);
                    }
                    (Value::ConstF64(n), _) => {
                        // Load float from constant pool (simplified)
                        self.emit(&format!("    movabsq ${:#x}, %rax", n.to_bits()));
                        let dst_offset = self.var_offsets[dst];
                        self.emit(&format!("    movq %rax, {}(%rbp)", dst_offset));
                    }
                    (
                        Value::Var(_)
                        | Value::Global(_)
                        | Value::ConstStr(_)
                        | Value::Function(_)
                        | Value::FunctionEntry(_),
                        _,
                    ) => {
                        self.load_value(src, "%rax", ty);
                        self.store_gpr_value_to_var(*dst, "%rax", ty);
                    }
                    _ => {}
                }
            }
            // Width/sign conversion. Load the source extended per its *source*
            // type (sign-extend signed, zero-extend unsigned), which is exactly
            // the widening semantics; for narrowing we then keep only the low
            // `to_ty` bytes when writing the destination slot. The destination
            // slot is sized by `to_ty` (recorded in the frame), so the store
            // width below truncates as required.
            Instruction::Cast {
                dst,
                src,
                from_ty,
                to_ty,
            } => {
                // Floating-point precision conversions flow through XMM:
                // `cvtsd2ss` rounds an f64 to binary32, `cvtss2sd` widens an
                // f32 to f64 exactly. (Same-width float casts are folded away by
                // the lowerer, so only the genuine width changes reach here.)
                if is_scalar_float(from_ty) && is_scalar_float(to_ty) {
                    self.load_value(src, "%xmm0", from_ty);
                    match (from_ty, to_ty) {
                        (Type::F64, Type::F32) => self.emit("    cvtsd2ss %xmm0, %xmm0"),
                        (Type::F32, Type::F64) => self.emit("    cvtss2sd %xmm0, %xmm0"),
                        // Same-width float cast: no conversion instruction.
                        _ => {}
                    }
                    self.store_xmm_value_to_var(*dst, "%xmm0", to_ty);
                    return;
                }
                self.load_value(src, "%rax", from_ty);
                self.store_gpr_value_to_var(*dst, "%rax", to_ty);
            }
            Instruction::BinOp {
                dst,
                op,
                lhs,
                rhs,
                ty,
            } => {
                let operand_ty = self.binop_operand_ty(op, lhs, rhs, ty);
                let result_ty = self
                    .var_types
                    .get(dst)
                    .cloned()
                    .unwrap_or_else(|| ty.clone());
                if is_scalar_float(&operand_ty) {
                    self.generate_float_binop(*dst, op, lhs, rhs, &operand_ty, &result_ty);
                    return;
                }

                // Whether the operand type is signed drives division, shift and
                // comparison instruction selection. `bool`/`char` are treated as
                // unsigned magnitudes.
                let signed = operand_ty.is_signed();
                let suffix = Self::int_instruction_suffix(&operand_ty);
                let lhs_reg = Self::gpr_sized("%rax", &operand_ty);
                let rhs_reg = Self::gpr_sized("%rcx", &operand_ty);

                let rhs_load_ty = if matches!(
                    op,
                    IrBinOp::BitAnd
                        | IrBinOp::BitOr
                        | IrBinOp::BitXor
                        | IrBinOp::Shl
                        | IrBinOp::Shr
                ) {
                    self.value_type(rhs).unwrap_or_else(|| operand_ty.clone())
                } else {
                    operand_ty.clone()
                };

                self.load_value(lhs, "%rax", &operand_ty);
                self.load_value(rhs, "%rcx", &rhs_load_ty);

                match op {
                    IrBinOp::Add if operand_ty.is_integer() => {
                        self.emit(&format!("    add{} {}, {}", suffix, rhs_reg, lhs_reg));
                    }
                    IrBinOp::Sub if operand_ty.is_integer() => {
                        self.emit(&format!("    sub{} {}, {}", suffix, rhs_reg, lhs_reg));
                    }
                    IrBinOp::Mul if operand_ty.is_integer() => {
                        if operand_ty.size() == 1 {
                            self.emit("    imulq %rcx, %rax");
                        } else {
                            self.emit(&format!("    imul{} {}, {}", suffix, rhs_reg, lhs_reg));
                        }
                    }
                    IrBinOp::Div if operand_ty.is_integer() => {
                        self.emit_integer_divmod(&operand_ty, signed, false);
                    }
                    IrBinOp::Mod if operand_ty.is_integer() => {
                        self.emit_integer_divmod(&operand_ty, signed, true);
                    }
                    // Bitwise/logical operators work on every integer and bool
                    // width. Emit the natural width so upper-byte state cannot
                    // affect flags or obscure the generated assembly.
                    IrBinOp::BitAnd | IrBinOp::And => {
                        self.emit(&format!("    and{} {}, {}", suffix, rhs_reg, lhs_reg));
                    }
                    IrBinOp::BitOr | IrBinOp::Or => {
                        self.emit(&format!("    or{} {}, {}", suffix, rhs_reg, lhs_reg));
                    }
                    IrBinOp::BitXor => {
                        self.emit(&format!("    xor{} {}, {}", suffix, rhs_reg, lhs_reg));
                    }
                    // Shifts take the count in %cl (the low byte of %rcx, where
                    // the rhs already lives). Left shift is the same for signed
                    // and unsigned; right shift is arithmetic (`sar`) for signed
                    // operands and logical (`shr`) for unsigned.
                    IrBinOp::Shl => {
                        self.emit(&format!("    shl{} %cl, {}", suffix, lhs_reg));
                    }
                    IrBinOp::Shr => {
                        if signed {
                            self.emit(&format!("    sar{} %cl, {}", suffix, lhs_reg));
                        } else {
                            self.emit(&format!("    shr{} %cl, {}", suffix, lhs_reg));
                        }
                    }
                    IrBinOp::Eq => {
                        self.emit(&format!("    cmp{} {}, {}", suffix, rhs_reg, lhs_reg));
                        self.emit("    sete %al");
                        self.emit("    movzbq %al, %rax");
                    }
                    IrBinOp::Ne => {
                        self.emit(&format!("    cmp{} {}, {}", suffix, rhs_reg, lhs_reg));
                        self.emit("    setne %al");
                        self.emit("    movzbq %al, %rax");
                    }
                    // Relational comparisons: signed types use signed condition
                    // codes (`setl/setle/setg/setge`); unsigned types use the
                    // unsigned codes (`setb/setbe/seta/setae`). Previously the
                    // unsigned arms emitted *nothing*, silently dropping the
                    // comparison.
                    IrBinOp::Lt => {
                        self.emit(&format!("    cmp{} {}, {}", suffix, rhs_reg, lhs_reg));
                        self.emit(if signed {
                            "    setl %al"
                        } else {
                            "    setb %al"
                        });
                        self.emit("    movzbq %al, %rax");
                    }
                    IrBinOp::Le => {
                        self.emit(&format!("    cmp{} {}, {}", suffix, rhs_reg, lhs_reg));
                        self.emit(if signed {
                            "    setle %al"
                        } else {
                            "    setbe %al"
                        });
                        self.emit("    movzbq %al, %rax");
                    }
                    IrBinOp::Gt => {
                        self.emit(&format!("    cmp{} {}, {}", suffix, rhs_reg, lhs_reg));
                        self.emit(if signed {
                            "    setg %al"
                        } else {
                            "    seta %al"
                        });
                        self.emit("    movzbq %al, %rax");
                    }
                    IrBinOp::Ge => {
                        self.emit(&format!("    cmp{} {}, {}", suffix, rhs_reg, lhs_reg));
                        self.emit(if signed {
                            "    setge %al"
                        } else {
                            "    setae %al"
                        });
                        self.emit("    movzbq %al, %rax");
                    }
                    _ => {}
                }

                self.store_gpr_value_to_var(*dst, "%rax", &result_ty);
            }
            Instruction::UnOp { dst, op, src, ty } => {
                if is_scalar_float(ty) {
                    self.load_value(src, "%xmm0", ty);
                    match op {
                        IrUnOp::Neg => {
                            // Negate by subtracting from zero at the operand
                            // width (`subss`/`subsd`), then move the result back
                            // with the matching packed move (`movaps`/`movapd`).
                            let single = matches!(ty, Type::F32);
                            self.emit("    pxor %xmm1, %xmm1");
                            self.emit(if single {
                                "    subss %xmm0, %xmm1"
                            } else {
                                "    subsd %xmm0, %xmm1"
                            });
                            self.emit(if single {
                                "    movaps %xmm1, %xmm0"
                            } else {
                                "    movapd %xmm1, %xmm0"
                            });
                        }
                        // Logical/bitwise complement are not defined on floats
                        // and are rejected by validation/typechecking before
                        // codegen.
                        IrUnOp::Not | IrUnOp::BitNot => {}
                    }
                    self.store_xmm_value_to_var(*dst, "%xmm0", ty);
                    return;
                }

                self.load_value(src, "%rax", ty);
                let suffix = Self::int_instruction_suffix(ty);
                let reg = Self::gpr_sized("%rax", ty);

                match op {
                    IrUnOp::Neg => {
                        self.emit(&format!("    neg{} {}", suffix, reg));
                    }
                    // Logical not on a 0/1 bool: flip the low bit.
                    IrUnOp::Not => {
                        self.emit(&format!("    xor{} $1, {}", suffix, reg));
                    }
                    // Bitwise complement (one's complement) on an integer.
                    IrUnOp::BitNot => {
                        self.emit(&format!("    not{} {}", suffix, reg));
                    }
                }

                self.store_gpr_value_to_var(*dst, "%rax", ty);
            }
            Instruction::Call {
                dst,
                func,
                args,
                ty,
            } => {
                let stack_arg_space = self.load_call_args(args);
                self.emit(&format!("    call {}", self.call_symbol(func)));
                self.release_call_args(stack_arg_space);
                self.store_call_result(dst, ty);
            }
            Instruction::CallIndirect {
                dst,
                func,
                args,
                ty,
            } => {
                let stack_arg_space = self.load_closure_call_args(args);
                let func_ty = self
                    .value_type(func)
                    .unwrap_or_else(|| Type::Func(Vec::new(), Box::new(Type::Unit)));
                self.load_value(func, "%r11", &func_ty);
                let env_reg = self.target.calling_convention().integer_arg_regs[0];
                self.emit(&format!("    movq 8(%r11), {}", env_reg));
                self.emit("    movq (%r11), %rax");
                self.emit("    call *%rax");
                self.release_call_args(stack_arg_space);
                self.store_call_result(dst, ty);
            }
            Instruction::TailCall { func: _, args, .. } => {
                self.generate_tail_call(args);
            }
            Instruction::Branch {
                cond,
                true_label,
                false_label,
            } => {
                self.load_value(cond, "%rax", &Type::Bool);
                self.emit("    testb %al, %al");
                self.emit(&format!("    jnz {}", self.block_label(true_label)));
                self.emit(&format!("    jmp {}", self.block_label(false_label)));
            }
            Instruction::Jump(label) => {
                self.emit(&format!("    jmp {}", self.block_label(label)));
            }
            // `let` binding / `set!`: store a value into a local's stack slot.
            // Ordinary local variables are stack slots. Vars produced by
            // `AddrOf`/`Gep` hold an address, so a Store through them writes to
            // the pointed-to memory instead of the pointer slot.
            Instruction::Store { dst, src, ty } => {
                if let Value::Global(name) = dst {
                    let addr = format!("{}(%rip)", Self::mangle_name(name));
                    self.store_value_to_addr(&addr, src, ty);
                    return;
                }

                let dst_var = match dst {
                    Value::Var(v) => *v,
                    // Validation rejects remaining non-Var store addresses.
                    _ => return,
                };
                if self.is_pointer_deref_var(dst_var, ty) {
                    self.store_value_through_pointer(dst_var, src, ty);
                    return;
                }
                if is_scalar_float(ty) {
                    self.load_value(src, "%xmm0", ty);
                    self.store_xmm_value_to_var(dst_var, "%xmm0", ty);
                    return;
                }

                match src {
                    Value::Var(_)
                    | Value::Global(_)
                    | Value::ConstStr(_)
                    | Value::Function(_)
                    | Value::FunctionEntry(_) => {
                        // Round-trip through a register sized to the value.
                        self.load_value(src, "%rax", ty);
                        self.store_gpr_value_to_var(dst_var, "%rax", ty);
                    }
                    Value::ConstI64(n) => {
                        self.store_integer_immediate_to_var(dst_var, *n as i128, ty);
                    }
                    Value::ConstI32(n) => {
                        self.store_integer_immediate_to_var(dst_var, *n as i128, ty);
                    }
                    Value::ConstI8(n) => {
                        self.store_integer_immediate_to_var(dst_var, *n as i128, ty);
                    }
                    Value::ConstBool(b) => {
                        let n = if *b { 1 } else { 0 };
                        self.store_integer_immediate_to_var(dst_var, n, ty);
                    }
                    _ => {}
                }
            }
            // Read a local's stack slot into the destination's slot, or
            // dereference a pointer-valued local produced by AddrOf/Gep.
            Instruction::Load { dst, src, ty } => {
                if let Value::Var(src_var) = src
                    && self.is_pointer_deref_var(*src_var, ty)
                {
                    self.load_value_through_pointer(*src_var, *dst, ty);
                    return;
                }
                if is_scalar_float(ty) {
                    self.load_value(src, "%xmm0", ty);
                    self.store_xmm_value_to_var(*dst, "%xmm0", ty);
                    return;
                }

                self.load_value(src, "%rax", ty);
                self.store_gpr_value_to_var(*dst, "%rax", ty);
            }
            Instruction::AddrOf { dst, src } => {
                let src_offset = self.var_offsets[src];
                let dst_ty = self.var_types.get(dst).cloned().unwrap_or(Type::U64);
                self.emit(&format!("    leaq {}(%rbp), %rax", src_offset));
                self.store_gpr_value_to_var(*dst, "%rax", &dst_ty);
            }
            Instruction::Gep {
                dst,
                base,
                offset,
                elem_ty,
            } => {
                let dst_ty = self.var_types.get(dst).cloned().unwrap_or(Type::U64);
                let base_ty = self.value_type(base).unwrap_or(Type::U64);
                let offset_ty = self.value_type(offset).unwrap_or(Type::I64);
                self.load_value(base, "%rax", &base_ty);
                self.load_value(offset, "%rcx", &offset_ty);
                let elem_size = elem_ty.size();
                if elem_size > 1 {
                    self.emit(&format!("    imulq ${}, %rcx", elem_size));
                }
                self.emit("    addq %rcx, %rax");
                self.store_gpr_value_to_var(*dst, "%rax", &dst_ty);
            }
            Instruction::VectorBinOp {
                dst,
                op,
                lhs,
                rhs,
                lanes,
                elem_ty,
            } if self.target.mode == BackendMode::Avx2 => {
                self.generate_avx2_vector_binop(*dst, *op, lhs, rhs, *lanes, elem_ty);
            }
            Instruction::VectorBinOp {
                dst,
                op,
                lhs,
                rhs,
                lanes,
                elem_ty,
            } if self.target.mode == BackendMode::Avx512 => {
                self.generate_avx512_vector_binop(*dst, *op, lhs, rhs, *lanes, elem_ty);
            }
            Instruction::VectorReduce {
                dst,
                op,
                src,
                lanes,
                elem_ty,
            } if self.target.mode == BackendMode::Avx2 => {
                self.generate_avx2_vector_reduce(*dst, *op, src, *lanes, elem_ty);
            }
            Instruction::VectorLoad {
                dst,
                base,
                index,
                lanes,
                elem_ty,
            } if self.target.mode == BackendMode::Avx2 => {
                self.generate_avx2_vector_load(*dst, base, index, *lanes, elem_ty);
            }
            Instruction::VectorLoad {
                dst,
                base,
                index,
                lanes,
                elem_ty,
            } if self.target.mode == BackendMode::Avx512 => {
                self.generate_avx512_vector_load(*dst, base, index, *lanes, elem_ty);
            }
            Instruction::VectorStore {
                base,
                index,
                value,
                lanes,
                elem_ty,
            } if self.target.mode == BackendMode::Avx2 => {
                self.generate_avx2_vector_store(base, index, value, *lanes, elem_ty);
            }
            Instruction::VectorStore {
                base,
                index,
                value,
                lanes,
                elem_ty,
            } if self.target.mode == BackendMode::Avx512 => {
                self.generate_avx512_vector_store(base, index, value, *lanes, elem_ty);
            }
            Instruction::TailMask {
                dst,
                index,
                len,
                lanes,
            } if self.target.mode == BackendMode::Avx512 => {
                self.generate_avx512_tail_mask(*dst, index, len, *lanes);
            }
            Instruction::PredicatedLoad {
                dst,
                base,
                index,
                mask,
                lanes,
                elem_ty,
            } if self.target.mode == BackendMode::Avx512 => {
                self.generate_avx512_predicated_load(*dst, base, index, mask, *lanes, elem_ty);
            }
            Instruction::PredicatedStore {
                base,
                index,
                value,
                mask,
                lanes,
                elem_ty,
            } if self.target.mode == BackendMode::Avx512 => {
                self.generate_avx512_predicated_store(base, index, value, mask, *lanes, elem_ty);
            }
            Instruction::LaneId { .. }
            | Instruction::Splat { .. }
            | Instruction::VectorBinOp { .. }
            | Instruction::VectorCompare { .. }
            | Instruction::VectorReduce { .. }
            | Instruction::MaskBinOp { .. }
            | Instruction::MaskNot { .. }
            | Instruction::MaskReduce { .. }
            | Instruction::Select { .. }
            | Instruction::VectorLoad { .. }
            | Instruction::VectorStore { .. }
            | Instruction::PredicatedStore { .. }
            | Instruction::PredicatedLoad { .. }
            | Instruction::TailMask { .. } => {
                self.emit("    # vector/mask IR rejected by backend validation");
            }
            // Phi nodes are lowered to predecessor moves by `eliminate_phis`
            // before instruction selection. If one reaches this point, there is
            // no standalone assembly instruction to emit for it.
            Instruction::Phi { .. } => {}
            Instruction::Return(val) => {
                if let Some(v) = val {
                    let ret_ty = self.return_ty.clone();
                    let calling_convention = self.target.calling_convention();
                    if is_scalar_float(&ret_ty) {
                        self.load_value(v, calling_convention.return_float_reg, &ret_ty);
                    } else {
                        self.load_value(v, calling_convention.return_gpr, &ret_ty);
                    }
                } else if self.target.runtime_policy().emits_windows_runtime_helpers
                    && self.current_fn == "main"
                {
                    self.emit("    xor %eax, %eax");
                }
                self.emit_epilogue();
            }
        }
    }

    fn assigned_callee_saved_home_regs(&self) -> Vec<&'static str> {
        let mut assigned = BTreeSet::new();
        if let Some(plan) = &self.reg_plan {
            for location in plan.assignments.values() {
                if let regalloc::Location::Reg(reg) = location {
                    assigned.insert(*reg);
                }
            }
        }

        regalloc::target_register_info(self.target)
            .callee_saved_integer
            .iter()
            .copied()
            .filter(|reg| assigned.contains(reg))
            .collect()
    }

    fn emit_epilogue(&mut self) {
        if self.target.mode == BackendMode::Avx2 || self.target.mode == BackendMode::Avx512 {
            self.emit("    vzeroupper");
        }

        for reg in self.assigned_callee_saved_home_regs().into_iter().rev() {
            let offset = self.callee_saved_offsets[reg];
            self.emit(&format!("    movq {}(%rbp), {}", offset, reg));
        }
        self.emit("    mov %rbp, %rsp");
        self.emit("    pop %rbp");
        self.emit("    ret");
    }

    fn generate_avx2_vector_binop(
        &mut self,
        dst: VarId,
        op: IrBinOp,
        lhs: &Value,
        rhs: &Value,
        _lanes: usize,
        elem_ty: &Type,
    ) {
        let Some(mnemonic) = Self::avx2_vector_binop_mnemonic(op, elem_ty) else {
            self.emit("    # unsupported AVX2 vector binop rejected by backend validation");
            return;
        };
        self.load_vector_value(lhs, "%ymm0", elem_ty);
        self.load_vector_value(rhs, "%ymm1", elem_ty);
        self.emit(&format!("    {} %ymm1, %ymm0, %ymm0", mnemonic));
        let dst_offset = self.var_offsets[&dst];
        self.store_vector_reg("%ymm0", dst_offset, elem_ty);
    }

    fn generate_avx2_vector_reduce(
        &mut self,
        dst: VarId,
        op: VectorReduceOp,
        src: &Value,
        _lanes: usize,
        elem_ty: &Type,
    ) {
        if op != VectorReduceOp::Sum {
            self.emit("    # unsupported AVX2 vector reduction rejected by backend validation");
            return;
        }
        self.load_vector_value(src, "%ymm0", elem_ty);
        match elem_ty {
            Type::I64 => {
                self.emit("    vextracti128 $1, %ymm0, %xmm1");
                self.emit("    vpaddq %xmm1, %xmm0, %xmm0");
                self.emit("    vpsrldq $8, %xmm0, %xmm1");
                self.emit("    vpaddq %xmm1, %xmm0, %xmm0");
                self.emit("    vmovq %xmm0, %rax");
            }
            Type::I32 => {
                self.emit("    vextracti128 $1, %ymm0, %xmm1");
                self.emit("    vpaddd %xmm1, %xmm0, %xmm0");
                self.emit("    vpsrldq $8, %xmm0, %xmm1");
                self.emit("    vpaddd %xmm1, %xmm0, %xmm0");
                self.emit("    vpsrldq $4, %xmm0, %xmm1");
                self.emit("    vpaddd %xmm1, %xmm0, %xmm0");
                self.emit("    vmovd %xmm0, %eax");
            }
            _ => {
                self.emit("    # unsupported AVX2 vector reduction rejected by backend validation");
                return;
            }
        }
        let dst_offset = self.var_offsets[&dst];
        self.store_gpr_value("%rax", dst_offset, elem_ty);
    }

    fn generate_avx2_vector_load(
        &mut self,
        dst: VarId,
        base: &Value,
        index: &Value,
        _lanes: usize,
        elem_ty: &Type,
    ) {
        self.load_dyn_array_data_ptr(base, "%rax");
        self.load_vector_index(index, "%rcx");
        let addr = Self::indexed_addr("%rax", "%rcx", elem_ty);
        let move_mnemonic = Self::vector_move_mnemonic(elem_ty);
        self.emit(&format!("    {} {}, %ymm0", move_mnemonic, addr));
        let dst_offset = self.var_offsets[&dst];
        self.store_vector_reg("%ymm0", dst_offset, elem_ty);
    }

    fn generate_avx2_vector_store(
        &mut self,
        base: &Value,
        index: &Value,
        value: &Value,
        _lanes: usize,
        elem_ty: &Type,
    ) {
        self.load_dyn_array_data_ptr(base, "%rax");
        self.load_vector_index(index, "%rcx");
        self.load_vector_value(value, "%ymm0", elem_ty);
        let addr = Self::indexed_addr("%rax", "%rcx", elem_ty);
        let move_mnemonic = Self::vector_move_mnemonic(elem_ty);
        self.emit(&format!("    {} %ymm0, {}", move_mnemonic, addr));
    }

    fn generate_avx512_vector_binop(
        &mut self,
        dst: VarId,
        op: IrBinOp,
        lhs: &Value,
        rhs: &Value,
        _lanes: usize,
        elem_ty: &Type,
    ) {
        let Some(mnemonic) = Self::avx512_vector_binop_mnemonic(op, elem_ty) else {
            self.emit("    # unsupported AVX-512 vector binop rejected by backend validation");
            return;
        };
        self.load_vector_value(lhs, "%zmm0", elem_ty);
        self.load_vector_value(rhs, "%zmm1", elem_ty);
        self.emit(&format!("    {} %zmm1, %zmm0, %zmm0", mnemonic));
        let dst_offset = self.var_offsets[&dst];
        self.store_vector_reg("%zmm0", dst_offset, elem_ty);
    }

    fn generate_avx512_vector_load(
        &mut self,
        dst: VarId,
        base: &Value,
        index: &Value,
        _lanes: usize,
        elem_ty: &Type,
    ) {
        self.load_dyn_array_data_ptr(base, "%rax");
        self.load_vector_index(index, "%rcx");
        let addr = Self::indexed_addr("%rax", "%rcx", elem_ty);
        let move_mnemonic = Self::vector_move_mnemonic_for_reg("%zmm0", elem_ty);
        self.emit(&format!("    {} {}, %zmm0", move_mnemonic, addr));
        let dst_offset = self.var_offsets[&dst];
        self.store_vector_reg("%zmm0", dst_offset, elem_ty);
    }

    fn generate_avx512_vector_store(
        &mut self,
        base: &Value,
        index: &Value,
        value: &Value,
        _lanes: usize,
        elem_ty: &Type,
    ) {
        self.load_dyn_array_data_ptr(base, "%rax");
        self.load_vector_index(index, "%rcx");
        self.load_vector_value(value, "%zmm0", elem_ty);
        let addr = Self::indexed_addr("%rax", "%rcx", elem_ty);
        let move_mnemonic = Self::vector_move_mnemonic_for_reg("%zmm0", elem_ty);
        self.emit(&format!("    {} %zmm0, {}", move_mnemonic, addr));
    }

    /// Build the contiguous tail mask `index + lane < len` as a small integer
    /// bitmask in the destination mask slot: `active = clamp(len - index, 0,
    /// lanes)` and `bitmask = (1 << active) - 1`. The bitmask is loaded into a
    /// `k` register on demand by predicated loads/stores.
    fn generate_avx512_tail_mask(&mut self, dst: VarId, index: &Value, len: &Value, lanes: usize) {
        let index_ty = self.value_type(index).unwrap_or(Type::I64);
        let len_ty = self.value_type(len).unwrap_or(Type::I64);
        self.load_value(index, "%rax", &index_ty);
        self.load_value(len, "%rcx", &len_ty);
        self.emit("    subq %rax, %rcx");
        self.emit(&format!("    movq ${}, %rax", lanes));
        self.emit("    cmpq %rax, %rcx");
        self.emit("    cmovgq %rax, %rcx");
        self.emit("    xorq %rax, %rax");
        self.emit("    cmpq %rax, %rcx");
        self.emit("    cmovlq %rax, %rcx");
        self.emit("    movq $1, %rdx");
        self.emit("    shlq %cl, %rdx");
        self.emit("    decq %rdx");
        let dst_offset = self.var_offsets[&dst];
        self.emit(&format!("    movw %dx, {}(%rbp)", dst_offset));
    }

    fn generate_avx512_predicated_load(
        &mut self,
        dst: VarId,
        base: &Value,
        index: &Value,
        mask: &Value,
        _lanes: usize,
        elem_ty: &Type,
    ) {
        self.load_mask_into_k1(mask);
        self.load_dyn_array_data_ptr(base, "%rax");
        self.load_vector_index(index, "%rcx");
        let addr = Self::indexed_addr("%rax", "%rcx", elem_ty);
        let move_mnemonic = Self::masked_vector_move_mnemonic(elem_ty);
        // Zero-masking: inactive lanes read as zero, so the full-width store of
        // the destination register below is well defined.
        self.emit(&format!(
            "    {} {}, %zmm0{{%k1}}{{z}}",
            move_mnemonic, addr
        ));
        let dst_offset = self.var_offsets[&dst];
        self.store_vector_reg("%zmm0", dst_offset, elem_ty);
    }

    fn generate_avx512_predicated_store(
        &mut self,
        base: &Value,
        index: &Value,
        value: &Value,
        mask: &Value,
        _lanes: usize,
        elem_ty: &Type,
    ) {
        self.load_mask_into_k1(mask);
        self.load_vector_value(value, "%zmm0", elem_ty);
        self.load_dyn_array_data_ptr(base, "%rax");
        self.load_vector_index(index, "%rcx");
        let addr = Self::indexed_addr("%rax", "%rcx", elem_ty);
        let move_mnemonic = Self::masked_vector_move_mnemonic(elem_ty);
        // Merge-masking: only active lanes are written to memory.
        self.emit(&format!("    {} %zmm0, {}{{%k1}}", move_mnemonic, addr));
    }

    /// Load a lane mask from its stack slot into `%k1`. Masks are stored as a
    /// 16-bit integer bitmask (one bit per lane), covering the 8- and 16-lane
    /// AVX-512 shapes. `k0` is intentionally avoided because AVX-512 treats it
    /// as the implicit all-ones / no-mask register.
    fn load_mask_into_k1(&mut self, mask: &Value) {
        let Value::Var(var) = mask else {
            self.emit("    # unsupported mask value rejected by backend validation");
            return;
        };
        let offset = self.var_offsets[var];
        self.emit(&format!("    movzwl {}(%rbp), %eax", offset));
        self.emit("    kmovw %eax, %k1");
    }

    /// EVEX masked move mnemonic for predicated loads/stores. Unlike the
    /// unmasked `vmovdqu`/`vmovupd` forms, these size-tagged encodings accept a
    /// `k` mask register.
    fn masked_vector_move_mnemonic(elem_ty: &Type) -> &'static str {
        match elem_ty {
            Type::F64 => "vmovupd",
            _ if elem_ty.size() == 4 => "vmovdqu32",
            _ => "vmovdqu64",
        }
    }

    fn load_dyn_array_data_ptr(&mut self, base: &Value, reg: &str) {
        let base_ty = self.value_type(base).unwrap_or(Type::U64);
        self.load_value(base, reg, &base_ty);
        self.emit(&format!(
            "    movq {}({}), {}",
            DYN_ARRAY_PTR_OFFSET, reg, reg
        ));
    }

    fn load_vector_index(&mut self, index: &Value, reg: &str) {
        let index_ty = self.value_type(index).unwrap_or(Type::I64);
        self.load_value(index, reg, &index_ty);
    }

    fn load_vector_value(&mut self, value: &Value, reg: &str, elem_ty: &Type) {
        let Value::Var(var) = value else {
            self.emit("    # unsupported vector value rejected by backend validation");
            return;
        };
        let offset = self.var_offsets[var];
        let move_mnemonic = Self::vector_move_mnemonic_for_reg(reg, elem_ty);
        self.emit(&format!("    {} {}(%rbp), {}", move_mnemonic, offset, reg));
    }

    fn store_vector_reg(&mut self, reg: &str, offset: i32, elem_ty: &Type) {
        let move_mnemonic = Self::vector_move_mnemonic_for_reg(reg, elem_ty);
        self.emit(&format!("    {} {}, {}(%rbp)", move_mnemonic, reg, offset));
    }

    fn indexed_addr(base_reg: &str, index_reg: &str, elem_ty: &Type) -> String {
        format!("({},{},{})", base_reg, index_reg, elem_ty.size())
    }

    fn vector_move_mnemonic(elem_ty: &Type) -> &'static str {
        if *elem_ty == Type::F64 {
            "vmovupd"
        } else {
            "vmovdqu"
        }
    }

    /// Unmasked vector move mnemonic for a specific register width. AVX2 `%ymm`
    /// (256-bit) moves use the VEX `vmovdqu`/`vmovupd` forms. AVX-512 `%zmm`
    /// (512-bit) moves must use the size-tagged EVEX forms
    /// (`vmovdqu64`/`vmovdqu32`/`vmovupd`): plain `vmovdqu` has no 512-bit
    /// encoding, so stricter assemblers (LLVM/clang) reject `vmovdqu %zmm`.
    /// `vmovupd` already has a 512-bit encoding, so float moves are unchanged.
    fn vector_move_mnemonic_for_reg(reg: &str, elem_ty: &Type) -> &'static str {
        if reg.contains("zmm") {
            Self::masked_vector_move_mnemonic(elem_ty)
        } else {
            Self::vector_move_mnemonic(elem_ty)
        }
    }

    fn avx2_vector_binop_mnemonic(op: IrBinOp, elem_ty: &Type) -> Option<&'static str> {
        Self::vector_binop_mnemonic(op, elem_ty)
    }

    fn avx512_vector_binop_mnemonic(op: IrBinOp, elem_ty: &Type) -> Option<&'static str> {
        Self::vector_binop_mnemonic(op, elem_ty)
    }

    fn vector_binop_mnemonic(op: IrBinOp, elem_ty: &Type) -> Option<&'static str> {
        match (op, elem_ty) {
            (IrBinOp::Add, Type::I64 | Type::U64) => Some("vpaddq"),
            (IrBinOp::Add, Type::I32 | Type::U32) => Some("vpaddd"),
            (IrBinOp::Add, Type::F64) => Some("vaddpd"),
            _ => None,
        }
    }

    fn store_incoming_stack_param(&mut self, stack_param: i32, local_offset: i32, ty: &Type) {
        let caller_offset = self
            .target
            .calling_convention()
            .incoming_stack_arg_offset(stack_param);
        if is_scalar_float(ty) {
            let mov = scalar_float_move(ty);
            self.emit(&format!("    {} {}(%rbp), %xmm15", mov, caller_offset));
            self.emit(&format!("    {} %xmm15, {}(%rbp)", mov, local_offset));
            return;
        }

        match ty.size() {
            8 => {
                self.emit(&format!("    movq {}(%rbp), %r11", caller_offset));
                self.emit(&format!("    movq %r11, {}(%rbp)", local_offset));
            }
            4 => {
                self.emit(&format!("    movl {}(%rbp), %r11d", caller_offset));
                self.emit(&format!("    movl %r11d, {}(%rbp)", local_offset));
            }
            2 => {
                self.emit(&format!("    movw {}(%rbp), %r11w", caller_offset));
                self.emit(&format!("    movw %r11w, {}(%rbp)", local_offset));
            }
            1 => {
                self.emit(&format!("    movb {}(%rbp), %r11b", caller_offset));
                self.emit(&format!("    movb %r11b, {}(%rbp)", local_offset));
            }
            _ => {}
        }
    }

    fn store_incoming_register_param(&mut self, reg: &str, local_offset: i32, ty: &Type) {
        if is_scalar_float(ty) {
            let mov = scalar_float_move(ty);
            self.emit(&format!("    {} {}, {}(%rbp)", mov, reg, local_offset));
            return;
        }

        match ty.size() {
            8 => self.emit(&format!("    movq {}, {}(%rbp)", reg, local_offset)),
            4 => self.emit(&format!(
                "    movl {}, {}(%rbp)",
                Self::gpr32(reg),
                local_offset
            )),
            2 => self.emit(&format!(
                "    movw {}, {}(%rbp)",
                Self::gpr16(reg),
                local_offset
            )),
            1 => self.emit(&format!(
                "    movb {}, {}(%rbp)",
                Self::gpr8(reg),
                local_offset
            )),
            _ => {}
        }
    }

    fn load_call_args(&mut self, args: &[Value]) -> i32 {
        let calling_convention = self.target.calling_convention();
        let param_regs = calling_convention.integer_arg_regs;
        let xmm_regs = calling_convention.float_arg_regs;
        let mut int_arg = 0;
        let mut float_arg = 0;
        let mut arg_position = 0;
        let mut stack_args = Vec::new();
        for arg in args {
            let arg_ty = self.value_type(arg).unwrap_or(Type::I64);
            if arg_ty == Type::Unit {
                continue;
            }
            if let Some(shared_slots) = calling_convention.shared_arg_register_slots {
                if arg_position < shared_slots {
                    if is_scalar_float(&arg_ty) {
                        self.load_value(arg, xmm_regs[arg_position], &arg_ty);
                    } else {
                        self.load_value(arg, param_regs[arg_position], &arg_ty);
                    }
                } else {
                    stack_args.push((arg.clone(), arg_ty));
                }
                arg_position += 1;
                continue;
            }
            if is_scalar_float(&arg_ty) {
                if float_arg < xmm_regs.len() {
                    self.load_value(arg, xmm_regs[float_arg], &arg_ty);
                } else {
                    stack_args.push((arg.clone(), arg_ty));
                }
                float_arg += 1;
            } else {
                if int_arg < param_regs.len() {
                    self.load_value(arg, param_regs[int_arg], &arg_ty);
                } else {
                    stack_args.push((arg.clone(), arg_ty));
                }
                int_arg += 1;
            }
        }

        let stack_arg_space = calling_convention.outgoing_stack_arg_space(stack_args.len());
        if stack_arg_space > 0 {
            self.emit(&format!("    sub ${}, %rsp", stack_arg_space));
            for (idx, (arg, ty)) in stack_args.iter().enumerate() {
                self.store_stack_call_arg(idx as i32, arg, ty);
            }
        }
        stack_arg_space
    }

    fn load_closure_call_args(&mut self, args: &[Value]) -> i32 {
        let calling_convention = self.target.calling_convention();
        let param_regs = calling_convention.integer_arg_regs;
        let xmm_regs = calling_convention.float_arg_regs;
        let mut int_arg = 1;
        let mut float_arg = 0;
        let mut arg_position = 1;
        let mut stack_args = Vec::new();

        for arg in args {
            let arg_ty = self.value_type(arg).unwrap_or(Type::I64);
            if arg_ty == Type::Unit {
                continue;
            }
            if let Some(shared_slots) = calling_convention.shared_arg_register_slots {
                if arg_position < shared_slots {
                    if is_scalar_float(&arg_ty) {
                        self.load_value(arg, xmm_regs[arg_position], &arg_ty);
                    } else {
                        self.load_value(arg, param_regs[arg_position], &arg_ty);
                    }
                } else {
                    stack_args.push((arg.clone(), arg_ty));
                }
                arg_position += 1;
                continue;
            }
            if is_scalar_float(&arg_ty) {
                if float_arg < xmm_regs.len() {
                    self.load_value(arg, xmm_regs[float_arg], &arg_ty);
                } else {
                    stack_args.push((arg.clone(), arg_ty));
                }
                float_arg += 1;
            } else {
                if int_arg < param_regs.len() {
                    self.load_value(arg, param_regs[int_arg], &arg_ty);
                } else {
                    stack_args.push((arg.clone(), arg_ty));
                }
                int_arg += 1;
            }
        }

        let stack_arg_space = calling_convention.outgoing_stack_arg_space(stack_args.len());
        if stack_arg_space > 0 {
            self.emit(&format!("    sub ${}, %rsp", stack_arg_space));
            for (idx, (arg, ty)) in stack_args.iter().enumerate() {
                self.store_stack_call_arg(idx as i32, arg, ty);
            }
        }
        stack_arg_space
    }

    fn emit_call(&mut self, symbol: &str) {
        let stack_arg_space = self.target.calling_convention().outgoing_stack_arg_space(0);
        if stack_arg_space > 0 {
            self.emit(&format!("    sub ${}, %rsp", stack_arg_space));
        }
        self.emit(&format!("    call {}", symbol));
        self.release_call_args(stack_arg_space);
    }

    fn store_stack_call_arg(&mut self, stack_arg: i32, arg: &Value, ty: &Type) {
        let offset = self
            .target
            .calling_convention()
            .outgoing_stack_arg_offset(stack_arg);
        if is_scalar_float(ty) {
            let mov = scalar_float_move(ty);
            self.load_value(arg, "%xmm15", ty);
            self.emit(&format!("    {} %xmm15, {}(%rsp)", mov, offset));
            return;
        }

        self.load_value(arg, "%r11", ty);
        self.emit(&format!("    movq %r11, {}(%rsp)", offset));
    }

    fn release_call_args(&mut self, stack_arg_space: i32) {
        if stack_arg_space > 0 {
            self.emit(&format!("    add ${}, %rsp", stack_arg_space));
        }
    }

    fn store_call_result(&mut self, dst: &Option<VarId>, ty: &Type) {
        if let Some(dst_var) = dst {
            let calling_convention = self.target.calling_convention();
            if is_scalar_float(ty) {
                self.store_xmm_value_to_var(*dst_var, calling_convention.return_float_reg, ty);
            } else {
                self.store_gpr_value_to_var(*dst_var, calling_convention.return_gpr, ty);
            }
        }
    }

    fn generate_tail_call(&mut self, args: &[Value]) {
        let params = self.current_params.clone();
        let mut staged = Vec::new();

        for ((param_var, param_ty), arg) in params.iter().zip(args.iter()) {
            if *param_ty == Type::Unit {
                continue;
            }

            if is_scalar_float(param_ty) {
                let mov = scalar_float_move(param_ty);
                self.load_value(arg, "%xmm15", param_ty);
                self.emit("    sub $8, %rsp");
                self.emit(&format!("    {} %xmm15, (%rsp)", mov));
            } else {
                self.load_value(arg, "%r11", param_ty);
                self.emit("    push %r11");
            }
            staged.push((*param_var, param_ty.clone()));
        }

        for (param_var, param_ty) in staged.iter().rev() {
            if is_scalar_float(param_ty) {
                let mov = scalar_float_move(param_ty);
                self.emit(&format!("    {} (%rsp), %xmm15", mov));
                self.emit("    add $8, %rsp");
                self.store_xmm_value_to_var(*param_var, "%xmm15", param_ty);
            } else {
                self.emit("    pop %r11");
                self.store_gpr_value_to_var(*param_var, "%r11", param_ty);
            }
        }

        let entry_label = self.current_entry_label.clone();
        self.emit(&format!("    jmp {}", self.block_label(&entry_label)));
    }

    fn is_pointer_deref_var(&self, var: VarId, access_ty: &Type) -> bool {
        if self.address_vars.contains(&var) {
            return true;
        }
        match self.var_types.get(&var) {
            Some(var_ty) => is_pointer_sized_type(var_ty) && var_ty != access_ty,
            None => false,
        }
    }

    fn load_value_through_pointer(&mut self, ptr_var: VarId, dst_var: VarId, ty: &Type) {
        self.load_pointer_value(ptr_var, "%r10");
        if is_scalar_float(ty) {
            let mov = scalar_float_move(ty);
            self.emit(&format!("    {} (%r10), %xmm0", mov));
            self.store_xmm_value_to_var(dst_var, "%xmm0", ty);
            return;
        }

        // Load the dereferenced value into the full 64-bit register, extending
        // narrower types so the stored stack slot is well-defined (signed types
        // sign-extend, unsigned/bool/char zero-extend — e.g. a `char` byte is
        // loaded with `movzbq`). The full register is then spilled width-first.
        self.load_memory_value("(%r10)", "%rax", ty);
        self.store_gpr_value_to_var(dst_var, "%rax", ty);
    }

    fn store_value_through_pointer(&mut self, ptr_var: VarId, src: &Value, ty: &Type) {
        self.load_pointer_value(ptr_var, "%r10");
        if is_scalar_float(ty) {
            let mov = scalar_float_move(ty);
            self.load_value(src, "%xmm0", ty);
            self.emit(&format!("    {} %xmm0, (%r10)", mov));
            return;
        }

        self.load_value(src, "%rax", ty);
        match ty.size() {
            8 => self.emit("    movq %rax, (%r10)"),
            4 => self.emit("    movl %eax, (%r10)"),
            2 => self.emit("    movw %ax, (%r10)"),
            1 => self.emit("    movb %al, (%r10)"),
            _ => {}
        }
    }

    fn load_pointer_value(&mut self, ptr_var: VarId, reg: &str) {
        let ptr_ty = self.var_types.get(&ptr_var).cloned().unwrap_or(Type::U64);
        self.load_value(&Value::Var(ptr_var), reg, &ptr_ty);
    }

    fn reg_home_for(&self, var: VarId) -> Option<&'static str> {
        match self.reg_plan.as_ref()?.assignments.get(&var) {
            Some(regalloc::Location::Reg(reg)) => Some(*reg),
            _ => None,
        }
    }

    fn store_gpr_value_to_var(&mut self, var: VarId, reg: &str, ty: &Type) {
        if let Some(home) = self.reg_home_for(var) {
            self.store_gpr_value_to_register(reg, home, ty);
            return;
        }

        let offset = self.var_offsets[&var];
        self.store_gpr_value(reg, offset, ty);
    }

    fn store_xmm_value_to_var(&mut self, var: VarId, reg: &str, ty: &Type) {
        let offset = self.var_offsets[&var];
        self.store_xmm_value(reg, offset, ty);
    }

    fn store_integer_immediate_to_var(&mut self, var: VarId, value: i128, ty: &Type) {
        if let Some(home) = self.reg_home_for(var) {
            match ty.size() {
                8 if (i32::MIN as i128..=i32::MAX as i128).contains(&value) => {
                    self.emit(&format!("    movq ${}, {}", value, home));
                }
                8 => {
                    self.emit(&format!("    movabsq ${}, {}", value, home));
                }
                4 => self.emit(&format!("    movl ${}, {}", value, Self::gpr32(home))),
                2 => self.emit(&format!("    movw ${}, {}", value, Self::gpr16(home))),
                1 => self.emit(&format!("    movb ${}, {}", value, Self::gpr8(home))),
                _ => {}
            }
            return;
        }

        let offset = self.var_offsets[&var];
        self.store_integer_immediate(value, offset, ty);
    }

    fn store_gpr_value_to_register(&mut self, src_reg: &str, dst_reg: &str, ty: &Type) {
        match ty.size() {
            8 if src_reg != dst_reg => {
                self.emit(&format!("    movq {}, {}", src_reg, dst_reg));
            }
            4 if Self::gpr32(src_reg) != Self::gpr32(dst_reg) => self.emit(&format!(
                "    movl {}, {}",
                Self::gpr32(src_reg),
                Self::gpr32(dst_reg)
            )),
            2 if Self::gpr16(src_reg) != Self::gpr16(dst_reg) => self.emit(&format!(
                "    movw {}, {}",
                Self::gpr16(src_reg),
                Self::gpr16(dst_reg)
            )),
            1 if Self::gpr8(src_reg) != Self::gpr8(dst_reg) => self.emit(&format!(
                "    movb {}, {}",
                Self::gpr8(src_reg),
                Self::gpr8(dst_reg)
            )),
            _ => {}
        }
    }

    fn load_register_value(&mut self, src_reg: &str, dst_reg: &str, ty: &Type) {
        let signed = ty.is_signed();
        match ty.size() {
            8 if src_reg != dst_reg => {
                self.emit(&format!("    movq {}, {}", src_reg, dst_reg));
            }
            4 if signed => {
                self.emit(&format!("    movslq {}, {}", Self::gpr32(src_reg), dst_reg));
            }
            4 => self.emit(&format!(
                "    movl {}, {}",
                Self::gpr32(src_reg),
                Self::gpr32(dst_reg)
            )),
            2 if signed => {
                self.emit(&format!("    movswq {}, {}", Self::gpr16(src_reg), dst_reg));
            }
            2 => self.emit(&format!("    movzwq {}, {}", Self::gpr16(src_reg), dst_reg)),
            1 if signed => {
                self.emit(&format!("    movsbq {}, {}", Self::gpr8(src_reg), dst_reg));
            }
            1 => self.emit(&format!("    movzbq {}, {}", Self::gpr8(src_reg), dst_reg)),
            _ => {}
        }
    }

    fn load_value(&mut self, val: &Value, reg: &str, ty: &Type) {
        if is_scalar_float(ty) {
            self.load_float_value(val, reg, ty);
            return;
        }

        match val {
            Value::ConstI64(n) => {
                self.emit(&format!("    movq ${}, {}", n, reg));
            }
            Value::ConstI32(n) => {
                self.emit(&format!("    movl ${}, {}", n, Self::gpr32(reg)));
            }
            Value::ConstI8(n) => {
                self.emit(&format!("    movq ${}, {}", n, reg));
            }
            Value::ConstBool(b) => {
                let n = if *b { 1 } else { 0 };
                self.emit(&format!("    movq ${}, {}", n, reg));
            }
            Value::ConstStr(s) => {
                // The data pointer of a string literal: the address of its
                // interned `.rodata` bytes, loaded RIP-relative.
                let label = self
                    .interned_strings
                    .get(s)
                    .cloned()
                    .expect("string literal interned in pre-pass");
                self.emit(&format!("    leaq {}(%rip), {}", label, reg));
            }
            Value::Function(name) => {
                let symbol = Self::closure_descriptor_label(name);
                self.emit(&format!("    leaq {}(%rip), {}", symbol, reg));
            }
            Value::FunctionEntry(name) => {
                let symbol = Self::mangle_name(name);
                self.emit(&format!("    leaq {}(%rip), {}", symbol, reg));
            }
            Value::Var(v) => {
                if let Some(home) = self.reg_home_for(*v) {
                    self.load_register_value(home, reg, ty);
                    return;
                }
                let offset = self.var_offsets[v];
                let addr = format!("{}(%rbp)", offset);
                self.load_memory_value(&addr, reg, ty);
            }
            Value::Global(name) => {
                let addr = format!("{}(%rip)", Self::mangle_name(name));
                self.load_memory_value(&addr, reg, ty);
            }
            _ => {}
        }
    }

    fn load_memory_value(&mut self, addr: &str, reg: &str, ty: &Type) {
        // Load the value into the full 64-bit register, extending narrower
        // types so upper bits are well-defined for the subsequent op/compare.
        // Signed types sign-extend; unsigned types (and bool/char) zero-extend.
        let signed = ty.is_signed();
        match ty.size() {
            8 => self.emit(&format!("    movq {}, {}", addr, reg)),
            4 if signed => self.emit(&format!("    movslq {}, {}", addr, reg)),
            // `movl` into the 32-bit sub-register zero-extends into the full
            // 64-bit register on x86_64.
            4 => self.emit(&format!("    movl {}, {}", addr, Self::gpr32(reg))),
            2 if signed => self.emit(&format!("    movswq {}, {}", addr, reg)),
            2 => self.emit(&format!("    movzwq {}, {}", addr, reg)),
            1 if signed => self.emit(&format!("    movsbq {}, {}", addr, reg)),
            1 => self.emit(&format!("    movzbq {}, {}", addr, reg)),
            _ => {}
        }
    }

    fn load_float_value(&mut self, val: &Value, reg: &str, ty: &Type) {
        let mov = scalar_float_move(ty);
        match val {
            Value::ConstF64(n) => {
                // Float literals are stored as `f64`; when materialized into an
                // `f32` slot we round the bit pattern to binary32 first so the
                // value matches IEEE-754 single precision.
                if matches!(ty, Type::F32) {
                    let bits = (*n as f32).to_bits();
                    self.emit(&format!("    movl ${:#x}, %eax", bits));
                    self.emit(&format!("    movd %eax, {}", reg));
                } else {
                    self.emit(&format!("    movabsq ${:#x}, %rax", n.to_bits()));
                    self.emit(&format!("    movq %rax, {}", reg));
                }
            }
            Value::Var(v) => {
                let offset = self.var_offsets[v];
                self.emit(&format!("    {} {}(%rbp), {}", mov, offset, reg));
            }
            Value::Global(name) => {
                self.emit(&format!(
                    "    {} {}(%rip), {}",
                    mov,
                    Self::mangle_name(name),
                    reg
                ));
            }
            _ => {}
        }
    }

    fn store_gpr_value(&mut self, reg: &str, offset: i32, ty: &Type) {
        match ty.size() {
            8 => self.emit(&format!("    movq {}, {}(%rbp)", reg, offset)),
            4 => self.emit(&format!("    movl {}, {}(%rbp)", Self::gpr32(reg), offset)),
            2 => self.emit(&format!("    movw {}, {}(%rbp)", Self::gpr16(reg), offset)),
            1 => self.emit(&format!("    movb {}, {}(%rbp)", Self::gpr8(reg), offset)),
            _ => {}
        }
    }

    fn store_value_to_addr(&mut self, addr: &str, src: &Value, ty: &Type) {
        if is_scalar_float(ty) {
            let mov = scalar_float_move(ty);
            self.load_value(src, "%xmm0", ty);
            self.emit(&format!("    {} %xmm0, {}", mov, addr));
            return;
        }

        match src {
            Value::ConstI64(n) => self.store_integer_immediate_to_addr(*n as i128, addr, ty),
            Value::ConstI32(n) => self.store_integer_immediate_to_addr(*n as i128, addr, ty),
            Value::ConstI8(n) => self.store_integer_immediate_to_addr(*n as i128, addr, ty),
            Value::ConstBool(b) => {
                let n = if *b { 1 } else { 0 };
                self.store_integer_immediate_to_addr(n, addr, ty);
            }
            _ => {
                self.load_value(src, "%rax", ty);
                self.store_gpr_value_to_addr("%rax", addr, ty);
            }
        }
    }

    fn store_gpr_value_to_addr(&mut self, reg: &str, addr: &str, ty: &Type) {
        match ty.size() {
            8 => self.emit(&format!("    movq {}, {}", reg, addr)),
            4 => self.emit(&format!("    movl {}, {}", Self::gpr32(reg), addr)),
            2 => self.emit(&format!("    movw {}, {}", Self::gpr16(reg), addr)),
            1 => self.emit(&format!("    movb {}, {}", Self::gpr8(reg), addr)),
            _ => {}
        }
    }

    fn store_integer_immediate(&mut self, value: i128, offset: i32, ty: &Type) {
        match ty.size() {
            8 if (i32::MIN as i128..=i32::MAX as i128).contains(&value) => {
                self.emit(&format!("    movq ${}, {}(%rbp)", value, offset));
            }
            8 => {
                self.emit(&format!("    movabsq ${}, %rax", value));
                self.emit(&format!("    movq %rax, {}(%rbp)", offset));
            }
            4 => self.emit(&format!("    movl ${}, {}(%rbp)", value, offset)),
            2 => self.emit(&format!("    movw ${}, {}(%rbp)", value, offset)),
            1 => self.emit(&format!("    movb ${}, {}(%rbp)", value, offset)),
            _ => {}
        }
    }

    fn store_integer_immediate_to_addr(&mut self, value: i128, addr: &str, ty: &Type) {
        match ty.size() {
            8 if (i32::MIN as i128..=i32::MAX as i128).contains(&value) => {
                self.emit(&format!("    movq ${}, {}", value, addr));
            }
            8 => {
                self.emit(&format!("    movabsq ${}, %rax", value));
                self.emit(&format!("    movq %rax, {}", addr));
            }
            4 => self.emit(&format!("    movl ${}, {}", value, addr)),
            2 => self.emit(&format!("    movw ${}, {}", value, addr)),
            1 => self.emit(&format!("    movb ${}, {}", value, addr)),
            _ => {}
        }
    }

    fn store_xmm_value(&mut self, reg: &str, offset: i32, ty: &Type) {
        let mov = scalar_float_move(ty);
        self.emit(&format!("    {} {}, {}(%rbp)", mov, reg, offset));
    }

    fn emit_integer_divmod(&mut self, ty: &Type, signed: bool, want_remainder: bool) {
        match ty.size() {
            1 => {
                if signed {
                    self.emit("    cbw");
                    self.emit("    idivb %cl");
                } else {
                    self.emit("    andw $0x00ff, %ax");
                    self.emit("    divb %cl");
                }
                if want_remainder {
                    self.emit("    movb %ah, %al");
                }
            }
            2 => {
                if signed {
                    self.emit("    cwd");
                    self.emit("    idivw %cx");
                } else {
                    self.emit("    xorw %dx, %dx");
                    self.emit("    divw %cx");
                }
                if want_remainder {
                    self.emit("    movw %dx, %ax");
                }
            }
            4 => {
                if signed {
                    self.emit("    cdq");
                    self.emit("    idivl %ecx");
                } else {
                    self.emit("    xorl %edx, %edx");
                    self.emit("    divl %ecx");
                }
                if want_remainder {
                    self.emit("    movl %edx, %eax");
                }
            }
            _ => {
                if signed {
                    self.emit("    cqo");
                    self.emit("    idivq %rcx");
                } else {
                    self.emit("    xorq %rdx, %rdx");
                    self.emit("    divq %rcx");
                }
                if want_remainder {
                    self.emit("    movq %rdx, %rax");
                }
            }
        }
    }

    fn generate_float_binop(
        &mut self,
        dst: VarId,
        op: &IrBinOp,
        lhs: &Value,
        rhs: &Value,
        operand_ty: &Type,
        result_ty: &Type,
    ) {
        self.load_value(lhs, "%xmm0", operand_ty);
        self.load_value(rhs, "%xmm1", operand_ty);

        match op {
            IrBinOp::Add | IrBinOp::Sub | IrBinOp::Mul | IrBinOp::Div => {
                let mnemonic = scalar_float_arith(op, operand_ty);
                self.emit(&format!("    {} %xmm1, %xmm0", mnemonic));
            }
            IrBinOp::Eq | IrBinOp::Ne | IrBinOp::Lt | IrBinOp::Le | IrBinOp::Gt | IrBinOp::Ge => {
                let cmp = scalar_float_compare(operand_ty);
                self.emit(&format!("    {} %xmm1, %xmm0", cmp));
                let setcc = match op {
                    IrBinOp::Eq => "sete",
                    IrBinOp::Ne => "setne",
                    IrBinOp::Lt => "setb",
                    IrBinOp::Le => "setbe",
                    IrBinOp::Gt => "seta",
                    IrBinOp::Ge => "setae",
                    _ => unreachable!(),
                };
                self.emit(&format!("    {} %al", setcc));
                self.emit("    movzbq %al, %rax");
                self.store_gpr_value_to_var(dst, "%rax", result_ty);
                return;
            }
            // Integer-only operators (modulo, logical and bitwise/shift) are
            // not defined on floats and are rejected by validation before
            // codegen.
            IrBinOp::Mod
            | IrBinOp::And
            | IrBinOp::Or
            | IrBinOp::BitAnd
            | IrBinOp::BitOr
            | IrBinOp::BitXor
            | IrBinOp::Shl
            | IrBinOp::Shr => {}
        }

        self.store_xmm_value_to_var(dst, "%xmm0", operand_ty);
    }

    fn binop_operand_ty(&self, op: &IrBinOp, lhs: &Value, rhs: &Value, result_ty: &Type) -> Type {
        match op {
            IrBinOp::Eq | IrBinOp::Ne | IrBinOp::Lt | IrBinOp::Le | IrBinOp::Gt | IrBinOp::Ge => {
                self.value_type(lhs)
                    .or_else(|| self.value_type(rhs))
                    .unwrap_or_else(|| result_ty.clone())
            }
            IrBinOp::BitAnd | IrBinOp::BitOr | IrBinOp::BitXor | IrBinOp::Shl | IrBinOp::Shr => {
                self.value_type(lhs).unwrap_or_else(|| result_ty.clone())
            }
            _ => result_ty.clone(),
        }
    }

    fn value_type(&self, val: &Value) -> Option<Type> {
        match val {
            Value::ConstI64(_) => Some(Type::I64),
            Value::ConstI32(_) => Some(Type::I32),
            Value::ConstI8(_) => Some(Type::I8),
            Value::ConstF64(_) => Some(Type::F64),
            Value::ConstBool(_) => Some(Type::Bool),
            Value::ConstUnit => Some(Type::Unit),
            // A `ConstStr` operand is the raw data pointer of a string literal.
            Value::ConstStr(_) => Some(Type::U64),
            Value::Function(_) | Value::FunctionEntry(_) => Some(Type::U64),
            Value::Var(v) => self.var_types.get(v).cloned(),
            Value::Global(name) => self.global_types.get(name).cloned(),
        }
    }

    /// Map a 64-bit register name (e.g. `%rax`) to its 32-bit sub-register
    /// (`%eax`). A `movl` into the 32-bit form zero-extends into the full
    /// 64-bit register on x86_64.
    fn gpr32(reg: &str) -> &str {
        match reg {
            "%rax" => "%eax",
            "%rcx" => "%ecx",
            "%rdx" => "%edx",
            "%rbx" => "%ebx",
            "%rdi" => "%edi",
            "%rsi" => "%esi",
            "%r8" => "%r8d",
            "%r9" => "%r9d",
            "%r10" => "%r10d",
            "%r11" => "%r11d",
            "%r12" => "%r12d",
            "%r13" => "%r13d",
            "%r14" => "%r14d",
            "%r15" => "%r15d",
            _ => reg,
        }
    }

    /// Map a 64-bit register name to its 16-bit sub-register (`%rax` -> `%ax`).
    fn gpr16(reg: &str) -> &str {
        match reg {
            "%rax" => "%ax",
            "%rcx" => "%cx",
            "%rdx" => "%dx",
            "%rbx" => "%bx",
            "%rsi" => "%si",
            "%rdi" => "%di",
            "%r8" => "%r8w",
            "%r9" => "%r9w",
            "%r10" => "%r10w",
            "%r11" => "%r11w",
            "%r12" => "%r12w",
            "%r13" => "%r13w",
            "%r14" => "%r14w",
            "%r15" => "%r15w",
            _ => reg,
        }
    }

    /// Map a 64-bit register name to its 8-bit (low byte) sub-register
    /// (`%rax`->`%al`).
    fn gpr8(reg: &str) -> &str {
        match reg {
            "%rax" => "%al",
            "%rcx" => "%cl",
            "%rdx" => "%dl",
            "%rbx" => "%bl",
            "%rdi" => "%dil",
            "%rsi" => "%sil",
            "%r8" => "%r8b",
            "%r9" => "%r9b",
            "%r10" => "%r10b",
            "%r11" => "%r11b",
            "%r12" => "%r12b",
            "%r13" => "%r13b",
            "%r14" => "%r14b",
            "%r15" => "%r15b",
            _ => reg,
        }
    }

    fn gpr_sized<'a>(reg: &'a str, ty: &Type) -> &'a str {
        match ty.size() {
            1 => Self::gpr8(reg),
            2 => Self::gpr16(reg),
            4 => Self::gpr32(reg),
            _ => reg,
        }
    }

    fn int_instruction_suffix(ty: &Type) -> &'static str {
        match ty.size() {
            1 => "b",
            2 => "w",
            4 => "l",
            _ => "q",
        }
    }

    fn emit(&mut self, line: &str) {
        self.output.push_str(line);
        self.output.push('\n');
    }

    fn emit_many(&mut self, lines: &[&str]) {
        for line in lines {
            self.emit(line);
        }
    }

    fn mangle_name(name: &str) -> String {
        // Simple name mangling
        if name == "main" {
            "main".into()
        } else {
            format!("_tl_{}", Self::asm_safe_symbol_name(name))
        }
    }

    fn asm_safe_symbol_name(name: &str) -> String {
        let mut out = String::new();
        for ch in name.chars() {
            match ch {
                'A'..='Z' | 'a'..='z' | '0'..='9' | '_' => out.push(ch),
                '-' => out.push('_'),
                '?' => out.push_str("_question"),
                '!' => out.push_str("_bang"),
                '+' => out.push_str("_plus"),
                '*' => out.push_str("_star"),
                '/' => out.push_str("_slash"),
                '=' => out.push_str("_eq"),
                '<' => out.push_str("_lt"),
                '>' => out.push_str("_gt"),
                ':' => out.push_str("_colon"),
                _ => out.push_str(&format!("_u{:x}", ch as u32)),
            }
        }
        out
    }

    fn closure_descriptor_label(name: &str) -> String {
        format!(".L_tl_fn_desc_{}", Self::asm_safe_symbol_name(name))
    }

    fn closure_entry_label(name: &str) -> String {
        format!(".L_tl_fn_entry_{}", Self::asm_safe_symbol_name(name))
    }

    fn call_symbol(&self, name: &str) -> String {
        if self.runtime_print_names.contains(name) {
            Self::runtime_symbol(name).unwrap_or_else(|| Self::mangle_name(name))
        } else if name == "tl_alloc" && self.needs_alloc_runtime {
            // The backend-provided bump allocator is referenced by its raw
            // runtime symbol, not a language-level builtin alias, so it resolves
            // to itself rather than being mangled to `_tl_tl_alloc`. When a
            // program defines its own `tl_alloc`, `needs_alloc_runtime` is
            // false and the call is mangled like any other user function.
            "tl_alloc".into()
        } else if name == REGION_MARK_RUNTIME_SYMBOL && self.needs_region_mark_runtime {
            REGION_MARK_RUNTIME_SYMBOL.into()
        } else if name == REGION_RESET_RUNTIME_SYMBOL && self.needs_region_reset_runtime {
            REGION_RESET_RUNTIME_SYMBOL.into()
        } else if name == "tl_oob_abort" && self.needs_oob_runtime {
            // The backend-provided abort runtime resolves to its raw symbol.
            "tl_oob_abort".into()
        } else if name == "tl_div_abort" && self.needs_div_runtime {
            "tl_div_abort".into()
        } else if name == "tl_shift_abort" && self.needs_shift_runtime {
            "tl_shift_abort".into()
        } else if name == ABORT_RUNTIME_SYMBOL && self.needs_abort_runtime {
            // The backend-provided message-abort runtime (emitted on demand by
            // `panic`/`error`) resolves to its private assembler label rather
            // than being mangled as a TypeLisp function.
            ABORT_RUNTIME_SYMBOL.into()
        } else if name == "tl_string_eq" && self.needs_string_eq_runtime {
            // The backend-provided string-equality helper, like `tl_alloc`, is
            // referenced by its raw runtime symbol so it resolves to itself
            // rather than being mangled to `_tl_tl_string_eq`.
            "tl_string_eq".into()
        } else if name == "tl_string_to_int" && self.needs_string_to_int_runtime {
            // The backend-provided decimal-parse helper, like `tl_string_eq`, is
            // referenced by its raw runtime symbol so it resolves to itself
            // rather than being mangled to `_tl_tl_string_to_int`.
            "tl_string_to_int".into()
        } else if name == "tl_int_to_string" && self.needs_int_to_string_runtime {
            // The backend-provided integer-to-string helper resolves to its raw
            // runtime symbol rather than being mangled to `_tl_tl_int_to_string`.
            "tl_int_to_string".into()
        } else if name == "tl_substring" && self.needs_substring_runtime {
            // The backend-provided byte-slice helper resolves to its raw runtime
            // symbol rather than being mangled to `_tl_tl_substring`.
            "tl_substring".into()
        } else if name == "tl_string_concat" && self.needs_string_concat_runtime {
            // The backend-provided byte-append helper resolves to its raw runtime
            // symbol rather than being mangled to `_tl_tl_string_concat`.
            "tl_string_concat".into()
        } else if name == "tl_print_str" && self.needs_print_str_runtime {
            // The backend-provided print-string helper resolves to its raw
            // runtime symbol rather than being mangled to `_tl_tl_print_str`.
            "tl_print_str".into()
        } else if name == "tl_print_err" && self.needs_print_err_runtime {
            "tl_print_err".into()
        } else if name == ARG_COUNT_RUNTIME_SYMBOL && self.needs_arg_count_runtime {
            ARG_COUNT_RUNTIME_SYMBOL.into()
        } else if name == ARG_RUNTIME_SYMBOL && self.needs_arg_runtime {
            ARG_RUNTIME_SYMBOL.into()
        } else if name == READ_FILE_RUNTIME_SYMBOL && self.needs_read_file_runtime {
            READ_FILE_RUNTIME_SYMBOL.into()
        } else if name == WRITE_FILE_RUNTIME_SYMBOL && self.needs_write_file_runtime {
            WRITE_FILE_RUNTIME_SYMBOL.into()
        } else if name == FILE_EXISTS_RUNTIME_SYMBOL && self.needs_file_exists_runtime {
            FILE_EXISTS_RUNTIME_SYMBOL.into()
        } else if name == READ_FILE_STATUS_RUNTIME_SYMBOL && self.needs_read_file_runtime {
            READ_FILE_STATUS_RUNTIME_SYMBOL.into()
        } else if name == WRITE_FILE_STATUS_RUNTIME_SYMBOL && self.needs_write_file_runtime {
            WRITE_FILE_STATUS_RUNTIME_SYMBOL.into()
        } else if name == FILE_EXISTS_STATUS_RUNTIME_SYMBOL && self.needs_file_exists_runtime {
            FILE_EXISTS_STATUS_RUNTIME_SYMBOL.into()
        } else if name == FS_MKDIR_STATUS_RUNTIME_SYMBOL && self.needs_fs_runtime {
            FS_MKDIR_STATUS_RUNTIME_SYMBOL.into()
        } else if name == FS_REMOVE_FILE_STATUS_RUNTIME_SYMBOL && self.needs_fs_runtime {
            FS_REMOVE_FILE_STATUS_RUNTIME_SYMBOL.into()
        } else if name == FS_REMOVE_DIR_STATUS_RUNTIME_SYMBOL && self.needs_fs_runtime {
            FS_REMOVE_DIR_STATUS_RUNTIME_SYMBOL.into()
        } else if name == FS_PROCESS_ID_RUNTIME_SYMBOL && self.needs_fs_runtime {
            FS_PROCESS_ID_RUNTIME_SYMBOL.into()
        } else if name == ENV_VAR_EXISTS_RUNTIME_SYMBOL && self.needs_env_var_exists_runtime {
            ENV_VAR_EXISTS_RUNTIME_SYMBOL.into()
        } else if name == ENV_VAR_VALUE_RUNTIME_SYMBOL && self.needs_env_var_value_runtime {
            ENV_VAR_VALUE_RUNTIME_SYMBOL.into()
        } else if name == ENV_PATH_SEPARATOR_RUNTIME_SYMBOL && self.needs_env_path_separator_runtime
        {
            ENV_PATH_SEPARATOR_RUNTIME_SYMBOL.into()
        } else if name == PROCESS_OUTPUT_RUNTIME_SYMBOL && self.needs_process_output_runtime {
            PROCESS_OUTPUT_RUNTIME_SYMBOL.into()
        } else if name == READ_STDIN_LINE_RUNTIME_SYMBOL && self.needs_read_stdin_line_runtime {
            READ_STDIN_LINE_RUNTIME_SYMBOL.into()
        } else if name == READ_STDIN_BYTES_RUNTIME_SYMBOL && self.needs_read_stdin_bytes_runtime {
            READ_STDIN_BYTES_RUNTIME_SYMBOL.into()
        } else if name == STDIN_EOF_RUNTIME_SYMBOL && self.needs_stdin_eof_runtime {
            STDIN_EOF_RUNTIME_SYMBOL.into()
        } else if name == FLUSH_STDOUT_RUNTIME_SYMBOL && self.needs_flush_stdout_runtime {
            FLUSH_STDOUT_RUNTIME_SYMBOL.into()
        } else if self.extern_names.contains(name) {
            Self::extern_symbol(name)
        } else {
            Self::mangle_name(name)
        }
    }

    fn extern_symbol(name: &str) -> String {
        Self::asm_safe_symbol_name(name)
    }

    fn runtime_symbol(name: &str) -> Option<String> {
        match name {
            "print" => Some("tl_print_i64".into()),
            "print-bool" => Some("tl_print_bool".into()),
            "print-float" => Some("tl_print_f64".into()),
            "print-char" => Some("tl_print_char".into()),
            "print-newline" => Some("tl_print_newline".into()),
            _ => None,
        }
    }

    fn is_defined_print_runtime_symbol(symbol: &str) -> bool {
        matches!(
            symbol,
            "tl_print_i64"
                | "tl_print_bool"
                | "tl_print_f64"
                | "tl_print_char"
                | "tl_print_newline"
        )
    }

    /// Qualify a bare IR block label (e.g. `then.0`) with the current function's
    /// mangled symbol so it matches the emitted block label `{fn}.{block}:`.
    fn block_label(&self, label: &str) -> String {
        format!("{}.{}", self.current_fn, label)
    }
}

/// Generate x86_64 assembly for a (lowered + optimized) IR program.
///
/// Returns `Err` with a clear, user-facing message if the program uses
/// constructs the backend cannot yet faithfully compile, rather than emitting
/// silently incorrect assembly.
#[allow(dead_code)]
pub fn generate_assembly(program: &Program) -> Result<String, String> {
    generate_assembly_for_target(program, BackendTarget::default())
}

pub fn generate_assembly_for_target(
    program: &Program,
    target: BackendTarget,
) -> Result<String, String> {
    target.validate_mode()?;
    validate_program_for_target(program, target)?;
    validate_target_runtime_support(program, target)?;
    let mut backend = X86_64Backend::with_target(target);
    Ok(backend.generate(program))
}

/// Generate x86_64 assembly, rendering backend validation failures as
/// source-located diagnostics when the lowerer supplied provenance.
#[allow(dead_code)]
pub fn generate_assembly_with_spans(
    program: &Program,
    source_spans: &SourceSpans,
) -> Result<String, BackendError> {
    generate_assembly_with_spans_for_target(program, source_spans, BackendTarget::default())
}

pub fn generate_assembly_with_spans_for_target(
    program: &Program,
    source_spans: &SourceSpans,
    target: BackendTarget,
) -> Result<String, BackendError> {
    target.validate_mode().map_err(BackendError::unspanned)?;
    validate_program_source_spans(program, source_spans, target)?;
    validate_program_for_target(program, target).map_err(BackendError::unspanned)?;
    validate_target_runtime_support(program, target).map_err(BackendError::unspanned)?;
    let mut backend = X86_64Backend::with_target(target);
    Ok(backend.generate(program))
}

fn validate_target_runtime_support(program: &Program, target: BackendTarget) -> Result<(), String> {
    let needs_region_runtime = X86_64Backend::needs_region_mark_runtime(program)
        || X86_64Backend::needs_region_reset_runtime(program);

    if needs_region_runtime && !target.supports_region_runtime() {
        return Err(
            "backend: tl_region_mark/tl_region_reset runtime helpers are only supported for linux-x86_64-system-v targets"
                .into(),
        );
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ast;
    use crate::ir::*;
    use crate::lower::{
        LowerMode, lower_program, lower_program_with_spans, lower_program_with_spans_for_mode,
    };
    use crate::optimizer::Optimizer;
    use crate::parser::parse;
    use std::collections::BTreeSet;
    #[cfg(target_os = "linux")]
    use std::process::Command;

    /// Compile source through the full pipeline (parse -> lower -> optimize ->
    /// codegen), returning generated assembly text.
    fn compile_ok(source: &str) -> String {
        let prog = parse(source).expect("parse failed");
        let mut ir = lower_program(&prog);
        Optimizer::optimize(&mut ir);
        generate_assembly(&ir).expect("backend should accept this program")
    }

    fn compile_ok_for_target(source: &str, target: BackendTarget) -> String {
        let prog = parse(source).expect("parse failed");
        let mut ir =
            lower_program_with_spans_for_mode(&prog, lower_mode_for_target(target)).program;
        Optimizer::optimize(&mut ir);
        generate_assembly_for_target(&ir, target).expect("backend should accept this program")
    }

    fn lower_mode_for_target(target: BackendTarget) -> LowerMode {
        match target.mode {
            BackendMode::Scalar => LowerMode::Scalar,
            BackendMode::Avx2 => LowerMode::Avx2,
            BackendMode::Avx512 => LowerMode::Avx512,
        }
    }

    fn var_set(vars: &[VarId]) -> BTreeSet<VarId> {
        vars.iter().copied().collect()
    }

    fn assert_var_set(actual: &BTreeSet<VarId>, expected: &[VarId]) {
        let expected = var_set(expected);
        assert_eq!(actual, &expected);
    }

    fn assert_live_after(
        analysis: &liveness::FunctionLiveness,
        label: &str,
        instruction_index: usize,
        expected: &[VarId],
    ) {
        let actual = analysis
            .live_after(label, instruction_index)
            .unwrap_or_else(|| panic!("missing live-after set for {label}[{instruction_index}]"));
        assert_var_set(actual, expected);
    }

    fn assert_windows_runtime_has_no_linux_syscalls(asm: &str) {
        assert!(!asm.contains("    syscall"), "asm:\n{}", asm);
        assert!(!asm.contains("\n_start:"), "asm:\n{}", asm);
        assert!(!asm.contains("    movq $60, %rax"), "asm:\n{}", asm);
    }

    /// Compile source expecting the backend to reject it.
    fn compile_err(source: &str) -> String {
        let prog = parse(source).expect("parse failed");
        let mut ir = lower_program(&prog);
        Optimizer::optimize(&mut ir);
        generate_assembly(&ir).expect_err("backend should reject this program")
    }

    #[test]
    fn test_backend_default_target_is_linux_x86_64_system_v() {
        let target = BackendTarget::default();
        assert_eq!(target, BackendTarget::linux_x86_64_system_v());
        assert_eq!(target.arch, BackendArch::X86_64);
        assert_eq!(target.os, BackendOs::Linux);
        assert_eq!(target.abi, BackendAbi::SystemV);
        assert_eq!(target.mode, BackendMode::Scalar);

        let calling_convention = target.calling_convention();
        let expected_integer_regs: &[&str] = &["%rdi", "%rsi", "%rdx", "%rcx", "%r8", "%r9"];
        let expected_float_regs: &[&str] = &[
            "%xmm0", "%xmm1", "%xmm2", "%xmm3", "%xmm4", "%xmm5", "%xmm6", "%xmm7",
        ];
        assert_eq!(calling_convention.integer_arg_regs, expected_integer_regs);
        assert_eq!(calling_convention.float_arg_regs, expected_float_regs);
        assert_eq!(calling_convention.incoming_stack_arg_offset(0), 16);
        assert_eq!(calling_convention.outgoing_stack_arg_offset(1), 8);
        assert_eq!(calling_convention.outgoing_stack_arg_space(2), 16);
        assert_eq!(calling_convention.shared_arg_register_slots, None);
        assert_eq!(calling_convention.return_gpr, "%rax");
        assert_eq!(calling_convention.return_float_reg, "%xmm0");

        let entry = target.entry_policy();
        assert_eq!(entry.symbol, Some("_start"));
        assert_eq!(entry.exit_syscall_number, Some(60));
        assert_eq!(entry.exit_status_reg, "%rdi");

        let runtime = target.runtime_policy();
        assert!(runtime.emits_linux_syscall_helpers);
        assert!(!runtime.emits_windows_runtime_helpers);
        assert!(runtime.uses_libc_print_runtime);

        let toolchain = target.toolchain();
        assert_eq!(toolchain.assembler, "as");
        assert_eq!(toolchain.linker, "ld");
        assert_eq!(
            toolchain.dynamic_linker,
            Some("/lib64/ld-linux-x86-64.so.2")
        );
        assert_eq!(toolchain.libraries, &["-lc"]);
    }

    #[test]
    fn test_backend_mode_names_parse_and_display() {
        assert_eq!(BackendMode::parse("scalar"), Some(BackendMode::Scalar));
        assert_eq!(BackendMode::parse("avx2"), Some(BackendMode::Avx2));
        assert_eq!(BackendMode::parse("avx512"), Some(BackendMode::Avx512));
        assert_eq!(BackendMode::parse("sse2"), None);
        assert_eq!(BackendMode::Scalar.to_string(), "scalar");
        assert_eq!(BackendMode::Avx2.to_string(), "avx2");
        assert_eq!(BackendMode::Avx512.to_string(), "avx512");
    }

    #[test]
    fn test_backend_target_names_parse_display_and_extensions() {
        assert_eq!(
            BackendTarget::parse("linux-x86_64"),
            Some(BackendTarget::linux_x86_64_system_v())
        );
        assert_eq!(
            BackendTarget::parse("linux_x86_64"),
            Some(BackendTarget::linux_x86_64_system_v())
        );
        assert_eq!(
            BackendTarget::parse("windows-x86_64"),
            Some(BackendTarget::windows_x86_64())
        );
        assert_eq!(
            BackendTarget::parse("windows_x86_64"),
            Some(BackendTarget::windows_x86_64())
        );
        assert_eq!(BackendTarget::parse("macos-x86_64"), None);

        let linux = BackendTarget::linux_x86_64_system_v();
        assert_eq!(linux.to_string(), "linux-x86_64");
        assert_eq!(linux.object_extension(), "o");
        assert_eq!(linux.executable_extension(), None);

        let windows = BackendTarget::windows_x86_64();
        assert_eq!(windows.to_string(), "windows-x86_64");
        assert_eq!(windows.object_extension(), "obj");
        assert_eq!(windows.executable_extension(), Some("exe"));
    }

    #[test]
    fn test_windows_x64_target_policy() {
        let target = BackendTarget::windows_x86_64();
        assert_eq!(target.arch, BackendArch::X86_64);
        assert_eq!(target.os, BackendOs::Windows);
        assert_eq!(target.abi, BackendAbi::WindowsX64);
        assert_eq!(target.mode, BackendMode::Scalar);

        let calling_convention = target.calling_convention();
        assert_eq!(
            calling_convention.integer_arg_regs,
            &["%rcx", "%rdx", "%r8", "%r9"]
        );
        assert_eq!(
            calling_convention.float_arg_regs,
            &["%xmm0", "%xmm1", "%xmm2", "%xmm3"]
        );
        assert_eq!(calling_convention.shared_arg_register_slots, Some(4));
        assert_eq!(calling_convention.incoming_stack_arg_offset(0), 48);
        assert_eq!(calling_convention.outgoing_stack_arg_offset(0), 32);
        assert_eq!(calling_convention.outgoing_stack_arg_space(0), 32);
        assert_eq!(calling_convention.outgoing_stack_arg_space(1), 48);
        assert_eq!(calling_convention.return_gpr, "%rax");
        assert_eq!(calling_convention.return_float_reg, "%xmm0");

        let entry = target.entry_policy();
        assert_eq!(entry.symbol, None);
        assert_eq!(entry.exit_syscall_number, None);
        assert_eq!(entry.exit_status_reg, "%rcx");

        let runtime = target.runtime_policy();
        assert!(!runtime.emits_linux_syscall_helpers);
        assert!(runtime.emits_windows_runtime_helpers);
        assert!(runtime.uses_libc_print_runtime);

        let toolchain = target.toolchain();
        assert_eq!(toolchain.assembler, "clang");
        assert_eq!(toolchain.linker, "lld-link");
        assert_eq!(toolchain.dynamic_linker, None);
        assert_eq!(
            toolchain.libraries,
            &["msvcrt.lib", "legacy_stdio_definitions.lib"]
        );
    }

    #[test]
    fn test_explicit_linux_target_matches_default_for_register_and_stack_calls() {
        let source = r#"
            (define (sum8
                [a : i64] [b : i64] [c : i64] [d : i64]
                [e : i64] [f : i64] [g : i64] [h : i64]) : i64
              (+ (+ (+ (+ (+ (+ (+ a b) c) d) e) f) g) h))
            (define (pick9
                [a : f64] [b : f64] [c : f64] [d : f64] [e : f64]
                [f : f64] [g : f64] [h : f64] [i : f64]) : f64
              i)
            (define (main) : i64
              (begin
                (pick9 1.0 2.0 3.0 4.0 5.0 6.0 7.0 8.0 9.0)
                (sum8 1 2 3 4 5 6 7 8)))
            "#;

        let default_asm = compile_ok(source);
        let explicit_asm = compile_ok_for_target(source, BackendTarget::linux_x86_64_system_v());
        assert_eq!(default_asm, explicit_asm);
        assert!(
            default_asm.contains("    movq 16(%rbp), %r11"),
            "asm:\n{}",
            default_asm
        );
        assert!(
            default_asm.contains("    movsd 16(%rbp), %xmm15"),
            "asm:\n{}",
            default_asm
        );
        assert!(
            default_asm.contains("    call _tl_sum8"),
            "asm:\n{}",
            default_asm
        );
        assert!(
            default_asm.contains("    call _tl_pick9"),
            "asm:\n{}",
            default_asm
        );
    }

    #[test]
    fn test_explicit_scalar_mode_matches_default_output() {
        let source = "(define (main) : i64 (+ 40 2))";

        let default_asm = compile_ok(source);
        let scalar_asm = compile_ok_for_target(
            source,
            BackendTarget::default().with_mode(BackendMode::Scalar),
        );
        assert_eq!(default_asm, scalar_asm);
    }

    #[test]
    fn test_avx2_backend_mode_accepts_scalar_ir() {
        let asm = compile_ok_for_target(
            "(define (main) : i64 42)",
            BackendTarget::default().with_mode(BackendMode::Avx2),
        );

        assert!(asm.contains("main:"), "asm:\n{}", asm);
        assert!(asm.contains("vzeroupper"), "asm:\n{}", asm);
    }

    #[test]
    fn test_avx2_foreach_maps_emit_ymm_instruction_families() {
        let asm = compile_ok_for_target(
            r#"
            (define (fill-i64 [a : (Array i64)]
                              [b : (Array i64)]
                              [out : (Array i64)]
                              [n : i64]) : unit
              (foreach ([i : i64 0 n])
                (array-set! out i (+ (array-ref a i) (array-ref b i)))))

            (define (fill-i32 [a : (Array i32)]
                              [b : (Array i32)]
                              [out : (Array i32)]
                              [n : i64]) : unit
              (foreach ([i : i64 0 n])
                (array-set! out i (+ (array-ref a i) (array-ref b i)))))

            (define (fill-f64 [a : (Array f64)]
                              [b : (Array f64)]
                              [out : (Array f64)]
                              [n : i64]) : unit
              (foreach ([i : i64 0 n])
                (array-set! out i (+ (array-ref a i) (array-ref b i)))))

            (define (main) : i64 42)
            "#,
            BackendTarget::default().with_mode(BackendMode::Avx2),
        );

        for expected in ["%ymm", "vmovdqu", "vmovupd", "vpaddq", "vpaddd", "vaddpd"] {
            assert!(asm.contains(expected), "missing {expected}; asm:\n{asm}");
        }
        assert!(
            asm.contains("foreach_tail_header"),
            "expected scalar cleanup tail; asm:\n{}",
            asm
        );
    }

    #[test]
    fn test_avx2_spmd_reduce_sum_emits_horizontal_instruction_families() {
        let asm = compile_ok_for_target(
            r#"
            (define (sum-i64 [xs : (Array i64)] [n : i64]) : i64
              (spmd-reduce sum ([i : i64 0 n]) 0 (array-ref xs i)))

            (define (sum-i32 [xs : (Array i32)] [n : i64]) : i32
              (spmd-reduce sum ([i : i64 0 n]) (cast 0 : i32) (array-ref xs i)))

            (define (main) : i64 42)
            "#,
            BackendTarget::default().with_mode(BackendMode::Avx2),
        );

        for expected in [
            "%ymm",
            "vmovdqu",
            "vextracti128",
            "vpaddq",
            "vpaddd",
            "vpsrldq",
            "    vmovq %xmm0, %rax",
            "    vmovd %xmm0, %eax",
        ] {
            assert!(asm.contains(expected), "missing {expected}; asm:\n{asm}");
        }
        assert!(
            asm.contains("reduce_avx2_header"),
            "expected AVX2 reduction loop; asm:\n{}",
            asm
        );
        assert!(
            asm.contains("reduce_tail_header"),
            "expected scalar cleanup tail; asm:\n{}",
            asm
        );
    }

    #[test]
    fn test_avx512_foreach_maps_emit_zmm_kmask_instruction_families() {
        // Source-level `foreach` lowered with `BackendMode::Avx512` must produce
        // AVX-512 evidence from the real lowerer path (#508), not only from
        // hand-built IR (#507). This proves the end-to-end source -> AVX-512
        // assembly path for i64, i32, and f64 kernel shapes.
        let asm = compile_ok_for_target(
            r#"
            (define (fill-i64 [a : (Array i64)]
                              [b : (Array i64)]
                              [out : (Array i64)]
                              [n : i64]) : unit
              (foreach ([i : i64 0 n])
                (array-set! out i (+ (array-ref a i) (array-ref b i)))))

            (define (fill-i32 [a : (Array i32)]
                              [b : (Array i32)]
                              [out : (Array i32)]
                              [n : i64]) : unit
              (foreach ([i : i64 0 n])
                (array-set! out i (+ (array-ref a i) (array-ref b i)))))

            (define (fill-f64 [a : (Array f64)]
                              [b : (Array f64)]
                              [out : (Array f64)]
                              [n : i64]) : unit
              (foreach ([i : i64 0 n])
                (array-set! out i (+ (array-ref a i) (array-ref b i)))))

            (define (main) : i64 42)
            "#,
            BackendTarget::default().with_mode(BackendMode::Avx512),
        );

        // 512-bit registers and the i64/i32/f64 add instruction families.
        for expected in ["%zmm", "vpaddq", "vpaddd", "vaddpd"] {
            assert!(asm.contains(expected), "missing {expected}; asm:\n{asm}");
        }
        // Unmasked ZMM moves must use the size-tagged EVEX encodings; plain
        // `vmovdqu` has no 512-bit form and is rejected by LLVM/clang.
        for expected in ["vmovdqu64", "vmovdqu32", "vmovupd"] {
            assert!(asm.contains(expected), "missing {expected}; asm:\n{asm}");
        }
        // k-mask predicated tail: a real `%k1` predicate (never the implicit
        // no-mask `%k0`), with zero-masked loads and merge-masked stores for all
        // three element widths.
        assert!(
            asm.contains("kmovw %eax, %k1"),
            "expected kmovw into k1; asm:\n{asm}"
        );
        assert!(
            !asm.contains("%k0"),
            "k0 must not be used as an active mask; asm:\n{asm}"
        );
        for expected in [
            "vmovdqu64 (%rax,%rcx,8), %zmm0{%k1}{z}",
            "vmovdqu64 %zmm0, (%rax,%rcx,8){%k1}",
            "vmovdqu32 (%rax,%rcx,4), %zmm0{%k1}{z}",
            "vmovdqu32 %zmm0, (%rax,%rcx,4){%k1}",
            "vmovupd (%rax,%rcx,8), %zmm0{%k1}{z}",
            "vmovupd %zmm0, (%rax,%rcx,8){%k1}",
        ] {
            assert!(
                asm.contains(expected),
                "missing masked move {expected}; asm:\n{asm}"
            );
        }
        // The AVX-512 lowerer uses a k-mask predicated tail, not the AVX2-style
        // scalar cleanup loop.
        assert!(
            asm.contains("foreach_avx512_tail"),
            "expected AVX-512 k-mask tail labels; asm:\n{asm}"
        );
        assert!(
            !asm.contains("foreach_tail_header"),
            "AVX-512 path must not fall back to the scalar cleanup tail; asm:\n{asm}"
        );
    }

    #[test]
    fn test_avx512_backend_mode_with_spans_is_accepted() {
        let prog = parse("(define (main) : i64 42)").expect("parse failed");
        let mut lowered = lower_program_with_spans(&prog);
        Optimizer::optimize(&mut lowered.program);
        let asm = generate_assembly_with_spans_for_target(
            &lowered.program,
            &lowered.source_spans,
            BackendTarget::default().with_mode(BackendMode::Avx512),
        )
        .expect("avx512 mode should be accepted for scalar IR");

        assert!(
            asm.contains("vzeroupper"),
            "AVX-512 epilogue should include vzeroupper"
        );
        assert!(
            !asm.contains("%zmm"),
            "scalar IR should not emit ZMM instructions: {}",
            asm
        );
    }

    #[test]
    fn test_avx512_vector_binop_load_store_emits_zmm_instructions() {
        // Hand-built IR with AVX-512 vector shapes to test backend
        // instruction selection without an AVX-512 lowerer.
        let func = Function {
            name: "vec_kernel".into(),
            params: vec![
                (0, Type::DynArray(Box::new(Type::I64))),
                (1, Type::DynArray(Box::new(Type::I64))),
                (2, Type::DynArray(Box::new(Type::I64))),
            ],
            ret: Type::Unit,
            locals: vec![
                (3, Type::Vector(Box::new(Type::I64), 8)),
                (4, Type::Vector(Box::new(Type::I64), 8)),
                (5, Type::Vector(Box::new(Type::I64), 8)),
            ],
            blocks: vec![BasicBlock {
                label: "entry".into(),
                instructions: vec![
                    Instruction::VectorLoad {
                        dst: 3,
                        base: Value::Var(0),
                        index: Value::ConstI64(0),
                        lanes: 8,
                        elem_ty: Type::I64,
                    },
                    Instruction::VectorLoad {
                        dst: 4,
                        base: Value::Var(1),
                        index: Value::ConstI64(0),
                        lanes: 8,
                        elem_ty: Type::I64,
                    },
                    Instruction::VectorBinOp {
                        dst: 5,
                        op: IrBinOp::Add,
                        lhs: Value::Var(3),
                        rhs: Value::Var(4),
                        lanes: 8,
                        elem_ty: Type::I64,
                    },
                    Instruction::VectorStore {
                        base: Value::Var(2),
                        index: Value::ConstI64(0),
                        value: Value::Var(5),
                        lanes: 8,
                        elem_ty: Type::I64,
                    },
                    Instruction::Return(None),
                ],
            }],
            entry: "entry".into(),
        };

        let program = Program {
            functions: vec![func],
            globals: vec![],
            externs: vec![],
        };

        let asm = generate_assembly_for_target(
            &program,
            BackendTarget::default().with_mode(BackendMode::Avx512),
        )
        .expect("AVX-512 backend should accept hand-built vector IR");

        assert!(asm.contains("%zmm0"), "expected %zmm0; asm:\n{}", asm);
        assert!(asm.contains("%zmm1"), "expected %zmm1; asm:\n{}", asm);
        assert!(asm.contains("vpaddq"), "expected vpaddq; asm:\n{}", asm);
        assert!(asm.contains("vmovdqu"), "expected vmovdqu; asm:\n{}", asm);
        assert!(
            asm.contains("vzeroupper"),
            "expected vzeroupper; asm:\n{}",
            asm
        );
    }

    #[test]
    fn test_avx512_f64_and_i32_shapes_emit_correct_zmm_instructions() {
        let func = Function {
            name: "vec_kernel".into(),
            params: vec![
                (0, Type::DynArray(Box::new(Type::F64))),
                (1, Type::DynArray(Box::new(Type::F64))),
                (2, Type::DynArray(Box::new(Type::F64))),
                (3, Type::DynArray(Box::new(Type::I32))),
                (4, Type::DynArray(Box::new(Type::I32))),
                (5, Type::DynArray(Box::new(Type::I32))),
            ],
            ret: Type::Unit,
            locals: vec![
                (6, Type::Vector(Box::new(Type::F64), 8)),
                (7, Type::Vector(Box::new(Type::F64), 8)),
                (8, Type::Vector(Box::new(Type::F64), 8)),
                (9, Type::Vector(Box::new(Type::I32), 16)),
                (10, Type::Vector(Box::new(Type::I32), 16)),
                (11, Type::Vector(Box::new(Type::I32), 16)),
            ],
            blocks: vec![BasicBlock {
                label: "entry".into(),
                instructions: vec![
                    Instruction::VectorLoad {
                        dst: 6,
                        base: Value::Var(0),
                        index: Value::ConstI64(0),
                        lanes: 8,
                        elem_ty: Type::F64,
                    },
                    Instruction::VectorLoad {
                        dst: 7,
                        base: Value::Var(1),
                        index: Value::ConstI64(0),
                        lanes: 8,
                        elem_ty: Type::F64,
                    },
                    Instruction::VectorBinOp {
                        dst: 8,
                        op: IrBinOp::Add,
                        lhs: Value::Var(6),
                        rhs: Value::Var(7),
                        lanes: 8,
                        elem_ty: Type::F64,
                    },
                    Instruction::VectorStore {
                        base: Value::Var(2),
                        index: Value::ConstI64(0),
                        value: Value::Var(8),
                        lanes: 8,
                        elem_ty: Type::F64,
                    },
                    Instruction::VectorLoad {
                        dst: 9,
                        base: Value::Var(3),
                        index: Value::ConstI64(0),
                        lanes: 16,
                        elem_ty: Type::I32,
                    },
                    Instruction::VectorLoad {
                        dst: 10,
                        base: Value::Var(4),
                        index: Value::ConstI64(0),
                        lanes: 16,
                        elem_ty: Type::I32,
                    },
                    Instruction::VectorBinOp {
                        dst: 11,
                        op: IrBinOp::Add,
                        lhs: Value::Var(9),
                        rhs: Value::Var(10),
                        lanes: 16,
                        elem_ty: Type::I32,
                    },
                    Instruction::VectorStore {
                        base: Value::Var(5),
                        index: Value::ConstI64(0),
                        value: Value::Var(11),
                        lanes: 16,
                        elem_ty: Type::I32,
                    },
                    Instruction::Return(None),
                ],
            }],
            entry: "entry".into(),
        };

        let program = Program {
            functions: vec![func],
            globals: vec![],
            externs: vec![],
        };

        let asm = generate_assembly_for_target(
            &program,
            BackendTarget::default().with_mode(BackendMode::Avx512),
        )
        .expect("AVX-512 backend should accept f64 and i32 vector IR");

        assert!(asm.contains("vaddpd"), "expected vaddpd; asm:\n{}", asm);
        assert!(asm.contains("vpaddd"), "expected vpaddd; asm:\n{}", asm);
        assert!(asm.contains("vmovupd"), "expected vmovupd; asm:\n{}", asm);
        assert!(asm.contains("vmovdqu"), "expected vmovdqu; asm:\n{}", asm);
        assert!(
            asm.contains("%zmm"),
            "expected %zmm registers; asm:\n{}",
            asm
        );
    }

    #[test]
    fn test_avx512_tail_mask_and_predicated_memory_emit_kmask_i64() {
        // Hand-built IR: build a tail mask, masked-load a tail, and masked-store
        // it back, exercising k-mask emission without a foreach lowerer.
        let func = Function {
            name: "masked_kernel".into(),
            params: vec![
                (0, Type::DynArray(Box::new(Type::I64))),
                (1, Type::DynArray(Box::new(Type::I64))),
                (2, Type::I64),
                (3, Type::I64),
            ],
            ret: Type::Unit,
            locals: vec![
                (4, Type::Mask(8)),
                (5, Type::Vector(Box::new(Type::I64), 8)),
            ],
            blocks: vec![BasicBlock {
                label: "entry".into(),
                instructions: vec![
                    Instruction::TailMask {
                        dst: 4,
                        index: Value::Var(3),
                        len: Value::Var(2),
                        lanes: 8,
                    },
                    Instruction::PredicatedLoad {
                        dst: 5,
                        base: Value::Var(0),
                        index: Value::Var(3),
                        mask: Value::Var(4),
                        lanes: 8,
                        elem_ty: Type::I64,
                    },
                    Instruction::PredicatedStore {
                        base: Value::Var(1),
                        index: Value::Var(3),
                        value: Value::Var(5),
                        mask: Value::Var(4),
                        lanes: 8,
                        elem_ty: Type::I64,
                    },
                    Instruction::Return(None),
                ],
            }],
            entry: "entry".into(),
        };

        let program = Program {
            functions: vec![func],
            globals: vec![],
            externs: vec![],
        };

        let asm = generate_assembly_for_target(
            &program,
            BackendTarget::default().with_mode(BackendMode::Avx512),
        )
        .expect("AVX-512 backend should accept tail-mask and predicated memory IR");

        // Tail-mask lowering: clamp(len - index, 0, lanes) -> (1 << active) - 1.
        assert!(asm.contains("cmovgq"), "expected high clamp; asm:\n{}", asm);
        assert!(asm.contains("cmovlq"), "expected low clamp; asm:\n{}", asm);
        assert!(
            asm.contains("shlq %cl, %rdx"),
            "expected bitmask shift; asm:\n{}",
            asm
        );
        assert!(
            asm.contains("decq %rdx"),
            "expected bitmask -1; asm:\n{}",
            asm
        );
        // k-mask register usage (k1, never the implicit no-mask register k0).
        assert!(
            asm.contains("kmovw %eax, %k1"),
            "expected kmovw into k1; asm:\n{}",
            asm
        );
        assert!(
            !asm.contains("%k0"),
            "k0 must not be used as an active mask; asm:\n{}",
            asm
        );
        // EVEX masked load (zero-masking) and masked store (merge-masking).
        assert!(
            asm.contains("vmovdqu64 (%rax,%rcx,8), %zmm0{%k1}{z}"),
            "expected zero-masked load; asm:\n{}",
            asm
        );
        assert!(
            asm.contains("vmovdqu64 %zmm0, (%rax,%rcx,8){%k1}"),
            "expected merge-masked store; asm:\n{}",
            asm
        );
    }

    #[test]
    fn test_avx512_predicated_memory_i32_and_f64_shapes() {
        let func = Function {
            name: "masked_shapes".into(),
            params: vec![
                (0, Type::DynArray(Box::new(Type::I32))),
                (1, Type::DynArray(Box::new(Type::F64))),
                (2, Type::I64),
                (3, Type::I64),
            ],
            ret: Type::Unit,
            locals: vec![
                (4, Type::Mask(16)),
                (5, Type::Vector(Box::new(Type::I32), 16)),
                (6, Type::Mask(8)),
                (7, Type::Vector(Box::new(Type::F64), 8)),
            ],
            blocks: vec![BasicBlock {
                label: "entry".into(),
                instructions: vec![
                    Instruction::TailMask {
                        dst: 4,
                        index: Value::Var(3),
                        len: Value::Var(2),
                        lanes: 16,
                    },
                    Instruction::PredicatedLoad {
                        dst: 5,
                        base: Value::Var(0),
                        index: Value::Var(3),
                        mask: Value::Var(4),
                        lanes: 16,
                        elem_ty: Type::I32,
                    },
                    Instruction::PredicatedStore {
                        base: Value::Var(0),
                        index: Value::Var(3),
                        value: Value::Var(5),
                        mask: Value::Var(4),
                        lanes: 16,
                        elem_ty: Type::I32,
                    },
                    Instruction::TailMask {
                        dst: 6,
                        index: Value::Var(3),
                        len: Value::Var(2),
                        lanes: 8,
                    },
                    Instruction::PredicatedLoad {
                        dst: 7,
                        base: Value::Var(1),
                        index: Value::Var(3),
                        mask: Value::Var(6),
                        lanes: 8,
                        elem_ty: Type::F64,
                    },
                    Instruction::PredicatedStore {
                        base: Value::Var(1),
                        index: Value::Var(3),
                        value: Value::Var(7),
                        mask: Value::Var(6),
                        lanes: 8,
                        elem_ty: Type::F64,
                    },
                    Instruction::Return(None),
                ],
            }],
            entry: "entry".into(),
        };

        let program = Program {
            functions: vec![func],
            globals: vec![],
            externs: vec![],
        };

        let asm = generate_assembly_for_target(
            &program,
            BackendTarget::default().with_mode(BackendMode::Avx512),
        )
        .expect("AVX-512 backend should accept i32 and f64 predicated memory IR");

        assert!(
            asm.contains("vmovdqu32 (%rax,%rcx,4), %zmm0{%k1}{z}"),
            "expected i32 masked load; asm:\n{}",
            asm
        );
        assert!(
            asm.contains("vmovdqu32 %zmm0, (%rax,%rcx,4){%k1}"),
            "expected i32 masked store; asm:\n{}",
            asm
        );
        assert!(
            asm.contains("vmovupd (%rax,%rcx,8), %zmm0{%k1}{z}"),
            "expected f64 masked load; asm:\n{}",
            asm
        );
        assert!(
            asm.contains("vmovupd %zmm0, (%rax,%rcx,8){%k1}"),
            "expected f64 masked store; asm:\n{}",
            asm
        );
    }

    #[test]
    fn test_avx2_rejects_tail_mask_and_predicated_memory() {
        // The AVX2 backend has no k-mask registers; mask locals (and therefore
        // tail-mask / predicated memory IR) must be rejected cleanly.
        let program = Program {
            functions: vec![Function {
                name: "masked_kernel".into(),
                params: vec![
                    (0, Type::DynArray(Box::new(Type::I64))),
                    (1, Type::I64),
                    (2, Type::I64),
                ],
                ret: Type::Unit,
                locals: vec![(3, Type::Mask(8))],
                blocks: vec![BasicBlock {
                    label: "entry".into(),
                    instructions: vec![
                        Instruction::TailMask {
                            dst: 3,
                            index: Value::Var(2),
                            len: Value::Var(1),
                            lanes: 8,
                        },
                        Instruction::Return(None),
                    ],
                }],
                entry: "entry".into(),
            }],
            globals: vec![],
            externs: vec![],
        };

        let err = generate_assembly_for_target(
            &program,
            BackendTarget::default().with_mode(BackendMode::Avx2),
        )
        .expect_err("AVX2 backend should reject AVX-512 mask IR");
        assert!(err.contains("(Mask 8)"), "unexpected error: {}", err);
    }

    #[test]
    fn test_linux_target_entry_policy_emits_start_and_exit_syscall() {
        let asm = compile_ok_for_target(
            "(define (main) : i64 3)",
            BackendTarget::linux_x86_64_system_v(),
        );

        assert!(asm.contains("    .globl _start"), "asm:\n{}", asm);
        let start = asm.split("_start:").nth(1).expect("expected _start");
        assert!(start.contains("    call main"), "start:\n{}", start);
        assert!(start.contains("    movq %rax, %rdi"), "start:\n{}", start);
        assert!(start.contains("    movq $60, %rax"), "start:\n{}", start);
        assert!(start.contains("    syscall"), "start:\n{}", start);
    }

    #[test]
    fn test_windows_target_entry_policy_omits_linux_start_and_exit_syscall() {
        let asm = compile_ok_for_target("(define (main) : i64 3)", BackendTarget::windows_x86_64());

        assert!(asm.contains("    .globl main"), "asm:\n{}", asm);
        assert!(!asm.contains("    .globl _start"), "asm:\n{}", asm);
        assert!(!asm.contains("\n_start:"), "asm:\n{}", asm);
        assert!(!asm.contains("    movq $60, %rax"), "asm:\n{}", asm);
        assert!(!asm.contains("    syscall"), "asm:\n{}", asm);
    }

    #[test]
    fn test_windows_target_unit_main_returns_zero_to_crt() {
        let asm = compile_ok_for_target(
            "(define (main) : unit (begin))",
            BackendTarget::windows_x86_64(),
        );
        let main = asm.split("main:").nth(1).expect("expected main function");

        assert!(
            main.contains("    xor %eax, %eax"),
            "unit main should return zero to the CRT:\n{}",
            main
        );
    }

    #[test]
    fn test_windows_target_integer_args_use_win64_registers_and_shadow_space() {
        let asm = compile_ok_for_target(
            r#"
            (define (sum5 [a : i64] [b : i64] [c : i64] [d : i64] [e : i64]) : i64
              (+ (+ (+ (+ a b) c) d) e))
            (define (main) : i64 (sum5 1 2 3 4 5))
            "#,
            BackendTarget::windows_x86_64(),
        );

        assert!(asm.contains("    movq %rcx, -8(%rbp)"), "asm:\n{}", asm);
        assert!(asm.contains("    movq %rdx, -16(%rbp)"), "asm:\n{}", asm);
        assert!(asm.contains("    movq %r8, -24(%rbp)"), "asm:\n{}", asm);
        assert!(asm.contains("    movq %r9, -32(%rbp)"), "asm:\n{}", asm);
        assert!(asm.contains("    movq 48(%rbp), %r11"), "asm:\n{}", asm);
        assert!(asm.contains("    movq $1, %rcx"), "asm:\n{}", asm);
        assert!(asm.contains("    movq $2, %rdx"), "asm:\n{}", asm);
        assert!(asm.contains("    movq $3, %r8"), "asm:\n{}", asm);
        assert!(asm.contains("    movq $4, %r9"), "asm:\n{}", asm);
        assert!(asm.contains("    sub $48, %rsp"), "asm:\n{}", asm);
        assert!(asm.contains("    movq %r11, 32(%rsp)"), "asm:\n{}", asm);
        assert!(asm.contains("    call _tl_sum5"), "asm:\n{}", asm);
        assert!(asm.contains("    add $48, %rsp"), "asm:\n{}", asm);
    }

    #[test]
    fn test_windows_target_float_args_use_win64_xmm_registers_and_shadow_space() {
        let asm = compile_ok_for_target(
            r#"
            (define (fifth [a : f64] [b : f64] [c : f64] [d : f64] [e : f64]) : f64 e)
            (define (main) : f64 (fifth 1.0 2.0 3.0 4.0 5.0))
            "#,
            BackendTarget::windows_x86_64(),
        );

        assert!(asm.contains("    movsd %xmm0, -8(%rbp)"), "asm:\n{}", asm);
        assert!(asm.contains("    movsd %xmm1, -16(%rbp)"), "asm:\n{}", asm);
        assert!(asm.contains("    movsd %xmm2, -24(%rbp)"), "asm:\n{}", asm);
        assert!(asm.contains("    movsd %xmm3, -32(%rbp)"), "asm:\n{}", asm);
        assert!(asm.contains("    movsd 48(%rbp), %xmm15"), "asm:\n{}", asm);
        assert!(asm.contains("    movq %rax, %xmm0"), "asm:\n{}", asm);
        assert!(asm.contains("    movq %rax, %xmm1"), "asm:\n{}", asm);
        assert!(asm.contains("    movq %rax, %xmm2"), "asm:\n{}", asm);
        assert!(asm.contains("    movq %rax, %xmm3"), "asm:\n{}", asm);
        assert!(asm.contains("    sub $48, %rsp"), "asm:\n{}", asm);
        assert!(asm.contains("    movsd %xmm15, 32(%rsp)"), "asm:\n{}", asm);
        assert!(asm.contains("    call _tl_fifth"), "asm:\n{}", asm);
        assert!(asm.contains("    add $48, %rsp"), "asm:\n{}", asm);
    }

    #[test]
    fn test_linux_target_runtime_policy_matches_default_for_runtime_helpers() {
        let source = r#"(define (main) : i64 (begin (read-file "input.txt") 0))"#;

        let default_asm = compile_ok(source);
        let explicit_asm = compile_ok_for_target(source, BackendTarget::linux_x86_64_system_v());
        assert_eq!(default_asm, explicit_asm);
        assert!(
            explicit_asm.contains(".L_tl_read_file:"),
            "asm:\n{}",
            explicit_asm
        );
        assert!(
            explicit_asm.contains(".L_tl_abort:"),
            "asm:\n{}",
            explicit_asm
        );
        assert!(
            explicit_asm.contains("    movq $257, %rax"),
            "asm:\n{}",
            explicit_asm
        );
        assert!(
            explicit_asm.contains("    syscall"),
            "asm:\n{}",
            explicit_asm
        );
    }

    #[test]
    fn test_windows_target_print_helpers_use_crt_calls() {
        let asm = compile_ok_for_target(
            r#"
            (define (main) : i64
              (begin
                (print 42)
                (print-bool true)
                (print-float 3.5)
                (print-char #A')
                (print-newline)
                (print-string "hi")
                0))
            "#,
            BackendTarget::windows_x86_64(),
        );

        assert_windows_runtime_has_no_linux_syscalls(&asm);
        assert!(asm.contains("    .extern _write"), "asm:\n{}", asm);
        assert!(asm.contains("    .extern printf"), "asm:\n{}", asm);
        assert!(asm.contains("    .extern fflush"), "asm:\n{}", asm);
        assert!(asm.contains("tl_print_i64:"), "asm:\n{}", asm);
        assert!(asm.contains("tl_print_bool:"), "asm:\n{}", asm);
        assert!(asm.contains("tl_print_f64:"), "asm:\n{}", asm);
        assert!(asm.contains("tl_print_char:"), "asm:\n{}", asm);
        assert!(asm.contains("tl_print_newline:"), "asm:\n{}", asm);
        assert!(asm.contains("tl_print_str:"), "asm:\n{}", asm);
        assert!(asm.contains("    movq %xmm0, %rdx"), "asm:\n{}", asm);
        assert!(asm.contains("    call printf"), "asm:\n{}", asm);
        assert!(asm.contains("    call fflush"), "asm:\n{}", asm);
        assert!(asm.contains("    call _write"), "asm:\n{}", asm);
        assert!(asm.contains("    movb %cl, -1(%rbp)"), "asm:\n{}", asm);
        assert!(asm.contains("    sub $32, %rsp"), "asm:\n{}", asm);
    }

    #[test]
    fn test_windows_target_allocator_and_allocating_string_helpers_use_crt() {
        let asm = compile_ok_for_target(
            r#"
            (define (main) : i64
              (begin
                (int->string 42)
                (substring "abcd" 1 2)
                (string-append "a" "b")
                0))
            "#,
            BackendTarget::windows_x86_64(),
        );

        assert_windows_runtime_has_no_linux_syscalls(&asm);
        assert!(asm.contains("    .extern malloc"), "asm:\n{}", asm);
        assert!(asm.contains("    .extern exit"), "asm:\n{}", asm);
        assert!(asm.contains("    .extern _write"), "asm:\n{}", asm);
        assert!(asm.contains("tl_alloc:"), "asm:\n{}", asm);
        assert!(asm.contains("    call malloc"), "asm:\n{}", asm);
        assert!(asm.contains("    jz .L_tl_alloc_abort"), "asm:\n{}", asm);
        assert!(!asm.contains("tl_current_arena:"), "asm:\n{}", asm);
        assert!(!asm.contains("    movq $9, %rax"), "asm:\n{}", asm);
        assert!(asm.contains("tl_int_to_string:"), "asm:\n{}", asm);
        assert!(asm.contains("tl_substring:"), "asm:\n{}", asm);
        assert!(asm.contains("tl_string_concat:"), "asm:\n{}", asm);
        assert!(asm.contains("    movq %r12, %rcx"), "asm:\n{}", asm);
        assert!(asm.contains("    movq $16, %rcx"), "asm:\n{}", asm);
        assert!(asm.contains("    call tl_alloc"), "asm:\n{}", asm);
        assert!(asm.contains("    sub $32, %rsp"), "asm:\n{}", asm);
    }

    #[test]
    fn test_windows_target_int_to_string_preserves_rcx_argument() {
        let asm = compile_ok_for_target(
            "(define (main) : i64 (begin (int->string 42) 0))",
            BackendTarget::windows_x86_64(),
        );
        let int_to_string = asm
            .split("tl_int_to_string:")
            .nth(1)
            .expect("expected tl_int_to_string runtime");
        let load_arg = int_to_string
            .find("    movq %rcx, %rax")
            .expect("expected Windows arg load");
        let clear_digit_count = int_to_string
            .find("    movq $0, %rcx")
            .expect("expected digit count clear");
        assert!(
            load_arg < clear_digit_count,
            "tl_int_to_string must copy the Windows arg before reusing %rcx:\n{}",
            int_to_string
        );
    }

    #[test]
    fn test_windows_target_argv_helpers_capture_crt_main_args() {
        let asm = compile_ok_for_target(
            "(define (main) : i64 (+ (arg-count) (string-length (arg 0))))",
            BackendTarget::windows_x86_64(),
        );

        assert_windows_runtime_has_no_linux_syscalls(&asm);
        assert!(asm.contains(".L_tl_argc:"), "asm:\n{}", asm);
        assert!(asm.contains(".L_tl_argv:"), "asm:\n{}", asm);
        assert!(asm.contains(".L_tl_arg_count:"), "asm:\n{}", asm);
        assert!(asm.contains(".L_tl_arg:"), "asm:\n{}", asm);
        assert!(
            asm.contains("    movq %rcx, .L_tl_argc(%rip)"),
            "asm:\n{}",
            asm
        );
        assert!(
            asm.contains("    movq %rdx, .L_tl_argv(%rip)"),
            "asm:\n{}",
            asm
        );
        assert!(asm.contains("    call .L_tl_arg"), "asm:\n{}", asm);
        assert!(asm.contains("    movq %rcx, %rbx"), "asm:\n{}", asm);
        assert!(asm.contains("    movq %r12, %rcx"), "asm:\n{}", asm);
        assert!(asm.contains("    call tl_alloc"), "asm:\n{}", asm);
        assert!(asm.contains("    call .L_tl_abort"), "asm:\n{}", asm);
    }

    #[test]
    fn test_windows_target_file_helpers_use_crt_calls() {
        let asm = compile_ok_for_target(
            r#"
            (define (main) : i64
              (begin
                (read-file "input.txt")
                (write-file "out.txt" "hi")
                (if (file-exists? "input.txt") 1 0)))
            "#,
            BackendTarget::windows_x86_64(),
        );

        assert_windows_runtime_has_no_linux_syscalls(&asm);
        for symbol in ["_open", "_lseeki64", "_read", "_write", "_close", "_access"] {
            assert!(
                asm.contains(&format!("    .extern {}", symbol)),
                "missing extern {symbol}; asm:\n{}",
                asm
            );
            assert!(
                asm.contains(&format!("    call {}", symbol)),
                "missing call {symbol}; asm:\n{}",
                asm
            );
        }
        assert!(asm.contains(".L_tl_read_file:"), "asm:\n{}", asm);
        assert!(asm.contains(".L_tl_write_file:"), "asm:\n{}", asm);
        assert!(asm.contains(".L_tl_file_exists:"), "asm:\n{}", asm);
        assert!(asm.contains("    movq $0x8000, %rdx"), "asm:\n{}", asm);
        assert!(asm.contains("    movq $0x8301, %rdx"), "asm:\n{}", asm);
        assert!(asm.contains("    movq $0x180, %r8"), "asm:\n{}", asm);
        assert!(!asm.contains("    movq $257, %rax"), "asm:\n{}", asm);
        assert!(!asm.contains("    movq $-100, %rdi"), "asm:\n{}", asm);
    }

    #[test]
    fn test_windows_target_stdin_helpers_use_crt_calls() {
        let asm = compile_ok_for_target(
            r#"
            (define (main) : i64
              (begin
                (read-stdin-line)
                (read-stdin-bytes 3)
                (flush-stdout)
                (if (stdin-eof?) 1 0)))
            "#,
            BackendTarget::windows_x86_64(),
        );

        assert_windows_runtime_has_no_linux_syscalls(&asm);
        assert!(asm.contains("    .extern _read"), "asm:\n{}", asm);
        assert!(asm.contains("    .extern fflush"), "asm:\n{}", asm);
        assert!(asm.contains(".L_tl_read_stdin_line:"), "asm:\n{}", asm);
        assert!(asm.contains(".L_tl_read_stdin_bytes:"), "asm:\n{}", asm);
        assert!(asm.contains(".L_tl_stdin_eof:"), "asm:\n{}", asm);
        assert!(asm.contains(".L_tl_flush_stdout:"), "asm:\n{}", asm);
        assert!(asm.contains(".L_tl_stdin_eof_flag:"), "asm:\n{}", asm);
        assert!(asm.contains("    call _read"), "asm:\n{}", asm);
        assert!(asm.contains("    call fflush"), "asm:\n{}", asm);
        assert!(asm.contains("    call .L_tl_abort"), "asm:\n{}", asm);
        assert!(asm.contains("    movq $16, %rcx"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_f32_parameter_and_return_use_xmm_movss() {
        // f32 params/returns flow through XMM registers with single-precision
        // moves, exactly like f64 but with `movss` instead of `movsd`.
        let asm = compile_ok("(define (idf [x : f32]) : f32 x)");
        assert!(asm.contains("    movss %xmm0,"), "asm:\n{}", asm);
        assert!(!asm.contains("    movsd %xmm0,"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_f32_arithmetic_uses_single_precision_mnemonics() {
        let asm = compile_ok(
            r#"
            (define (calc [a : f32] [b : f32]) : f32
              (let ([s : f32 (+ a b)]
                    [d : f32 (- a b)]
                    [p : f32 (* a b)])
                (/ (+ s (+ d p)) b)))
            "#,
        );
        assert!(asm.contains("addss %xmm1, %xmm0"), "asm:\n{}", asm);
        assert!(asm.contains("subss %xmm1, %xmm0"), "asm:\n{}", asm);
        assert!(asm.contains("mulss %xmm1, %xmm0"), "asm:\n{}", asm);
        assert!(asm.contains("divss %xmm1, %xmm0"), "asm:\n{}", asm);
        assert!(!asm.contains("addsd %xmm1, %xmm0"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_f32_comparison_uses_ucomiss() {
        let asm = compile_ok("(define (ltf [a : f32] [b : f32]) : bool (< a b))");
        assert!(asm.contains("ucomiss %xmm1, %xmm0"), "asm:\n{}", asm);
        assert!(!asm.contains("ucomisd %xmm1, %xmm0"), "asm:\n{}", asm);
        assert!(asm.contains("setb %al"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_f64_to_f32_cast_uses_cvtsd2ss() {
        let asm = compile_ok("(define (narrow [x : f64]) : f32 (cast x : f32))");
        assert!(asm.contains("cvtsd2ss %xmm0, %xmm0"), "asm:\n{}", asm);
        assert!(asm.contains("    movss %xmm0,"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_f32_to_f64_cast_uses_cvtss2sd() {
        let asm = compile_ok("(define (widen [x : f32]) : f64 (cast x : f64))");
        assert!(asm.contains("cvtss2sd %xmm0, %xmm0"), "asm:\n{}", asm);
        assert!(asm.contains("    movsd %xmm0,"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_f64_to_f32_roundtrip_uses_both_conversions() {
        let asm = compile_ok("(define (roundtrip [x : f64]) : f64 (cast (cast x : f32) : f64))");
        assert!(asm.contains("cvtsd2ss %xmm0, %xmm0"), "asm:\n{}", asm);
        assert!(asm.contains("cvtss2sd %xmm0, %xmm0"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_f32_negation_uses_subss() {
        let prog = ast::Program {
            decls: vec![ast::Decl::DefFn {
                name: "negf".into(),
                params: vec![("x".into(), Type::F32)],
                comptime_params: vec![],
                ret: Type::F32,
                body: ast::Expr::Unary {
                    op: ast::UnOp::Neg,
                    expr: Box::new(ast::Expr::Var("x".into())),
                },
            }],
        };
        let mut ir = lower_program(&prog);
        Optimizer::optimize(&mut ir);
        let asm = generate_assembly(&ir).expect("backend should accept f32 negation");
        assert!(asm.contains("pxor %xmm1, %xmm1"), "asm:\n{}", asm);
        assert!(asm.contains("subss %xmm0, %xmm1"), "asm:\n{}", asm);
        assert!(asm.contains("movaps %xmm1, %xmm0"), "asm:\n{}", asm);
    }

    #[test]
    fn test_reject_by_value_tuple_return_type_before_codegen() {
        let err = compile_err(
            r#"
            (define (make_pair [a : i64] [b : bool]) : (Tuple i64 bool)
              (tuple a b))
            "#,
        );
        assert!(
            err.contains("return type (Tuple i64 bool)"),
            "unexpected error: {}",
            err
        );
    }

    #[test]
    fn test_reject_by_value_fixed_array_return_type_before_codegen() {
        let err = compile_err(
            r#"
            (define (make_arr) : (Array i64 3)
              (array 1 2 3))
            "#,
        );
        assert!(
            err.contains("return type (Array i64 3)"),
            "unexpected error: {}",
            err
        );
    }

    #[test]
    fn test_compile_tuple_roundtrip_construct_then_read_no_todo() {
        let asm = compile_ok(
            r#"
            (define (main) : i64
              (let ([t : (Tuple bool i64) (tuple true 42)])
                (if (tuple-ref t 0) (tuple-ref t 1) 0)))
            "#,
        );
        assert!(asm.contains("movq $42,"), "asm:\n{}", asm);
        assert!(!asm.contains("# TODO"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_f32_local_slot_uses_movss() {
        // An f32 local is now a supported scalar backend slot; copying through
        // it uses single-precision XMM moves.
        let asm = compile_ok("(define (idlet [x : f32]) : f32 (let ([y : f32 x]) y))");
        assert!(asm.contains("movss -4(%rbp), %xmm0"), "asm:\n{}", asm);
        assert!(asm.contains("movss %xmm0, -8(%rbp)"), "asm:\n{}", asm);
        assert!(!asm.contains("movsd"), "asm:\n{}", asm);
        assert!(!asm.contains("# TODO"), "unhandled instruction:\n{}", asm);
    }

    #[test]
    fn test_reject_vector_mask_ir_before_codegen() {
        let err = generate_assembly(&Program {
            functions: vec![Function {
                name: "main".into(),
                params: vec![],
                ret: Type::Unit,
                locals: vec![(0, Type::I64)],
                blocks: vec![BasicBlock {
                    label: "entry".into(),
                    instructions: vec![
                        Instruction::LaneId {
                            dst: 0,
                            lanes: 4,
                            ty: Type::I64,
                        },
                        Instruction::Return(None),
                    ],
                }],
                entry: "entry".into(),
            }],
            globals: vec![],
            externs: vec![],
        })
        .expect_err("scalar backend should reject vector/mask IR");
        assert!(
            err.contains("vector/mask IR requires a SIMD backend target"),
            "unexpected error: {}",
            err
        );
    }

    #[test]
    fn test_reject_vector_reduction_ir_before_codegen() {
        let err = generate_assembly(&Program {
            functions: vec![Function {
                name: "main".into(),
                params: vec![],
                ret: Type::I64,
                locals: vec![(0, Type::I64)],
                blocks: vec![BasicBlock {
                    label: "entry".into(),
                    instructions: vec![
                        Instruction::VectorReduce {
                            dst: 0,
                            op: VectorReduceOp::Sum,
                            src: Value::ConstI64(1),
                            lanes: 4,
                            elem_ty: Type::I64,
                        },
                        Instruction::Return(Some(Value::Var(0))),
                    ],
                }],
                entry: "entry".into(),
            }],
            globals: vec![],
            externs: vec![],
        })
        .expect_err("scalar backend should reject vector reduction IR");
        assert!(
            err.contains("vector/mask IR requires a SIMD backend target"),
            "unexpected error: {}",
            err
        );
    }

    #[test]
    fn test_reject_unsupported_extern_signature_before_codegen() {
        let err = generate_assembly(&Program {
            functions: vec![Function {
                name: "main".into(),
                params: vec![],
                ret: Type::I64,
                locals: vec![],
                blocks: vec![BasicBlock {
                    label: "entry".into(),
                    instructions: vec![Instruction::Return(Some(Value::ConstI64(0)))],
                }],
                entry: "entry".into(),
            }],
            globals: vec![],
            externs: vec![(
                "foreign_array".into(),
                Type::Func(
                    vec![Type::Array(Box::new(Type::I64), 3)],
                    Box::new(Type::I64),
                ),
            )],
        })
        .expect_err("backend should reject unsupported extern ABI types");
        assert!(
            err.contains("extern 'foreign_array' has unsupported argument type (Array i64 3)"),
            "unexpected error: {}",
            err
        );
    }

    #[test]
    fn test_accept_f32_extern_signature() {
        // f32 args/returns now use the XMM ABI, so an extern with f32 in its
        // signature is accepted by backend validation.
        generate_assembly(&Program {
            functions: vec![Function {
                name: "main".into(),
                params: vec![],
                ret: Type::I64,
                locals: vec![],
                blocks: vec![BasicBlock {
                    label: "entry".into(),
                    instructions: vec![Instruction::Return(Some(Value::ConstI64(0)))],
                }],
                entry: "entry".into(),
            }],
            globals: vec![],
            externs: vec![(
                "foreign_f32".into(),
                Type::Func(vec![Type::F32], Box::new(Type::F32)),
            )],
        })
        .expect("backend should accept f32 extern ABI types");
    }

    #[test]
    fn test_accept_f32_global_zero_init_emits_four_byte_slot() {
        // A non-constant f32 global is zero-initialized as a 4-byte .comm slot
        // and its startup initializer stores via movss.
        let asm = generate_assembly(&Program {
            functions: vec![Function {
                name: "main".into(),
                params: vec![],
                ret: Type::I64,
                locals: vec![],
                blocks: vec![BasicBlock {
                    label: "entry".into(),
                    instructions: vec![Instruction::Return(Some(Value::ConstI64(0)))],
                }],
                entry: "entry".into(),
            }],
            globals: vec![("g".into(), Type::F32, None)],
            externs: vec![],
        })
        .expect("backend should accept f32 globals");
        assert!(asm.contains(".comm _tl_g, 4,"), "asm:\n{}", asm);
    }

    #[test]
    fn test_reject_extern_tuple_containing_enum_signature_before_codegen() {
        let err = compile_err(
            r#"
            (defenum Shape (Circle i64) (Nothing))
            (extern foreign_tuple : (-> (Tuple Shape i64) i64))
            (define (main) : i64 0)
            "#,
        );
        assert!(
            err.contains("extern 'foreign_tuple' has unsupported argument type (Tuple Shape i64)"),
            "unexpected error: {}",
            err
        );
    }

    fn compile_unop_param(op: UnOp, ty: Type) -> String {
        let program = Program {
            functions: vec![Function {
                name: "f".into(),
                params: vec![(0, ty.clone())],
                ret: ty.clone(),
                locals: vec![(1, ty.clone())],
                blocks: vec![BasicBlock {
                    label: "entry".into(),
                    instructions: vec![
                        Instruction::Alloc {
                            var: 0,
                            ty: ty.clone(),
                        },
                        Instruction::UnOp {
                            dst: 1,
                            op,
                            src: Value::Var(0),
                            ty,
                        },
                        Instruction::Return(Some(Value::Var(1))),
                    ],
                }],
                entry: "entry".into(),
            }],
            globals: vec![],
            externs: vec![],
        };
        generate_assembly(&program).expect("unary op should compile")
    }

    #[test]
    fn test_backend_simple_main() {
        let program = Program {
            functions: vec![Function {
                name: "main".to_string(),
                params: vec![],
                ret: Type::I64,
                locals: vec![],
                blocks: vec![BasicBlock {
                    label: "entry".to_string(),
                    instructions: vec![Instruction::Return(Some(Value::ConstI64(3)))],
                }],
                entry: "entry".to_string(),
            }],
            globals: vec![],
            externs: vec![],
        };
        let asm = generate_assembly(&program).expect("simple main should compile");
        assert!(asm.contains("    .globl _start"));
        assert!(asm.contains("main:"));
        assert!(asm.contains("movq $3, %rax"));
        assert!(asm.contains("ret"));
        assert!(asm.contains("_start:"));
        assert!(asm.contains("    call main"));
        assert!(asm.contains("    movq $60, %rax"));
    }

    #[test]
    fn test_compile_loads_i64_global() {
        let asm = compile_ok(
            r#"
            (define answer 42)
            (define (main) : i64 answer)
            "#,
        );
        assert!(asm.contains("    .data"), "asm:\n{}", asm);
        assert!(asm.contains("_tl_answer:"), "asm:\n{}", asm);
        assert!(asm.contains("    .quad 42"), "asm:\n{}", asm);
        assert!(
            asm.contains("    movq _tl_answer(%rip), %rax"),
            "asm:\n{}",
            asm
        );
        assert!(!asm.contains("# TODO"), "unhandled instruction:\n{}", asm);
    }

    #[test]
    fn test_compile_loads_f64_global() {
        let asm = compile_ok(
            r#"
            (define pi 3.14)
            (define (main) : f64 pi)
            "#,
        );
        assert!(asm.contains("_tl_pi:"), "asm:\n{}", asm);
        assert!(
            asm.contains("    .quad 0x40091eb851eb851f"),
            "asm:\n{}",
            asm
        );
        assert!(
            asm.contains("    movsd _tl_pi(%rip), %xmm0"),
            "asm:\n{}",
            asm
        );
        assert!(!asm.contains("# TODO"), "unhandled instruction:\n{}", asm);
    }

    #[test]
    fn test_compile_stores_i64_global_into_local() {
        // A global used as a let initializer lowers to Store { src: Global, ... }.
        // The backend must materialize that source instead of silently leaving
        // the local slot uninitialized.
        let asm = compile_ok(
            r#"
            (define answer 41)
            (define (main) : i64
              (let ([x : i64 answer])
                (+ x 1)))
            "#,
        );
        assert!(
            asm.contains("    movq _tl_answer(%rip), %rax"),
            "asm:\n{}",
            asm
        );
        assert!(asm.contains("    addq %rcx, %rax"), "asm:\n{}", asm);
        assert!(!asm.contains("# TODO"), "unhandled instruction:\n{}", asm);
    }

    #[test]
    fn test_compile_phi_can_select_i64_global() {
        // Phi elimination inserts Mov instructions in predecessor blocks. When
        // one incoming value is global, Mov must load it just like Return/Call
        // operands do.
        let asm = compile_ok(
            r#"
            (define fallback 9)
            (define (choose [c : bool]) : i64
              (if c fallback 2))
            "#,
        );
        assert!(
            asm.contains("    movq _tl_fallback(%rip), %rax"),
            "asm:\n{}",
            asm
        );
        assert!(!asm.contains("# TODO"), "unhandled instruction:\n{}", asm);
    }

    #[test]
    fn test_compile_set_global_i64_stores_to_data_symbol() {
        // `set!` can target a top-level scalar binding. It lowers to a Store
        // whose destination is Value::Global and codegen writes the data symbol.
        let asm = compile_ok(
            r#"
            (define counter 0)
            (define (main) : i64
              (begin
                (set! counter 5)
                counter))
            "#,
        );
        assert!(
            asm.contains("    movq $5, _tl_counter(%rip)"),
            "asm:\n{}",
            asm
        );
        assert!(
            asm.contains("    movq _tl_counter(%rip), %rax"),
            "asm:\n{}",
            asm
        );
        assert!(!asm.contains("# TODO"), "unhandled instruction:\n{}", asm);
    }

    #[test]
    fn test_compile_casted_narrow_globals_emit_sized_data() {
        let asm = compile_ok(
            r#"
            (define small : i32 (cast 7 : i32))
            (define mid : u16 (cast 513 : u16))
            (define byte : u8 (cast 255 : u8))
            (define smallf : f32 1.5)
            (define (main) : i32 small)
            "#,
        );
        assert!(asm.contains("_tl_small:"), "asm:\n{}", asm);
        assert!(asm.contains("    .long 7"), "asm:\n{}", asm);
        assert!(asm.contains("_tl_mid:"), "asm:\n{}", asm);
        assert!(asm.contains("    .word 513"), "asm:\n{}", asm);
        assert!(asm.contains("_tl_byte:"), "asm:\n{}", asm);
        assert!(asm.contains("    .byte -1"), "asm:\n{}", asm);
        assert!(asm.contains("_tl_smallf:"), "asm:\n{}", asm);
        assert!(asm.contains("    .long 0x3fc00000"), "asm:\n{}", asm);
        assert!(
            asm.contains("    movslq _tl_small(%rip), %rax"),
            "asm:\n{}",
            asm
        );
        assert!(!asm.contains("non-constant initializer"), "asm:\n{}", asm);
        assert!(!asm.contains("# TODO"), "unhandled instruction:\n{}", asm);
    }

    #[test]
    fn test_non_constant_global_initializer() {
        let asm = compile_ok(
            r#"
            (define (add [a : i64] [b : i64]) : i64 (+ a b))
            (define result : i64 (add 1 2))
            (define (main) : i64 result)
            "#,
        );
        // The global should be emitted as .comm (bss) and _start should call
        // __global_init_result before main.
        assert!(
            asm.contains("    .comm _tl_result,"),
            "expected .comm for result, got:\n{}",
            asm
        );
        assert!(
            asm.contains("    call _tl___global_init_result"),
            "expected init call, got:\n{}",
            asm
        );
        assert!(
            asm.contains("    movq %rax, _tl_result(%rip)"),
            "expected store after init, got:\n{}",
            asm
        );
        assert!(asm.contains("add:"), "expected add function, got:\n{}", asm);
    }

    #[test]
    fn test_windows_target_non_constant_global_initializer_uses_coff_comm_alignment() {
        let asm = compile_ok_for_target(
            r#"
            (define (add [a : i64] [b : i64]) : i64 (+ a b))
            (define result : i64 (add 1 2))
            (define (main) : i64 result)
            "#,
            BackendTarget::windows_x86_64(),
        );

        assert!(
            asm.contains("    .comm _tl_result, 8, 3"),
            "expected COFF log2 .comm alignment for result, got:\n{}",
            asm
        );
        assert!(
            asm.contains("    call _tl___global_init_result"),
            "expected init call, got:\n{}",
            asm
        );
        let main = asm.split("main:").nth(1).expect("expected main function");
        let init_call = main
            .find("    call _tl___global_init_result")
            .expect("expected init call in Windows main");
        let global_load = main
            .find("    movq _tl_result(%rip), %rax")
            .expect("expected global load in Windows main");
        assert!(
            init_call < global_load,
            "Windows main must initialize globals before reading them:\n{}",
            main
        );
    }

    #[test]
    fn test_non_constant_global_initializer_can_use_arg_count() {
        let asm = compile_ok(
            r#"
            (define count : i64 (arg-count))
            (define (main) : i64 count)
            "#,
        );
        let start = asm.split("_start:").nth(1).expect("expected _start");
        let argv_save = start
            .find("    movq %rax, .L_tl_argv(%rip)")
            .expect("expected argv capture");
        let init_call = start
            .find("    call _tl___global_init_count")
            .expect("expected global init call");
        let main_call = start.find("    call main").expect("expected main call");
        assert!(
            argv_save < init_call,
            "argv must be captured before global initializers:\n{}",
            start
        );
        assert!(
            init_call < main_call,
            "global initializers must run before main:\n{}",
            start
        );
    }

    #[test]
    fn test_windows_target_global_initializer_can_use_arg_count() {
        let asm = compile_ok_for_target(
            r#"
            (define count : i64 (arg-count))
            (define (main) : i64 count)
            "#,
            BackendTarget::windows_x86_64(),
        );
        let main = asm.split("main:").nth(1).expect("expected main function");
        let argc_save = main
            .find("    movq %rcx, .L_tl_argc(%rip)")
            .expect("expected argc capture");
        let argv_save = main
            .find("    movq %rdx, .L_tl_argv(%rip)")
            .expect("expected argv capture");
        let init_call = main
            .find("    call _tl___global_init_count")
            .expect("expected global init call");
        let main_load = main
            .find("    movq _tl_count(%rip), %rax")
            .expect("expected initialized global load");
        assert!(
            argc_save < init_call && argv_save < init_call && init_call < main_load,
            "Windows main must capture CRT argv before global init and read after init:\n{}",
            main
        );
    }

    #[test]
    fn test_non_constant_aggregate_global_initializers_store_pointer_values() {
        let asm = compile_ok(
            r#"
            (defenum MaybeI64 (Some i64) (None))
            (defstruct Pair (x i64) (y i64))
            (defstruct Nested (label String) (choice MaybeI64))

            (define greeting "hello")
            (define choice : MaybeI64 (Some 8))
            (define pair (Pair 10 11))
            (define cells (make-array i64 3))
            (define nested : Nested (Nested "ok" (Some 3)))

            (define (main) : i64
              (+ (+ (+ (string-length greeting) (length cells))
                    (+ (struct-get pair x) (struct-get pair y)))
                 (+ (match choice [(Some n) n] [None 0])
                    (+ (string-length (struct-get nested label))
                       (match (struct-get nested choice) [(Some n) n] [None 0])))))
            "#,
        );

        for name in ["greeting", "choice", "pair", "cells", "nested"] {
            assert!(
                asm.contains(&format!("    .comm _tl_{}, 8, 8", name)),
                "expected pointer-sized .comm for {name}, got:\n{asm}"
            );
            assert!(
                asm.contains(&format!("    call _tl___global_init_{}", name)),
                "expected runtime global initializer call for {name}, got:\n{asm}"
            );
            assert!(
                asm.contains(&format!("    movq %rax, _tl_{}(%rip)", name)),
                "expected pointer store after initializer for {name}, got:\n{asm}"
            );
        }
        assert!(
            asm.contains("    movq _tl_greeting(%rip), %rax"),
            "expected string global load, got:\n{}",
            asm
        );
        assert!(
            asm.contains("    movq _tl_cells(%rip), %rax"),
            "expected dynamic-array global load, got:\n{}",
            asm
        );
        assert!(!asm.contains("# TODO"), "unhandled instruction:\n{}", asm);
    }

    #[test]
    fn test_compile_builtin_print_runtime_calls() {
        let asm = compile_ok(
            r#"
            (define (main) : i64
              (begin
                (print 42)
                (print-bool true)
                0))
            "#,
        );
        assert!(asm.contains("    call tl_print_i64"), "asm:\n{}", asm);
        assert!(asm.contains("    call tl_print_bool"), "asm:\n{}", asm);
        assert!(!asm.contains("    call _tl_print"), "asm:\n{}", asm);
        assert!(asm.contains("tl_print_i64:"), "asm:\n{}", asm);
        assert!(asm.contains("    leaq -1(%rbp), %rsi"), "asm:\n{}", asm);
        assert!(asm.contains("    movb $10, (%rsi)"), "asm:\n{}", asm);
        assert!(asm.contains("tl_print_bool:"), "asm:\n{}", asm);
        assert!(asm.contains(".L_tl_bool_true:"), "asm:\n{}", asm);
        assert!(asm.contains("    syscall"), "asm:\n{}", asm);
        assert!(!asm.contains("# TODO"), "unhandled instruction:\n{}", asm);
    }

    #[test]
    fn test_compile_builtin_print_float_runtime_call() {
        let asm = compile_ok(
            r#"
            (define (main) : i64
              (begin
                (print-float 3.5)
                0))
            "#,
        );
        assert!(asm.contains("    call tl_print_f64"), "asm:\n{}", asm);
        assert!(!asm.contains("    call _tl_print_float"), "asm:\n{}", asm);
        assert!(asm.contains("tl_print_f64:"), "asm:\n{}", asm);
        assert!(asm.contains("    .extern printf"), "asm:\n{}", asm);
        assert!(asm.contains("    .extern fflush"), "asm:\n{}", asm);
        assert!(asm.contains("    .asciz \"%.17g\\n\""), "asm:\n{}", asm);
        assert!(asm.contains("    call printf"), "asm:\n{}", asm);
        assert!(asm.contains("    call fflush"), "asm:\n{}", asm);
        assert!(!asm.contains("# TODO"), "unhandled instruction:\n{}", asm);
    }

    #[test]
    fn test_compile_builtin_print_char_and_newline_runtime_calls() {
        let asm = compile_ok(
            r#"
            (define (main) : i64
              (begin
                (print-char #A')
                (print-newline)
                0))
            "#,
        );
        assert!(asm.contains("    call tl_print_char"), "asm:\n{}", asm);
        assert!(asm.contains("    call tl_print_newline"), "asm:\n{}", asm);
        assert!(!asm.contains("    call _tl_print_char"), "asm:\n{}", asm);
        assert!(!asm.contains("    call _tl_print_newline"), "asm:\n{}", asm);
        assert!(asm.contains("tl_print_char:"), "asm:\n{}", asm);
        assert!(asm.contains("tl_print_newline:"), "asm:\n{}", asm);
        assert!(asm.contains("    movb %dil, -1(%rbp)"), "asm:\n{}", asm);
        assert!(asm.contains("    movb $10, -1(%rbp)"), "asm:\n{}", asm);
        assert!(!asm.contains("# TODO"), "unhandled instruction:\n{}", asm);
    }

    #[test]
    fn test_compile_unit_return_function() {
        let asm = compile_ok(
            r#"
            (define (noop) : unit unit)
            (define (main) : i64
              (begin
                (noop)
                7))
            "#,
        );
        assert!(asm.contains("_tl_noop:"), "asm:\n{}", asm);
        assert!(asm.contains("    call _tl_noop"), "asm:\n{}", asm);
        assert!(!asm.contains("# TODO"), "unhandled instruction:\n{}", asm);
    }

    #[test]
    fn test_compile_unit_main_exits_zero() {
        let asm = compile_ok("(define (main) : unit unit)");
        let start = asm.split("_start:").nth(1).expect("expected _start entry");

        assert!(start.contains("    call main"), "asm:\n{}", asm);
        assert!(start.contains("    xor %edi, %edi"), "asm:\n{}", asm);
        assert!(
            !start.contains("    movq %rax, %rdi"),
            "unit main must not use an undefined return value as the exit code:\n{}",
            asm
        );
        assert!(!asm.contains("# TODO"), "unhandled instruction:\n{}", asm);
    }

    #[test]
    fn test_compile_unit_phi_and_store_are_noops() {
        let asm = compile_ok(
            r#"
            (define (branch_unit [b : bool]) : unit
              (if b unit unit))
            (define (main) : i64
              (begin
                (let ([x : unit unit]) x)
                (branch_unit true)
                0))
            "#,
        );
        assert!(asm.contains("_tl_branch_unit:"), "asm:\n{}", asm);
        assert!(asm.contains("    call _tl_branch_unit"), "asm:\n{}", asm);
        assert!(!asm.contains("# TODO"), "unhandled instruction:\n{}", asm);
    }

    #[test]
    fn test_user_defined_print_uses_typelisp_symbol() {
        let asm = compile_ok(
            r#"
            (define (print [x : i64]) : i64 (+ x 1))
            (define (main) : i64 (print 41))
            "#,
        );
        assert!(asm.contains("_tl_print:"), "asm:\n{}", asm);
        assert!(asm.contains("    call _tl_print"), "asm:\n{}", asm);
        assert!(!asm.contains("    call tl_print_i64"), "asm:\n{}", asm);
        assert!(!asm.contains("tl_print_i64:"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_extern_call_uses_raw_symbol() {
        let asm = compile_ok(
            r#"
            (extern foreign_add : (-> i64 i64 i64))
            (define (main) : i64 (foreign_add 20 22))
            "#,
        );

        assert!(asm.contains("    .extern foreign_add"), "asm:\n{}", asm);
        assert!(asm.contains("    call foreign_add"), "asm:\n{}", asm);
        assert!(!asm.contains("_tl_foreign_add"), "asm:\n{}", asm);
        assert!(!asm.contains("# TODO"), "unhandled instruction:\n{}", asm);
    }

    #[test]
    fn test_compile_extern_hyphen_name_uses_asm_safe_raw_symbol() {
        let asm = compile_ok(
            r#"
            (extern foreign-add : (-> i64 i64 i64))
            (define (main) : i64 (foreign-add 20 22))
            "#,
        );

        assert!(asm.contains("    .extern foreign_add"), "asm:\n{}", asm);
        assert!(asm.contains("    call foreign_add"), "asm:\n{}", asm);
        assert!(!asm.contains("_tl_foreign_add"), "asm:\n{}", asm);
        assert!(!asm.contains("    .extern foreign-add"), "asm:\n{}", asm);
        assert!(!asm.contains("    call foreign-add"), "asm:\n{}", asm);
        assert!(!asm.contains("# TODO"), "unhandled instruction:\n{}", asm);
    }

    #[test]
    fn test_compile_extern_enum_argument_and_return() {
        let asm = compile_ok(
            r#"
            (defenum Shape (Circle i64) (Square i64) (Nothing))
            (extern foreign_shape : (-> Shape Shape))
            (define (main) : i64
              (match (foreign_shape (Circle 7))
                [(Circle r) r]
                [(Square w) w]
                [Nothing 0]))
            "#,
        );

        assert!(asm.contains("    .extern foreign_shape"), "asm:\n{}", asm);
        assert!(asm.contains("    call foreign_shape"), "asm:\n{}", asm);
        assert!(!asm.contains("_tl_foreign_shape"), "asm:\n{}", asm);
        assert!(!asm.contains("# TODO"), "unhandled instruction:\n{}", asm);
    }

    #[test]
    fn test_compile_extern_dyn_array_of_enum_argument_and_enum_return() {
        let asm = compile_ok(
            r#"
            (defenum Shape (Circle i64) (Nothing))
            (extern foreign_pick : (-> (Array Shape) Shape))
            (define (pick [xs : (Array Shape)]) : Shape (foreign_pick xs))
            (define (main) : i64 0)
            "#,
        );

        assert!(asm.contains("    .extern foreign_pick"), "asm:\n{}", asm);
        assert!(asm.contains("    call foreign_pick"), "asm:\n{}", asm);
        assert!(!asm.contains("_tl_foreign_pick"), "asm:\n{}", asm);
        assert!(!asm.contains("# TODO"), "unhandled instruction:\n{}", asm);
    }

    #[test]
    fn test_compile_constant_main() {
        // (+ 1 2) folds to a constant; backend should emit the literal in %rax.
        let asm = compile_ok("(define (main) : i64 (+ 1 2))");
        assert!(asm.contains("    .globl main"));
        assert!(asm.contains("    .globl _start"));
        assert!(asm.contains("main:"));
        assert!(asm.contains("movq $3, %rax"));
    }

    #[test]
    fn test_compile_add_function() {
        // Parameters are loaded from registers into stack slots, added, returned.
        let asm = compile_ok("(define (add [a : i64] [b : i64]) : i64 (+ a b))");
        // Mangled non-main name.
        assert!(asm.contains("_tl_add:"), "asm:\n{}", asm);
        // Prologue moves the two integer params from rdi/rsi to stack slots
        // (now emitted with an explicit size suffix).
        assert!(asm.contains("movq %rdi,"), "asm:\n{}", asm);
        assert!(asm.contains("movq %rsi,"), "asm:\n{}", asm);
        // The actual addition.
        assert!(asm.contains("addq %rcx, %rax"), "asm:\n{}", asm);
        // Block labels are emitted as valid (colon-terminated) GAS labels.
        assert!(asm.contains("_tl_add.entry:"), "asm:\n{}", asm);
    }

    #[test]
    fn test_register_backed_scalar_locals_use_callee_saved_homes() {
        let asm = compile_ok(
            r#"
            (define (main) : i64
              (let ([a : i64 40] [b : i64 2])
                (+ a b)))
            "#,
        );

        assert!(asm.contains("    movq %rbx, -"), "asm:\n{}", asm);
        assert!(asm.contains("    movq %r12, -"), "asm:\n{}", asm);
        assert!(asm.contains("    movq %r13, -"), "asm:\n{}", asm);
        assert!(asm.contains("    movq $40, %rbx"), "asm:\n{}", asm);
        assert!(asm.contains("    movq $2, %r12"), "asm:\n{}", asm);
        assert!(asm.contains("    movq %rax, %r13"), "asm:\n{}", asm);
        assert!(asm.contains("(%rbp), %r13"), "asm:\n{}", asm);
        assert!(asm.contains("(%rbp), %r12"), "asm:\n{}", asm);
        assert!(asm.contains("(%rbp), %rbx"), "asm:\n{}", asm);
        assert!(!asm.contains("    movq $40, -"), "asm:\n{}", asm);
        assert!(!asm.contains("    movq $2, -"), "asm:\n{}", asm);
    }

    #[test]
    fn test_windows_register_homes_include_windows_callee_saved_regs() {
        let asm = compile_ok_for_target(
            r#"
            (define (main) : i64
              (let ([a : i64 1] [b : i64 2] [c : i64 3] [d : i64 4]
                    [e : i64 5] [f : i64 6] [g : i64 7])
                (+ (+ (+ a b) (+ c d)) (+ (+ e f) g))))
            "#,
            BackendTarget::windows_x86_64(),
        );

        assert!(asm.contains("    movq %rbx, -"), "asm:\n{}", asm);
        assert!(asm.contains("    movq %rsi, -"), "asm:\n{}", asm);
        assert!(asm.contains("    movq %rdi, -"), "asm:\n{}", asm);
        assert!(asm.contains("    movq $1, %rbx"), "asm:\n{}", asm);
        assert!(asm.contains("    movq $2, %rsi"), "asm:\n{}", asm);
        assert!(asm.contains("    movq $3, %rdi"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_comptime_function_params_emit_specialized_symbols() {
        let asm = compile_ok(
            r#"
            (define (scale [comptime n : i64] [x : i64]) : i64
              (* n x))
            (define (main) : i64
              (+ (scale 2 10) (scale 3 20)))
            "#,
        );
        assert!(!asm.contains("_tl_scale:"), "asm:\n{}", asm);
        assert!(
            asm.matches("_tl___tl_specialized_scale_").count() >= 2,
            "asm:\n{}",
            asm
        );
    }

    #[test]
    fn test_compile_subtraction() {
        let asm = compile_ok("(define (sub [a : i64] [b : i64]) : i64 (- a b))");
        assert!(asm.contains("subq %rcx, %rax"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_direct_call_and_recursion() {
        // Direct calls (including the recursive shape without `if`) are supported:
        // arguments go into the SysV argument registers and a `call` is emitted.
        let asm = compile_ok(
            r#"
            (define (inc [x : i64]) : i64 (+ x 1))
            (define (twice [x : i64]) : i64 (inc (inc x)))
        "#,
        );
        assert!(asm.contains("_tl_inc:"), "asm:\n{}", asm);
        assert!(asm.contains("_tl_twice:"), "asm:\n{}", asm);
        assert!(asm.contains("call _tl_inc"), "asm:\n{}", asm);
        // Argument register load for the call.
        assert!(asm.contains("%rdi"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_direct_call_stack_integer_args() {
        let asm = compile_ok(
            r#"
            (define (sum8
                [a : i64] [b : i64] [c : i64] [d : i64]
                [e : i64] [f : i64] [g : i64] [h : i64]) : i64
              (+ (+ (+ (+ (+ (+ (+ a b) c) d) e) f) g) h))
            (define (main) : i64 (sum8 1 2 3 4 5 6 7 8))
            "#,
        );
        assert!(asm.contains("_tl_sum8:"), "asm:\n{}", asm);
        assert!(asm.contains("    movq 16(%rbp), %r11"), "asm:\n{}", asm);
        assert!(asm.contains("    movq 24(%rbp), %r11"), "asm:\n{}", asm);
        assert!(asm.contains("    sub $16, %rsp"), "asm:\n{}", asm);
        assert!(asm.contains("    movq $7, %r11"), "asm:\n{}", asm);
        assert!(asm.contains("    movq %r11, 0(%rsp)"), "asm:\n{}", asm);
        assert!(asm.contains("    movq $8, %r11"), "asm:\n{}", asm);
        assert!(asm.contains("    movq %r11, 8(%rsp)"), "asm:\n{}", asm);
        assert!(asm.contains("    call _tl_sum8"), "asm:\n{}", asm);
        assert!(asm.contains("    add $16, %rsp"), "asm:\n{}", asm);
        assert!(!asm.contains("# TODO"), "unhandled instruction:\n{}", asm);
    }

    #[test]
    fn test_compile_direct_call_stack_float_arg() {
        let asm = compile_ok(
            r#"
            (define (pick9
                [a : f64] [b : f64] [c : f64] [d : f64] [e : f64]
                [f : f64] [g : f64] [h : f64] [i : f64]) : f64
              i)
            (define (main) : f64 (pick9 1.0 2.0 3.0 4.0 5.0 6.0 7.0 8.0 9.0))
            "#,
        );
        assert!(asm.contains("_tl_pick9:"), "asm:\n{}", asm);
        assert!(asm.contains("    movsd 16(%rbp), %xmm15"), "asm:\n{}", asm);
        assert!(asm.contains("    sub $16, %rsp"), "asm:\n{}", asm);
        assert!(asm.contains("    movq %rax, %xmm15"), "asm:\n{}", asm);
        assert!(asm.contains("    movsd %xmm15, 0(%rsp)"), "asm:\n{}", asm);
        assert!(asm.contains("    call _tl_pick9"), "asm:\n{}", asm);
        assert!(asm.contains("    add $16, %rsp"), "asm:\n{}", asm);
        assert!(!asm.contains("# TODO"), "unhandled instruction:\n{}", asm);
    }

    #[test]
    fn test_compile_surface_function_pointer_param_call() {
        let asm = compile_ok(
            r#"
            (define (apply1 [f : (-> i64 i64)] [x : i64]) : i64
              (f x))
            "#,
        );
        assert!(asm.contains("_tl_apply1:"), "asm:\n{}", asm);
        assert!(asm.contains("    movq -16(%rbp), %rsi"), "asm:\n{}", asm);
        assert!(asm.contains("    movq -8(%rbp), %r11"), "asm:\n{}", asm);
        assert!(asm.contains("    movq 8(%r11), %rdi"), "asm:\n{}", asm);
        assert!(asm.contains("    movq (%r11), %rax"), "asm:\n{}", asm);
        assert!(asm.contains("    call *%rax"), "asm:\n{}", asm);
        assert!(!asm.contains("    call _tl_f"), "asm:\n{}", asm);
        assert!(!asm.contains("# TODO"), "unhandled instruction:\n{}", asm);
    }

    #[test]
    fn test_compile_named_function_pointer_value_arg_from_source() {
        let asm = compile_ok(
            r#"
            (define (inc [x : i64]) : i64
              (+ x 1))
            (define (apply1 [f : (-> i64 i64)] [x : i64]) : i64
              (f x))
            (define (main) : i64
              (apply1 inc 41))
            "#,
        );
        assert!(asm.contains("_tl_inc:"), "asm:\n{}", asm);
        assert!(asm.contains(".L_tl_fn_desc_inc:"), "asm:\n{}", asm);
        assert!(
            asm.contains("    .quad .L_tl_fn_entry_inc"),
            "asm:\n{}",
            asm
        );
        assert!(asm.contains("    .quad 0"), "asm:\n{}", asm);
        assert!(asm.contains(".L_tl_fn_entry_inc:"), "asm:\n{}", asm);
        assert!(asm.contains("    call _tl_inc"), "asm:\n{}", asm);
        assert!(
            asm.contains("    leaq .L_tl_fn_desc_inc(%rip), %rdi"),
            "asm:\n{}",
            asm
        );
        assert!(asm.contains("    call _tl_apply1"), "asm:\n{}", asm);
        assert!(asm.contains("    call *%rax"), "asm:\n{}", asm);
        assert!(!asm.contains("# TODO"), "unhandled instruction:\n{}", asm);
    }

    #[test]
    fn test_compile_extern_function_pointer_value_arg_from_source() {
        let asm = compile_ok(
            r#"
            (extern host-inc : (-> i64 i64))
            (define (apply1 [f : (-> i64 i64)] [x : i64]) : i64
              (f x))
            (define (main) : i64
              (apply1 host-inc 41))
            "#,
        );
        assert!(asm.contains("    .extern host_inc"), "asm:\n{}", asm);
        assert!(asm.contains(".L_tl_fn_desc_host_inc:"), "asm:\n{}", asm);
        assert!(
            asm.contains("    .quad .L_tl_fn_entry_host_inc"),
            "asm:\n{}",
            asm
        );
        assert!(asm.contains(".L_tl_fn_entry_host_inc:"), "asm:\n{}", asm);
        assert!(asm.contains("    call host_inc"), "asm:\n{}", asm);
        assert!(
            asm.contains("    leaq .L_tl_fn_desc_host_inc(%rip), %rdi"),
            "asm:\n{}",
            asm
        );
        assert!(asm.contains("    call _tl_apply1"), "asm:\n{}", asm);
        assert!(asm.contains("    call *%rax"), "asm:\n{}", asm);
        assert!(!asm.contains("# TODO"), "unhandled instruction:\n{}", asm);
    }

    #[test]
    fn test_compile_noncapturing_lambda_literal_from_source() {
        let asm = compile_ok(
            r#"
            (define (main) : i64
              ((lambda ([x : i64]) : i64 (+ x 1)) 41))
            "#,
        );
        assert!(asm.contains("_tl___tl_lambda_main_0:"), "asm:\n{}", asm);
        assert!(
            asm.contains(".L_tl_fn_desc___tl_lambda_main_0:"),
            "asm:\n{}",
            asm
        );
        assert!(
            asm.contains("    .quad .L_tl_fn_entry___tl_lambda_main_0"),
            "asm:\n{}",
            asm
        );
        assert!(
            asm.contains(".L_tl_fn_entry___tl_lambda_main_0:"),
            "asm:\n{}",
            asm
        );
        assert!(
            asm.contains("    call _tl___tl_lambda_main_0"),
            "asm:\n{}",
            asm
        );
        assert!(
            asm.contains("    leaq .L_tl_fn_desc___tl_lambda_main_0(%rip), %r11"),
            "asm:\n{}",
            asm
        );
        assert!(asm.contains("    call *%rax"), "asm:\n{}", asm);
        assert!(!asm.contains("# TODO"), "unhandled instruction:\n{}", asm);
    }

    #[test]
    fn test_compile_inferred_lambda_return_with_local_let_from_source() {
        let asm = compile_ok(
            r#"
            (define (main) : i64
              ((lambda ([x : i64])
                 (let ([y : i64 (+ x 1)])
                   y))
               41))
            "#,
        );
        assert!(asm.contains("_tl___tl_lambda_main_0:"), "asm:\n{}", asm);
        assert!(asm.contains("    call *%rax"), "asm:\n{}", asm);
        assert!(!asm.contains("# TODO"), "unhandled instruction:\n{}", asm);
    }

    #[test]
    fn test_compile_aggregate_returning_lambdas_from_source() {
        let asm = compile_ok(
            r#"
            (defenum Box (BoxI i64))
            (defstruct Pair (x i64) (y i64))

            (define (main) : i64
              (let ([mk-string : (-> String) (lambda () : String "hello")]
                    [mk-enum : (-> Box) (lambda () : Box (BoxI 11))]
                    [mk-array : (-> (Array i64)) (lambda () : (Array i64) (make-array i64 13))]
                    [mk-struct : (-> Pair) (lambda () : Pair (Pair 1 13))])
                (+ (string-length (mk-string))
                   (+ (match (mk-enum) [(BoxI n) n])
                      (+ (array-length (mk-array))
                         (struct-get (mk-struct) y))))))
            "#,
        );

        for name in [
            "_tl___tl_lambda_main_0:",
            "_tl___tl_lambda_main_1:",
            "_tl___tl_lambda_main_2:",
            "_tl___tl_lambda_main_3:",
        ] {
            assert!(asm.contains(name), "asm:\n{}", asm);
        }
        assert!(asm.contains("tl_alloc:"), "asm:\n{}", asm);
        assert!(
            asm.matches("    call tl_alloc").count() >= 5,
            "expected heap promotion for aggregate lambda returns:\n{}",
            asm
        );
        assert!(asm.contains("    call *%rax"), "asm:\n{}", asm);
        assert!(!asm.contains("# TODO"), "unhandled instruction:\n{}", asm);
    }

    #[test]
    fn test_compile_unit_named_function_pointer_value_arg_from_source() {
        let asm = compile_ok(
            r#"
            (define seen : i64 0)
            (define (mark) : unit
              (set! seen 42))
            (define (apply0u [f : (-> unit)]) : unit
              (f))
            (define (main) : i64
              (begin
                (apply0u mark)
                seen))
            "#,
        );
        assert!(asm.contains("_tl_mark:"), "asm:\n{}", asm);
        assert!(asm.contains(".L_tl_fn_desc_mark:"), "asm:\n{}", asm);
        assert!(
            asm.contains("    .quad .L_tl_fn_entry_mark"),
            "asm:\n{}",
            asm
        );
        assert!(asm.contains(".L_tl_fn_entry_mark:"), "asm:\n{}", asm);
        assert!(asm.contains("    call _tl_mark"), "asm:\n{}", asm);
        assert!(
            asm.contains("    leaq .L_tl_fn_desc_mark(%rip), %rdi"),
            "asm:\n{}",
            asm
        );
        assert!(asm.contains("    call _tl_apply0u"), "asm:\n{}", asm);
        assert!(asm.contains("    call *%rax"), "asm:\n{}", asm);
        assert!(!asm.contains("# TODO"), "unhandled instruction:\n{}", asm);
    }

    #[test]
    fn test_compile_indirect_call_through_function_pointer_param() {
        let program = Program {
            functions: vec![Function {
                name: "apply1".into(),
                params: vec![
                    (0, Type::Func(vec![Type::I64], Box::new(Type::I64))),
                    (1, Type::I64),
                ],
                ret: Type::I64,
                locals: vec![(2, Type::I64)],
                blocks: vec![BasicBlock {
                    label: "entry".into(),
                    instructions: vec![
                        Instruction::CallIndirect {
                            dst: Some(2),
                            func: Value::Var(0),
                            args: vec![Value::Var(1)],
                            ty: Type::I64,
                        },
                        Instruction::Return(Some(Value::Var(2))),
                    ],
                }],
                entry: "entry".into(),
            }],
            globals: vec![],
            externs: vec![],
        };
        let asm = generate_assembly(&program).expect("function-pointer call should compile");
        assert!(asm.contains("_tl_apply1:"), "asm:\n{}", asm);
        assert!(asm.contains("    movq -16(%rbp), %rsi"), "asm:\n{}", asm);
        assert!(asm.contains("    movq -8(%rbp), %r11"), "asm:\n{}", asm);
        assert!(asm.contains("    movq 8(%r11), %rdi"), "asm:\n{}", asm);
        assert!(asm.contains("    movq (%r11), %rax"), "asm:\n{}", asm);
        assert!(asm.contains("    call *%rax"), "asm:\n{}", asm);
        assert!(!asm.contains("# TODO"), "unhandled instruction:\n{}", asm);
    }

    #[test]
    fn test_reject_indirect_call_through_non_function_value() {
        let err = generate_assembly(&Program {
            functions: vec![Function {
                name: "bad".into(),
                params: vec![(0, Type::I64)],
                ret: Type::I64,
                locals: vec![(1, Type::I64)],
                blocks: vec![BasicBlock {
                    label: "entry".into(),
                    instructions: vec![Instruction::CallIndirect {
                        dst: Some(1),
                        func: Value::Var(0),
                        args: vec![],
                        ty: Type::I64,
                    }],
                }],
                entry: "entry".into(),
            }],
            globals: vec![],
            externs: vec![],
        })
        .expect_err("non-function indirect call target should be rejected");
        assert!(
            err.contains("indirect call through a non-function value"),
            "err: {}",
            err
        );
    }

    #[test]
    fn test_compile_address_of_local_slot() {
        let program = Program {
            functions: vec![Function {
                name: "addr".into(),
                params: vec![],
                ret: Type::U64,
                locals: vec![(0, Type::I64), (1, Type::U64)],
                blocks: vec![BasicBlock {
                    label: "entry".into(),
                    instructions: vec![
                        Instruction::AddrOf { dst: 1, src: 0 },
                        Instruction::Return(Some(Value::Var(1))),
                    ],
                }],
                entry: "entry".into(),
            }],
            globals: vec![],
            externs: vec![],
        };
        let asm = generate_assembly(&program).expect("address-of should compile");
        assert!(asm.contains("    leaq -8(%rbp), %rax"), "asm:\n{}", asm);
        assert!(asm.contains("    movq %rax, %rbx"), "asm:\n{}", asm);
        assert!(asm.contains("    movq %rbx, %rax"), "asm:\n{}", asm);
        assert!(!asm.contains("# TODO"), "unhandled instruction:\n{}", asm);
    }

    #[test]
    fn test_compile_gep_scales_offset_by_element_size() {
        let program = Program {
            functions: vec![Function {
                name: "gep".into(),
                params: vec![],
                ret: Type::U64,
                locals: vec![(0, Type::U64), (1, Type::U64)],
                blocks: vec![BasicBlock {
                    label: "entry".into(),
                    instructions: vec![
                        Instruction::Mov {
                            dst: 0,
                            src: Value::ConstI64(1000),
                            ty: Type::U64,
                        },
                        Instruction::Gep {
                            dst: 1,
                            base: Value::Var(0),
                            offset: Value::ConstI64(3),
                            elem_ty: Type::I64,
                        },
                        Instruction::Return(Some(Value::Var(1))),
                    ],
                }],
                entry: "entry".into(),
            }],
            globals: vec![],
            externs: vec![],
        };
        let asm = generate_assembly(&program).expect("gep should compile");
        assert!(asm.contains("    movq $1000, %rbx"), "asm:\n{}", asm);
        assert!(asm.contains("    movq %rbx, %rax"), "asm:\n{}", asm);
        assert!(asm.contains("    movq $3, %rcx"), "asm:\n{}", asm);
        assert!(asm.contains("    imulq $8, %rcx"), "asm:\n{}", asm);
        assert!(asm.contains("    addq %rcx, %rax"), "asm:\n{}", asm);
        assert!(asm.contains("    movq %rax, %r12"), "asm:\n{}", asm);
        assert!(!asm.contains("# TODO"), "unhandled instruction:\n{}", asm);
    }

    #[test]
    fn test_compile_load_store_through_computed_address() {
        let program = Program {
            functions: vec![Function {
                name: "ptr_rw".into(),
                params: vec![],
                ret: Type::I64,
                locals: vec![(0, Type::I64), (1, Type::U64), (2, Type::I64)],
                blocks: vec![BasicBlock {
                    label: "entry".into(),
                    instructions: vec![
                        Instruction::AddrOf { dst: 1, src: 0 },
                        Instruction::Store {
                            dst: Value::Var(1),
                            src: Value::ConstI64(99),
                            ty: Type::I64,
                        },
                        Instruction::Load {
                            dst: 2,
                            src: Value::Var(1),
                            ty: Type::I64,
                        },
                        Instruction::Return(Some(Value::Var(2))),
                    ],
                }],
                entry: "entry".into(),
            }],
            globals: vec![],
            externs: vec![],
        };
        let asm = generate_assembly(&program).expect("computed-address load/store should compile");
        assert!(asm.contains("    leaq -8(%rbp), %rax"), "asm:\n{}", asm);
        assert!(asm.contains("    movq %rax, %rbx"), "asm:\n{}", asm);
        assert!(asm.contains("    movq %rbx, %r10"), "asm:\n{}", asm);
        assert!(asm.contains("    movq $99, %rax"), "asm:\n{}", asm);
        assert!(asm.contains("    movq %rax, (%r10)"), "asm:\n{}", asm);
        assert!(asm.contains("    movq (%r10), %rax"), "asm:\n{}", asm);
        assert!(asm.contains("    movq %rax, %r12"), "asm:\n{}", asm);
        assert!(!asm.contains("# TODO"), "unhandled instruction:\n{}", asm);
    }

    #[test]
    fn test_compile_synthesizes_main_when_absent() {
        // A program with no `main` gets a trivial `main` so the entry symbol exists.
        let asm = compile_ok("(define (helper [x : i64]) : i64 (+ x 1))");
        assert!(asm.contains("main:"), "asm:\n{}", asm);
        assert!(asm.contains("xor %eax, %eax"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_comparison() {
        let asm = compile_ok("(define (lt [a : i64] [b : i64]) : bool (< a b))");
        assert!(asm.contains("cmpq %rcx, %rax"), "asm:\n{}", asm);
        assert!(asm.contains("setl %al"), "asm:\n{}", asm);
        assert!(asm.contains("movb %al,"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_float_constant_return() {
        let asm = compile_ok("(define (pi) : f64 3.14)");
        assert!(
            asm.contains("movabsq $0x40091eb851eb851f, %rax"),
            "asm:\n{}",
            asm
        );
        assert!(asm.contains("movq %rax, %xmm0"), "asm:\n{}", asm);
        assert!(asm.contains("ret"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_float_add_function() {
        let asm = compile_ok("(define (addf [a : f64] [b : f64]) : f64 (+ a b))");
        assert!(asm.contains("movsd %xmm0,"), "asm:\n{}", asm);
        assert!(asm.contains("movsd %xmm1,"), "asm:\n{}", asm);
        assert!(asm.contains("addsd %xmm1, %xmm0"), "asm:\n{}", asm);
        assert!(!asm.contains("addq %rcx, %rax"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_float_comparison() {
        let asm = compile_ok("(define (ltf [a : f64] [b : f64]) : bool (< a b))");
        assert!(asm.contains("ucomisd %xmm1, %xmm0"), "asm:\n{}", asm);
        assert!(asm.contains("setb %al"), "asm:\n{}", asm);
        assert!(asm.contains("movb %al,"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_float_negation() {
        let prog = ast::Program {
            decls: vec![ast::Decl::DefFn {
                name: "negf".into(),
                params: vec![("x".into(), Type::F64)],
                comptime_params: vec![],
                ret: Type::F64,
                body: ast::Expr::Unary {
                    op: ast::UnOp::Neg,
                    expr: Box::new(ast::Expr::Var("x".into())),
                },
            }],
        };
        let mut ir = lower_program(&prog);
        Optimizer::optimize(&mut ir);
        let asm = generate_assembly(&ir).expect("backend should accept f64 negation");
        assert!(asm.contains("pxor %xmm1, %xmm1"), "asm:\n{}", asm);
        assert!(asm.contains("subsd %xmm0, %xmm1"), "asm:\n{}", asm);
        assert!(asm.contains("movapd %xmm1, %xmm0"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_float_call_args_and_return() {
        let asm = compile_ok(
            r#"
            (define (half [x : f64]) : f64 (/ x 2.0))
            (define (main) : f64 (half 4.0))
        "#,
        );
        assert!(asm.contains("call _tl_half"), "asm:\n{}", asm);
        assert!(asm.contains("divsd %xmm1, %xmm0"), "asm:\n{}", asm);
        assert!(asm.contains("movq %rax, %xmm0"), "asm:\n{}", asm);
        assert!(asm.contains("movsd %xmm0,"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_mixed_integer_and_float_params_use_independent_abi_registers() {
        let asm = compile_ok("(define (second [n : i64] [x : f64]) : f64 x)");
        assert!(asm.contains("    movq %rdi, -8(%rbp)"), "asm:\n{}", asm);
        assert!(asm.contains("    movsd %xmm0, -16(%rbp)"), "asm:\n{}", asm);
        assert!(!asm.contains("    movsd %xmm1, -16(%rbp)"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_float_let_binding_uses_xmm_load_store() {
        let asm = compile_ok("(define (idlet [x : f64]) : f64 (let ([y : f64 x]) y))");
        assert!(asm.contains("movsd -8(%rbp), %xmm0"), "asm:\n{}", asm);
        assert!(asm.contains("movsd %xmm0, -16(%rbp)"), "asm:\n{}", asm);
        assert!(!asm.contains("movsd %rax"), "asm:\n{}", asm);
        assert!(!asm.contains("# TODO"), "unhandled instruction:\n{}", asm);
    }

    // ---- Graceful rejection of out-of-scope constructs -----------------

    // ---- Control flow: `if` / Phi (issue #36) --------------------------

    #[test]
    fn test_compile_if_expression() {
        // `if` lowers to a Branch into then/else blocks and a Phi in the merge
        // block. The backend now selects this: a conditional `jnz` to the then
        // label, an unconditional fall-through `jmp` to the else label, a
        // colon-terminated merge label, and a `mov` of each arm's value into
        // the phi's stack slot at the end of each predecessor.
        let asm = compile_ok("(define (max [a : i64] [b : i64]) : i64 (if (> a b) a b))");

        // Conditional branch selection against qualified block labels.
        assert!(asm.contains("testb %al, %al"), "asm:\n{}", asm);
        assert!(
            !asm.contains("testq %rax, %rax"),
            "bool branch condition must use byte-width test; asm:\n{}",
            asm
        );
        assert!(asm.contains("jnz _tl_max.then."), "asm:\n{}", asm);
        assert!(asm.contains("jmp _tl_max.else."), "asm:\n{}", asm);

        // The merge block is emitted as a real, colon-terminated GAS label, and
        // both arms jump to it. Find the actual merge label and assert it is
        // defined (followed by `:`) as well as targeted by the jumps.
        let merge_def = asm
            .lines()
            .find(|l| l.starts_with("_tl_max.merge.") && l.ends_with(':'));
        assert!(
            merge_def.is_some(),
            "merge label not defined; asm:\n{}",
            asm
        );
        let merge_jumps = asm.matches("jmp _tl_max.merge.").count();
        assert_eq!(
            merge_jumps, 2,
            "both arms should jump to merge; asm:\n{}",
            asm
        );

        // Phi elimination: each arm writes its value into the phi's stack slot.
        // The phi result is the function result, so the merge block returns it.
        assert!(asm.contains("(%rbp)"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_if_phi_slot_moves() {
        // Verify the phi result is materialized by stack-slot moves in the
        // predecessor blocks (not by a fall-through that reads an undefined
        // register). We expect a load of each arm's value into a register and a
        // store into a single stack slot, performed on both arms.
        let asm = compile_ok("(define (pick [a : i64] [b : i64]) : i64 (if (> a b) 100 200))");
        // The two constant arms move their literals into the phi slot. After
        // copy-propagation the constants reach the phi sources directly.
        assert!(asm.contains("$100"), "asm:\n{}", asm);
        assert!(asm.contains("$200"), "asm:\n{}", asm);
        // Branch + both merge jumps present.
        assert!(asm.contains("jnz _tl_pick.then."), "asm:\n{}", asm);
        assert_eq!(
            asm.matches("jmp _tl_pick.merge.").count(),
            2,
            "asm:\n{}",
            asm
        );
    }

    #[test]
    fn test_phi_elimination_parallel_copies_preserve_overlapping_sources() {
        // Multiple phis from the same predecessor are parallel copies. A swap
        // like `%0 <- %1`, `%1 <- %0` must preserve the original `%0` and `%1`
        // values before either destination slot is overwritten.
        let func = Function {
            name: "swap_phi".into(),
            params: vec![],
            ret: Type::I64,
            locals: vec![(0, Type::I64), (1, Type::I64)],
            blocks: vec![
                BasicBlock {
                    label: "pred".into(),
                    instructions: vec![Instruction::Jump("merge".into())],
                },
                BasicBlock {
                    label: "merge".into(),
                    instructions: vec![
                        Instruction::Phi {
                            dst: 0,
                            incoming: vec![(Value::Var(1), "pred".into())],
                            ty: Type::I64,
                        },
                        Instruction::Phi {
                            dst: 1,
                            incoming: vec![(Value::Var(0), "pred".into())],
                            ty: Type::I64,
                        },
                        Instruction::Return(Some(Value::Var(0))),
                    ],
                },
            ],
            entry: "pred".into(),
        };

        let lowered = eliminate_phis(&func);
        assert!(lowered.locals.contains(&(2, Type::I64)));
        assert!(lowered.locals.contains(&(3, Type::I64)));
        assert!(
            lowered
                .blocks
                .iter()
                .flat_map(|b| &b.instructions)
                .all(|i| !matches!(i, Instruction::Phi { .. }))
        );

        let pred = lowered
            .blocks
            .iter()
            .find(|b| b.label == "pred")
            .expect("pred block");
        assert_eq!(
            pred.instructions,
            vec![
                Instruction::Mov {
                    dst: 2,
                    src: Value::Var(1),
                    ty: Type::I64,
                },
                Instruction::Mov {
                    dst: 3,
                    src: Value::Var(0),
                    ty: Type::I64,
                },
                Instruction::Mov {
                    dst: 0,
                    src: Value::Var(2),
                    ty: Type::I64,
                },
                Instruction::Mov {
                    dst: 1,
                    src: Value::Var(3),
                    ty: Type::I64,
                },
                Instruction::Jump("merge".into()),
            ]
        );
    }

    #[test]
    fn test_liveness_tracks_straight_line_defs_and_live_after() {
        let func = Function {
            name: "straight_line".into(),
            params: vec![],
            ret: Type::I64,
            locals: vec![(0, Type::I64), (1, Type::I64)],
            blocks: vec![BasicBlock {
                label: "entry".into(),
                instructions: vec![
                    Instruction::Mov {
                        dst: 0,
                        src: Value::ConstI64(40),
                        ty: Type::I64,
                    },
                    Instruction::BinOp {
                        dst: 1,
                        op: BinOp::Add,
                        lhs: Value::Var(0),
                        rhs: Value::ConstI64(2),
                        ty: Type::I64,
                    },
                    Instruction::Return(Some(Value::Var(1))),
                ],
            }],
            entry: "entry".into(),
        };

        let analysis = liveness::analyze(&func);
        let entry = analysis.block("entry").expect("entry block");
        assert_var_set(&entry.uses, &[]);
        assert_var_set(&entry.defs, &[0, 1]);
        assert_var_set(&entry.live_in, &[]);
        assert_var_set(&entry.live_out, &[]);
        assert_live_after(&analysis, "entry", 0, &[0]);
        assert_live_after(&analysis, "entry", 1, &[1]);
        assert_live_after(&analysis, "entry", 2, &[]);
    }

    #[test]
    fn test_liveness_tracks_branch_merge_after_phi_elimination() {
        let func = Function {
            name: "branch_merge".into(),
            params: vec![(0, Type::Bool)],
            ret: Type::I64,
            locals: vec![(1, Type::I64), (2, Type::I64), (3, Type::I64)],
            blocks: vec![
                BasicBlock {
                    label: "entry".into(),
                    instructions: vec![Instruction::Branch {
                        cond: Value::Var(0),
                        true_label: "then".into(),
                        false_label: "else".into(),
                    }],
                },
                BasicBlock {
                    label: "then".into(),
                    instructions: vec![
                        Instruction::Mov {
                            dst: 1,
                            src: Value::ConstI64(10),
                            ty: Type::I64,
                        },
                        Instruction::Jump("merge".into()),
                    ],
                },
                BasicBlock {
                    label: "else".into(),
                    instructions: vec![
                        Instruction::Mov {
                            dst: 2,
                            src: Value::ConstI64(20),
                            ty: Type::I64,
                        },
                        Instruction::Jump("merge".into()),
                    ],
                },
                BasicBlock {
                    label: "merge".into(),
                    instructions: vec![
                        Instruction::Phi {
                            dst: 3,
                            incoming: vec![
                                (Value::Var(1), "then".into()),
                                (Value::Var(2), "else".into()),
                            ],
                            ty: Type::I64,
                        },
                        Instruction::Return(Some(Value::Var(3))),
                    ],
                },
            ],
            entry: "entry".into(),
        };

        let lowered = eliminate_phis(&func);
        assert!(
            lowered
                .blocks
                .iter()
                .flat_map(|block| &block.instructions)
                .all(|instr| !matches!(instr, Instruction::Phi { .. }))
        );

        let analysis = liveness::analyze(&lowered);
        let entry = analysis.block("entry").expect("entry block");
        assert_var_set(&entry.uses, &[0]);
        assert_var_set(&entry.live_in, &[0]);
        assert_var_set(&entry.live_out, &[]);

        let then_block = analysis.block("then").expect("then block");
        assert_var_set(&then_block.uses, &[]);
        assert_var_set(&then_block.defs, &[1, 3]);
        assert_var_set(&then_block.live_in, &[]);
        assert_var_set(&then_block.live_out, &[3]);
        assert_live_after(&analysis, "then", 0, &[1]);
        assert_live_after(&analysis, "then", 1, &[3]);
        assert_live_after(&analysis, "then", 2, &[3]);

        let else_block = analysis.block("else").expect("else block");
        assert_var_set(&else_block.defs, &[2, 3]);
        assert_var_set(&else_block.live_out, &[3]);
        assert_live_after(&analysis, "else", 0, &[2]);
        assert_live_after(&analysis, "else", 1, &[3]);

        let merge = analysis.block("merge").expect("merge block");
        assert_var_set(&merge.uses, &[3]);
        assert_var_set(&merge.live_in, &[3]);
        assert_var_set(&merge.live_out, &[]);
        assert_live_after(&analysis, "merge", 0, &[]);
    }

    #[test]
    fn test_liveness_tracks_call_arguments_results_and_returns() {
        let func = Function {
            name: "call_liveness".into(),
            params: vec![],
            ret: Type::I64,
            locals: vec![(0, Type::I64), (1, Type::I64), (2, Type::I64)],
            blocks: vec![BasicBlock {
                label: "entry".into(),
                instructions: vec![
                    Instruction::Mov {
                        dst: 0,
                        src: Value::ConstI64(7),
                        ty: Type::I64,
                    },
                    Instruction::Call {
                        dst: Some(1),
                        func: "callee".into(),
                        args: vec![Value::Var(0)],
                        ty: Type::I64,
                    },
                    Instruction::BinOp {
                        dst: 2,
                        op: BinOp::Add,
                        lhs: Value::Var(0),
                        rhs: Value::Var(1),
                        ty: Type::I64,
                    },
                    Instruction::Return(Some(Value::Var(2))),
                ],
            }],
            entry: "entry".into(),
        };

        let analysis = liveness::analyze(&func);
        let entry = analysis.block("entry").expect("entry block");
        assert_var_set(&entry.uses, &[]);
        assert_var_set(&entry.defs, &[0, 1, 2]);
        assert_live_after(&analysis, "entry", 0, &[0]);
        assert_live_after(&analysis, "entry", 1, &[0, 1]);
        assert_live_after(&analysis, "entry", 2, &[2]);
        assert_live_after(&analysis, "entry", 3, &[]);
    }

    #[test]
    fn test_liveness_tracks_tail_call_arguments_as_terminator_inputs() {
        let func = Function {
            name: "tail_liveness".into(),
            params: vec![(0, Type::I64), (1, Type::I64)],
            ret: Type::I64,
            locals: vec![(2, Type::I64)],
            blocks: vec![BasicBlock {
                label: "entry".into(),
                instructions: vec![
                    Instruction::BinOp {
                        dst: 2,
                        op: BinOp::Add,
                        lhs: Value::Var(0),
                        rhs: Value::Var(1),
                        ty: Type::I64,
                    },
                    Instruction::TailCall {
                        func: "tail_liveness".into(),
                        args: vec![Value::Var(2), Value::Var(1)],
                        ty: Type::I64,
                    },
                ],
            }],
            entry: "entry".into(),
        };

        let analysis = liveness::analyze(&func);
        let entry = analysis.block("entry").expect("entry block");
        assert_var_set(&entry.uses, &[0, 1]);
        assert_var_set(&entry.defs, &[2]);
        assert_var_set(&entry.live_in, &[0, 1]);
        assert_var_set(&entry.live_out, &[]);
        assert_live_after(&analysis, "entry", 0, &[1, 2]);
        assert_live_after(&analysis, "entry", 1, &[]);
    }

    #[test]
    fn test_liveness_marks_address_taken_vars() {
        let func = Function {
            name: "address_taken".into(),
            params: vec![],
            ret: Type::I64,
            locals: vec![(0, Type::I64), (1, Type::I64)],
            blocks: vec![BasicBlock {
                label: "entry".into(),
                instructions: vec![
                    Instruction::Alloc {
                        var: 0,
                        ty: Type::I64,
                    },
                    Instruction::AddrOf { dst: 1, src: 0 },
                    Instruction::Return(Some(Value::Var(1))),
                ],
            }],
            entry: "entry".into(),
        };

        let analysis = liveness::analyze(&func);
        let entry = analysis.block("entry").expect("entry block");
        assert_var_set(&entry.uses, &[]);
        assert_var_set(&entry.defs, &[0, 1]);
        assert_var_set(&entry.live_in, &[]);
        assert_var_set(&entry.live_out, &[]);
        assert_var_set(&analysis.address_taken_vars, &[0]);
        assert_live_after(&analysis, "entry", 0, &[0]);
        assert_live_after(&analysis, "entry", 1, &[1]);
        assert_live_after(&analysis, "entry", 2, &[]);
    }

    #[test]
    fn test_compile_recursive_factorial() {
        // A recursive function using `if` must emit real branching assembly
        // plus a recursive `call`. This exercises Branch/Phi/Call together.
        let asm = compile_ok(
            r#"
            (define (fact [n : i64]) : i64
              (if (<= n 1)
                1
                (* n (fact (- n 1)))))
        "#,
        );
        assert!(asm.contains("_tl_fact:"), "asm:\n{}", asm);
        // The condition comparison and branch.
        assert!(asm.contains("setle %al"), "asm:\n{}", asm);
        assert!(asm.contains("jnz _tl_fact.then."), "asm:\n{}", asm);
        assert!(asm.contains("jmp _tl_fact.else."), "asm:\n{}", asm);
        // Recursive call.
        assert!(asm.contains("call _tl_fact"), "asm:\n{}", asm);
        // Multiplication on the recursive arm.
        assert!(asm.contains("imulq %rcx, %rax"), "asm:\n{}", asm);
        // Both arms converge on the merge block.
        assert_eq!(
            asm.matches("jmp _tl_fact.merge.").count(),
            2,
            "asm:\n{}",
            asm
        );
    }

    fn self_tail_sum_program() -> Program {
        Program {
            functions: vec![
                Function {
                    name: "sum_down".into(),
                    params: vec![(0, Type::I64), (1, Type::I64)],
                    ret: Type::I64,
                    locals: vec![(2, Type::Bool), (3, Type::I64), (4, Type::I64)],
                    blocks: vec![
                        BasicBlock {
                            label: "entry".into(),
                            instructions: vec![
                                Instruction::BinOp {
                                    dst: 2,
                                    op: BinOp::Le,
                                    lhs: Value::Var(0),
                                    rhs: Value::ConstI64(0),
                                    ty: Type::Bool,
                                },
                                Instruction::Branch {
                                    cond: Value::Var(2),
                                    true_label: "done".into(),
                                    false_label: "recurse".into(),
                                },
                            ],
                        },
                        BasicBlock {
                            label: "recurse".into(),
                            instructions: vec![
                                Instruction::BinOp {
                                    dst: 3,
                                    op: BinOp::Sub,
                                    lhs: Value::Var(0),
                                    rhs: Value::ConstI64(1),
                                    ty: Type::I64,
                                },
                                Instruction::BinOp {
                                    dst: 4,
                                    op: BinOp::Add,
                                    lhs: Value::Var(1),
                                    rhs: Value::Var(0),
                                    ty: Type::I64,
                                },
                                Instruction::TailCall {
                                    func: "sum_down".into(),
                                    args: vec![Value::Var(3), Value::Var(4)],
                                    ty: Type::I64,
                                },
                            ],
                        },
                        BasicBlock {
                            label: "done".into(),
                            instructions: vec![Instruction::Return(Some(Value::Var(1)))],
                        },
                    ],
                    entry: "entry".into(),
                },
                Function {
                    name: "main".into(),
                    params: vec![],
                    ret: Type::I64,
                    locals: vec![(10, Type::I64)],
                    blocks: vec![BasicBlock {
                        label: "entry".into(),
                        instructions: vec![
                            Instruction::Call {
                                dst: Some(10),
                                func: "sum_down".into(),
                                args: vec![Value::ConstI64(5), Value::ConstI64(0)],
                                ty: Type::I64,
                            },
                            Instruction::Return(Some(Value::Var(10))),
                        ],
                    }],
                    entry: "entry".into(),
                },
            ],
            globals: vec![],
            externs: vec![],
        }
    }

    #[test]
    fn test_backend_self_tail_call_rewrites_params_and_jumps_to_entry() {
        let asm = generate_assembly(&self_tail_sum_program())
            .expect("self tail-call program should compile");

        assert!(
            asm.contains("    jmp _tl_sum_down.entry"),
            "tail call should jump to the entry block:\n{}",
            asm
        );
        assert_eq!(
            asm.matches("    call _tl_sum_down").count(),
            1,
            "only main should call sum_down; self tail recursion must be a jump:\n{}",
            asm
        );
        assert!(asm.contains("    push %r11"), "asm:\n{}", asm);
        assert!(asm.contains("    pop %r11"), "asm:\n{}", asm);
        assert!(!asm.contains("# TODO"), "unhandled instruction:\n{}", asm);
    }

    #[test]
    fn test_backend_rejects_non_self_tail_call() {
        let err = generate_assembly(&Program {
            functions: vec![Function {
                name: "f".into(),
                params: vec![(0, Type::I64)],
                ret: Type::I64,
                locals: vec![],
                blocks: vec![BasicBlock {
                    label: "entry".into(),
                    instructions: vec![Instruction::TailCall {
                        func: "g".into(),
                        args: vec![Value::Var(0)],
                        ty: Type::I64,
                    }],
                }],
                entry: "entry".into(),
            }],
            globals: vec![],
            externs: vec![],
        })
        .expect_err("non-self tail calls should be rejected");

        assert!(
            err.contains("tail call target 'g' is not the current function 'f'"),
            "unexpected error: {}",
            err
        );
    }

    #[test]
    fn test_backend_rejects_tail_call_arity_mismatch() {
        let err = generate_assembly(&Program {
            functions: vec![Function {
                name: "f".into(),
                params: vec![(0, Type::I64), (1, Type::I64)],
                ret: Type::I64,
                locals: vec![],
                blocks: vec![BasicBlock {
                    label: "entry".into(),
                    instructions: vec![Instruction::TailCall {
                        func: "f".into(),
                        args: vec![Value::Var(0)],
                        ty: Type::I64,
                    }],
                }],
                entry: "entry".into(),
            }],
            globals: vec![],
            externs: vec![],
        })
        .expect_err("tail call arity mismatch should be rejected");

        assert!(
            err.contains("tail call to 'f' has 1 args but function has 2 params"),
            "unexpected error: {}",
            err
        );
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn test_self_tail_call_hand_built_ir_assembles_links_and_runs() {
        let asm = generate_assembly(&self_tail_sum_program())
            .expect("self tail-call program should compile");
        let root = std::env::temp_dir().join(format!("typelisp-tail-call-{}", std::process::id()));
        std::fs::create_dir_all(&root).expect("create tail-call test directory");
        let asm_path = root.join("tailcall.s");
        let obj_path = root.join("tailcall.o");
        let bin_path = root.join("tailcall");
        std::fs::write(&asm_path, asm).expect("write tail-call assembly");

        let assemble = Command::new("as")
            .arg(&asm_path)
            .arg("-o")
            .arg(&obj_path)
            .status()
            .expect("run assembler");
        assert!(assemble.success(), "assembling tail-call program failed");

        let link = Command::new("ld")
            .arg(&obj_path)
            .arg("-o")
            .arg(&bin_path)
            .status()
            .expect("run linker");
        assert!(link.success(), "linking tail-call program failed");

        let output = Command::new(&bin_path)
            .output()
            .expect("run tail-call program");
        assert_eq!(output.status.code(), Some(15), "output: {:?}", output);

        let _ = std::fs::remove_dir_all(root);
    }

    // ---- Locals: `let` / `set!` (Alloc/Store/Load) (issue #36) ---------

    #[test]
    fn test_compile_let_binding() {
        // `(let ([y (+ x x)]) (+ y x))` allocates a slot for `y`, stores the
        // computed value into it, and later loads it. The backend now emits a
        // real store into y's slot rather than rejecting the program.
        let asm = compile_ok("(define (triple [x : i64]) : i64 (let ([y : i64 (+ x x)]) (+ y x)))");
        assert!(asm.contains("_tl_triple:"), "asm:\n{}", asm);
        // The `(+ x x)` addition feeding the binding.
        assert!(asm.contains("addq %rcx, %rax"), "asm:\n{}", asm);
        // A store into y's stack slot, then a later load/use from a slot.
        assert!(asm.contains("(%rbp)"), "asm:\n{}", asm);
        // No leftover TODO placeholder for Store/Load.
        assert!(!asm.contains("# TODO"), "unhandled instruction:\n{}", asm);
    }

    #[test]
    fn test_compile_set_mutation() {
        // `set!` lowers to a Store into the variable's existing slot. The
        // begin-sequence increments x twice, so two stores must be emitted.
        let asm = compile_ok(
            r#"
            (define (add2 [x : i64]) : i64
              (begin
                (set! x (+ x 1))
                (set! x (+ x 1))
                x))
        "#,
        );
        assert!(asm.contains("_tl_add2:"), "asm:\n{}", asm);
        // Two `(+ x 1)` additions.
        assert_eq!(asm.matches("addq %rcx, %rax").count(), 2, "asm:\n{}", asm);
        assert!(!asm.contains("# TODO"), "unhandled instruction:\n{}", asm);
    }

    #[test]
    fn test_compile_while_loop() {
        // `while` lowers to a header/body/exit block structure with a back-edge
        // jump from the body to the header. Verify the qualified labels and the
        // back-edge are emitted.
        let asm = compile_ok(
            r#"
            (define (countdown [n : i64]) : i64
              (let ([x : i64 n])
                (begin
                  (while (> x 0)
                    (set! x (- x 1)))
                  x)))
        "#,
        );
        assert!(asm.contains("_tl_countdown.while_header."), "asm:\n{}", asm);
        assert!(asm.contains("_tl_countdown.while_body."), "asm:\n{}", asm);
        assert!(asm.contains("_tl_countdown.while_exit."), "asm:\n{}", asm);
        // Header conditional branch into body / exit.
        assert!(
            asm.contains("jnz _tl_countdown.while_body."),
            "asm:\n{}",
            asm
        );
        // Back-edge from the body to the header.
        assert!(
            asm.contains("jmp _tl_countdown.while_header."),
            "asm:\n{}",
            asm
        );
        assert!(!asm.contains("# TODO"), "unhandled instruction:\n{}", asm);
    }

    #[test]
    fn test_reject_empty_program() {
        let err = generate_assembly(&Program {
            functions: vec![],
            globals: vec![],
            externs: vec![],
        })
        .expect_err("empty program should be rejected");
        assert!(err.contains("no functions"), "err: {}", err);
    }

    // ---- Bitwise / shift / cast / unsigned codegen (issue #46) ---------

    #[test]
    fn test_compile_bit_and() {
        let asm = compile_ok("(define (f [a : i64] [b : i64]) : i64 (bit-and a b))");
        assert!(asm.contains("andq %rcx, %rax"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_bit_or() {
        let asm = compile_ok("(define (f [a : i64] [b : i64]) : i64 (bit-or a b))");
        assert!(asm.contains("orq %rcx, %rax"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_bit_xor_emits_xor_not_or() {
        // Miscompile bug 1: bit-xor used to emit `orq`. It must now emit `xorq`.
        let asm = compile_ok("(define (f [a : i64] [b : i64]) : i64 (bit-xor a b))");
        assert!(asm.contains("xorq %rcx, %rax"), "asm:\n{}", asm);
        // The only `orq` allowed would be a bitwise-or, which this program has
        // none of, so assert no stray `orq` instruction slipped through. Match
        // the emitted-line form (`    orq `) to avoid matching the substring
        // inside `xorq`.
        assert!(
            !asm.contains("    orq "),
            "bit-xor must not emit orq; asm:\n{}",
            asm
        );
    }

    #[test]
    fn test_compile_shl_emits_shift_not_add() {
        // Miscompile bug 2: shl used to emit `addq`. It must now emit a real
        // shift through %cl.
        let asm = compile_ok("(define (f [a : i64] [b : i64]) : i64 (shl a b))");
        assert!(asm.contains("shlq %cl, %rax"), "asm:\n{}", asm);
        assert!(
            !asm.contains("addq %rcx, %rax"),
            "shl must not emit addq; asm:\n{}",
            asm
        );
    }

    #[test]
    fn test_compile_mixed_width_shift_uses_lhs_width_and_rhs_count_width() {
        // The shift result has the lhs width, while the count is loaded at its
        // own declared width before %cl is consumed by the shift instruction.
        let asm = compile_ok("(define (f [x : i64] [count : u8]) : i64 (shl x count))");
        assert!(
            asm.contains("    movzbq -9(%rbp), %rcx"),
            "u8 shift count must be byte-loaded into rcx:\n{}",
            asm
        );
        assert!(asm.contains("    shlq %cl, %rax"), "asm:\n{}", asm);
        assert!(
            !asm.contains("    shlb %cl, %al"),
            "shift must keep lhs/result width:\n{}",
            asm
        );
        assert!(
            !asm.contains("    movq -9(%rbp), %rcx"),
            "u8 count must not be read as an i64 stack slot:\n{}",
            asm
        );
    }

    #[test]
    fn test_compile_mixed_width_bitwise_uses_lhs_width_and_rhs_width() {
        // Mixed-width bitwise operations return the lhs type. The rhs still
        // needs a correctly-sized load so a narrow slot is not read as i64.
        let asm = compile_ok("(define (f [x : i64] [mask : u8]) : i64 (bit-and x mask))");
        assert!(
            asm.contains("    movzbq -9(%rbp), %rcx"),
            "u8 rhs must be byte-loaded into rcx:\n{}",
            asm
        );
        assert!(asm.contains("    andq %rcx, %rax"), "asm:\n{}", asm);
        assert!(
            !asm.contains("    andb %cl, %al"),
            "bitwise op must keep lhs/result width:\n{}",
            asm
        );
        assert!(
            !asm.contains("    movq -9(%rbp), %rcx"),
            "u8 rhs must not be read as an i64 stack slot:\n{}",
            asm
        );
    }

    #[test]
    fn test_compile_shr_signed_is_arithmetic() {
        // Signed right shift must be arithmetic (`sarq`).
        let asm = compile_ok("(define (f [a : i64] [b : i64]) : i64 (shr a b))");
        assert!(asm.contains("sarq %cl, %rax"), "asm:\n{}", asm);
        assert!(
            !asm.contains("shrq %cl, %rax"),
            "signed shr must be arithmetic; asm:\n{}",
            asm
        );
    }

    #[test]
    fn test_compile_shr_unsigned_is_logical() {
        // Unsigned right shift must be logical (`shrq`).
        let asm = compile_ok("(define (f [a : u64] [b : u64]) : u64 (shr a b))");
        assert!(asm.contains("shrq %cl, %rax"), "asm:\n{}", asm);
        assert!(
            !asm.contains("sarq %cl, %rax"),
            "unsigned shr must be logical; asm:\n{}",
            asm
        );
    }

    #[test]
    fn test_compile_signed_comparison_uses_signed_codes() {
        // i64 `<` keeps signed condition codes.
        let asm = compile_ok("(define (f [a : i64] [b : i64]) : bool (< a b))");
        assert!(asm.contains("setl %al"), "asm:\n{}", asm);
        assert!(!asm.contains("setb %al"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_unsigned_less_emits_setb() {
        // Previously the `is_signed()` gate dropped unsigned comparisons
        // entirely (no `set*` emitted). They must now emit unsigned codes.
        let asm = compile_ok("(define (f [a : u64] [b : u64]) : bool (< a b))");
        assert!(asm.contains("setb %al"), "asm:\n{}", asm);
        assert!(!asm.contains("setl %al"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_unsigned_relations_emit_unsigned_codes() {
        let asm_le = compile_ok("(define (f [a : u32] [b : u32]) : bool (<= a b))");
        assert!(asm_le.contains("setbe %al"), "asm:\n{}", asm_le);
        let asm_gt = compile_ok("(define (f [a : u32] [b : u32]) : bool (> a b))");
        assert!(asm_gt.contains("seta %al"), "asm:\n{}", asm_gt);
        let asm_ge = compile_ok("(define (f [a : u32] [b : u32]) : bool (>= a b))");
        assert!(asm_ge.contains("setae %al"), "asm:\n{}", asm_ge);
    }

    #[test]
    fn test_compile_i32_add_uses_32_bit_instruction() {
        let asm = compile_ok("(define (f [a : i32] [b : i32]) : i32 (+ a b))");
        assert!(asm.contains("addl %ecx, %eax"), "asm:\n{}", asm);
        assert!(
            !asm.contains("addq %rcx, %rax"),
            "i32 add must not use 64-bit add; asm:\n{}",
            asm
        );
    }

    #[test]
    fn test_compile_i8_add_sub_use_8_bit_instructions() {
        let add_asm = compile_ok("(define (f [a : i8] [b : i8]) : i8 (+ a b))");
        assert!(add_asm.contains("addb %cl, %al"), "asm:\n{}", add_asm);
        assert!(
            !add_asm.contains("addq %rcx, %rax"),
            "i8 add must not use 64-bit add; asm:\n{}",
            add_asm
        );

        let sub_asm = compile_ok("(define (f [a : i8] [b : i8]) : i8 (- a b))");
        assert!(sub_asm.contains("subb %cl, %al"), "asm:\n{}", sub_asm);
        assert!(
            !sub_asm.contains("subq %rcx, %rax"),
            "i8 sub must not use 64-bit sub; asm:\n{}",
            sub_asm
        );
    }

    #[test]
    fn test_compile_i32_mul_uses_32_bit_instruction() {
        let asm = compile_ok("(define (f [a : i32] [b : i32]) : i32 (* a b))");
        assert!(asm.contains("imull %ecx, %eax"), "asm:\n{}", asm);
        assert!(
            !asm.contains("imulq %rcx, %rax"),
            "i32 mul must not use 64-bit imul; asm:\n{}",
            asm
        );
    }

    #[test]
    fn test_compile_i16_bit_and_uses_16_bit_instruction() {
        let asm = compile_ok("(define (f [a : i16] [b : i16]) : i16 (bit-and a b))");
        assert!(asm.contains("andw %cx, %ax"), "asm:\n{}", asm);
        assert!(
            !asm.contains("andq %rcx, %rax"),
            "i16 bit-and must not use 64-bit and; asm:\n{}",
            asm
        );
    }

    #[test]
    fn test_compile_i8_compare_uses_8_bit_cmp() {
        let asm = compile_ok("(define (f [a : i8] [b : i8]) : bool (< a b))");
        assert!(asm.contains("cmpb %cl, %al"), "asm:\n{}", asm);
        assert!(
            !asm.contains("cmpq %rcx, %rax"),
            "i8 comparison must not use 64-bit cmp; asm:\n{}",
            asm
        );
    }

    #[test]
    fn test_compile_u8_shift_uses_8_bit_instruction() {
        let asm = compile_ok("(define (f [a : u8] [b : u8]) : u8 (shl a b))");
        assert!(asm.contains("shlb %cl, %al"), "asm:\n{}", asm);
        assert!(
            !asm.contains("shlq %cl, %rax"),
            "u8 shift must not use 64-bit shl; asm:\n{}",
            asm
        );
    }

    #[test]
    fn test_compile_shl_has_guard_and_tl_shift_abort() {
        let asm = compile_ok("(define (f [a : i64] [b : i64]) : i64 (shl a b))");
        assert!(
            asm.contains("tl_shift_abort:"),
            "asm must contain tl_shift_abort runtime:\n{}",
            asm
        );
        assert!(
            asm.contains("call tl_shift_abort"),
            "asm must call tl_shift_abort:\n{}",
            asm
        );
        assert!(
            asm.contains("    shlq %cl, %rax"),
            "asm must still contain the shift instruction:\n{}",
            asm
        );
    }

    #[test]
    fn test_compile_shr_unsigned_has_guard() {
        let asm = compile_ok("(define (f [a : u64] [b : u64]) : u64 (shr a b))");
        assert!(
            asm.contains("call tl_shift_abort"),
            "unsigned shr must also guard:\n{}",
            asm
        );
    }

    #[test]
    fn test_compile_i32_div_uses_32_bit_instruction() {
        let asm = compile_ok("(define (f [a : i32] [b : i32]) : i32 (/ a b))");
        assert!(asm.contains("cdq"), "asm:\n{}", asm);
        assert!(asm.contains("idivl %ecx"), "asm:\n{}", asm);
        assert!(
            !asm.contains("idivq %rcx"),
            "i32 division must not use 64-bit idiv; asm:\n{}",
            asm
        );
    }

    #[test]
    fn test_compile_u16_div_uses_16_bit_instruction() {
        let asm = compile_ok("(define (f [a : u16] [b : u16]) : u16 (/ a b))");
        assert!(asm.contains("xorw %dx, %dx"), "asm:\n{}", asm);
        assert!(asm.contains("divw %cx"), "asm:\n{}", asm);
        assert!(
            !asm.contains("divq %rcx"),
            "u16 division must not use 64-bit div; asm:\n{}",
            asm
        );
    }

    #[test]
    fn test_compile_i8_mod_uses_8_bit_instruction() {
        let asm = compile_ok("(define (f [a : i8] [b : i8]) : i8 (% a b))");
        assert!(asm.contains("cbw"), "asm:\n{}", asm);
        assert!(asm.contains("idivb %cl"), "asm:\n{}", asm);
        assert!(asm.contains("movb %ah, %al"), "asm:\n{}", asm);
        assert!(
            !asm.contains("idivq %rcx"),
            "i8 modulo must not use 64-bit idiv; asm:\n{}",
            asm
        );
    }

    #[test]
    fn test_compile_u8_mod_uses_8_bit_instruction() {
        let asm = compile_ok("(define (f [a : u8] [b : u8]) : u8 (% a b))");
        assert!(asm.contains("andw $0x00ff, %ax"), "asm:\n{}", asm);
        assert!(asm.contains("divb %cl"), "asm:\n{}", asm);
        assert!(asm.contains("movb %ah, %al"), "asm:\n{}", asm);
        assert!(
            !asm.contains("divq %rcx"),
            "u8 modulo must not use 64-bit div; asm:\n{}",
            asm
        );
    }

    #[test]
    fn test_compile_i64_div_has_guard_and_tl_div_abort() {
        let asm = compile_ok("(define (f [a : i64] [b : i64]) : i64 (/ a b))");
        assert!(
            asm.contains("tl_div_abort:"),
            "asm must contain tl_div_abort runtime:\n{}",
            asm
        );
        assert!(
            asm.contains("call tl_div_abort"),
            "asm must call tl_div_abort:\n{}",
            asm
        );
        assert!(
            asm.contains("idivq %rcx"),
            "asm must contain idivq:\n{}",
            asm
        );
    }

    #[test]
    fn test_compile_mov_const_i64_to_i8_uses_8_bit_store() {
        let program = Program {
            functions: vec![Function {
                name: "f".into(),
                params: vec![],
                ret: Type::I8,
                locals: vec![(0, Type::I8)],
                blocks: vec![BasicBlock {
                    label: "entry".into(),
                    instructions: vec![
                        Instruction::Mov {
                            dst: 0,
                            src: Value::ConstI64(7),
                            ty: Type::I8,
                        },
                        Instruction::Return(Some(Value::Var(0))),
                    ],
                }],
                entry: "entry".into(),
            }],
            globals: vec![],
            externs: vec![],
        };
        let asm = generate_assembly(&program).expect("narrow immediate mov should compile");
        assert!(asm.contains("movb $7, %bl"), "asm:\n{}", asm);
        assert!(
            !asm.contains("movq $7"),
            "i8 immediate mov must not use a 64-bit store; asm:\n{}",
            asm
        );
    }

    #[test]
    fn test_compile_large_i64_immediate_mov_materializes_through_register() {
        let program = Program {
            functions: vec![Function {
                name: "f".into(),
                params: vec![],
                ret: Type::I64,
                locals: vec![(0, Type::I64)],
                blocks: vec![BasicBlock {
                    label: "entry".into(),
                    instructions: vec![
                        Instruction::Mov {
                            dst: 0,
                            src: Value::ConstI64(i64::MAX),
                            ty: Type::I64,
                        },
                        Instruction::Return(Some(Value::Var(0))),
                    ],
                }],
                entry: "entry".into(),
            }],
            globals: vec![],
            externs: vec![],
        };
        let asm = generate_assembly(&program).expect("large immediate mov should compile");
        assert!(
            asm.contains("movabsq $9223372036854775807, %rbx"),
            "large i64 immediate must be materialized through a register; asm:\n{}",
            asm
        );
        assert!(
            asm.contains("movq %rbx, %rax"),
            "large i64 immediate register value must be returned from its home; asm:\n{}",
            asm
        );
        assert!(
            !asm.contains("movq $9223372036854775807, -8(%rbp)"),
            "large i64 immediate must not be encoded directly to memory; asm:\n{}",
            asm
        );
    }

    #[test]
    fn test_compile_store_const_i64_to_i16_uses_16_bit_store() {
        let program = Program {
            functions: vec![Function {
                name: "f".into(),
                params: vec![],
                ret: Type::Unit,
                locals: vec![(0, Type::I16)],
                blocks: vec![BasicBlock {
                    label: "entry".into(),
                    instructions: vec![
                        Instruction::Alloc {
                            var: 0,
                            ty: Type::I16,
                        },
                        Instruction::Store {
                            dst: Value::Var(0),
                            src: Value::ConstI64(300),
                            ty: Type::I16,
                        },
                        Instruction::Return(None),
                    ],
                }],
                entry: "entry".into(),
            }],
            globals: vec![],
            externs: vec![],
        };
        let asm = generate_assembly(&program).expect("narrow immediate store should compile");
        assert!(asm.contains("movw $300, %bx"), "asm:\n{}", asm);
        assert!(
            !asm.contains("movq $300"),
            "i16 immediate store must not use a 64-bit store; asm:\n{}",
            asm
        );
    }

    #[test]
    fn test_compile_i32_neg_uses_32_bit_instruction() {
        let asm = compile_unop_param(UnOp::Neg, Type::I32);
        assert!(asm.contains("negl %eax"), "asm:\n{}", asm);
        assert!(
            !asm.contains("negq %rax"),
            "i32 neg must not use 64-bit neg; asm:\n{}",
            asm
        );
    }

    #[test]
    fn test_compile_i8_neg_uses_8_bit_instruction() {
        let asm = compile_unop_param(UnOp::Neg, Type::I8);
        assert!(asm.contains("negb %al"), "asm:\n{}", asm);
        assert!(
            !asm.contains("negq %rax"),
            "i8 neg must not use 64-bit neg; asm:\n{}",
            asm
        );
    }

    #[test]
    fn test_compile_i16_bit_not_uses_16_bit_instruction() {
        let asm = compile_unop_param(UnOp::BitNot, Type::I16);
        assert!(asm.contains("notw %ax"), "asm:\n{}", asm);
        assert!(
            !asm.contains("notq %rax"),
            "i16 bit-not must not use 64-bit not; asm:\n{}",
            asm
        );
    }

    #[test]
    fn test_compile_bool_not_uses_8_bit_instruction() {
        let asm = compile_unop_param(UnOp::Not, Type::Bool);
        assert!(asm.contains("xorb $1, %al"), "asm:\n{}", asm);
        assert!(
            !asm.contains("xorq $1, %rax"),
            "bool not must not use 64-bit xor; asm:\n{}",
            asm
        );
    }

    // --- boolean logic ops from source text (Issue #27) ---

    #[test]
    fn test_compile_not_from_source_emits_xor() {
        // `(not b)` flows parse -> lower -> codegen and emits an 8-bit `xor $1`.
        let asm = compile_ok("(define (f [b : bool]) : bool (not b))");
        assert!(asm.contains("xorb $1, %al"), "asm:\n{}", asm);
        assert!(!asm.contains("# TODO"), "unhandled instruction:\n{}", asm);
    }

    #[test]
    fn test_compile_and_from_source_emits_and() {
        // `(and a b)` over canonical 0/1 bools is a bitwise `and` on the 8-bit
        // registers (bitwise == logical for canonical bools).
        let asm = compile_ok("(define (f [a : bool] [b : bool]) : bool (and a b))");
        assert!(asm.contains("andb"), "asm:\n{}", asm);
        assert!(!asm.contains("# TODO"), "unhandled instruction:\n{}", asm);
    }

    #[test]
    fn test_compile_or_from_source_emits_or() {
        let asm = compile_ok("(define (f [a : bool] [b : bool]) : bool (or a b))");
        assert!(asm.contains("orb"), "asm:\n{}", asm);
        assert!(!asm.contains("# TODO"), "unhandled instruction:\n{}", asm);
    }

    #[test]
    fn test_compile_bool_equality_emits_setcc() {
        // `(= a b)` over two bools compiles via the comparison path: `cmp` then
        // a `set` byte-setting instruction producing a 0/1 bool.
        let asm = compile_ok("(define (f [a : bool] [b : bool]) : bool (= a b))");
        assert!(asm.contains("cmp"), "expected cmp; asm:\n{}", asm);
        assert!(asm.contains("sete"), "expected sete; asm:\n{}", asm);
        assert!(!asm.contains("# TODO"), "unhandled instruction:\n{}", asm);
    }

    #[test]
    fn test_compile_cast_truncate_to_i8() {
        // Narrowing cast i64 -> i8: load source then store only the low byte.
        let asm = compile_ok("(define (f [x : i64]) : i8 (cast x : i8))");
        assert!(
            asm.contains("movb %al,"),
            "truncation expected; asm:\n{}",
            asm
        );
    }

    #[test]
    fn test_compile_cast_widen_i8_to_i64_sign_extends() {
        // Widening cast i8 -> i64 must sign-extend the source.
        let asm = compile_ok("(define (f [x : i8]) : i64 (cast x : i64))");
        assert!(
            asm.contains("movsbq"),
            "sign-extension expected; asm:\n{}",
            asm
        );
    }

    #[test]
    fn test_compile_cast_widen_u8_to_i64_zero_extends() {
        // Widening cast u8 -> i64 must zero-extend the source.
        let asm = compile_ok("(define (f [x : u8]) : i64 (cast x : i64))");
        assert!(
            asm.contains("movzbq"),
            "zero-extension expected; asm:\n{}",
            asm
        );
    }

    #[test]
    fn test_compile_cast_widen_char_to_i64_zero_extends() {
        // Widening cast char -> i64 must zero-extend the source byte.
        let asm = compile_ok("(define (f [x : char]) : i64 (cast x : i64))");
        assert!(
            asm.contains("movzbq"),
            "zero-extension expected; asm:\n{}",
            asm
        );
    }

    #[test]
    fn test_compile_bit_not_emits_notq() {
        // bit-not (one's complement). Unary ops are not parsed from text yet,
        // so drive the backend from hand-built IR.
        let program = Program {
            functions: vec![Function {
                name: "f".into(),
                params: vec![(0, Type::I64)],
                ret: Type::I64,
                locals: vec![(1, Type::I64)],
                blocks: vec![BasicBlock {
                    label: "entry".into(),
                    instructions: vec![
                        Instruction::Alloc {
                            var: 0,
                            ty: Type::I64,
                        },
                        Instruction::UnOp {
                            dst: 1,
                            op: UnOp::BitNot,
                            src: Value::Var(0),
                            ty: Type::I64,
                        },
                        Instruction::Return(Some(Value::Var(1))),
                    ],
                }],
                entry: "entry".into(),
            }],
            globals: vec![],
            externs: vec![],
        };
        let asm = generate_assembly(&program).expect("bit-not should compile");
        assert!(asm.contains("notq %rax"), "asm:\n{}", asm);
    }

    // ------------------------------------------------------------------
    // Sum types + pattern matching — Issue #41
    // ------------------------------------------------------------------

    #[test]
    fn test_backend_enum_constructor_and_match() {
        let asm = compile_ok(
            "(defenum Shape (Circle i64) (Square i64) (Nothing))\n\
             (define (area [s : Shape]) : i64 \
               (match s [(Circle r) (* r r)] [(Square w) (* w w)] [Nothing 0]))\n\
             (define (main) : i64 (area (Circle 5)))",
        );

        // No instruction fell through to the unimplemented stub.
        assert!(!asm.contains("# TODO"), "asm:\n{}", asm);

        // Tag dispatch compares the loaded tag against each variant index.
        assert!(asm.contains("cmpq"), "expected tag cmpq; asm:\n{}", asm);
        // Tag immediates appear as movq $<tag> material.
        assert!(asm.contains("movq $0,"), "asm:\n{}", asm);
        assert!(asm.contains("movq $1,"), "asm:\n{}", asm);

        // Match arms jump to fully-qualified, function-prefixed labels.
        assert!(
            asm.contains("_tl_area.match_arm."),
            "expected qualified arm label; asm:\n{}",
            asm
        );
        assert!(
            asm.contains("jnz _tl_area.match_arm."),
            "expected conditional jump to arm; asm:\n{}",
            asm
        );

        // Constructor materializes the storage address (AddrOf -> leaq) and
        // writes fields through the computed pointer.
        assert!(
            asm.contains("leaq"),
            "expected leaq for AddrOf; asm:\n{}",
            asm
        );
        assert!(
            asm.contains("(%r10)"),
            "expected pointer store/load through %r10; asm:\n{}",
            asm
        );

        // The Circle payload (5) is stored by the constructor in main.
        assert!(asm.contains("movq $5,"), "asm:\n{}", asm);
    }

    #[test]
    fn test_backend_match_payload_gep_offset() {
        // The payload of Circle lives at byte offset 8 (after the i64 tag); the
        // arm's field Load adds $8 to the base pointer.
        let asm = compile_ok(
            "(defenum Box (Wrap i64) (Empty))\n\
             (define (unwrap [b : Box]) : i64 \
               (match b [(Wrap x) x] [Empty 0]))",
        );
        assert!(!asm.contains("# TODO"), "asm:\n{}", asm);
        assert!(
            asm.contains("movq $8, %rcx"),
            "expected payload gep at byte offset 8; asm:\n{}",
            asm
        );
    }

    #[test]
    fn test_backend_scalar_literal_match() {
        // A scalar match over an i64 dispatches on the value directly: no tag
        // load, a cmpq per literal arm, conditional jumps to qualified arm
        // labels, and no unhandled instruction.
        let asm = compile_ok(
            "(define (classify [n : i64]) : i64 \
               (match n [0 100] [1 200] [_ 0]))\n\
             (define (main) : i64 (classify 1))",
        );

        assert!(!asm.contains("# TODO"), "asm:\n{}", asm);
        // Value dispatch compares against the literal constants.
        assert!(
            asm.contains("cmpq"),
            "expected cmpq for literal compare; asm:\n{}",
            asm
        );
        // Arms jump to fully-qualified, function-prefixed labels.
        assert!(
            asm.contains("jnz _tl_classify.match_arm."),
            "expected conditional jump to arm; asm:\n{}",
            asm
        );
    }

    #[test]
    fn test_backend_scalar_wildcard_only_match() {
        let asm = compile_ok(
            "(define (classify [n : i64]) : i64 (match n [_ 0]))\n\
             (define (main) : i64 (classify 1))",
        );

        assert!(!asm.contains("# TODO"), "asm:\n{}", asm);
        assert!(
            !asm.contains("(%r10)"),
            "wildcard-only scalar match must not dereference a tag pointer; asm:\n{}",
            asm
        );
    }

    // ------------------------------------------------------------------
    // Runtime delivery: bump allocator `tl_alloc` (issue #13)
    // ------------------------------------------------------------------

    /// A program whose IR references `tl_alloc` (the runtime bump allocator).
    /// `make-array` does not yet exist in the surface language, so we drive the
    /// allocator emission from hand-built IR — the same approach used by the
    /// `tl_*` print-runtime call sites once they reach the backend.
    fn program_calling_tl_alloc() -> Program {
        Program {
            functions: vec![Function {
                name: "main".into(),
                params: vec![],
                ret: Type::U64,
                locals: vec![(0, Type::U64)],
                blocks: vec![BasicBlock {
                    label: "entry".into(),
                    instructions: vec![
                        Instruction::Call {
                            dst: Some(0),
                            func: "tl_alloc".into(),
                            args: vec![Value::ConstI64(16)],
                            ty: Type::U64,
                        },
                        Instruction::Return(Some(Value::Var(0))),
                    ],
                }],
                entry: "entry".into(),
            }],
            globals: vec![],
            externs: vec![],
        }
    }

    #[test]
    fn test_alloc_runtime_emitted_when_referenced() {
        let asm = generate_assembly(&program_calling_tl_alloc())
            .expect("program calling tl_alloc should compile");

        // The call site resolves to the raw runtime symbol, not a mangled
        // `_tl_tl_alloc`, and the allocator body is defined in the same unit.
        assert!(asm.contains("    call tl_alloc"), "asm:\n{}", asm);
        assert!(!asm.contains("_tl_tl_alloc"), "asm:\n{}", asm);
        assert!(asm.contains("    .globl tl_alloc"), "asm:\n{}", asm);
        assert!(asm.contains("tl_alloc:"), "asm:\n{}", asm);

        // Arena state lives in `.bss` as the current arena-record pointer.
        assert!(asm.contains("    .section .bss"), "asm:\n{}", asm);
        assert!(asm.contains("tl_current_arena:"), "asm:\n{}", asm);

        // The request is rounded up to 8 bytes before bumping.
        assert!(asm.contains("    addq $7, %rdi"), "asm:\n{}", asm);
        assert!(asm.contains("    andq $-8, %rdi"), "asm:\n{}", asm);

        // The bump pointer is read from / written back to the current arena record.
        assert!(
            asm.contains("movq tl_current_arena(%rip), %r8"),
            "asm:\n{}",
            asm
        );
        assert!(asm.contains("movq 16(%r8), %rax"), "asm:\n{}", asm);
        assert!(asm.contains("movq %rcx, 16(%r8)"), "asm:\n{}", asm);

        // Lazy mmap: raw mmap syscall (rax=9) with PROT_READ|PROT_WRITE (3) and
        // MAP_PRIVATE|MAP_ANONYMOUS (0x22) in %r10, fd=-1, and a syscall.
        assert!(asm.contains("    movq $9, %rax"), "asm:\n{}", asm);
        assert!(asm.contains("    movq $3, %rdx"), "asm:\n{}", asm);
        assert!(asm.contains("    movq $0x22, %r10"), "asm:\n{}", asm);
        assert!(asm.contains("    movq $-1, %r8"), "asm:\n{}", asm);
        assert!(asm.contains("    syscall"), "asm:\n{}", asm);

        // Overflow guard: `addq $7, %rdi` followed by a carry check before `andq`
        assert!(asm.contains("    jc .L_tl_alloc_abort"), "asm:\n{}", asm);
        // mmap-failure guard: test mmap result, trap if negative (errno in low bits)
        assert!(asm.contains("    js .L_tl_alloc_abort"), "asm:\n{}", asm);
        // Self-contained abort path writes to fd 2 and exits 134.
        assert!(asm.contains(".L_tl_alloc_abort:"), "asm:\n{}", asm);
        assert!(
            asm.contains("leaq .L_tl_alloc_msg(%rip), %rsi"),
            "asm:\n{}",
            asm
        );

        // No unhandled instruction slipped through.
        assert!(!asm.contains("# TODO"), "asm:\n{}", asm);
    }

    #[test]
    fn test_alloc_runtime_referenced_via_extern() {
        // A bare `extern tl_alloc` declaration also triggers emission and must
        // not produce a stray `.extern tl_alloc` (it is defined inline here).
        let program = Program {
            functions: vec![Function {
                name: "main".into(),
                params: vec![],
                ret: Type::I64,
                locals: vec![],
                blocks: vec![BasicBlock {
                    label: "entry".into(),
                    instructions: vec![Instruction::Return(Some(Value::ConstI64(0)))],
                }],
                entry: "entry".into(),
            }],
            globals: vec![],
            externs: vec![(
                "tl_alloc".into(),
                Type::Func(vec![Type::U64], Box::new(Type::U64)),
            )],
        };
        let asm = generate_assembly(&program).expect("extern tl_alloc should compile");
        assert!(asm.contains("tl_alloc:"), "asm:\n{}", asm);
        assert!(!asm.contains("    .extern tl_alloc"), "asm:\n{}", asm);
    }

    #[test]
    fn test_alloc_runtime_absent_when_unreferenced() {
        // Programs that never touch the allocator must not carry its code or
        // its `.bss` arena state — keeping minimal programs minimal.
        let asm = compile_ok("(define (main) : i64 (+ 1 2))");
        assert!(!asm.contains("tl_alloc:"), "asm:\n{}", asm);
        assert!(!asm.contains("tl_region_mark:"), "asm:\n{}", asm);
        assert!(!asm.contains("tl_region_reset:"), "asm:\n{}", asm);
        assert!(!asm.contains("tl_current_arena:"), "asm:\n{}", asm);
        assert!(!asm.contains("    .section .bss"), "asm:\n{}", asm);
    }

    fn program_calling_region_helpers() -> Program {
        Program {
            functions: vec![Function {
                name: "main".into(),
                params: vec![],
                ret: Type::I64,
                locals: vec![(0, Type::U64)],
                blocks: vec![BasicBlock {
                    label: "entry".into(),
                    instructions: vec![
                        Instruction::Call {
                            dst: Some(0),
                            func: super::REGION_MARK_RUNTIME_SYMBOL.into(),
                            args: vec![],
                            ty: Type::U64,
                        },
                        Instruction::Call {
                            dst: None,
                            func: super::REGION_RESET_RUNTIME_SYMBOL.into(),
                            args: vec![Value::Var(0)],
                            ty: Type::Unit,
                        },
                        Instruction::Return(Some(Value::ConstI64(0))),
                    ],
                }],
                entry: "entry".into(),
            }],
            globals: vec![],
            externs: vec![],
        }
    }

    #[test]
    fn test_region_runtime_referenced_via_call() {
        let asm = generate_assembly(&program_calling_region_helpers())
            .expect("program calling region helpers should compile");

        assert!(asm.contains("    call tl_region_mark"), "asm:\n{}", asm);
        assert!(asm.contains("    call tl_region_reset"), "asm:\n{}", asm);
        assert!(!asm.contains("_tl_tl_region_mark"), "asm:\n{}", asm);
        assert!(!asm.contains("_tl_tl_region_reset"), "asm:\n{}", asm);
        assert!(asm.contains("tl_region_mark:"), "asm:\n{}", asm);
        assert!(asm.contains("tl_region_reset:"), "asm:\n{}", asm);
        assert!(asm.contains("tl_current_arena:"), "asm:\n{}", asm);
        assert!(asm.contains("    movq 16(%rax), %rax"), "asm:\n{}", asm);
        assert!(asm.contains("    movq $11, %rax"), "asm:\n{}", asm);
        assert!(asm.contains("tl: invalid region mark"), "asm:\n{}", asm);
        assert!(!asm.contains("tl_alloc:"), "asm:\n{}", asm);
        assert!(!asm.contains("    .extern tl_region_mark"), "asm:\n{}", asm);
        assert!(
            !asm.contains("    .extern tl_region_reset"),
            "asm:\n{}",
            asm
        );
    }

    #[test]
    fn test_region_runtime_referenced_via_extern() {
        let program = Program {
            functions: vec![Function {
                name: "main".into(),
                params: vec![],
                ret: Type::I64,
                locals: vec![],
                blocks: vec![BasicBlock {
                    label: "entry".into(),
                    instructions: vec![Instruction::Return(Some(Value::ConstI64(0)))],
                }],
                entry: "entry".into(),
            }],
            globals: vec![],
            externs: vec![
                (
                    super::REGION_MARK_RUNTIME_SYMBOL.into(),
                    Type::Func(vec![], Box::new(Type::U64)),
                ),
                (
                    super::REGION_RESET_RUNTIME_SYMBOL.into(),
                    Type::Func(vec![Type::U64], Box::new(Type::Unit)),
                ),
            ],
        };

        let asm = generate_assembly(&program).expect("extern region helpers should compile");
        assert!(asm.contains("tl_region_mark:"), "asm:\n{}", asm);
        assert!(asm.contains("tl_region_reset:"), "asm:\n{}", asm);
        assert!(asm.contains("tl_current_arena:"), "asm:\n{}", asm);
        assert!(!asm.contains("    .extern tl_region_mark"), "asm:\n{}", asm);
        assert!(
            !asm.contains("    .extern tl_region_reset"),
            "asm:\n{}",
            asm
        );
    }

    #[test]
    fn test_region_runtime_surface_extern_calls_compile() {
        let asm = compile_ok(
            r#"
            (extern tl_region_mark : (-> u64))
            (extern tl_region_reset : (-> u64 unit))

            (define (main) : i64
              (let ([m : u64 (tl_region_mark)])
                (begin
                  (string-append "a" "b")
                  (tl_region_reset m)
                  0)))
            "#,
        );

        assert!(asm.contains("    call tl_region_mark"), "asm:\n{}", asm);
        assert!(asm.contains("    call tl_region_reset"), "asm:\n{}", asm);
        assert!(asm.contains("tl_region_mark:"), "asm:\n{}", asm);
        assert!(asm.contains("tl_region_reset:"), "asm:\n{}", asm);
        assert!(!asm.contains("    .extern tl_region_mark"), "asm:\n{}", asm);
        assert!(
            !asm.contains("    .extern tl_region_reset"),
            "asm:\n{}",
            asm
        );
    }

    #[test]
    fn test_region_mark_runtime_before_allocation_omits_alloc_body() {
        let program = Program {
            functions: vec![Function {
                name: "main".into(),
                params: vec![],
                ret: Type::I64,
                locals: vec![],
                blocks: vec![BasicBlock {
                    label: "entry".into(),
                    instructions: vec![Instruction::Return(Some(Value::ConstI64(0)))],
                }],
                entry: "entry".into(),
            }],
            globals: vec![],
            externs: vec![(
                super::REGION_MARK_RUNTIME_SYMBOL.into(),
                Type::Func(vec![], Box::new(Type::U64)),
            )],
        };

        let asm = generate_assembly(&program).expect("extern region mark should compile");
        assert!(asm.contains("tl_region_mark:"), "asm:\n{}", asm);
        assert!(asm.contains("tl_current_arena:"), "asm:\n{}", asm);
        assert!(asm.contains("    xorq %rax, %rax"), "asm:\n{}", asm);
        assert!(!asm.contains("tl_region_reset:"), "asm:\n{}", asm);
        assert!(!asm.contains("tl: invalid region mark"), "asm:\n{}", asm);
        assert!(!asm.contains("tl_alloc:"), "asm:\n{}", asm);
    }

    #[test]
    fn test_windows_target_rejects_region_runtime_helpers() {
        let err = generate_assembly_for_target(
            &program_calling_region_helpers(),
            BackendTarget::windows_x86_64(),
        )
        .expect_err("windows target should reject region helpers");

        assert!(
            err.contains("tl_region_mark/tl_region_reset"),
            "error: {}",
            err
        );
        assert!(err.contains("linux-x86_64-system-v"), "error: {}", err);
    }

    #[test]
    fn test_user_defined_tl_alloc_not_overridden() {
        // If a program defines its own `tl_alloc`, the backend must not also
        // emit the runtime allocator (no duplicate symbol).
        let program = Program {
            functions: vec![
                Function {
                    name: "tl_alloc".into(),
                    params: vec![(0, Type::U64)],
                    ret: Type::U64,
                    locals: vec![],
                    blocks: vec![BasicBlock {
                        label: "entry".into(),
                        instructions: vec![Instruction::Return(Some(Value::Var(0)))],
                    }],
                    entry: "entry".into(),
                },
                Function {
                    name: "main".into(),
                    params: vec![],
                    ret: Type::U64,
                    locals: vec![(1, Type::U64)],
                    blocks: vec![BasicBlock {
                        label: "entry".into(),
                        instructions: vec![
                            Instruction::Call {
                                dst: Some(1),
                                func: "tl_alloc".into(),
                                args: vec![Value::ConstI64(8)],
                                ty: Type::U64,
                            },
                            Instruction::Return(Some(Value::Var(1))),
                        ],
                    }],
                    entry: "entry".into(),
                },
            ],
            globals: vec![],
            externs: vec![],
        };
        let asm = generate_assembly(&program).expect("user-defined tl_alloc should compile");
        // Only the user's definition exists; no runtime arena/.bss emitted.
        assert!(!asm.contains("tl_current_arena:"), "asm:\n{}", asm);
        // The call targets the user's (mangled) function.
        assert!(asm.contains("_tl_tl_alloc:"), "asm:\n{}", asm);
        assert!(asm.contains("    call _tl_tl_alloc"), "asm:\n{}", asm);
    }

    #[test]
    fn test_int_to_string_allocator_runtime_coexists_with_user_tl_alloc() {
        // `int->string` needs the backend's raw `tl_alloc` helper internally.
        // A user function named `tl_alloc` is a separate TypeLisp symbol and is
        // still called through its mangled name.
        let asm = compile_ok(
            r#"
            (define (tl_alloc [n : u64]) : u64 n)
            (define (main) : i64
              (begin
                (tl_alloc (cast 8 : u64))
                (string-length (int->string 42))))
            "#,
        );

        assert!(asm.contains("\n_tl_tl_alloc:\n"), "asm:\n{}", asm);
        assert!(asm.contains("    call _tl_tl_alloc"), "asm:\n{}", asm);
        assert!(asm.contains("\ntl_alloc:\n"), "asm:\n{}", asm);
        assert!(asm.contains("    call tl_int_to_string"), "asm:\n{}", asm);
        assert!(asm.contains("    call tl_alloc"), "asm:\n{}", asm);
        assert!(!asm.contains("    .extern tl_alloc"), "asm:\n{}", asm);
        assert!(!asm.contains("# TODO"), "asm:\n{}", asm);
    }

    #[test]
    fn test_alloc_runtime_overflow_guard_exists() {
        let asm = generate_assembly(&program_calling_tl_alloc())
            .expect("program calling tl_alloc should compile");

        // There should be exactly four carry-check jumps to the abort label:
        // request rounding, active-arena bump pointer, request+header length,
        // and fresh-arena end.
        let jc_count = asm.matches("    jc .L_tl_alloc_abort").count();
        assert_eq!(
            jc_count, 4,
            "expected four carry guards (rounding + bump + header/end overflow), got {}\nasm:\n{}",
            jc_count, asm
        );

        // mmap result test: exactly one js after syscall before the arena is used.
        let js_count = asm.matches("    js .L_tl_alloc_abort").count();
        assert_eq!(
            js_count, 1,
            "expected one mmap-failure guard, got {}\nasm:\n{}",
            js_count, asm
        );
    }

    #[test]
    fn test_alloc_runtime_tracks_linked_arena_records() {
        let asm = generate_assembly(&program_calling_tl_alloc())
            .expect("program calling tl_alloc should compile");

        // The old two-global allocator shape should be gone; the backend keeps
        // one current-arena pointer and per-arena records in the mapped memory.
        assert!(asm.contains("tl_current_arena:"), "asm:\n{}", asm);
        assert!(!asm.contains("tl_arena_ptr:"), "asm:\n{}", asm);
        assert!(!asm.contains("tl_arena_end:"), "asm:\n{}", asm);

        // Fresh arenas store previous/base/bump/end in deterministic offsets:
        //   0: previous arena
        //   8: payload base
        //  16: current bump
        //  24: end pointer
        let prev_link = "    movq tl_current_arena(%rip), %r8\n    movq %r8, 0(%rax)";
        assert!(asm.contains(prev_link), "asm:\n{}", asm);
        assert!(asm.contains("    leaq 32(%rax), %r8"), "asm:\n{}", asm);
        assert!(asm.contains("    movq %r8, 8(%rax)"), "asm:\n{}", asm);
        assert!(asm.contains("    movq %rcx, 24(%rax)"), "asm:\n{}", asm);
        assert!(asm.contains("    movq %rcx, 16(%rax)"), "asm:\n{}", asm);
        assert!(
            asm.contains("    movq %rax, tl_current_arena(%rip)"),
            "asm:\n{}",
            asm
        );

        // New arena length accounts for the 32-byte header before mmap.
        assert!(asm.contains("    addq $32, %rcx"), "asm:\n{}", asm);
    }

    // ------------------------------------------------------------------
    // String literals — Issue #13
    // ------------------------------------------------------------------

    #[test]
    fn test_compile_string_literal_emits_rodata_and_fat_value() {
        // `string-length` returns i64, so the function is backend-valid; the
        // string literal is constructed inline and its length read back.
        let asm = compile_ok(r#"(define (main) : i64 (string-length "hello"))"#);

        // The literal's bytes are interned into `.rodata` as a `.string`.
        assert!(asm.contains("    .section .rodata"), "asm:\n{}", asm);
        assert!(asm.contains(".L_tl_str_0:"), "asm:\n{}", asm);
        assert!(asm.contains("    .string \"hello\""), "asm:\n{}", asm);

        // The fat value's data pointer is loaded RIP-relative from that label.
        assert!(asm.contains("leaq .L_tl_str_0(%rip)"), "asm:\n{}", asm);

        // The byte length (5) is stored into the fat value.
        assert!(asm.contains("$5,"), "asm:\n{}", asm);

        // No instruction selection fell through to a TODO stub.
        assert!(!asm.contains("# TODO"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_identical_string_literals_share_rodata() {
        // Two identical literals intern to one set of bytes / one label.
        let asm =
            compile_ok(r#"(define (main) : i64 (+ (string-length "hi") (string-length "hi")))"#);
        let occurrences = asm.matches(".L_tl_str_0:").count();
        assert_eq!(occurrences, 1, "asm:\n{}", asm);
        // No second distinct string label was allocated.
        assert!(!asm.contains(".L_tl_str_1:"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_string_length_reads_len_field() {
        // `string-length` is not a runtime call; it loads the fat value's len
        // field. There must be no call to a `string-length` symbol.
        let asm = compile_ok(r#"(define (main) : i64 (string-length "abc"))"#);
        assert!(!asm.contains("string_length"), "asm:\n{}", asm);
        assert!(!asm.contains("# TODO"), "asm:\n{}", asm);
        // The length byte count for "abc" is 3.
        assert!(asm.contains("$3,"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_distinct_string_literals_get_distinct_labels() {
        let asm =
            compile_ok(r#"(define (main) : i64 (+ (string-length "aa") (string-length "bbb")))"#);
        assert!(asm.contains(".L_tl_str_0:"), "asm:\n{}", asm);
        assert!(asm.contains(".L_tl_str_1:"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_string_eq_emits_runtime_and_calls_it() {
        // `(string-eq a b)` calls the emit-on-demand `tl_string_eq` helper and
        // the backend defines that helper inline (gated like `tl_alloc`).
        let asm = compile_ok(r#"(define (main) : bool (string-eq "hi" "hi"))"#);

        // The runtime function is emitted and globally visible.
        assert!(asm.contains("    .globl tl_string_eq"), "asm:\n{}", asm);
        assert!(asm.contains("tl_string_eq:"), "asm:\n{}", asm);

        // The call site dispatches to the raw runtime symbol (not mangled).
        assert!(asm.contains("    call tl_string_eq"), "asm:\n{}", asm);
        assert!(!asm.contains("_tl_tl_string_eq"), "asm:\n{}", asm);
        assert!(!asm.contains("_tl_string_eq:"), "asm:\n{}", asm);

        // The helper is a pure byte comparison: a length compare, a byte-by-byte
        // loop, and a `cmpb` of the loaded bytes — and crucially NO syscall (it
        // neither allocates nor writes), unlike `tl_alloc`/the print helpers.
        assert!(asm.contains("    cmpq %rcx, %rsi"), "asm:\n{}", asm);
        assert!(asm.contains(".L_tl_string_eq_loop:"), "asm:\n{}", asm);
        assert!(asm.contains("    cmpb %r8b, %al"), "asm:\n{}", asm);
        let eq_section = asm
            .split("tl_string_eq:")
            .nth(1)
            .expect("tl_string_eq body");
        let eq_body = eq_section.split("\n_start:").next().unwrap_or(eq_section);
        assert!(
            !eq_body.contains("syscall"),
            "tl_string_eq must be syscall-free:\n{}",
            eq_body
        );

        // The helper is not declared `.extern` (it is defined in this unit).
        assert!(!asm.contains("    .extern tl_string_eq"), "asm:\n{}", asm);

        // No instruction selection fell through to a TODO stub.
        assert!(!asm.contains("# TODO"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_string_match_emits_runtime_and_calls_it() {
        let asm = compile_ok(
            r#"
            (define (classify [s : String]) : i64
              (match s ["if" 10] [_ 0]))
            (define (main) : i64 (classify "if"))
            "#,
        );

        assert!(asm.contains("    .globl tl_string_eq"), "asm:\n{}", asm);
        assert!(asm.contains("tl_string_eq:"), "asm:\n{}", asm);
        assert!(asm.contains("    call tl_string_eq"), "asm:\n{}", asm);
        assert!(!asm.contains("_tl_tl_string_eq"), "asm:\n{}", asm);
        assert!(!asm.contains("# TODO"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_no_string_eq_means_no_runtime() {
        // A program that never compares strings must not emit the helper.
        let asm = compile_ok(r#"(define (main) : i64 (string-length "hi"))"#);
        assert!(!asm.contains("tl_string_eq"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_panic_emits_abort_runtime_and_calls_it() {
        // `(panic msg)` calls the emit-on-demand `tl_abort` helper and the
        // backend defines that helper inline (gated like `tl_string_eq`).
        let asm = compile_ok(r#"(define (main) : unit (panic "boom"))"#);

        // The private runtime function is emitted.
        assert!(asm.contains(".L_tl_abort:"), "asm:\n{}", asm);

        // The call site dispatches to the raw runtime symbol (not mangled).
        assert!(asm.contains("    call .L_tl_abort"), "asm:\n{}", asm);
        assert!(!asm.contains("_tl_tl_abort"), "asm:\n{}", asm);
        assert!(!asm.contains("\n_tl_abort:\n"), "asm:\n{}", asm);

        // The helper writes the caller's message to fd 2 and exits: a `write(2)`
        // setup (fd 2 in %rdi) followed by a syscall, then `exit(134)` (status
        // 134 in %rdi) followed by a syscall. The abort body therefore DOES
        // contain syscalls (unlike the pure string helpers).
        let abort_section = asm.split(".L_tl_abort:").nth(1).expect("tl_abort body");
        let abort_body = abort_section
            .split("\n    .globl ")
            .next()
            .unwrap_or(abort_section)
            .split("\n_start:")
            .next()
            .unwrap_or(abort_section);
        assert!(
            abort_body.contains("movq $2, %rdi"),
            "tl_abort writes to fd 2:\n{}",
            abort_body
        );
        assert!(
            abort_body.contains("movq $1, %rax"),
            "tl_abort uses the write syscall (number 1):\n{}",
            abort_body
        );
        assert!(
            abort_body.contains("movq $60, %rax"),
            "tl_abort uses the exit syscall (number 60):\n{}",
            abort_body
        );
        assert!(
            abort_body.contains("movq $134, %rdi"),
            "tl_abort exits with status 134:\n{}",
            abort_body
        );
        assert!(
            abort_body.matches("syscall").count() >= 2,
            "tl_abort issues a write and an exit syscall:\n{}",
            abort_body
        );

        // The helper is not declared `.extern` (it is defined in this unit).
        assert!(!asm.contains("    .extern .L_tl_abort"), "asm:\n{}", asm);

        // No instruction selection fell through to a TODO stub.
        assert!(!asm.contains("# TODO"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_error_aliases_panic_abort_runtime() {
        // `(error msg)` emits and calls the same `tl_abort` runtime as `panic`.
        let asm = compile_ok(r#"(define (main) : unit (error "boom"))"#);
        assert!(asm.contains(".L_tl_abort:"), "asm:\n{}", asm);
        assert!(asm.contains("    call .L_tl_abort"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_panic_can_stand_in_for_i64_return() {
        let asm = compile_ok(r#"(define (main) : i64 (panic "boom"))"#);
        assert!(asm.contains(".L_tl_abort:"), "asm:\n{}", asm);
        assert!(asm.contains("    call .L_tl_abort"), "asm:\n{}", asm);
        assert!(!asm.contains("# TODO"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_panic_can_stand_in_for_i64_branch() {
        let asm = compile_ok(r#"(define (main) : i64 (if true 1 (panic "boom")))"#);
        assert!(asm.contains(".L_tl_abort:"), "asm:\n{}", asm);
        assert!(asm.contains("    call .L_tl_abort"), "asm:\n{}", asm);
        assert!(!asm.contains("# TODO"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_panic_can_stand_in_for_i64_match_arm() {
        let asm = compile_ok(
            r#"
            (define (main) : i64
              (match 0 [0 (panic "zero")] [_ 1]))
            "#,
        );
        assert!(asm.contains(".L_tl_abort:"), "asm:\n{}", asm);
        assert!(asm.contains("    call .L_tl_abort"), "asm:\n{}", asm);
        assert!(!asm.contains("# TODO"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_no_panic_means_no_abort_runtime() {
        // A program that never panics must not emit the `tl_abort` helper.
        let asm = compile_ok(r#"(define (main) : i64 (string-length "hi"))"#);
        assert!(!asm.contains(".L_tl_abort"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_arg_count_preserves_start_argv_and_calls_runtime() {
        let asm = compile_ok("(define (main) : i64 (arg-count))");

        assert!(asm.contains(".L_tl_argc:"), "asm:\n{}", asm);
        assert!(asm.contains(".L_tl_argv:"), "asm:\n{}", asm);
        assert!(asm.contains(".L_tl_arg_count:"), "asm:\n{}", asm);
        assert!(asm.contains("    call .L_tl_arg_count"), "asm:\n{}", asm);

        let start = asm.split("_start:").nth(1).expect("expected _start");
        assert!(
            start.contains("    movq (%rsp), %rax"),
            "_start must read argc from initial stack:\n{}",
            start
        );
        assert!(
            start.contains("    movq %rax, .L_tl_argc(%rip)"),
            "_start must save argc:\n{}",
            start
        );
        assert!(
            start.contains("    leaq 8(%rsp), %rax"),
            "_start must compute argv pointer:\n{}",
            start
        );
        assert!(
            start.contains("    movq %rax, .L_tl_argv(%rip)"),
            "_start must save argv pointer:\n{}",
            start
        );
    }

    #[test]
    fn test_compile_arg_emits_runtime_alloc_and_abort_paths() {
        let asm = compile_ok("(define (main) : i64 (string-length (arg 0)))");

        assert!(asm.contains(".L_tl_arg:"), "asm:\n{}", asm);
        assert!(asm.contains("    call .L_tl_arg"), "asm:\n{}", asm);
        assert!(asm.contains("    call tl_alloc"), "asm:\n{}", asm);
        assert!(asm.contains("tl_alloc:"), "asm:\n{}", asm);
        assert!(asm.contains(".L_tl_abort:"), "asm:\n{}", asm);
        assert!(
            asm.contains("tl: argv index out of bounds"),
            "asm:\n{}",
            asm
        );
        assert!(asm.contains("    jl .L_tl_arg_oob"), "asm:\n{}", asm);
        assert!(asm.contains("    jge .L_tl_arg_oob"), "asm:\n{}", asm);
        assert!(asm.contains("    call .L_tl_abort"), "asm:\n{}", asm);
        assert!(!asm.contains("_tl_.L_tl_arg"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_no_argv_builtin_means_no_argv_runtime() {
        let asm = compile_ok(r#"(define (main) : i64 (string-length "hi"))"#);
        assert!(!asm.contains(".L_tl_argc"), "asm:\n{}", asm);
        assert!(!asm.contains(".L_tl_argv"), "asm:\n{}", asm);
        assert!(!asm.contains(".L_tl_arg:"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_user_defined_arg_shadows_builtin() {
        let asm = compile_ok(
            r#"
            (define (arg [n : i64]) : i64 (+ n 1))
            (define (main) : i64 (arg 41))
            "#,
        );
        assert!(asm.contains("_tl_arg:"), "asm:\n{}", asm);
        assert!(asm.contains("    call _tl_arg"), "asm:\n{}", asm);
        assert!(!asm.contains(".L_tl_arg:"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_user_defined_arg_count_shadows_builtin() {
        let asm = compile_ok(
            r#"
            (define (arg-count) : i64 9)
            (define (main) : i64 (arg-count))
            "#,
        );
        assert!(asm.contains("_tl_arg_count:"), "asm:\n{}", asm);
        assert!(asm.contains("    call _tl_arg_count"), "asm:\n{}", asm);
        assert!(!asm.contains(".L_tl_arg_count:"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_env_var_exists_captures_linux_envp_without_libc_getenv() {
        let asm = compile_ok(
            r#"
            (define (main) : i64
              (if (env-var-exists? "TYPELISP_TEST_ENV") 1 0))
            "#,
        );

        assert!(asm.contains(".L_tl_envp:"), "asm:\n{}", asm);
        assert!(asm.contains(".L_tl_env_var_exists:"), "asm:\n{}", asm);
        assert!(
            asm.contains("    call .L_tl_env_var_exists"),
            "asm:\n{}",
            asm
        );
        let start = asm.split("_start:").nth(1).expect("expected _start");
        assert!(
            start.contains("    leaq 16(%rsp,%rax,8), %rax"),
            "_start must compute envp from the initial stack:\n{}",
            start
        );
        assert!(
            start.contains("    movq %rax, .L_tl_envp(%rip)"),
            "_start must save envp before main:\n{}",
            start
        );
        assert!(!asm.contains("getenv"), "asm:\n{}", asm);
        assert!(!asm.contains("tl_alloc:"), "asm:\n{}", asm);
        assert!(!asm.contains(".L_tl_abort:"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_env_var_value_uses_linux_envp_lookup_and_allocates_string() {
        let asm = compile_ok(
            r#"
            (define (main) : i64
              (string-length (env-var-value "TYPELISP_TEST_ENV")))
            "#,
        );

        assert!(asm.contains(".L_tl_envp:"), "asm:\n{}", asm);
        assert!(asm.contains(".L_tl_env_var_value:"), "asm:\n{}", asm);
        assert!(
            asm.contains("    call .L_tl_env_var_value"),
            "asm:\n{}",
            asm
        );
        assert!(asm.contains("tl_alloc:"), "asm:\n{}", asm);
        assert!(
            asm.contains(".L_tl_env_var_value_len_loop:"),
            "asm:\n{}",
            asm
        );
        assert!(!asm.contains("getenv"), "asm:\n{}", asm);
        assert!(!asm.contains(".L_tl_abort:"), "asm:\n{}", asm);
    }

    #[test]
    fn test_windows_target_env_helpers_use_crt_getenv() {
        let asm = compile_ok_for_target(
            r#"
            (define (main) : i64
              (if (env-var-exists? "TYPELISP_TEST_ENV")
                (string-length (env-var-value "TYPELISP_TEST_ENV"))
                0))
            "#,
            BackendTarget::windows_x86_64(),
        );

        assert!(asm.contains(".L_tl_env_var_exists:"), "asm:\n{}", asm);
        assert!(asm.contains(".L_tl_env_var_value:"), "asm:\n{}", asm);
        assert!(asm.contains("    .extern getenv"), "asm:\n{}", asm);
        assert!(asm.contains("    .extern strlen"), "asm:\n{}", asm);
        assert!(asm.contains("    call getenv"), "asm:\n{}", asm);
        assert!(!asm.contains(".L_tl_envp:"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_process_output_extern_emits_linux_runtime() {
        let asm = compile_ok(
            r#"
            (extern tl_process_output : (-> i64 i64))
            (define (main) : i64 (tl_process_output 0))
            "#,
        );

        assert!(asm.contains("tl_process_output:"), "asm:\n{}", asm);
        assert!(asm.contains("    call tl_process_output"), "asm:\n{}", asm);
        assert!(
            !asm.contains("    .extern tl_process_output"),
            "asm:\n{}",
            asm
        );
        assert!(!asm.contains("_tl_tl_process_output"), "asm:\n{}", asm);
        assert!(asm.contains(".L_tl_process_read_all:"), "asm:\n{}", asm);
        assert!(asm.contains(".L_tl_process_exec_marker:"), "asm:\n{}", asm);
        assert!(asm.contains(".L_tl_envp:"), "asm:\n{}", asm);
        assert!(asm.contains("    movq $57, %rax"), "asm:\n{}", asm);
        assert!(asm.contains("    movq $59, %rax"), "asm:\n{}", asm);
        assert!(asm.contains("    movq $61, %rax"), "asm:\n{}", asm);
        assert!(asm.contains("    movq $319, %rax"), "asm:\n{}", asm);
        assert!(asm.contains("    movq $293, %rax"), "asm:\n{}", asm);
        assert!(asm.contains("tl_alloc:"), "asm:\n{}", asm);
    }

    #[test]
    fn test_windows_target_process_output_extern_emits_crt_runtime() {
        let asm = compile_ok_for_target(
            r#"
            (extern tl_process_output : (-> i64 i64))
            (define (main) : i64 (tl_process_output 0))
            "#,
            BackendTarget::windows_x86_64(),
        );

        assert!(asm.contains("tl_process_output:"), "asm:\n{}", asm);
        assert!(
            !asm.contains("    .extern tl_process_output"),
            "asm:\n{}",
            asm
        );
        assert!(!asm.contains("_tl_tl_process_output"), "asm:\n{}", asm);
        assert!(!asm.contains("    syscall"), "asm:\n{}", asm);
        assert!(!asm.contains(".L_tl_envp:"), "asm:\n{}", asm);
        assert!(asm.contains("tl_alloc:"), "asm:\n{}", asm);
        for symbol in [
            "_close",
            "_dup",
            "_dup2",
            "_fileno",
            "_lseeki64",
            "_read",
            "_spawnv",
            "fclose",
            "fflush",
            "tmpfile",
        ] {
            assert!(
                asm.contains(&format!("    .extern {}", symbol)),
                "missing extern {symbol}; asm:\n{}",
                asm
            );
        }
        for snippet in [
            "    call _spawnv",
            "    call _dup2",
            "    call tmpfile",
            ".L_tl_process_copy_c_string:",
            ".L_tl_process_read_fd_to_string:",
            ".L_tl_process_error_result:",
        ] {
            assert!(asm.contains(snippet), "missing {snippet}; asm:\n{}", asm);
        }
    }

    #[test]
    fn test_compile_read_file_emits_runtime_alloc_syscalls_and_abort_path() {
        let asm = compile_ok(r#"(define (main) : i64 (begin (read-file "input.txt") 0))"#);

        assert!(asm.contains(".L_tl_read_file:"), "asm:\n{}", asm);
        assert!(asm.contains("    call .L_tl_read_file"), "asm:\n{}", asm);
        assert!(asm.contains("tl_alloc:"), "asm:\n{}", asm);
        assert!(asm.contains("    call tl_alloc"), "asm:\n{}", asm);
        assert!(asm.contains(".L_tl_abort:"), "asm:\n{}", asm);
        assert!(asm.contains("tl: read-file failed"), "asm:\n{}", asm);
        assert!(asm.contains("    movb $0, (%r13,%r12)"), "asm:\n{}", asm);
        assert!(asm.contains("    movq $257, %rax"), "asm:\n{}", asm);
        assert!(asm.contains("    movq $-100, %rdi"), "asm:\n{}", asm);
        assert!(asm.contains("    movq $8, %rax"), "asm:\n{}", asm);
        assert!(asm.contains("    xorq %rax, %rax"), "asm:\n{}", asm);
        assert!(asm.contains("    movq $3, %rax"), "asm:\n{}", asm);
        assert!(!asm.contains("_tl_.L_tl_read_file"), "asm:\n{}", asm);
        assert!(
            !asm.contains("    .extern .L_tl_read_file"),
            "asm:\n{}",
            asm
        );
    }

    #[test]
    fn test_compile_no_read_file_means_no_read_file_runtime() {
        let asm = compile_ok(r#"(define (main) : i64 (string-length "hi"))"#);
        assert!(!asm.contains(".L_tl_read_file"), "asm:\n{}", asm);
        assert!(!asm.contains("tl: read-file failed"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_user_defined_read_file_shadows_builtin() {
        let asm = compile_ok(
            r#"
            (define (read-file [n : i64]) : i64 (+ n 1))
            (define (main) : i64 (read-file 41))
            "#,
        );
        assert!(asm.contains("_tl_read_file:"), "asm:\n{}", asm);
        assert!(asm.contains("    call _tl_read_file"), "asm:\n{}", asm);
        assert!(!asm.contains(".L_tl_read_file:"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_write_file_emits_runtime_alloc_syscalls_and_abort_path() {
        let asm = compile_ok(r#"(define (main) : i64 (begin (write-file "out.txt" "hi") 0))"#);

        assert!(asm.contains(".L_tl_write_file:"), "asm:\n{}", asm);
        assert!(asm.contains("    call .L_tl_write_file"), "asm:\n{}", asm);
        assert!(asm.contains("tl_alloc:"), "asm:\n{}", asm);
        assert!(asm.contains("    call tl_alloc"), "asm:\n{}", asm);
        assert!(asm.contains(".L_tl_abort:"), "asm:\n{}", asm);
        assert!(asm.contains("tl: write-file failed"), "asm:\n{}", asm);
        assert!(asm.contains("    movb $0, (%r15,%r12)"), "asm:\n{}", asm);
        assert!(asm.contains("    movq $257, %rax"), "asm:\n{}", asm);
        assert!(asm.contains("    movq $-100, %rdi"), "asm:\n{}", asm);
        assert!(asm.contains("    movq $577, %rdx"), "asm:\n{}", asm);
        assert!(asm.contains("    movq $438, %r10"), "asm:\n{}", asm);
        assert!(asm.contains("    movq $1, %rax"), "asm:\n{}", asm);
        assert!(asm.contains("    cmpq %r14, %rax"), "asm:\n{}", asm);
        assert!(asm.contains("    movq $3, %rax"), "asm:\n{}", asm);
        assert!(!asm.contains("_tl_.L_tl_write_file"), "asm:\n{}", asm);
        assert!(
            !asm.contains("    .extern .L_tl_write_file"),
            "asm:\n{}",
            asm
        );
    }

    #[test]
    fn test_compile_no_write_file_means_no_write_file_runtime() {
        let asm = compile_ok(r#"(define (main) : i64 (string-length "hi"))"#);
        assert!(!asm.contains(".L_tl_write_file"), "asm:\n{}", asm);
        assert!(!asm.contains("tl: write-file failed"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_user_defined_write_file_shadows_builtin() {
        let asm = compile_ok(
            r#"
            (define (write-file [n : i64]) : i64 (+ n 1))
            (define (main) : i64 (write-file 41))
            "#,
        );
        assert!(asm.contains("_tl_write_file:"), "asm:\n{}", asm);
        assert!(asm.contains("    call _tl_write_file"), "asm:\n{}", asm);
        assert!(!asm.contains(".L_tl_write_file:"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_file_exists_emits_runtime_alloc_syscall_and_abort_path() {
        let asm = compile_ok(r#"(define (main) : bool (file-exists? "input.txt"))"#);

        assert!(asm.contains(".L_tl_file_exists:"), "asm:\n{}", asm);
        assert!(asm.contains("    call .L_tl_file_exists"), "asm:\n{}", asm);
        assert!(asm.contains("tl_alloc:"), "asm:\n{}", asm);
        assert!(asm.contains("    call tl_alloc"), "asm:\n{}", asm);
        assert!(asm.contains(".L_tl_abort:"), "asm:\n{}", asm);
        assert!(asm.contains("tl: file-exists? failed"), "asm:\n{}", asm);
        assert!(asm.contains("    movb $0, (%r13,%r12)"), "asm:\n{}", asm);
        assert!(asm.contains("    movq $21, %rax"), "asm:\n{}", asm);
        assert!(asm.contains("    xorq %rsi, %rsi"), "asm:\n{}", asm);
        assert!(asm.contains("    cmpq $-2, %rax"), "asm:\n{}", asm);
        assert!(asm.contains("    movq $1, %rax"), "asm:\n{}", asm);
        assert!(!asm.contains("_tl_.L_tl_file_exists"), "asm:\n{}", asm);
        assert!(
            !asm.contains("    .extern .L_tl_file_exists"),
            "asm:\n{}",
            asm
        );
    }

    #[test]
    fn test_compile_file_status_helpers_emit_recoverable_runtimes() {
        let asm = compile_ok(
            r#"
            (define (main) : i64
              (+ (read-file-status "input.txt")
                (+ (write-file-status "out.txt" "hi")
                   (file-exists-status "input.txt"))))
            "#,
        );

        for symbol in [
            ".L_tl_read_file_status:",
            ".L_tl_write_file_status:",
            ".L_tl_file_exists_status:",
        ] {
            assert!(asm.contains(symbol), "asm:\n{}", asm);
        }
        assert!(
            asm.contains("    call .L_tl_read_file_status"),
            "asm:\n{}",
            asm
        );
        assert!(
            asm.contains("    call .L_tl_write_file_status"),
            "asm:\n{}",
            asm
        );
        assert!(
            asm.contains("    call .L_tl_file_exists_status"),
            "asm:\n{}",
            asm
        );
        assert!(asm.contains("    movq $22, %rax"), "asm:\n{}", asm);
        assert!(asm.contains("    negq %rax"), "asm:\n{}", asm);
        assert!(!asm.contains("_tl_.L_tl_read_file_status"), "asm:\n{}", asm);
        assert!(
            !asm.contains("    .extern .L_tl_read_file_status"),
            "asm:\n{}",
            asm
        );
    }

    #[test]
    fn test_windows_target_fs_mkdir_status_uses_crt_mkdir() {
        let asm = compile_ok_for_target(
            r#"(define (main) : i64 (fs-mkdir-status "target/site"))"#,
            BackendTarget::windows_x86_64(),
        );

        assert!(asm.contains(".L_tl_fs_mkdir_status:"), "asm:\n{}", asm);
        assert!(
            asm.contains("    .extern _mkdir"),
            "asm should declare the CRT mkdir helper:\n{}",
            asm
        );
        assert!(
            asm.contains("    call _mkdir"),
            "asm should call the CRT mkdir helper:\n{}",
            asm
        );
        assert!(
            asm.contains(".L_tl_fs_mkdir_status_win_errno:"),
            "asm should return errno on mkdir failure:\n{}",
            asm
        );
        assert!(
            asm.contains("    call _errno"),
            "asm should read errno on mkdir failure:\n{}",
            asm
        );
    }

    #[test]
    fn test_compile_no_file_exists_means_no_file_exists_runtime() {
        let asm = compile_ok(r#"(define (main) : i64 (string-length "hi"))"#);
        assert!(!asm.contains(".L_tl_file_exists"), "asm:\n{}", asm);
        assert!(!asm.contains("tl: file-exists? failed"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_user_defined_file_exists_shadows_builtin() {
        let asm = compile_ok(
            r#"
            (define (file-exists? [n : i64]) : i64 (+ n 1))
            (define (main) : i64 (file-exists? 41))
            "#,
        );
        assert!(asm.contains("_tl_file_exists_question:"), "asm:\n{}", asm);
        assert!(
            asm.contains("    call _tl_file_exists_question"),
            "asm:\n{}",
            asm
        );
        assert!(!asm.contains("_tl_file_exists?"), "asm:\n{}", asm);
        assert!(!asm.contains(".L_tl_file_exists:"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_stdin_helpers_emit_runtime_alloc_and_eof_state() {
        let asm = compile_ok(
            r#"
            (define (main) : i64
              (begin
                (read-stdin-line)
                (read-stdin-bytes 3)
                (flush-stdout)
                (if (stdin-eof?) 1 0)))
            "#,
        );

        assert!(asm.contains(".L_tl_read_stdin_line:"), "asm:\n{}", asm);
        assert!(asm.contains(".L_tl_read_stdin_bytes:"), "asm:\n{}", asm);
        assert!(asm.contains(".L_tl_stdin_eof:"), "asm:\n{}", asm);
        assert!(asm.contains(".L_tl_flush_stdout:"), "asm:\n{}", asm);
        assert!(asm.contains(".L_tl_stdin_eof_flag:"), "asm:\n{}", asm);
        assert!(asm.contains("tl_alloc:"), "asm:\n{}", asm);
        assert!(asm.contains("tl: stdin failed"), "asm:\n{}", asm);
        assert!(
            asm.contains("    call .L_tl_read_stdin_line"),
            "asm:\n{}",
            asm
        );
        assert!(
            asm.contains("    call .L_tl_read_stdin_bytes"),
            "asm:\n{}",
            asm
        );
        assert!(asm.contains("    call .L_tl_stdin_eof"), "asm:\n{}", asm);
        assert!(asm.contains("    call .L_tl_flush_stdout"), "asm:\n{}", asm);
        assert!(asm.contains("    xorq %rax, %rax"), "asm:\n{}", asm);
        assert!(asm.contains("    syscall"), "asm:\n{}", asm);
        assert!(!asm.contains("_tl_.L_tl_read_stdin"), "asm:\n{}", asm);
        assert!(
            !asm.contains("    .extern .L_tl_read_stdin"),
            "asm:\n{}",
            asm
        );
    }

    #[test]
    fn test_compile_no_stdin_helpers_means_no_stdin_runtime() {
        let asm = compile_ok(r#"(define (main) : i64 (string-length "hi"))"#);
        assert!(!asm.contains(".L_tl_read_stdin"), "asm:\n{}", asm);
        assert!(!asm.contains(".L_tl_stdin_eof"), "asm:\n{}", asm);
        assert!(!asm.contains(".L_tl_flush_stdout"), "asm:\n{}", asm);
        assert!(!asm.contains("tl: stdin failed"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_user_defined_stdin_helpers_shadow_builtins() {
        let asm = compile_ok(
            r#"
            (define (read-stdin-line [n : i64]) : i64 n)
            (define (read-stdin-bytes) : i64 2)
            (define (stdin-eof? [n : i64]) : i64 n)
            (define (flush-stdout [n : i64]) : i64 n)
            (define (main) : i64
              (+ (read-stdin-line 1)
                 (+ (read-stdin-bytes)
                    (+ (stdin-eof? 3) (flush-stdout 4)))))
            "#,
        );
        assert!(asm.contains("_tl_read_stdin_line:"), "asm:\n{}", asm);
        assert!(asm.contains("_tl_read_stdin_bytes:"), "asm:\n{}", asm);
        assert!(asm.contains("_tl_stdin_eof_question:"), "asm:\n{}", asm);
        assert!(asm.contains("_tl_flush_stdout:"), "asm:\n{}", asm);
        assert!(
            asm.contains("    call _tl_read_stdin_line"),
            "asm:\n{}",
            asm
        );
        assert!(
            asm.contains("    call _tl_read_stdin_bytes"),
            "asm:\n{}",
            asm
        );
        assert!(
            asm.contains("    call _tl_stdin_eof_question"),
            "asm:\n{}",
            asm
        );
        assert!(asm.contains("    call _tl_flush_stdout"), "asm:\n{}", asm);
        assert!(!asm.contains(".L_tl_read_stdin_line:"), "asm:\n{}", asm);
        assert!(!asm.contains(".L_tl_read_stdin_bytes:"), "asm:\n{}", asm);
        assert!(!asm.contains(".L_tl_stdin_eof:"), "asm:\n{}", asm);
        assert!(!asm.contains(".L_tl_flush_stdout:"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_print_string_emits_runtime_and_calls_it() {
        // `(print-string s)` calls the emit-on-demand `tl_print_str` helper and
        // the backend defines that helper inline (gated like `tl_string_eq`).
        let asm = compile_ok(r#"(define (main) : unit (print-string "hi"))"#);

        // The runtime function is emitted and globally visible.
        assert!(asm.contains("    .globl tl_print_str"), "asm:\n{}", asm);
        assert!(asm.contains("tl_print_str:"), "asm:\n{}", asm);

        // The call site dispatches to the raw runtime symbol (not mangled).
        assert!(asm.contains("    call tl_print_str"), "asm:\n{}", asm);
        assert!(!asm.contains("_tl_tl_print_str"), "asm:\n{}", asm);
        assert!(!asm.contains("_tl_print_str:"), "asm:\n{}", asm);

        // The helper issues a single `write(2)` syscall to fd 1 (stdout): the
        // write syscall number 1 in %rax, fd 1 in %rdi, then a `syscall`, and it
        // RETURNS (unlike `tl_abort` it does not exit). Isolate the body.
        let ps_section = asm
            .split("tl_print_str:")
            .nth(1)
            .expect("tl_print_str body");
        let ps_body = ps_section
            .split("\n    .globl ")
            .next()
            .unwrap_or(ps_section)
            .split("\nmain:")
            .next()
            .unwrap_or(ps_section)
            .split("\n_start:")
            .next()
            .unwrap_or(ps_section);
        assert!(
            ps_body.contains("movq $1, %rdi"),
            "tl_print_str writes to fd 1 (stdout):\n{}",
            ps_body
        );
        assert!(
            ps_body.contains("movq $1, %rax"),
            "tl_print_str uses the write syscall (number 1):\n{}",
            ps_body
        );
        assert!(
            ps_body.contains("syscall"),
            "tl_print_str issues a syscall:\n{}",
            ps_body
        );
        assert!(
            ps_body.contains("ret"),
            "tl_print_str returns rather than exiting:\n{}",
            ps_body
        );
        // It does not terminate the process (no exit syscall like tl_abort).
        assert!(
            !ps_body.contains("movq $60, %rax"),
            "tl_print_str must not exit the process:\n{}",
            ps_body
        );

        // The helper is not declared `.extern` (it is defined in this unit).
        assert!(!asm.contains("    .extern tl_print_str"), "asm:\n{}", asm);

        // No instruction selection fell through to a TODO stub.
        assert!(!asm.contains("# TODO"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_print_str_aliases_print_string_runtime() {
        // `(print-str s)` emits and calls the same `tl_print_str` runtime.
        let asm = compile_ok(r#"(define (main) : unit (print-str "hi"))"#);
        assert!(asm.contains("tl_print_str:"), "asm:\n{}", asm);
        assert!(asm.contains("    call tl_print_str"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_no_print_string_means_no_runtime() {
        // A program that never prints a string must not emit the helper.
        let asm = compile_ok(r#"(define (main) : i64 (string-length "hi"))"#);
        assert!(!asm.contains("tl_print_str"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_user_defined_print_string_shadows_builtin() {
        // A user-defined `print-string` function must be a mangled TypeLisp call,
        // not forced through the `tl_print_str` runtime.
        let asm = compile_ok(
            r#"
            (define (print-string [n : i64]) : i64 (+ n 1))
            (define (main) : i64 (print-string 41))
            "#,
        );
        assert!(asm.contains("_tl_print_string:"), "asm:\n{}", asm);
        assert!(asm.contains("    call _tl_print_string"), "asm:\n{}", asm);
        assert!(!asm.contains("    call tl_print_str"), "asm:\n{}", asm);
        assert!(!asm.contains("\ntl_print_str:\n"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_user_defined_panic_shadows_builtin() {
        // User-defined functions may shadow builtin names. If `panic` is a
        // normal user function, calls to it must be mangled TypeLisp calls, not
        // forced through the abort runtime.
        let asm = compile_ok(
            r#"
            (define (panic [n : i64]) : i64 (+ n 1))
            (define (main) : i64 (panic 41))
            "#,
        );

        assert!(asm.contains("_tl_panic:"), "asm:\n{}", asm);
        assert!(asm.contains("    call _tl_panic"), "asm:\n{}", asm);
        assert!(!asm.contains(".L_tl_abort"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_panic_runtime_coexists_with_user_defined_tl_abort() {
        // The panic builtin lowers to a private assembler label, so it cannot
        // collide with a user-defined function named `tl_abort`.
        let asm = compile_ok(
            r#"
            (define (tl_abort [n : i64]) : i64 n)
            (define (main) : unit (panic "boom"))
            "#,
        );

        assert!(asm.contains("_tl_tl_abort:"), "asm:\n{}", asm);
        assert!(asm.contains(".L_tl_abort:"), "asm:\n{}", asm);
        assert!(asm.contains("    call .L_tl_abort"), "asm:\n{}", asm);
        assert!(!asm.contains("    call _tl_tl_abort"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_string_to_int_emits_runtime_and_calls_it() {
        // `(string->int s)` calls the emit-on-demand `tl_string_to_int` helper
        // and the backend defines that helper inline (gated like `tl_string_eq`).
        let asm = compile_ok(r#"(define (main) : i64 (string->int "42"))"#);

        // The runtime function is emitted and globally visible.
        assert!(asm.contains("    .globl tl_string_to_int"), "asm:\n{}", asm);
        assert!(asm.contains("tl_string_to_int:"), "asm:\n{}", asm);

        // The call site dispatches to the raw runtime symbol (not mangled).
        assert!(asm.contains("    call tl_string_to_int"), "asm:\n{}", asm);
        assert!(!asm.contains("_tl_tl_string_to_int"), "asm:\n{}", asm);
        assert!(!asm.contains("_tl_string_to_int:"), "asm:\n{}", asm);

        // The helper is a pure decimal parse: it skips an optional '-' (45),
        // accumulates via an imul-by-10 loop, and subtracts '0' (48) per digit —
        // and crucially NO syscall (it neither allocates nor writes).
        assert!(asm.contains("    cmpb $45, %cl"), "asm:\n{}", asm);
        assert!(asm.contains(".L_tl_string_to_int_loop:"), "asm:\n{}", asm);
        assert!(asm.contains("    imulq $10, %rax, %rax"), "asm:\n{}", asm);
        assert!(asm.contains("    subq $48, %rcx"), "asm:\n{}", asm);
        let conv_section = asm
            .split("tl_string_to_int:")
            .nth(1)
            .expect("tl_string_to_int body");
        let conv_body = conv_section
            .split("\n_start:")
            .next()
            .unwrap_or(conv_section);
        assert!(
            !conv_body.contains("syscall"),
            "tl_string_to_int must be syscall-free:\n{}",
            conv_body
        );

        // The helper is not declared `.extern` (it is defined in this unit).
        assert!(
            !asm.contains("    .extern tl_string_to_int"),
            "asm:\n{}",
            asm
        );

        // No instruction selection fell through to a TODO stub.
        assert!(!asm.contains("# TODO"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_int_to_string_emits_runtime_and_calls_it() {
        // `(int->string n)` calls the emit-on-demand `tl_int_to_string` helper,
        // which the backend defines inline (gated like `tl_alloc`). The result is
        // discarded but the `Call` survives DCE (it has side effects).
        let asm = compile_ok("(define (main) : i64 (begin (int->string 42) 0))");

        // The runtime function is emitted and globally visible.
        assert!(asm.contains("    .globl tl_int_to_string"), "asm:\n{}", asm);
        assert!(asm.contains("tl_int_to_string:"), "asm:\n{}", asm);

        // The call site dispatches to the raw runtime symbol (not mangled).
        assert!(asm.contains("    call tl_int_to_string"), "asm:\n{}", asm);
        assert!(!asm.contains("_tl_tl_int_to_string"), "asm:\n{}", asm);
        assert!(!asm.contains("_tl_int_to_string:"), "asm:\n{}", asm);

        // The helper formats with a divide-by-10 digit loop (like tl_print_i64),
        // handles the negative sign (`movb $45`), and the zero/'0' digit
        // (`movb $48`).
        assert!(
            asm.contains(".L_tl_int_to_string_digit_loop:"),
            "asm:\n{}",
            asm
        );
        assert!(asm.contains("    divq %r9"), "asm:\n{}", asm);
        assert!(asm.contains("    movb $45,"), "asm:\n{}", asm);
        assert!(asm.contains("    movb $48,"), "asm:\n{}", asm);

        // It heap-allocates both the digit buffer and the 16-byte fat value via
        // the bump allocator, whose self-contained body is also emitted here.
        assert!(asm.contains("    call tl_alloc"), "asm:\n{}", asm);
        assert!(asm.contains("tl_alloc:"), "asm:\n{}", asm);
        assert!(asm.contains("    movq $16, %rdi"), "asm:\n{}", asm);
        // The fat value's data pointer (offset 0) and length (offset 8) are
        // stored before returning.
        assert!(asm.contains("    movq %r13, 0(%rax)"), "asm:\n{}", asm);
        assert!(asm.contains("    movq %r12, 8(%rax)"), "asm:\n{}", asm);

        // The helper is not declared `.extern` (it is defined in this unit).
        assert!(
            !asm.contains("    .extern tl_int_to_string"),
            "asm:\n{}",
            asm
        );

        // No instruction selection fell through to a TODO stub.
        assert!(!asm.contains("# TODO"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_no_string_to_int_means_no_runtime() {
        // A program that never parses strings must not emit the helper.
        let asm = compile_ok(r#"(define (main) : i64 (string-length "hi"))"#);
        assert!(!asm.contains("tl_string_to_int"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_no_int_to_string_means_no_runtime() {
        // A program that never converts ints to strings must not emit the helper.
        let asm = compile_ok(r#"(define (main) : i64 (string-length "hi"))"#);
        assert!(!asm.contains("tl_int_to_string"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_substring_emits_runtime_and_calls_it() {
        // `(substring s a b)` calls the emit-on-demand `tl_substring` helper,
        // which the backend defines inline (gated like `tl_alloc`). The result is
        // discarded but the `Call` survives DCE (it has side effects).
        let asm = compile_ok("(define (f [s : String]) : i64 (begin (substring s 1 3) 0))");

        // The runtime function is emitted and globally visible.
        assert!(asm.contains("    .globl tl_substring"), "asm:\n{}", asm);
        assert!(asm.contains("tl_substring:"), "asm:\n{}", asm);

        // The call site dispatches to the raw runtime symbol (not mangled).
        assert!(asm.contains("    call tl_substring"), "asm:\n{}", asm);
        assert!(!asm.contains("_tl_tl_substring"), "asm:\n{}", asm);

        // It heap-allocates both the slice buffer and the 16-byte fat value via
        // the bump allocator, whose self-contained body is also emitted here.
        assert!(asm.contains("    call tl_alloc"), "asm:\n{}", asm);
        assert!(asm.contains("tl_alloc:"), "asm:\n{}", asm);
        assert!(asm.contains("    movq $16, %rdi"), "asm:\n{}", asm);

        // The runtime copies bytes in a loop (movb of one byte per iteration) and
        // stores the fat value's data pointer (offset 0) and length (offset 8).
        assert!(asm.contains(".L_tl_substring_copy_loop:"), "asm:\n{}", asm);
        assert!(asm.contains("    movb %dl, (%r13,%rcx)"), "asm:\n{}", asm);
        assert!(asm.contains("    movq %r13, 0(%rax)"), "asm:\n{}", asm);
        assert!(asm.contains("    movq %r12, 8(%rax)"), "asm:\n{}", asm);

        // The helper is not declared `.extern` (it is defined in this unit).
        assert!(!asm.contains("    .extern tl_substring"), "asm:\n{}", asm);

        // No instruction selection fell through to a TODO stub.
        assert!(!asm.contains("# TODO"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_substring_bounds_check_is_unsigned_and_traps_via_call() {
        // The range is bounds-checked with UNSIGNED compares (`setbe`, not the
        // signed `setle`); failing either branch traps through the shared abort
        // runtime (a Call, so it survives DCE).
        let asm = compile_ok("(define (f [s : String]) : i64 (begin (substring s 1 3) 0))");

        // Unsigned comparison for the bounds check (`setbe`, not signed `setle`).
        assert!(asm.contains("setbe %al"), "asm:\n{}", asm);
        assert!(!asm.contains("setle %al"), "asm:\n{}", asm);
        // The out-of-bounds trap is a Call to the abort symbol, whose
        // self-contained body is emitted in this same unit.
        assert!(asm.contains("    call tl_oob_abort"), "asm:\n{}", asm);
        assert!(asm.contains("tl_oob_abort:"), "asm:\n{}", asm);
        // The remaining-length `len - start` subtraction is emitted.
        assert!(asm.contains("    subq"), "asm:\n{}", asm);
        assert!(!asm.contains("# TODO"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_no_substring_means_no_runtime() {
        // A program that never slices strings must not emit the helper.
        let asm = compile_ok(r#"(define (main) : i64 (string-length "hi"))"#);
        assert!(!asm.contains("tl_substring"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_user_defined_substring_shadows_builtin() {
        // User-defined functions may shadow builtin names. A surface function
        // named `substring` must call the mangled TypeLisp symbol and must not
        // emit the backend substring runtime.
        let asm = compile_ok(
            r#"
            (define (substring [n : i64] [a : i64] [b : i64]) : i64
              (+ (+ n a) b))
            (define (main) : i64 (substring 1 2 3))
            "#,
        );
        assert!(asm.contains("_tl_substring:"), "asm:\n{}", asm);
        assert!(asm.contains("    call _tl_substring"), "asm:\n{}", asm);
        assert!(!asm.contains("\ntl_substring:\n"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_string_append_emits_runtime_and_calls_it() {
        // `(string-append a b)` calls the emit-on-demand `tl_string_concat`
        // helper, which the backend defines inline (gated like `tl_alloc`). The
        // result is discarded but the `Call` survives DCE (it has side effects).
        let asm = compile_ok(
            "(define (f [a : String] [b : String]) : i64 (begin (string-append a b) 0))",
        );

        // The runtime function is emitted and globally visible.
        assert!(asm.contains("    .globl tl_string_concat"), "asm:\n{}", asm);
        assert!(asm.contains("tl_string_concat:"), "asm:\n{}", asm);

        // The call site dispatches to the raw runtime symbol (not mangled).
        assert!(asm.contains("    call tl_string_concat"), "asm:\n{}", asm);
        assert!(!asm.contains("_tl_tl_string_concat"), "asm:\n{}", asm);

        // It heap-allocates both the joined data buffer and the 16-byte fat value
        // via the bump allocator, whose self-contained body is also emitted here.
        assert!(asm.contains("    call tl_alloc"), "asm:\n{}", asm);
        assert!(asm.contains("tl_alloc:"), "asm:\n{}", asm);
        assert!(asm.contains("    movq $16, %rdi"), "asm:\n{}", asm);

        // The runtime copies each operand's bytes in its own loop (two byte-copy
        // loops, one per source) and stores the fat value's data pointer
        // (offset 0) and total length (offset 8).
        assert!(asm.contains(".L_tl_string_concat_copy_a:"), "asm:\n{}", asm);
        assert!(asm.contains(".L_tl_string_concat_copy_b:"), "asm:\n{}", asm);
        assert!(asm.contains("    movq %r15, 0(%rax)"), "asm:\n{}", asm);
        assert!(asm.contains("    movq %rdx, 8(%rax)"), "asm:\n{}", asm);

        // The helper is not declared `.extern` (it is defined in this unit).
        assert!(
            !asm.contains("    .extern tl_string_concat"),
            "asm:\n{}",
            asm
        );

        // No instruction selection fell through to a TODO stub.
        assert!(!asm.contains("# TODO"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_string_concat_alias_emits_runtime() {
        // `string-concat` is the alias of `string-append`; it emits and calls the
        // same `tl_string_concat` runtime.
        let asm = compile_ok(
            "(define (f [a : String] [b : String]) : i64 (begin (string-concat a b) 0))",
        );
        assert!(asm.contains("tl_string_concat:"), "asm:\n{}", asm);
        assert!(asm.contains("    call tl_string_concat"), "asm:\n{}", asm);
        assert!(!asm.contains("# TODO"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_no_string_append_means_no_runtime() {
        // A program that never concatenates strings must not emit the helper.
        let asm = compile_ok(r#"(define (main) : i64 (string-length "hi"))"#);
        assert!(!asm.contains("tl_string_concat"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_user_defined_string_append_shadows_builtin() {
        // User-defined functions may shadow builtin names. A surface function
        // named `string-append` must call the mangled TypeLisp symbol and must
        // not emit the backend concat runtime.
        let asm = compile_ok(
            r#"
            (define (string-append [a : i64] [b : i64]) : i64
              (+ a b))
            (define (main) : i64 (string-append 1 2))
            "#,
        );
        assert!(asm.contains("_tl_string_append:"), "asm:\n{}", asm);
        assert!(asm.contains("    call _tl_string_append"), "asm:\n{}", asm);
        assert!(!asm.contains("\ntl_string_concat:\n"), "asm:\n{}", asm);
    }

    #[test]
    fn test_escape_string_bytes_escapes_specials() {
        // Quote, backslash, newline and a non-printable byte are escaped so the
        // assembler reproduces the exact bytes.
        let rendered = X86_64Backend::escape_string_bytes("a\"b\\c\n\u{7}");
        assert_eq!(rendered, "\"a\\\"b\\\\c\\n\\007\"");
    }

    // ------------------------------------------------------------------
    // Dynamic arrays — Issue #13
    // ------------------------------------------------------------------

    #[test]
    fn test_compile_make_array_calls_alloc_and_stores_ptr_len() {
        // `(make-array i64 n)` allocates the element buffer via tl_alloc and
        // stores the buffer pointer + element count into the fat value.
        let asm = compile_ok("(define (f [n : i64]) : i64 (begin (make-array i64 n) 0))");

        // The element buffer is allocated through the runtime bump allocator,
        // whose self-contained body is emitted in this same unit.
        assert!(asm.contains("    call tl_alloc"), "asm:\n{}", asm);
        assert!(asm.contains("tl_alloc:"), "asm:\n{}", asm);
        // Dynamic lengths are checked before allocation: signed <= comparisons
        // reject negative lengths and byte-count overflow.
        assert!(asm.matches("setle %al").count() >= 2, "asm:\n{}", asm);
        assert!(asm.contains("$1152921504606846975"), "asm:\n{}", asm);
        assert!(asm.contains("    call tl_oob_abort"), "asm:\n{}", asm);
        assert!(asm.contains("tl_oob_abort:"), "asm:\n{}", asm);
        // The byte count is the element count scaled by sizeof(i64) = 8, then
        // passed to the allocator in %rdi.
        assert!(asm.contains("$8, %rcx"), "asm:\n{}", asm);
        assert!(asm.contains("imulq %rcx, %rax"), "asm:\n{}", asm);
        assert!(
            asm.contains("movq -16(%rbp), %rdi") || asm.contains(", %rdi"),
            "asm:\n{}",
            asm
        );
        // No instruction selection fell through to a TODO stub.
        assert!(!asm.contains("# TODO"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_array_ref_bounds_check_traps_via_call() {
        // `array-ref` emits an unsigned bounds compare, a conditional branch and
        // a Call to the abort runtime on the out-of-bounds path, then a Gep +
        // Load of the element.
        let asm = compile_ok("(define (f [a : (Array i64)] [i : i64]) : i64 (array-ref a i))");

        // Unsigned compare for the bounds check (`setb`, not the signed `setl`).
        assert!(asm.contains("setb %al"), "asm:\n{}", asm);
        assert!(!asm.contains("setl %al"), "asm:\n{}", asm);
        // A conditional branch decides in-bounds vs out-of-bounds.
        assert!(asm.contains("jnz "), "asm:\n{}", asm);
        // The out-of-bounds trap is a Call (survives DCE) to the abort symbol,
        // whose self-contained body is emitted in this same unit.
        assert!(asm.contains("    call tl_oob_abort"), "asm:\n{}", asm);
        assert!(asm.contains("tl_oob_abort:"), "asm:\n{}", asm);
        // The element address is formed by scaling the index and adding it to
        // the buffer pointer (Gep), then the element is loaded via the pointer.
        assert!(asm.contains("imulq $8"), "asm:\n{}", asm);
        assert!(asm.contains("(%r10)"), "asm:\n{}", asm);
        assert!(!asm.contains("# TODO"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_array_set_bounds_check_then_stores_in_place() {
        // `array-set!` is the store-side mirror of `array-ref`: an unsigned
        // bounds compare (`setb`, not signed `setl`), a conditional branch, a
        // Call to the abort runtime on the out-of-bounds path, then a Gep to the
        // element address and a `mov`-to-memory store of the value (in place).
        let asm = compile_ok(
            "(define (f [a : (Array i64)] [i : i64] [v : i64]) : unit (array-set! a i v))",
        );

        // Unsigned compare for the bounds check (`setb`, not the signed `setl`).
        assert!(asm.contains("setb %al"), "asm:\n{}", asm);
        assert!(!asm.contains("setl %al"), "asm:\n{}", asm);
        // A conditional branch decides in-bounds vs out-of-bounds.
        assert!(asm.contains("jnz "), "asm:\n{}", asm);
        // The out-of-bounds trap is a Call (survives DCE) to the abort symbol.
        assert!(asm.contains("    call tl_oob_abort"), "asm:\n{}", asm);
        assert!(asm.contains("tl_oob_abort:"), "asm:\n{}", asm);
        // The element address is formed by scaling the index (Gep), then the
        // value is written through the computed pointer in %r10 — a store to
        // memory, not a load from it.
        assert!(asm.contains("imulq $8"), "asm:\n{}", asm);
        assert!(asm.contains("%rax, (%r10)"), "asm:\n{}", asm);
        assert!(!asm.contains("# TODO"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_fixed_array_literal_ref_and_set() {
        let asm = compile_ok(
            "(define (f [i : i64]) : i64 \
               (let ([a : (Array i64 3) (array 2 2 3)]) \
                 (begin \
                   (array-set! a i 40) \
                   (+ (array-ref a 0) (array-ref a i)))))",
        );

        assert!(asm.contains("setb %al"), "asm:\n{}", asm);
        assert!(asm.contains("    call tl_oob_abort"), "asm:\n{}", asm);
        assert!(asm.contains("tl_oob_abort:"), "asm:\n{}", asm);
        assert!(asm.contains("imulq $8, %rcx"), "asm:\n{}", asm);
        assert!(asm.contains("movq $40"), "asm:\n{}", asm);
        assert!(asm.contains("%rax, (%r10)"), "asm:\n{}", asm);
        assert!(!asm.contains("# TODO"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_array_of_enum_set_then_ref_uses_pointer_stride() {
        // Dynamic array of an AGGREGATE (enum) element. Each element is a pointer
        // (8 bytes), so the element address scales by 8 (`imulq $8`) — the same
        // stride as an i64 array, driven by Type::size, not hardcoded. The set
        // stores a pointer through the computed address (`%rax, (%r10)`) and the
        // ref loads a pointer back; both still go through the bounds-check trap.
        let asm = compile_ok(
            "(defenum Shape (Circle i64) (Square i64) (Nothing))\n\
             (define (f [a : (Array Shape)] [i : i64]) : i64 \
               (begin \
                 (array-set! a i (Circle 3)) \
                 (match (array-ref a i) [(Circle r) r] [(Square s) s] [Nothing 0])))",
        );

        // Pointer-sized element stride.
        assert!(asm.contains("imulq $8"), "asm:\n{}", asm);
        // The store writes a pointer through the computed element address.
        assert!(asm.contains("%rax, (%r10)"), "asm:\n{}", asm);
        // The element is read back through the computed pointer (the ref Load).
        assert!(asm.contains("(%r10)"), "asm:\n{}", asm);
        // Bounds-check trap remains intact for the aggregate-element accesses.
        assert!(asm.contains("    call tl_oob_abort"), "asm:\n{}", asm);
        assert!(asm.contains("setb %al"), "asm:\n{}", asm);
        assert!(!asm.contains("# TODO"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_oob_abort_runtime_writes_to_fd2_and_exits() {
        // The emitted abort runtime writes a message to fd 2 (write syscall) and
        // terminates the process (exit syscall, status 134), zero-dependency.
        let asm = compile_ok("(define (f [a : (Array i64)] [i : i64]) : i64 (array-ref a i))");

        assert!(asm.contains("tl_oob_abort:"), "asm:\n{}", asm);
        // write(2, msg, len): fd 2 in %rdi, message label loaded RIP-relative.
        assert!(asm.contains("movq $2, %rdi"), "asm:\n{}", asm);
        assert!(asm.contains(".L_tl_oob_msg"), "asm:\n{}", asm);
        // The two syscalls (write then exit) are present.
        assert!(asm.matches("    syscall").count() >= 2, "asm:\n{}", asm);
        // exit(134) via syscall 60.
        assert!(asm.contains("movq $60, %rax"), "asm:\n{}", asm);
        assert!(asm.contains("movq $134, %rdi"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_length_reads_len_field_not_a_call() {
        // `(length a)` loads the fat value's len field; there is no runtime call
        // to a `length`/`array-length` symbol, and no abort runtime is emitted
        // (no bounds check on a bare length read).
        let asm = compile_ok("(define (f [a : (Array i64)]) : i64 (length a))");

        assert!(!asm.contains("call _tl_length"), "asm:\n{}", asm);
        assert!(!asm.contains("call _tl_array_length"), "asm:\n{}", asm);
        assert!(!asm.contains("tl_oob_abort:"), "asm:\n{}", asm);
        assert!(!asm.contains("# TODO"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_string_ref_bounds_check_traps_via_call() {
        // `string-ref` emits an UNSIGNED bounds compare, a conditional branch and
        // a Call to the abort runtime on the out-of-bounds path, then loads a
        // single byte zero-extended into the char result.
        let asm = compile_ok(r#"(define (f [s : String] [i : i64]) : char (string-ref s i))"#);

        // Unsigned compare for the bounds check (`setb`, NOT the signed `setl`).
        assert!(asm.contains("setb %al"), "asm:\n{}", asm);
        assert!(!asm.contains("setl %al"), "asm:\n{}", asm);
        // A conditional branch decides in-bounds vs out-of-bounds.
        assert!(asm.contains("jnz "), "asm:\n{}", asm);
        // The out-of-bounds trap is a Call (survives DCE) to the abort symbol,
        // whose self-contained body is emitted in this same unit.
        assert!(asm.contains("    call tl_oob_abort"), "asm:\n{}", asm);
        assert!(asm.contains("tl_oob_abort:"), "asm:\n{}", asm);
        // The indexed byte is loaded through the computed pointer and
        // zero-extended into the full register (`movzbq`), as befits a char.
        assert!(asm.contains("(%r10)"), "asm:\n{}", asm);
        assert!(asm.contains("movzbq"), "asm:\n{}", asm);
        assert!(!asm.contains("# TODO"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_string_ref_byte_load_does_not_sign_extend() {
        // A char load must zero-extend (`movzbq`), never sign-extend (`movsbq`),
        // so high-bit bytes (>= 0x80) read back as positive byte values.
        let asm = compile_ok(r#"(define (f [s : String] [i : i64]) : char (string-ref s i))"#);
        assert!(asm.contains("movzbq"), "asm:\n{}", asm);
        assert!(
            !asm.contains("movsbq (%r10)"),
            "char byte load must not sign-extend; asm:\n{}",
            asm
        );
    }

    #[test]
    fn test_compile_make_array_then_length_round_trips() {
        // End-to-end through the surface language: allocate then read length.
        let asm = compile_ok(
            "(define (f [n : i64]) : i64 \
               (let ([a : (Array i64) (make-array i64 n)]) (length a)))",
        );
        assert!(asm.contains("    call tl_alloc"), "asm:\n{}", asm);
        assert!(asm.contains("tl_alloc:"), "asm:\n{}", asm);
        assert!(!asm.contains("# TODO"), "asm:\n{}", asm);
    }

    // ------------------------------------------------------------------
    // Heap promotion of escaping aggregates — refs #13/#45
    // ------------------------------------------------------------------

    #[test]
    fn test_compile_returned_enum_constructor_is_heap_allocated() {
        // A function whose return type is the enum heap-promotes the constructor
        // storage: it is allocated through the runtime bump allocator (whose body
        // is emitted in this same unit) rather than carved from the frame, so the
        // returned pointer outlives the epilogue's frame teardown.
        let asm = compile_ok(
            "(defenum Shape (Circle i64) (Square i64) (Nothing))\n\
             (define (mk) : Shape (Circle 7))",
        );

        // Storage comes from tl_alloc, not a frame slot + leaq.
        assert!(asm.contains("    call tl_alloc"), "asm:\n{}", asm);
        assert!(asm.contains("tl_alloc:"), "asm:\n{}", asm);
        // The 16-byte enum storage size is requested from the allocator.
        assert!(asm.contains("$16"), "asm:\n{}", asm);
        // The payload (7) is stored into the heap storage through a pointer.
        assert!(asm.contains("movq $7,"), "asm:\n{}", asm);
        assert!(!asm.contains("# TODO"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_returned_string_is_heap_allocated() {
        // A `String`-returning function heap-promotes the fat-string storage.
        let asm = compile_ok(r#"(define (mk) : String "hi")"#);
        assert!(asm.contains("    call tl_alloc"), "asm:\n{}", asm);
        assert!(asm.contains("tl_alloc:"), "asm:\n{}", asm);
        assert!(!asm.contains("# TODO"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_local_enum_not_returned_uses_no_alloc_runtime() {
        // When the function does NOT return an aggregate, its local enum keeps
        // frame allocation: no allocator runtime is emitted at all.
        let asm = compile_ok(
            "(defenum Shape (Circle i64) (Square i64) (Nothing))\n\
             (define (main) : i64 (begin (Circle 7) 0))",
        );
        assert!(!asm.contains("    call tl_alloc"), "asm:\n{}", asm);
        assert!(!asm.contains("tl_alloc:"), "asm:\n{}", asm);
        // Frame allocation still materializes the storage address via leaq.
        assert!(asm.contains("leaq"), "asm:\n{}", asm);
        assert!(!asm.contains("# TODO"), "asm:\n{}", asm);
    }

    // ------------------------------------------------------------------
    // Recursive enums (heap-pointer indirection) — refs #13/#27
    // ------------------------------------------------------------------

    #[test]
    fn test_compile_recursive_enum_tree_build_and_eval() {
        // Building `(EAdd (ENum 1) (ENum 2))` and a recursive `eval` over it
        // compiles cleanly through the backend: every node is heap-allocated via
        // the bump allocator (whose body is emitted in this unit), the recursive
        // payload pointers are stored/loaded, and `eval` recurses on itself.
        let asm = compile_ok(
            "(defenum Expr (ENum i64) (EAdd Expr Expr))\n\
             (define (mk) : Expr (EAdd (ENum 1) (ENum 2)))\n\
             (define (eval [e : Expr]) : i64 \
               (match e [(ENum n) n] [(EAdd l r) (+ (eval l) (eval r))]))",
        );

        // Nodes are heap-allocated; the bump allocator body is emitted here.
        assert!(asm.contains("    call tl_alloc"), "asm:\n{}", asm);
        assert!(asm.contains("tl_alloc:"), "asm:\n{}", asm);
        // The uniform 24-byte Expr storage (tag + two 8-byte pointer fields) is
        // requested from the allocator.
        assert!(asm.contains("$24"), "asm:\n{}", asm);
        // `eval` recurses on itself (the call target is the mangled `eval`).
        assert!(asm.contains("call _tl_eval"), "asm:\n{}", asm);
        // No unhandled instructions slipped through.
        assert!(!asm.contains("# TODO"), "asm:\n{}", asm);
    }

    // ------------------------------------------------------------------
    // Structs / records — Issue #18
    // ------------------------------------------------------------------

    #[test]
    fn test_compile_struct_field_access_no_todo() {
        // Reading a field of a struct *parameter* compiles to a Gep+Load over
        // the struct pointer with no unhandled instructions.
        let asm = compile_ok(
            "(defstruct Point (x i64) (y i64))\n\
             (define (getx [p : Point]) : i64 (struct-get p x))",
        );
        assert!(!asm.contains("# TODO"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_returned_struct_is_heap_allocated() {
        // A function whose return type is the struct heap-promotes the
        // constructor storage through the runtime bump allocator so the returned
        // pointer outlives the frame (#85). The 16-byte storage is requested and
        // the field values are stored into it.
        let asm = compile_ok(
            "(defstruct Point (x i64) (y i64))\n\
             (define (mk) : Point (Point 1 2))",
        );
        assert!(asm.contains("    call tl_alloc"), "asm:\n{}", asm);
        assert!(asm.contains("tl_alloc:"), "asm:\n{}", asm);
        // The 16-byte struct storage size is requested from the allocator.
        assert!(asm.contains("$16"), "asm:\n{}", asm);
        // Field values are stored into the heap storage.
        assert!(asm.contains("movq $1,"), "asm:\n{}", asm);
        assert!(asm.contains("movq $2,"), "asm:\n{}", asm);
        assert!(!asm.contains("# TODO"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_struct_roundtrip_construct_then_read_no_todo() {
        // Construct a struct in a local and read a field back: the full
        // construct + access path lowers to memory ops the backend handles.
        let asm = compile_ok(
            "(defstruct Point (x i64) (y i64))\n\
             (define (main) : i64 \
               (let ([p : Point (Point 10 20)]) (struct-get p y)))",
        );
        assert!(!asm.contains("# TODO"), "asm:\n{}", asm);
    }
}
