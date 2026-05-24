//! Cross-platform proof that the selfhost compiler IR/lowering slice compiles.

use std::fs;
use std::path::PathBuf;
use std::process::Command;

fn compile_selfhost_source(source_file: &str, work_name: &str, asm_file: &str) -> String {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let source_path = manifest_dir.join("selfhost").join(source_file);
    let work_dir = manifest_dir.join("target").join(work_name);
    fs::create_dir_all(&work_dir).expect("create compiler lower compile test work dir");
    let asm_path = work_dir.join(asm_file);

    let output = Command::new(env!("CARGO_BIN_EXE_typelisp"))
        .arg("compile")
        .arg(&source_path)
        .arg("-o")
        .arg(&asm_path)
        .output()
        .expect("run typelisp compile");

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        output.status.success(),
        "{} compile step failed\nstdout:\n{}\nstderr:\n{}",
        source_file,
        stdout,
        stderr,
    );

    fs::read_to_string(&asm_path).expect("read generated compiler lower assembly")
}

fn assert_no_todo(asm: &str, name: &str) {
    assert!(
        !asm.contains("# TODO"),
        "{name} assembly still contains a # TODO marker:\n{asm}",
    );
}

fn assert_symbol(asm: &str, sym: &str, name: &str) {
    assert!(
        asm.contains(sym),
        "{name} assembly is missing expected symbol {sym}:\n{asm}",
    );
}

fn assert_message(asm: &str, message: &str, name: &str) {
    assert!(
        asm.contains(message),
        "{name} assembly is missing message {message:?}:\n{asm}",
    );
}

#[test]
fn compiler_ir_types_tl_compiles_to_assembly() {
    let asm = compile_selfhost_source(
        "compiler_ir_types.tl",
        "tl-compiler-ir-types-compile-test",
        "compiler_ir_types.s",
    );

    assert_no_todo(&asm, "compiler_ir_types");

    for sym in [
        "_tl_compiler_ir_summary_globals:",
        "_tl_compiler_ir_summary_functions:",
        "_tl_compiler_ir_summary_externs:",
        "_tl_compiler_ir_summary_blocks:",
        "_tl_compiler_ir_summary_instructions:",
        "_tl_compiler_ir_summary_vars:",
        "_tl_compiler_ir_summary_score:",
        "_tl_compiler_ir_program_summary:",
        "_tl_compiler_ir_function_list_block_count:",
        "_tl_compiler_ir_function_list_instruction_count:",
        "_tl_compiler_ir_function_list_var_count:",
    ] {
        assert_symbol(&asm, sym, "compiler_ir_types");
    }
}

#[test]
fn compiler_lower_tl_compiles_to_assembly() {
    let asm = compile_selfhost_source(
        "compiler_lower.tl",
        "tl-compiler-lower-compile-test",
        "compiler_lower.s",
    );

    assert_no_todo(&asm, "compiler_lower");

    for sym in [
        "_tl_lower_compiler_source:",
        "_tl_lower_compiler_program:",
        "_tl_lower_function:",
        "_tl_lower_expr:",
        "_tl_lower_call:",
        "_tl_lower_stdio_builtin_question:",
        "_tl_lower_stdio_runtime_name:",
        "_tl_lower_construct_enum_with_handle:",
        "_tl_lower_construct_struct:",
        "_tl_lower_struct_get:",
        "_tl_lower_string_ref:",
        "_tl_lower_substring:",
        "_tl_lower_string_concat:",
        // Dynamic-array element access (#528).
        "_tl_lower_array_ref:",
        "_tl_lower_array_set:",
        "_tl_lower_array_element_addr:",
        "_tl_lower_string_fields:",
        "_tl_lower_oob_abort:",
        "_tl_lower_load_at_offset:",
        "_tl_lower_bind_variant_payloads:",
        "_tl_lower_match_enum:",
        "_tl_lower_match_enum_arms:",
        "_tl_lower_match_variant_final:",
        "_tl_lower_match_variant_arm:",
        "_tl_lower_args:",
        "_tl_lower_args_as:",
        "_tl_lower_let_bindings:",
        "_tl_lower_begin:",
        "_tl_lower_if:",
        "_tl_lower_if_merge:",
        "_tl_lower_while:",
        "_tl_lower_state_finish_block:",
        "_tl_lower_compiler_program_checked:",
        "_tl_compiler_lower_self_test:",
        // Scalar-match phi-shape self-test assertion (#602).
        "_tl_compiler_lower_match_phi_shape_ok_question:",
        // Enum-match payload-load and phi-shape self-test assertion (#517).
        "_tl_compiler_lower_enum_match_shape_ok_question:",
        "_tl_compiler_ir_program_summary:",
        "_tl_typecheck_compiler_program:",
        "_tl_parse_ast_source:",
    ] {
        assert_symbol(&asm, sym, "compiler_lower");
    }

    for message in [
        "lower: unsupported expression",
        "lower: only direct calls are supported",
        "lower: assignment to unknown local ",
        "lower: smoke score mismatch",
        "(while (< x 45)",
        "(extern print-i64 : (-> i64 unit))",
        ".L_tl_read_stdin_line",
        ".L_tl_read_stdin_bytes",
        ".L_tl_stdin_eof",
        ".L_tl_flush_stdout",
        "tl_substring",
        "tl_string_concat",
        "tl_oob_abort",
        "char-at \\\" x\\\"",
        "(defstruct Point (x i64) (y i64))",
        "(struct-get p y)",
        "(defenum Maybe (None) (Some i64) (Pair i64 i64))",
        "[(Pair left _) left]",
        "lower: unsupported enum payload pattern",
    ] {
        assert_message(&asm, message, "compiler_lower");
    }
}

