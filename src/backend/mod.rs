use crate::ir::{
    BasicBlock, BinOp as IrBinOp, Function, Instruction, Label, Program, UnOp as IrUnOp, Value,
    VarId,
};
use crate::types::Type;
use std::collections::{HashMap, HashSet};

const ABORT_RUNTIME_SYMBOL: &str = ".L_tl_abort";
const ARG_COUNT_RUNTIME_SYMBOL: &str = ".L_tl_arg_count";
const ARG_RUNTIME_SYMBOL: &str = ".L_tl_arg";
const READ_FILE_RUNTIME_SYMBOL: &str = ".L_tl_read_file";
const WRITE_FILE_RUNTIME_SYMBOL: &str = ".L_tl_write_file";
const FILE_EXISTS_RUNTIME_SYMBOL: &str = ".L_tl_file_exists";

/// x86_64 assembly code generator
/// Target: Linux, System V AMD64 ABI
pub struct X86_64Backend {
    output: String,
    stack_size: i32,
    var_offsets: HashMap<VarId, i32>,
    var_types: HashMap<VarId, Type>,
    global_types: HashMap<String, Type>,
    address_vars: HashSet<VarId>,
    extern_names: HashSet<String>,
    runtime_print_names: HashSet<String>,
    /// Whether the program references the bump allocator `tl_alloc` and the
    /// backend must therefore emit the self-contained allocator runtime
    /// (mmap arena + bump pointer) into the program's `.s`.
    needs_alloc_runtime: bool,
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
pub fn validate_program(program: &Program) -> Result<(), String> {
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
        validate_function(func, &global_types)?;
    }
    Ok(())
}

