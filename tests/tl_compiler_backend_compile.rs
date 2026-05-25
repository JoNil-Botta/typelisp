//! Cross-platform proof that the selfhost compiler backend emitter slice compiles.

use std::fs;
use std::path::PathBuf;
use std::process::Command;

fn compile_selfhost_source(source_file: &str, work_name: &str, asm_file: &str) -> String {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let source_path = manifest_dir.join("selfhost").join(source_file);
    let work_dir = manifest_dir.join("target").join(work_name);
    fs::create_dir_all(&work_dir).expect("create compiler backend compile test work dir");
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

    fs::read_to_string(&asm_path).expect("read generated compiler backend assembly")
}

fn run_selfhost_source_expect_42(source_file: &str) {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let source_path = manifest_dir.join("selfhost").join(source_file);
    let output = Command::new(env!("CARGO_BIN_EXE_typelisp"))
        .arg("run")
        .arg(&source_path)
        .arg("--target")
        .arg("windows-x86_64")
        .output()
        .expect("run typelisp selfhost smoke");

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert_eq!(
        output.status.code(),
        Some(42),
        "{} run step exited unexpectedly\nstdout:\n{}\nstderr:\n{}",
        source_file,
        stdout,
        stderr,
    );
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
fn compiler_backend_tl_compiles_to_assembly() {
    let asm = compile_selfhost_source(
        "compiler_backend.tl",
        "tl-compiler-backend-compile-test",
        "compiler_backend.s",
    );

    assert_no_todo(&asm, "compiler_backend");

    for sym in [
        "_tl_compiler_backend_emit_source:",
        "_tl_compiler_backend_emit_source_for_target:",
        "_tl_compiler_backend_emit_program:",
        "_tl_compiler_backend_emit_program_for_target:",
        "_tl_compiler_backend_emit_program_target:",
        "_tl_compiler_backend_emit_program_linux:",
        "_tl_compiler_backend_emit_function:",
        "_tl_compiler_backend_emit_instr:",
        "_tl_compiler_backend_emit_bounds_check:",
        "_tl_compiler_backend_emit_phi_edge_copies:",
        "_tl_compiler_backend_emit_call_args:",
        "_tl_compiler_backend_call_arg_space:",
        "_tl_compiler_backend_emit_call_space_sub:",
        "_tl_compiler_backend_target_arg_reg:",
        "_tl_compiler_backend_target_float_arg_reg:",
        "_tl_compiler_backend_float_arg_reg:",
        "_tl_compiler_backend_outgoing_shadow_space:",
        "_tl_compiler_backend_target_entry_text:",
        "_tl_compiler_backend_emit_param_spills:",
        "_tl_compiler_backend_emit_load_var_with_plan:",
        "_tl_compiler_backend_emit_store_var_with_plan:",
        "_tl_compiler_backend_emit_load_f64_value_with_plan:",
        "_tl_compiler_backend_emit_load_f64_var_with_plan:",
        "_tl_compiler_backend_emit_store_f64_var_with_plan:",
        "_tl_compiler_backend_emit_f64_rodata:",
        "_tl_compiler_backend_emit_save_callee_regs:",
        "_tl_compiler_backend_drop_param_assignments:",
        "_tl_compiler_backend_user_symbol:",
        "_tl_compiler_backend_call_symbol:",
        "_tl_compiler_backend_runtime_plan:",
        "_tl_compiler_backend_runtime_functions:",
        "_tl_compiler_backend_runtime_functions_for_target:",
        "_tl_compiler_backend_runtime_region_mark_functions:",
        "_tl_compiler_backend_runtime_region_reset_functions:",
        "_tl_compiler_backend_runtime_windows_alloc_functions:",
        "_tl_compiler_backend_runtime_windows_read_stdin_line_functions:",
        "_tl_compiler_backend_runtime_read_stdin_line_functions:",
        "_tl_compiler_backend_runtime_read_stdin_bytes_functions:",
        "_tl_compiler_backend_runtime_stdin_eof_functions:",
        "_tl_compiler_backend_runtime_process_output_data:",
        "_tl_compiler_backend_runtime_process_output_functions:",
        "_tl_compiler_backend_runtime_windows_process_output_functions:",
        "_tl_compiler_backend_runtime_flush_stdout_functions:",
        "_tl_compiler_backend_runtime_helper_program:",
        "_tl_compiler_backend_self_test:",
        "_tl_compiler_backend_target_model_ok_question:",
        "_tl_compiler_backend_target_windows_abi_ok_question:",
        "_tl_compiler_backend_target_windows_callee_save_ok_question:",
        "_tl_compiler_backend_target_windows_runtime_ok_question:",
        "_tl_compiler_backend_deterministic_ok_question:",
        "_tl_compiler_backend_string_ok_question:",
        "_tl_compiler_backend_aggregate_ok_question:",
        "_tl_compiler_backend_enum_match_ok_question:",
        "_tl_compiler_backend_memory_op_ok_question:",
        "_tl_compiler_backend_make_array_ok_question:",
        "_tl_compiler_backend_region_ok_question:",
        "_tl_compiler_backend_process_output_ok_question:",
        "_tl_compiler_backend_windows_process_output_ok_question:",
        "_tl_compiler_backend_regalloc_ok_question:",
        "_tl_compiler_backend_f64_ok_question:",
        "_tl_compiler_backend_f64_binop_asm:",
        "_tl_compiler_backend_f64_type_question:",
        "_tl_compiler_backend_unsigned_rel_ty_question:",
        "_tl_compiler_backend_emit_string_rodata:",
        "_tl_compiler_backend_emit_store_ptr:",
        "_tl_lower_compiler_source:",
        "_tl_text_buf_append:",
        "_tl_text_buf_render:",
    ] {
        assert_symbol(&asm, sym, "compiler_backend");
    }

    for message in [
        "backend: too many call args",
        "backend: too many params",
        "backend: unsupported global initializer",
        "backend: smoke output mismatch",
        ".L_tl_str_data_6869:",
        ".L_tl_str_6869:",
        "_tl_greeting:\\n    .quad .L_tl_str_6869\\n",
        ".globl _start\\n",
        "_start:\\n    call main\\n",
        "    call _tl_inc\\n",
        "    call tl_alloc\\n",
        "    call tl_region_mark\\n",
        "    call tl_region_reset\\n",
        ".globl tl_region_mark\\n",
        ".globl tl_region_reset\\n",
        ".L_tl_region_reset_msg:",
        "    call _tl_tl_alloc\\n",
        "    call _tl_Point\\n",
        "(defenum Maybe (None) (Some i64))",
        ".L_tl_score_match_arm.",
        "(defstruct Point (x i64) (y i64))",
        ".globl tl_string_concat\\n",
        ".L_tl_read_stdin_line:\\n",
        ".L_tl_read_stdin_bytes:\\n",
        ".L_tl_stdin_eof:\\n",
        ".L_tl_flush_stdout:\\n",
        "tl_process_output:\\n",
        ".L_tl_process_read_all:\\n",
        ".L_tl_process_exec_marker:",
        ".L_tl_envp:",
        "process: spawn failed",
        "process: runtime execution is not supported on this target",
        ".L_tl_stdin_eof_flag:\\n",
        "tl: stdin failed",
        ".extern malloc\\n",
        "    call malloc\\n",
        "    call _read\\n",
        "    call fflush\\n",
        "(make-array i64 2)",
        "(with-region r",
        "make_array_len_ok",
        "    jne .Lmain_while_body.1\\n",
        "    jmp .Lmain_while_header.0\\n",
        "    setl %al\\n",
        "    setb %al\\n",
        "    setbe %al\\n",
        "    setg %al\\n",
        "backend: f64 values are not supported yet",
        "backend: unsupported f64 binary op",
        ".L_tl_f64_",
        "    .double 1.5\\n",
        "    movsd %xmm0, ",
        "    movsd %xmm1, ",
        "    addsd %xmm1, %xmm0\\n",
        "    ucomisd %xmm1, %xmm0\\n",
        "    xorpd %xmm1, %xmm0\\n",
    ] {
        assert_message(&asm, message, "compiler_backend");
    }
    assert!(
        !asm.contains("backend: Windows runtime helpers not yet implemented (#648)"),
        "compiler_backend should no longer carry the old Windows runtime rejection:\n{asm}",
    );
}

#[test]
fn compiler_bounds_check_smoke_runs() {
    run_selfhost_source_expect_42("compiler_bounds_check_smoke.tl");
}

#[test]
fn compiler_backend_smoke_tl_compiles_to_assembly() {
    let asm = compile_selfhost_source(
        "compiler_backend_smoke.tl",
        "tl-compiler-backend-smoke-compile-test",
        "compiler_backend_smoke.s",
    );

    assert_no_todo(&asm, "compiler_backend_smoke");
    assert_eq!(
        asm.matches("\nmain:").count() + usize::from(asm.starts_with("main:")),
        1,
        "compiler_backend_smoke assembly must have exactly one main:\n{asm}",
    );

    for sym in [
        "_tl_compiler_backend_self_test:",
        "_tl_compiler_backend_emit_source:",
        "_tl_compiler_backend_asm_ok_question:",
        "_tl_lower_compiler_source:",
    ] {
        assert_symbol(&asm, sym, "compiler_backend_smoke");
    }
}

#[test]
fn compiler_backend_runtime_fixture_tl_compiles_to_assembly() {
    let asm = compile_selfhost_source(
        "compiler_backend_runtime_fixture.tl",
        "tl-compiler-backend-runtime-fixture-compile-test",
        "compiler_backend_runtime_fixture.s",
    );

    assert_no_todo(&asm, "compiler_backend_runtime_fixture");
    for sym in [
        "_tl_compiler_backend_runtime_fixture_emit:",
        "_tl_compiler_backend_runtime_helper_program:",
        "_tl_compiler_backend_runtime_helper_asm_ok_question:",
        "_tl_compiler_backend_emit_program:",
    ] {
        assert_symbol(&asm, sym, "compiler_backend_runtime_fixture");
    }
}

#[test]
fn compiler_driver_tl_compiles_to_assembly() {
    let asm = compile_selfhost_source(
        "compiler_driver.tl",
        "tl-compiler-driver-compile-test",
        "compiler_driver.s",
    );

    assert_no_todo(&asm, "compiler_driver");
    assert_eq!(
        asm.matches("\nmain:").count() + usize::from(asm.starts_with("main:")),
        1,
        "compiler_driver assembly must have exactly one main:\n{asm}",
    );

    for sym in [
        "_tl_compiler_driver_compile_file:",
        "_tl_compiler_driver_emit_file:",
        "_tl_compiler_diagnostic_render:",
        "_tl_compiler_load_file:",
        "_tl_compiler_load_resolve_import:",
        "_tl_compiler_backend_emit_source:",
        "_tl_lower_compiler_source:",
        "_tl_parse_ast_source_diagnostic:",
        "_tl_parse_ast_source:",
        // The driver runs the optimizer between lowering and backend emission.
        "_tl_optimize_program:",
        "_tl_optimize_program_with_level:",
    ] {
        assert_symbol(&asm, sym, "compiler_driver");
    }

    for message in [
        "compiler-driver: expected input and output paths",
        "compiler-load: cannot read import ",
        "lower: unsupported expression",
    ] {
        assert_message(&asm, message, "compiler_driver");
    }
}

#[test]
fn compiler_optimize_tl_compiles_to_assembly() {
    let asm = compile_selfhost_source(
        "compiler_optimize.tl",
        "tl-compiler-optimize-compile-test",
        "compiler_optimize.s",
    );

    assert_no_todo(&asm, "compiler_optimize");
    for sym in [
        "_tl_optimize_program:",
        "_tl_optimize_program_with_level:",
        "_tl_optimize_function:",
        "_tl_optimize_function_with_level:",
        "_tl_compiler_optimize_default_level:",
        "_tl_compiler_optimize_parse_level:",
        "_tl_opt_fold_instrs:",
        "_tl_opt_fold_binop:",
        "_tl_opt_const_lookup:",
        "_tl_compiler_optimize_self_test:",
        "_tl_compiler_optimize_typed_fold_self_test:",
        "_tl_compiler_optimize_level_self_test:",
        // Strength reduction / algebraic identities (#924).
        "_tl_opt_strength_instrs:",
        "_tl_opt_strength_binop:",
        "_tl_compiler_optimize_strength_self_test:",
        // Dead-code elimination pass (#544).
        "_tl_opt_collect_instrs_uses:",
        "_tl_opt_dce_instrs:",
        "_tl_compiler_optimize_dce_self_test:",
        // Common subexpression elimination pass (#546).
        "_tl_opt_cse_instrs:",
        "_tl_opt_expr_invalidate_var:",
        "_tl_compiler_optimize_cse_self_test:",
        // Copy propagation pass (#545).
        "_tl_opt_copy_instrs:",
        "_tl_opt_copy_invalidate_var:",
        "_tl_compiler_optimize_copy_self_test:",
        // Redundant bounds-check elimination pass (#930).
        "_tl_opt_bounds_instrs:",
        "_tl_compiler_optimize_bounds_self_test:",
        // Fixed-point optimizer iteration (#923).
        "_tl_optimize_function_once:",
        "_tl_optimize_function_fixed:",
        "_tl_compiler_optimize_fixed_point_self_test:",
    ] {
        assert_symbol(&asm, sym, "compiler_optimize");
    }
}

#[test]
fn compiler_optimize_smoke_tl_compiles_to_assembly() {
    let asm = compile_selfhost_source(
        "compiler_optimize_smoke.tl",
        "tl-compiler-optimize-smoke-compile-test",
        "compiler_optimize_smoke.s",
    );

    assert_no_todo(&asm, "compiler_optimize_smoke");
    assert_eq!(
        asm.matches("\nmain:").count() + usize::from(asm.starts_with("main:")),
        1,
        "compiler_optimize_smoke assembly must have exactly one main:\n{asm}",
    );
    assert_symbol(
        &asm,
        "_tl_compiler_optimize_self_test:",
        "compiler_optimize_smoke",
    );
    assert_symbol(
        &asm,
        "_tl_compiler_optimize_level_self_test:",
        "compiler_optimize_smoke",
    );
    assert_symbol(
        &asm,
        "_tl_compiler_optimize_bounds_self_test:",
        "compiler_optimize_smoke",
    );
}

#[test]
fn compile_tl_compiles_to_assembly() {
    let asm = compile_selfhost_source("compile.tl", "tl-compile-cli-compile-test", "compile_cli.s");

    assert_no_todo(&asm, "compile");
    assert_eq!(
        asm.matches("\nmain:").count() + usize::from(asm.starts_with("main:")),
        1,
        "compile assembly must have exactly one main:\n{asm}",
    );

    for sym in [
        "_tl_compile_cli_config:",
        "_tl_compile_cli_parse_options:",
        "_tl_compile_cli_target:",
        "_tl_compile_cli_default_output:",
        "_tl_compile_cli_invalid_opt_level:",
        "_tl_compile_cli_root_list_append:",
        "_tl_compiler_driver_compile_file:",
        "_tl_compiler_driver_compile_file_with_roots:",
        "_tl_compiler_driver_compile_file_with_roots_and_level:",
        "_tl_compiler_driver_compile_file_for_target:",
        "_tl_compiler_driver_compile_file_for_target_with_roots:",
        "_tl_compiler_driver_compile_file_for_target_with_roots_and_level:",
        "_tl_compiler_driver_emit_file_for_target:",
        "_tl_compiler_driver_emit_file_with_target_and_roots:",
        "_tl_compiler_driver_emit_file_with_target_roots_and_level:",
        "_tl_compiler_backend_emit_program_with_spans_for_target:",
        "_tl_compiler_load_file:",
        "_tl_compiler_load_file_with_path",
    ] {
        assert_symbol(&asm, sym, "compile");
    }

    for message in [
        "compile: expected source path",
        "compile: -o requires a value",
        "compile: -o was provided more than once",
        "compile: --target requires a value",
        "compile: --target was provided more than once",
        "compile: --stdlib-root requires a value",
        "compile: --opt-level requires a value",
        "compile: --opt-level was provided more than once",
        "compile: invalid --opt-level ",
        "; expected 0, 1, 2, or 3",
        "Error: unknown target '",
        "'. Expected linux-x86_64 or windows-x86_64",
        "--emit-ir",
        " is not supported by the selfhost compile driver yet; use Rust typelisp compile",
        "compile: unknown flag ",
        "compile: unexpected argument ",
    ] {
        assert_message(&asm, message, "compile");
    }
}

#[test]
fn build_and_run_planners_compile_to_assembly() {
    let build_asm = compile_selfhost_source(
        "build.tl",
        "tl-build-planner-compile-test",
        "build_planner.s",
    );
    assert_no_todo(&build_asm, "build planner");
    for sym in [
        "_tl_build_plan_config:",
        "_tl_build_plan_parse_options:",
        "_tl_build_plan_render:",
        "_tl_host_plan_netline:",
        "_tl_host_plan_target_valid_question:",
    ] {
        assert_symbol(&build_asm, sym, "build planner");
    }
    for message in [
        "typelisp-host-plan v1\\n",
        "action",
        "build-source",
        "build: expected source path",
        "build: --manifest-path is handled by Rust typelisp build",
    ] {
        assert_message(&build_asm, message, "build planner");
    }

    let run_asm = compile_selfhost_source("run.tl", "tl-run-planner-compile-test", "run_planner.s");
    assert_no_todo(&run_asm, "run planner");
    for sym in [
        "_tl_run_plan_config:",
        "_tl_run_plan_parse_options:",
        "_tl_run_plan_runtime_args:",
        "_tl_run_plan_render:",
        "_tl_host_plan_netline:",
    ] {
        assert_symbol(&run_asm, sym, "run planner");
    }
    for message in [
        "typelisp-host-plan v1\\n",
        "action",
        "run-source",
        "run: expected source path",
        "run: --target requires a value",
    ] {
        assert_message(&run_asm, message, "run planner");
    }

    let test_asm =
        compile_selfhost_source("test.tl", "tl-test-planner-compile-test", "test_planner.s");
    assert_no_todo(&test_asm, "test planner");
    for sym in [
        "_tl_tltest_config:",
        "_tl_tltest_parse_options:",
        "_tl_tltest_run_plan:",
        "_tl_tltest_invalid_opt_level:",
        "_tl_optimize_program_with_level:",
        "_tl_compiler_backend_emit_program_with_spans_for_target:",
        "_tl_host_plan_netline:",
    ] {
        assert_symbol(&test_asm, sym, "test planner");
    }
    for message in [
        "typelisp-host-plan v1\\n",
        "action",
        "run-scratch-assembly",
        "test: expected source path",
        "test: --opt-level requires a value",
        "test: --opt-level was provided more than once",
        "test: invalid --opt-level ",
        "; expected 0, 1, 2, or 3",
    ] {
        assert_message(&test_asm, message, "test planner");
    }
}