#[test]
fn compiler_liveness_tl_compiles_to_assembly() {
    let asm = compile_selfhost_source(
        "compiler_liveness.tl",
        "tl-compiler-liveness-compile-test",
        "compiler_liveness.s",
    );

    assert_no_todo(&asm, "compiler_liveness");

    for sym in [
        "_tl_compiler_live_analyze_function:",
        "_tl_compiler_live_block_use_def:",
        "_tl_compiler_live_block_successors:",
        "_tl_compiler_live_instr_uses:",
        "_tl_compiler_live_instr_defs:",
        "_tl_compiler_live_memory_use_def_ok_question:",
        "_tl_compiler_live_after:",
        "_tl_compiler_live_self_test:",
    ] {
        assert_symbol(&asm, sym, "compiler_liveness");
    }

    assert_message(&asm, "liveness: smoke mismatch", "compiler_liveness");
}

#[test]
fn compiler_lower_smoke_tl_compiles_to_assembly() {
    let asm = compile_selfhost_source(
        "compiler_lower_smoke.tl",
        "tl-compiler-lower-smoke-compile-test",
        "compiler_lower_smoke.s",
    );

    assert_no_todo(&asm, "compiler_lower_smoke");
    assert_eq!(
        asm.matches("\nmain:").count() + usize::from(asm.starts_with("main:")),
        1,
        "compiler_lower_smoke assembly must have exactly one main:\n{asm}",
    );

    for sym in [
        "_tl_compiler_lower_self_test:",
        "_tl_compiler_lower_ok_summary_question:",
        "_tl_lower_compiler_source:",
        "_tl_compiler_ir_summary_score:",
    ] {
        assert_symbol(&asm, sym, "compiler_lower_smoke");
    }
}

#[test]
fn compiler_liveness_smoke_tl_compiles_to_assembly() {
    let asm = compile_selfhost_source(
        "compiler_liveness_smoke.tl",
        "tl-compiler-liveness-smoke-compile-test",
        "compiler_liveness_smoke.s",
    );

    assert_no_todo(&asm, "compiler_liveness_smoke");
    assert_eq!(
        asm.matches("\nmain:").count() + usize::from(asm.starts_with("main:")),
        1,
        "compiler_liveness_smoke assembly must have exactly one main:\n{asm}",
    );

    for sym in [
        "_tl_compiler_live_self_test:",
        "_tl_compiler_live_analyze_function:",
        "_tl_compiler_live_straight_ok_question:",
        "_tl_compiler_live_branch_ok_question:",
        "_tl_compiler_live_phi_ok_question:",
    ] {
        assert_symbol(&asm, sym, "compiler_liveness_smoke");
    }
}

#[test]
fn compiler_regalloc_tl_compiles_to_assembly() {
    let asm = compile_selfhost_source(
        "compiler_regalloc.tl",
        "tl-compiler-regalloc-compile-test",
        "compiler_regalloc.s",
    );

    assert_no_todo(&asm, "compiler_regalloc");

    for sym in [
        "_tl_compiler_reg_plan_function:",
        "_tl_compiler_reg_live_intervals:",
        "_tl_compiler_reg_ineligible_vars:",
        "_tl_compiler_reg_assign_candidates:",
        "_tl_compiler_reg_spill_at_interval:",
        "_tl_compiler_regalloc_self_test:",
    ] {
        assert_symbol(&asm, sym, "compiler_regalloc");
    }

    for message in ["regalloc: smoke mismatch", "%r12", "%r15"] {
        assert_message(&asm, message, "compiler_regalloc");
    }
}

#[test]
fn compiler_regalloc_smoke_tl_compiles_to_assembly() {
    let asm = compile_selfhost_source(
        "compiler_regalloc_smoke.tl",
        "tl-compiler-regalloc-smoke-compile-test",
        "compiler_regalloc_smoke.s",
    );

    assert_no_todo(&asm, "compiler_regalloc_smoke");
    assert_eq!(
        asm.matches("\nmain:").count() + usize::from(asm.starts_with("main:")),
        1,
        "compiler_regalloc_smoke assembly must have exactly one main:\n{asm}",
    );

    for sym in [
        "_tl_compiler_regalloc_self_test:",
        "_tl_compiler_reg_plan_function:",
        "_tl_compiler_reg_reuse_ok_question:",
        "_tl_compiler_reg_overlap_spill_ok_question:",
        "_tl_compiler_reg_call_live_ok_question:",
    ] {
        assert_symbol(&asm, sym, "compiler_regalloc_smoke");
    }
}