fn validate_global(name: &str, ty: &Type, init: Option<&Value>) -> Result<(), String> {
    if !is_global_data_type(ty) {
        return Err(format!(
            "backend: global '{}' has unsupported type {}. \
             The x86_64 backend currently supports scalar integer, bool, char, f64 \
             and unit globals.",
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

fn validate_function(func: &Function, global_types: &HashMap<String, Type>) -> Result<(), String> {
    let var_types: HashMap<VarId, Type> = func
        .params
        .iter()
        .chain(func.locals.iter())
        .map(|(var, ty)| (*var, ty.clone()))
        .collect();

    let unsupported = |what: &str| {
        Err(format!(
            "backend: function '{}' uses an unsupported construct ({}). \
             The x86_64 backend currently supports scalar arithmetic, comparisons, \
             unary/binary operators, direct function calls, recursion, control flow \
             (if/while), indirect calls through function-pointer values and scalar \
             let/set! locals. F32 values and by-value tuples/fixed arrays are \
             not yet wired.",
            func.name, what
        ))
    };

    if !is_backend_abi_value_type(&func.ret) {
        return unsupported(&format!("return type {}", func.ret));
    }
    for (var, ty) in &func.params {
        if !is_backend_abi_value_type(ty) {
            return unsupported(&format!("parameter %{} has type {}", var, ty));
        }
    }
    for (var, ty) in &func.locals {
        if !is_backend_local_type(ty) {
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
                    if (lhs_ty == Type::F64 || rhs_ty == Type::F64 || *ty == Type::F64)
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
                        return unsupported("unsupported f64 binary operator");
                    }
                }
                Instruction::UnOp { op, src, ty, .. } => {
                    check_operand(src, global_types)
                        .map_err(|w| unsupported_value(&func.name, &w))?;
                    let src_ty = validate_value_type(src, &var_types, global_types)
                        .unwrap_or_else(|| ty.clone());
                    if src_ty == Type::F64 && matches!(*op, IrUnOp::Not | IrUnOp::BitNot) {
                        return unsupported("unsupported f64 unary operator");
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
                    if from_ty.is_float() || to_ty.is_float() {
                        return unsupported("floating-point cast");
                    }
                }
                Instruction::Call { args, .. } => {
                    for arg in args {
                        check_operand(arg, global_types)
                            .map_err(|w| unsupported_value(&func.name, &w))?;
                    }
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
            }
        }
    }
    Ok(())
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
    // An enum value is a pointer to its inline tagged storage; a struct is a
    // pointer to its inline field storage; a string and a dynamic array are
    // pointers to their inline `{ptr,len}` storage. All are pointer-sized like
    // I64/U64/function pointers.
    matches!(
        ty,
        Type::I64
            | Type::U64
            | Type::Func(_, _)
            | Type::Enum(_)
            | Type::Struct(_)
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
            | Type::String
            | Type::Unit
            | Type::Func(_, _)
            | Type::DynArray(_)
            | Type::Enum(_)
            | Type::Struct(_)
    )
}

fn is_backend_local_type(ty: &Type) -> bool {
    *ty == Type::Unit || is_sized_backend_type(ty)
}

fn is_sized_backend_type(ty: &Type) -> bool {
    match ty {
        Type::F32 | Type::Var(_) | Type::Unit | Type::Never => false,
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
            | Type::Unit
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
            output: String::new(),

            stack_size: 0,
            var_offsets: HashMap::new(),
            var_types: HashMap::new(),
            global_types: HashMap::new(),
            address_vars: HashSet::new(),
            extern_names: HashSet::new(),
            runtime_print_names: HashSet::new(),
            needs_alloc_runtime: false,
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
            needs_arg_count_runtime: false,
            needs_arg_runtime: false,
            needs_read_file_runtime: false,
            needs_write_file_runtime: false,
            needs_file_exists_runtime: false,
            return_ty: Type::Unit,
            param_vars: HashSet::new(),
            current_fn: String::new(),
            interned_strings: HashMap::new(),
        }
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
        self.emits_alloc_runtime = false;

        self.generate_globals(&program.globals);
        self.runtime_print_names = Self::runtime_print_names(program);
        self.needs_alloc_runtime = Self::needs_alloc_runtime(program);
        self.needs_oob_runtime = Self::needs_oob_runtime(program);
        self.needs_div_runtime = Self::needs_div_runtime(program);
        self.needs_shift_runtime = Self::needs_shift_runtime(program);
        self.needs_string_eq_runtime = Self::needs_string_eq_runtime(program);
        self.needs_string_to_int_runtime = Self::needs_string_to_int_runtime(program);
        self.needs_int_to_string_runtime = Self::needs_int_to_string_runtime(program);
        self.needs_substring_runtime = Self::needs_substring_runtime(program);
        self.needs_string_concat_runtime = Self::needs_string_concat_runtime(program);
        self.needs_print_str_runtime = Self::needs_print_str_runtime(program);
        self.needs_arg_count_runtime = Self::needs_arg_count_runtime(program);
        self.needs_arg_runtime = Self::needs_arg_runtime(program);
        self.needs_read_file_runtime = Self::needs_read_file_runtime(program);
        self.needs_write_file_runtime = Self::needs_write_file_runtime(program);
        self.needs_file_exists_runtime = Self::needs_file_exists_runtime(program);
        self.needs_abort_runtime = Self::needs_abort_runtime(program)
            || self.needs_arg_runtime
            || self.needs_read_file_runtime
            || self.needs_write_file_runtime
            || self.needs_file_exists_runtime;
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
            || self.needs_file_exists_runtime;
        let needs_print_runtime = !self.runtime_print_names.is_empty();
        let needs_argv_data = self.needs_arg_count_runtime || self.needs_arg_runtime;
        if needs_print_runtime {
            self.generate_print_runtime_data();
        }
        if self.emits_alloc_runtime {
            self.generate_alloc_runtime_data();
            self.generate_alloc_failure_data();
        }
        if needs_argv_data {
            self.generate_argv_runtime_data();
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

        self.emit("    .text");
        self.emit("    .globl main");
        self.emit("    .globl _start");
        self.emit("");

        // Generate extern declarations
        for (name, _) in &program.externs {
            let symbol = self.call_symbol(name);
            // Runtime functions defined inline by the backend (the print
            // helpers and the bump allocator) must not also be declared
            // `.extern` — they are defined in this same translation unit.
            let defined_inline = Self::is_defined_print_runtime_symbol(&symbol)
                || (self.emits_alloc_runtime && symbol == "tl_alloc")
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
                || (self.needs_arg_count_runtime && symbol == ARG_COUNT_RUNTIME_SYMBOL)
                || (self.needs_arg_runtime && symbol == ARG_RUNTIME_SYMBOL)
                || (self.needs_read_file_runtime && symbol == READ_FILE_RUNTIME_SYMBOL)
                || (self.needs_write_file_runtime && symbol == WRITE_FILE_RUNTIME_SYMBOL)
                || (self.needs_file_exists_runtime && symbol == FILE_EXISTS_RUNTIME_SYMBOL);
            if !defined_inline {
                self.emit(&format!("    .extern {}", symbol));
            }
        }
        if needs_print_runtime {
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
        if self.needs_arg_count_runtime {
            self.generate_arg_count_runtime_functions();
        }
        if self.needs_arg_runtime {
            self.generate_arg_runtime_functions();
        }
        if self.needs_read_file_runtime {
            self.generate_read_file_runtime_functions();
        }
        if self.needs_write_file_runtime {
            self.generate_write_file_runtime_functions();
        }
        if self.needs_file_exists_runtime {
            self.generate_file_exists_runtime_functions();
        }

        // Generate functions
        for func in &program.functions {
            self.generate_function(func);
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

        self.emit("");
        self.emit("_start:");
        if needs_argv_data {
            self.emit("    movq (%rsp), %rax");
            self.emit("    movq %rax, .L_tl_argc(%rip)");
            self.emit("    leaq 8(%rsp), %rax");
            self.emit("    movq %rax, .L_tl_argv(%rip)");
        }
        // Initialize non-constant globals: call their __global_init_* function
        // and store the returned value (in %rax for integers, %xmm0 for f64).
        for (name, ty, init) in &program.globals {
            if init.is_some() {
                continue;
            }
            let init_fn = format!("__global_init_{}", name);
            if program.functions.iter().any(|f| f.name == init_fn) {
                self.emit(&format!("    call {}", Self::mangle_name(&init_fn)));
                let symbol = Self::mangle_name(name);
                match ty {
                    Type::F64 => {
                        self.emit(&format!("    movsd %xmm0, {}(%rip)", symbol));
                    }
                    Type::I64 | Type::U64 => {
                        self.emit(&format!("    movq %rax, {}(%rip)", symbol));
                    }
                    Type::I32 | Type::U32 => {
                        self.emit(&format!("    movl %eax, {}(%rip)", symbol));
                    }
                    Type::I16 | Type::U16 => {
                        self.emit(&format!("    movw %ax, {}(%rip)", symbol));
                    }
                    Type::I8 | Type::U8 | Type::Bool | Type::Char => {
                        self.emit(&format!("    movb %al, {}(%rip)", symbol));
                    }
                    Type::Unit => {}
                    _ => {}
                }
            }
        }
        self.emit("    call main");
        if main_ret == Type::Unit {
            self.emit("    xor %edi, %edi");
        } else {
            self.emit("    movq %rax, %rdi");
        }
        self.emit("    movq $60, %rax");
        self.emit("    syscall");

        self.output.clone()
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
    /// runtime (an `mmap`'d arena plus a bump pointer) into the program's `.s`
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
                        Instruction::Call { func, .. } if func == READ_FILE_RUNTIME_SYMBOL
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
                        Instruction::Call { func, .. } if func == WRITE_FILE_RUNTIME_SYMBOL
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
                        Instruction::Call { func, .. } if func == FILE_EXISTS_RUNTIME_SYMBOL
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

    /// Emit the `.bss` storage backing the bump allocator: the current bump
    /// pointer and the one-past-the-end pointer of the active `mmap` arena.
    /// Both start zeroed; a zero `tl_arena_ptr` signals "no arena yet" and
    /// triggers lazy `mmap` on the first allocation.
    fn generate_alloc_runtime_data(&mut self) {
        self.emit("    .section .bss");
        self.emit("    .balign 8");
        self.emit("tl_arena_ptr:");
        self.emit("    .zero 8");
        self.emit("tl_arena_end:");
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
            Instruction::Call { args, .. } | Instruction::CallIndirect { args, .. } => {
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
    /// bumps `tl_arena_ptr` within the active arena. When the arena is empty
    /// (lazy init) or exhausted it `mmap`s a fresh anonymous arena of
    /// `max(ARENA_SIZE, request)` bytes via the raw `mmap` syscall (no libc).
    /// There is no `free` and no GC: the arena lives for the whole process,
    /// matching the README's "minimal runtime".
    fn generate_alloc_runtime_functions(&mut self) {
        // Arena granule: 64 MiB. `mmap` syscall number is 9; PROT_READ|PROT_WRITE
        // = 3; MAP_PRIVATE|MAP_ANONYMOUS = 0x22; fd = -1; offset = 0. The 4th
        // syscall argument is passed in %r10 (not %rcx) per the syscall ABI.
        self.emit("    .globl tl_alloc");
        self.emit("tl_alloc:");
        // Round the requested size up to an 8-byte boundary: size = (size+7)&~7.
        self.emit("    addq $7, %rdi");
        self.emit("    jc .L_tl_alloc_abort"); // alignment-rounding overflow
        self.emit("    andq $-8, %rdi");
        // %rsi holds the (aligned) request size for the duration of the routine.
        self.emit("    movq %rdi, %rsi");
        // If no arena has been mapped yet (ptr == 0), go map one.
        self.emit("    movq tl_arena_ptr(%rip), %rax");
        self.emit("    testq %rax, %rax");
        self.emit("    jz .L_tl_alloc_new_arena");
        // Enough room left? new_ptr = ptr + size; if new_ptr <= end, bump.
        self.emit("    movq %rax, %rcx");
        self.emit("    addq %rsi, %rcx");
        self.emit("    jc .L_tl_alloc_abort"); // pointer overflow
        self.emit("    cmpq tl_arena_end(%rip), %rcx");
        self.emit("    ja .L_tl_alloc_new_arena");
        // Fast path: commit the bump and return the old pointer (already in %rax).
        self.emit("    movq %rcx, tl_arena_ptr(%rip)");
        self.emit("    ret");
        self.emit(".L_tl_alloc_new_arena:");
        // Choose arena length = max(ARENA_SIZE, aligned request). %rdx = len.
        self.emit("    movq $0x4000000, %rdx");
        self.emit("    cmpq %rdx, %rsi");
        self.emit("    jbe .L_tl_alloc_len_ready");
        self.emit("    movq %rsi, %rdx");
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
        self.emit("    movq %rcx, tl_arena_end(%rip)");
        self.emit("    movq %rax, %rcx");
        self.emit("    addq %rsi, %rcx");
        self.emit("    movq %rcx, tl_arena_ptr(%rip)");
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
        self.emit(&format!("{}:", ARG_RUNTIME_SYMBOL));
        self.emit("    push %rbp");
        self.emit("    mov %rsp, %rbp");
        self.emit("    push %rbx");
        self.emit("    push %r12");
        self.emit("    push %r13");
        self.emit("    sub $8, %rsp");
        self.emit("    movq %rdi, %rbx");
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
        self.emit("    movq %r12, %rdi");
        self.emit("    call tl_alloc");
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
        self.emit(".L_tl_arg_oob:");
        self.emit("    leaq .L_tl_arg_oob_msg(%rip), %rdi");
        self.emit("    movq $.L_tl_arg_oob_msg_len, %rsi");
        self.emit(&format!("    call {}", ABORT_RUNTIME_SYMBOL));
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
        // Digit generation (mirrors tl_print_i64). %rsi = descending write
        // cursor, starting one past the top of the scratch region; %rcx = digit
        // count. %rax holds the working magnitude.
        self.emit("    leaq 72(%rsp), %rsi");
        self.emit("    movq $0, %rcx");
        self.emit("    movq %rdi, %rax");
        self.emit("    cmpq $0, %rax");
        self.emit("    jne .L_tl_int_to_string_nonzero");
        // Zero: a single '0' digit.
        self.emit("    decq %rsi");
        self.emit("    movb $48, (%rsi)");
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
        self.emit("    decq %rsi");
        self.emit("    movb %dl, (%rsi)");
        self.emit("    incq %rcx");
        self.emit("    testq %rax, %rax");
        self.emit("    jne .L_tl_int_to_string_digit_loop");
        // Prepend the '-' sign for negatives.
        self.emit("    testq %r8, %r8");
        self.emit("    jz .L_tl_int_to_string_digits_done");
        self.emit("    decq %rsi");
        self.emit("    movb $45, (%rsi)");
        self.emit("    incq %rcx");
        self.emit(".L_tl_int_to_string_digits_done:");
        // %rbx = pointer to the first digit; %r12 = byte length. Both survive the
        // upcoming `tl_alloc` calls (callee-saved).
        self.emit("    movq %rsi, %rbx");
        self.emit("    movq %rcx, %r12");
        // data = tl_alloc(len). The returned heap pointer is saved in %r13.
        self.emit("    movq %r12, %rdi");
        self.emit("    call tl_alloc");
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
        self.emit("    movq $16, %rdi");
        self.emit("    call tl_alloc");
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
        self.emit("    movq %rdi, %rbx");
        self.emit("    addq %rsi, %rbx");
        self.emit("    movq %rdx, %r12");
        // data = tl_alloc(slice_len). The returned heap pointer is saved in %r13.
        self.emit("    movq %r12, %rdi");
        self.emit("    call tl_alloc");
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
        self.emit("    movq $16, %rdi");
        self.emit("    call tl_alloc");
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
        self.emit("    movq %rdi, %rbx");
        self.emit("    movq %rsi, %r12");
        self.emit("    movq %rdx, %r13");
        self.emit("    movq %rcx, %r14");
        // data = tl_alloc(a_len + b_len). The returned heap pointer is saved in
        // %r15.
        self.emit("    movq %r12, %rdi");
        self.emit("    addq %r14, %rdi");
        self.emit("    call tl_alloc");
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
        self.emit("    movq $16, %rdi");
        self.emit("    call tl_alloc");
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
                self.emit(&format!(
                    "    .comm {}, {}, {}",
                    symbol,
                    ty.size(),
                    ty.align().max(1)
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

    fn generate_function(&mut self, func: &Function) {
        let name = Self::mangle_name(&func.name);
        self.current_fn = name.clone();
        self.emit(&format!("{}:", name));

        // Eliminate SSA `Phi` nodes by inserting copies into the Phi's stack
        // slot at the end of each predecessor block. After this pass the IR
        // contains no `Phi` instructions and can be selected directly.
        let func = eliminate_phis(func);
        let func = &func;

        // Prologue
        self.emit("    push %rbp");
        self.emit("    mov %rsp, %rbp");

        // Calculate stack frame
        self.stack_size = 0;
        self.var_offsets.clear();
        self.var_types.clear();
        self.address_vars.clear();
        self.return_ty = func.ret.clone();
        self.param_vars = func.params.iter().map(|(v, _)| *v).collect();

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

        // Align stack to 16 bytes
        self.stack_size = (self.stack_size + 15) & !15;

        if self.stack_size > 0 {
            self.emit(&format!("    sub ${}, %rsp", self.stack_size));
        }

        // Move parameters to stack slots. Each argument register is written at
        // the width of its declared type, so a narrow parameter does not clobber
        // adjacent slots. The sub-register names differ per register
        // (`%rdi`->`%edi`/`%di`/`%dil`), so we look them up rather than string
        // -slicing the 64-bit name.
        let param_regs = ["%rdi", "%rsi", "%rdx", "%rcx", "%r8", "%r9"];
        let xmm_regs = [
            "%xmm0", "%xmm1", "%xmm2", "%xmm3", "%xmm4", "%xmm5", "%xmm6", "%xmm7",
        ];
        // System V AMD64: integer and floating-point arguments consume
        // *independent* register sequences, so we track two counters. Each
        // argument register is written at the width of its declared type so a
        // narrow parameter does not clobber adjacent slots.
        let mut int_param = 0;
        let mut float_param = 0;
        let mut stack_param = 0;
        for (var, ty) in &func.params {
            let offset = self.var_offsets[var];
            match ty {
                Type::I64
                | Type::U64
                | Type::Func(_, _)
                | Type::Enum(_)
                | Type::Struct(_)
                | Type::String
                | Type::DynArray(_) => {
                    if int_param < param_regs.len() {
                        self.emit(&format!(
                            "    movq {}, {}(%rbp)",
                            param_regs[int_param], offset
                        ));
                    } else {
                        self.store_incoming_stack_param(stack_param, offset, ty);
                        stack_param += 1;
                    }
                    int_param += 1;
                }
                Type::I32 | Type::U32 => {
                    if int_param < param_regs.len() {
                        self.emit(&format!(
                            "    movl {}, {}(%rbp)",
                            Self::gpr32(param_regs[int_param]),
                            offset
                        ));
                    } else {
                        self.store_incoming_stack_param(stack_param, offset, ty);
                        stack_param += 1;
                    }
                    int_param += 1;
                }
                Type::I16 | Type::U16 => {
                    if int_param < param_regs.len() {
                        self.emit(&format!(
                            "    movw {}, {}(%rbp)",
                            Self::gpr16(param_regs[int_param]),
                            offset
                        ));
                    } else {
                        self.store_incoming_stack_param(stack_param, offset, ty);
                        stack_param += 1;
                    }
                    int_param += 1;
                }
                Type::I8 | Type::U8 | Type::Bool | Type::Char => {
                    if int_param < param_regs.len() {
                        self.emit(&format!(
                            "    movb {}, {}(%rbp)",
                            Self::gpr8(param_regs[int_param]),
                            offset
                        ));
                    } else {
                        self.store_incoming_stack_param(stack_param, offset, ty);
                        stack_param += 1;
                    }
                    int_param += 1;
                }
                Type::F64 => {
                    if float_param < xmm_regs.len() {
                        self.emit(&format!(
                            "    movsd {}, {}(%rbp)",
                            xmm_regs[float_param], offset
                        ));
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
    }

    fn generate_instruction(&mut self, instr: &Instruction) {
        match instr {
            // Parameter slots are materialized by the prologue; their Alloc is a
            // no-op here. (Non-parameter Allocs are rejected by validation.)
            Instruction::Alloc { .. } => {}
            Instruction::Mov { dst, src, ty } => {
                let dst_offset = self.var_offsets[dst];
                if *ty == Type::F64 {
                    self.load_value(src, "%xmm0", ty);
                    self.store_xmm_value("%xmm0", dst_offset);
                    return;
                }

                match (src, ty) {
                    (Value::ConstI64(n), _) => {
                        self.store_integer_immediate(*n as i128, dst_offset, ty);
                    }
                    (Value::ConstI32(n), _) => {
                        self.store_integer_immediate(*n as i128, dst_offset, ty);
                    }
                    (Value::ConstI8(n), _) => {
                        self.store_integer_immediate(*n as i128, dst_offset, ty);
                    }
                    (Value::ConstBool(b), _) => {
                        let n = if *b { 1 } else { 0 };
                        self.store_integer_immediate(n, dst_offset, ty);
                    }
                    (Value::ConstF64(n), _) => {
                        // Load float from constant pool (simplified)
                        self.emit(&format!("    movabsq ${:#x}, %rax", n.to_bits()));
                        self.emit(&format!("    movq %rax, {}(%rbp)", dst_offset));
                    }
                    (Value::Var(_) | Value::Global(_) | Value::ConstStr(_), _) => {
                        self.load_value(src, "%rax", ty);
                        self.store_gpr_value("%rax", dst_offset, ty);
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
                let dst_offset = self.var_offsets[dst];
                self.load_value(src, "%rax", from_ty);
                match to_ty.size() {
                    8 => self.emit(&format!("    movq %rax, {}(%rbp)", dst_offset)),
                    4 => self.emit(&format!("    movl %eax, {}(%rbp)", dst_offset)),
                    2 => self.emit(&format!("    movw %ax, {}(%rbp)", dst_offset)),
                    1 => self.emit(&format!("    movb %al, {}(%rbp)", dst_offset)),
                    _ => {}
                }
            }
            Instruction::BinOp {
                dst,
                op,
                lhs,
                rhs,
                ty,
            } => {
                let dst_offset = self.var_offsets[dst];
                let operand_ty = self.binop_operand_ty(op, lhs, rhs, ty);
                let result_ty = self
                    .var_types
                    .get(dst)
                    .cloned()
                    .unwrap_or_else(|| ty.clone());
                if operand_ty == Type::F64 {
                    self.generate_float_binop(dst_offset, op, lhs, rhs, &result_ty);
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

                self.store_gpr_value("%rax", dst_offset, &result_ty);
            }
            Instruction::UnOp { dst, op, src, ty } => {
                let dst_offset = self.var_offsets[dst];
                if *ty == Type::F64 {
                    self.load_value(src, "%xmm0", ty);
                    match op {
                        IrUnOp::Neg => {
                            self.emit("    pxor %xmm1, %xmm1");
                            self.emit("    subsd %xmm0, %xmm1");
                            self.emit("    movapd %xmm1, %xmm0");
                        }
                        // Logical/bitwise complement are not defined on f64 and
                        // are rejected by validation/typechecking before codegen.
                        IrUnOp::Not | IrUnOp::BitNot => {}
                    }
                    self.store_xmm_value("%xmm0", dst_offset);
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

                self.store_gpr_value("%rax", dst_offset, ty);
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
                let stack_arg_space = self.load_call_args(args);
                let func_ty = self
                    .value_type(func)
                    .unwrap_or_else(|| Type::Func(Vec::new(), Box::new(Type::Unit)));
                self.load_value(func, "%rax", &func_ty);
                self.emit("    call *%rax");
                self.release_call_args(stack_arg_space);
                self.store_call_result(dst, ty);
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
                let dst_offset = self.var_offsets[&dst_var];
                if *ty == Type::F64 {
                    self.load_value(src, "%xmm0", ty);
                    self.store_xmm_value("%xmm0", dst_offset);
                    return;
                }

                match src {
                    Value::Var(_) | Value::Global(_) | Value::ConstStr(_) => {
                        // Round-trip through a register sized to the value.
                        self.load_value(src, "%rax", ty);
                        self.store_gpr_value("%rax", dst_offset, ty);
                    }
                    Value::ConstI64(n) => {
                        self.store_integer_immediate(*n as i128, dst_offset, ty);
                    }
                    Value::ConstI32(n) => {
                        self.store_integer_immediate(*n as i128, dst_offset, ty);
                    }
                    Value::ConstI8(n) => {
                        self.store_integer_immediate(*n as i128, dst_offset, ty);
                    }
                    Value::ConstBool(b) => {
                        let n = if *b { 1 } else { 0 };
                        self.store_integer_immediate(n, dst_offset, ty);
                    }
                    _ => {}
                }
            }
            // Read a local's stack slot into the destination's slot, or
            // dereference a pointer-valued local produced by AddrOf/Gep.
            Instruction::Load { dst, src, ty } => {
                let dst_offset = self.var_offsets[dst];
                if let Value::Var(src_var) = src
                    && self.is_pointer_deref_var(*src_var, ty)
                {
                    self.load_value_through_pointer(*src_var, dst_offset, ty);
                    return;
                }
                if *ty == Type::F64 {
                    self.load_value(src, "%xmm0", ty);
                    self.store_xmm_value("%xmm0", dst_offset);
                    return;
                }

                match ty.size() {
                    8 => {
                        self.load_value(src, "%rax", ty);
                        self.emit(&format!("    movq %rax, {}(%rbp)", dst_offset));
                    }
                    4 => {
                        self.load_value(src, "%rax", ty);
                        self.emit(&format!("    movl %eax, {}(%rbp)", dst_offset));
                    }
                    2 => {
                        self.load_value(src, "%rax", ty);
                        self.emit(&format!("    movw %ax, {}(%rbp)", dst_offset));
                    }
                    1 => {
                        self.load_value(src, "%rax", ty);
                        self.emit(&format!("    movb %al, {}(%rbp)", dst_offset));
                    }
                    _ => {}
                }
            }
            Instruction::AddrOf { dst, src } => {
                let src_offset = self.var_offsets[src];
                let dst_offset = self.var_offsets[dst];
                let dst_ty = self.var_types.get(dst).cloned().unwrap_or(Type::U64);
                self.emit(&format!("    leaq {}(%rbp), %rax", src_offset));
                self.store_gpr_value("%rax", dst_offset, &dst_ty);
            }
            Instruction::Gep {
                dst,
                base,
                offset,
                elem_ty,
            } => {
                let dst_offset = self.var_offsets[dst];
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
                self.store_gpr_value("%rax", dst_offset, &dst_ty);
            }
            // Phi nodes are lowered to predecessor moves by `eliminate_phis`
            // before instruction selection. If one reaches this point, there is
            // no standalone assembly instruction to emit for it.
            Instruction::Phi { .. } => {}
            Instruction::Return(val) => {
                if let Some(v) = val {
                    let ret_ty = self.return_ty.clone();
                    if ret_ty == Type::F64 {
                        self.load_value(v, "%xmm0", &ret_ty);
                    } else {
                        self.load_value(v, "%rax", &ret_ty);
                    }
                }
                // Epilogue
                self.emit("    mov %rbp, %rsp");
                self.emit("    pop %rbp");
                self.emit("    ret");
            }
        }
    }

    fn store_incoming_stack_param(&mut self, stack_param: i32, local_offset: i32, ty: &Type) {
        let caller_offset = 16 + stack_param * 8;
        if *ty == Type::F64 {
            self.emit(&format!("    movsd {}(%rbp), %xmm15", caller_offset));
            self.emit(&format!("    movsd %xmm15, {}(%rbp)", local_offset));
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

    fn load_call_args(&mut self, args: &[Value]) -> i32 {
        let param_regs = ["%rdi", "%rsi", "%rdx", "%rcx", "%r8", "%r9"];
        let xmm_regs = [
            "%xmm0", "%xmm1", "%xmm2", "%xmm3", "%xmm4", "%xmm5", "%xmm6", "%xmm7",
        ];
        let mut int_arg = 0;
        let mut float_arg = 0;
        let mut stack_args = Vec::new();
        for arg in args {
            let arg_ty = self.value_type(arg).unwrap_or(Type::I64);
            if arg_ty == Type::F64 {
                if float_arg < xmm_regs.len() {
                    self.load_value(arg, xmm_regs[float_arg], &Type::F64);
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

        let stack_arg_space = ((stack_args.len() as i32 * 8) + 15) & !15;
        if stack_arg_space > 0 {
            self.emit(&format!("    sub ${}, %rsp", stack_arg_space));
            for (idx, (arg, ty)) in stack_args.iter().enumerate() {
                self.store_stack_call_arg(idx as i32, arg, ty);
            }
        }
        stack_arg_space
    }

    fn store_stack_call_arg(&mut self, stack_arg: i32, arg: &Value, ty: &Type) {
        let offset = stack_arg * 8;
        if *ty == Type::F64 {
            self.load_value(arg, "%xmm15", ty);
            self.emit(&format!("    movsd %xmm15, {}(%rsp)", offset));
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
            let dst_offset = self.var_offsets[dst_var];
            if *ty == Type::F64 {
                self.store_xmm_value("%xmm0", dst_offset);
            } else {
                self.store_gpr_value("%rax", dst_offset, ty);
            }
        }
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

    fn load_value_through_pointer(&mut self, ptr_var: VarId, dst_offset: i32, ty: &Type) {
        self.load_pointer_value(ptr_var, "%r10");
        if *ty == Type::F64 {
            self.emit("    movsd (%r10), %xmm0");
            self.store_xmm_value("%xmm0", dst_offset);
            return;
        }

        // Load the dereferenced value into the full 64-bit register, extending
        // narrower types so the stored stack slot is well-defined (signed types
        // sign-extend, unsigned/bool/char zero-extend — e.g. a `char` byte is
        // loaded with `movzbq`). The full register is then spilled width-first.
        self.load_memory_value("(%r10)", "%rax", ty);
        match ty.size() {
            8 => self.emit(&format!("    movq %rax, {}(%rbp)", dst_offset)),
            4 => self.emit(&format!("    movl %eax, {}(%rbp)", dst_offset)),
            2 => self.emit(&format!("    movw %ax, {}(%rbp)", dst_offset)),
            1 => self.emit(&format!("    movb %al, {}(%rbp)", dst_offset)),
            _ => {}
        }
    }

    fn store_value_through_pointer(&mut self, ptr_var: VarId, src: &Value, ty: &Type) {
        self.load_pointer_value(ptr_var, "%r10");
        if *ty == Type::F64 {
            self.load_value(src, "%xmm0", ty);
            self.emit("    movsd %xmm0, (%r10)");
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

    fn load_value(&mut self, val: &Value, reg: &str, ty: &Type) {
        if *ty == Type::F64 {
            self.load_float_value(val, reg);
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
            Value::Var(v) => {
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

    fn load_float_value(&mut self, val: &Value, reg: &str) {
        match val {
            Value::ConstF64(n) => {
                self.emit(&format!("    movabsq ${:#x}, %rax", n.to_bits()));
                self.emit(&format!("    movq %rax, {}", reg));
            }
            Value::Var(v) => {
                let offset = self.var_offsets[v];
                self.emit(&format!("    movsd {}(%rbp), {}", offset, reg));
            }
            Value::Global(name) => {
                self.emit(&format!(
                    "    movsd {}(%rip), {}",
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
        if *ty == Type::F64 {
            self.load_value(src, "%xmm0", ty);
            self.emit(&format!("    movsd %xmm0, {}", addr));
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
            8 => self.emit(&format!("    movq ${}, {}(%rbp)", value, offset)),
            4 => self.emit(&format!("    movl ${}, {}(%rbp)", value, offset)),
            2 => self.emit(&format!("    movw ${}, {}(%rbp)", value, offset)),
            1 => self.emit(&format!("    movb ${}, {}(%rbp)", value, offset)),
            _ => {}
        }
    }

    fn store_integer_immediate_to_addr(&mut self, value: i128, addr: &str, ty: &Type) {
        match ty.size() {
            8 => self.emit(&format!("    movq ${}, {}", value, addr)),
            4 => self.emit(&format!("    movl ${}, {}", value, addr)),
            2 => self.emit(&format!("    movw ${}, {}", value, addr)),
            1 => self.emit(&format!("    movb ${}, {}", value, addr)),
            _ => {}
        }
    }

    fn store_xmm_value(&mut self, reg: &str, offset: i32) {
        self.emit(&format!("    movsd {}, {}(%rbp)", reg, offset));
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
        dst_offset: i32,
        op: &IrBinOp,
        lhs: &Value,
        rhs: &Value,
        result_ty: &Type,
    ) {
        self.load_value(lhs, "%xmm0", &Type::F64);
        self.load_value(rhs, "%xmm1", &Type::F64);

        match op {
            IrBinOp::Add => self.emit("    addsd %xmm1, %xmm0"),
            IrBinOp::Sub => self.emit("    subsd %xmm1, %xmm0"),
            IrBinOp::Mul => self.emit("    mulsd %xmm1, %xmm0"),
            IrBinOp::Div => self.emit("    divsd %xmm1, %xmm0"),
            IrBinOp::Eq | IrBinOp::Ne | IrBinOp::Lt | IrBinOp::Le | IrBinOp::Gt | IrBinOp::Ge => {
                self.emit("    ucomisd %xmm1, %xmm0");
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
                self.store_gpr_value("%rax", dst_offset, result_ty);
                return;
            }
            // Integer-only operators (modulo, logical and bitwise/shift) are
            // not defined on f64 and are rejected by validation before codegen.
            IrBinOp::Mod
            | IrBinOp::And
            | IrBinOp::Or
            | IrBinOp::BitAnd
            | IrBinOp::BitOr
            | IrBinOp::BitXor
            | IrBinOp::Shl
            | IrBinOp::Shr => {}
        }

        self.store_xmm_value("%xmm0", dst_offset);
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
pub fn generate_assembly(program: &Program) -> Result<String, String> {
    validate_program(program)?;
    let mut backend = X86_64Backend::new();
    Ok(backend.generate(program))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ast;
    use crate::ir::*;
    use crate::lower::lower_program;
    use crate::optimizer::Optimizer;
    use crate::parser::parse;

    /// Compile source through the full pipeline (parse -> lower -> optimize ->
    /// codegen), returning generated assembly text.
    fn compile_ok(source: &str) -> String {
        let prog = parse(source).expect("parse failed");
        let mut ir = lower_program(&prog);
        Optimizer::optimize(&mut ir);
        generate_assembly(&ir).expect("backend should accept this program")
    }

    /// Compile source expecting the backend to reject it.
    fn compile_err(source: &str) -> String {
        let prog = parse(source).expect("parse failed");
        let mut ir = lower_program(&prog);
        Optimizer::optimize(&mut ir);
        generate_assembly(&ir).expect_err("backend should reject this program")
    }

    #[test]
    fn test_reject_f32_parameter_type_before_codegen() {
        let err = compile_err("(define (bad [x : f32]) : i64 0)");
        assert!(
            err.contains("parameter %0 has type f32"),
            "unexpected error: {}",
            err
        );
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
    fn test_reject_f32_local_type_before_codegen() {
        let err = generate_assembly(&Program {
            functions: vec![Function {
                name: "main".into(),
                params: vec![],
                ret: Type::I64,
                locals: vec![(0, Type::F32)],
                blocks: vec![BasicBlock {
                    label: "entry".into(),
                    instructions: vec![Instruction::Return(Some(Value::ConstI64(0)))],
                }],
                entry: "entry".into(),
            }],
            globals: vec![],
            externs: vec![],
        })
        .expect_err("backend should reject unsupported local slot types");
        assert!(
            err.contains("local %0 has type f32"),
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
                "foreign_f32".into(),
                Type::Func(vec![Type::F32], Box::new(Type::I64)),
            )],
        })
        .expect_err("backend should reject unsupported extern ABI types");
        assert!(
            err.contains("extern 'foreign_f32' has unsupported argument type f32"),
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
            (define (main) : i32 small)
            "#,
        );
        assert!(asm.contains("_tl_small:"), "asm:\n{}", asm);
        assert!(asm.contains("    .long 7"), "asm:\n{}", asm);
        assert!(asm.contains("_tl_mid:"), "asm:\n{}", asm);
        assert!(asm.contains("    .word 513"), "asm:\n{}", asm);
        assert!(asm.contains("_tl_byte:"), "asm:\n{}", asm);
        assert!(asm.contains("    .byte -1"), "asm:\n{}", asm);
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
        assert!(asm.contains("    movq -16(%rbp), %rdi"), "asm:\n{}", asm);
        assert!(asm.contains("    movq -8(%rbp), %rax"), "asm:\n{}", asm);
        assert!(asm.contains("    call *%rax"), "asm:\n{}", asm);
        assert!(!asm.contains("    call _tl_f"), "asm:\n{}", asm);
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
        assert!(asm.contains("    movq -16(%rbp), %rdi"), "asm:\n{}", asm);
        assert!(asm.contains("    movq -8(%rbp), %rax"), "asm:\n{}", asm);
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
        assert!(asm.contains("    movq %rax, -16(%rbp)"), "asm:\n{}", asm);
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
        assert!(asm.contains("    movq -8(%rbp), %rax"), "asm:\n{}", asm);
        assert!(asm.contains("    movq $3, %rcx"), "asm:\n{}", asm);
        assert!(asm.contains("    imulq $8, %rcx"), "asm:\n{}", asm);
        assert!(asm.contains("    addq %rcx, %rax"), "asm:\n{}", asm);
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
        assert!(asm.contains("    movq -16(%rbp), %r10"), "asm:\n{}", asm);
        assert!(asm.contains("    movq $99, %rax"), "asm:\n{}", asm);
        assert!(asm.contains("    movq %rax, (%r10)"), "asm:\n{}", asm);
        assert!(asm.contains("    movq (%r10), %rax"), "asm:\n{}", asm);
        assert!(asm.contains("    movq %rax, -24(%rbp)"), "asm:\n{}", asm);
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
        assert!(asm.contains("movb $7, -1(%rbp)"), "asm:\n{}", asm);
        assert!(
            !asm.contains("movq $7, -1(%rbp)"),
            "i8 immediate mov must not use 64-bit store; asm:\n{}",
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
        assert!(asm.contains("movw $300, -2(%rbp)"), "asm:\n{}", asm);
        assert!(
            !asm.contains("movq $300, -2(%rbp)"),
            "i16 immediate store must not use 64-bit store; asm:\n{}",
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

        // Arena state lives in `.bss` as two 8-byte pointer slots.
        assert!(asm.contains("    .section .bss"), "asm:\n{}", asm);
        assert!(asm.contains("tl_arena_ptr:"), "asm:\n{}", asm);
        assert!(asm.contains("tl_arena_end:"), "asm:\n{}", asm);

        // The request is rounded up to 8 bytes before bumping.
        assert!(asm.contains("    addq $7, %rdi"), "asm:\n{}", asm);
        assert!(asm.contains("    andq $-8, %rdi"), "asm:\n{}", asm);

        // The bump pointer is read from / written back to the arena slot.
        assert!(
            asm.contains("movq tl_arena_ptr(%rip), %rax"),
            "asm:\n{}",
            asm
        );
        assert!(
            asm.contains("movq %rcx, tl_arena_ptr(%rip)"),
            "asm:\n{}",
            asm
        );

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
        assert!(!asm.contains("tl_arena_ptr:"), "asm:\n{}", asm);
        assert!(!asm.contains("    .section .bss"), "asm:\n{}", asm);
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
        assert!(!asm.contains("tl_arena_ptr:"), "asm:\n{}", asm);
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

        // There should be exactly three carry-check jumps to the abort label:
        // request rounding, active-arena bump pointer, and fresh-arena end.
        let jc_count = asm.matches("    jc .L_tl_alloc_abort").count();
        assert_eq!(
            jc_count, 3,
            "expected three carry guards (rounding + bump/end overflow), got {}\nasm:\n{}",
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
