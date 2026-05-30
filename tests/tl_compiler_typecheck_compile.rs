use std::fs;
use std::path::PathBuf;
use std::process::Command;

fn compile_selfhost_source(source_file: &str, work_name: &str, asm_file: &str) -> String {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let source_path = manifest_dir.join("selfhost").join(source_file);
    let work_dir = manifest_dir.join("target").join(work_name);
    fs::create_dir_all(&work_dir).expect("create compiler typecheck compile test work dir");
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

    fs::read_to_string(&asm_path).expect("read generated compiler typecheck assembly")
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
fn compiler_typecheck_tl_compiles_to_assembly() {
    let asm = compile_selfhost_source(
        "compiler_typecheck.tl",
        "tl-compiler-typecheck-compile-test",
        "compiler_typecheck.s",
    );

    assert_no_todo(&asm, "compiler_typecheck");

    for sym in [
        "_tl_tc_type_eq:",
        "_tl_tc_type_without_regions:",
        "_tl_tc_tag_active_region:",
        "_tl_tc_ensure_region_value_can_flow_into:",
        "_tl_tc_resolve_type:",
        "_tl_tc_bind_enum_variants:",
        "_tl_tc_expr:",
        "_tl_tc_struct_field_type:",
        "_tl_tc_bind_variant_pattern:",
        "_tl_tc_match_expr:",
        "_tl_tc_spmd_expr:",
        "_tl_tc_result_info:",
        "_tl_tc_try_expr:",
        "_tl_tc_check_decl:",
        "_tl_typecheck_compiler_program:",
        "_tl_typecheck_compiler_source:",
        "_tl_compiler_typecheck_self_test:",
        "_tl_compiler_typecheck_foreach_control_flow_tests_ok_question:",
        "_tl_compiler_typecheck_foreach_spmd_tests_ok_question:",
        "_tl_compiler_typecheck_region_tests_ok_question:",
        "_tl_compiler_typecheck_result_try_tests_ok_question:",
        "_tl_compiler_typecheck_resource_with_tests_ok_question:",
        "_tl_tc_resource_bindings:",
        "_tl_build_compiler_symbols:",
        "_tl_parse_ast_source:",
    ] {
        assert_symbol(&asm, sym, "compiler_typecheck");
    }

    for message in [
        "typecheck: unbound name ",
        "typecheck: arity mismatch",
        "typecheck: argument type mismatch",
        "typecheck: if condition must be bool",
        "typecheck: if branches must match",
        "typecheck: assignment type mismatch",
        "typecheck: return type mismatch",
        "typecheck: tuple index out of bounds",
        "typecheck: array elements must have same type",
        "typecheck: string index must be integer",
        "typecheck: cast requires integer/char source and target",
        "typecheck: foreach body must be unit",
        "typecheck: foreach if condition must be uniform",
        "typecheck: foreach while condition must be uniform",
        "typecheck: foreach calls with varying arguments are not supported",
        "typecheck: foreach cannot set binding declared outside foreach",
        "typecheck: foreach varying array lane type is not supported: ",
        "typecheck: lambda return type mismatch",
        "typecheck: region-tagged value cannot escape with-arena 'r'",
        "typecheck: region-tagged value cannot escape with-arena 'inner'",
        "typecheck: cannot pass region-tagged value to function parameter; region value would escape",
        "typecheck: str is a borrowed string-slice referent; use (& lifetime str)",
        "typecheck: mutable references to str are reserved; use immutable (& lifetime str)",
        "typecheck: match arms must agree",
        "typecheck: unknown variant ",
        "typecheck: unknown struct field ",
        "typecheck: non-exhaustive match",
        "typecheck: try operand must be Result-like enum",
        "typecheck: try requires enclosing Result-like function",
        "typecheck: try error type mismatch",
        "typecheck: with cleanup function type mismatch",
        "typecheck: with cleanup must be a direct function name",
        "typecheck: ordinary let cannot own cleanup-required resource; use with",
        "typecheck: cleanup-required resource would escape with scope",
        "typecheck: cannot store cleanup-required resource in ordinary aggregate",
        "typecheck: lambda cannot capture cleanup-required resource; resource value would escape",
        "typecheck: cleanup-required resource already has a cleanup owner",
        "typecheck: cannot store cleanup-required resource in longer-lived binding",
        "typecheck: smoke score mismatch",
        "(extern print-i64 : (-> i64 unit))",
        "[fixed : (Array i64 3) (array 1 2 3)]",
        "(read-stdin-bytes 3)",
        "(flush-stdout)",
        "(defenum Maybe (None) (Some i64))",
        "(defstruct Point (x i64) (y i64))",
        "(with-arena r",
        "(with ([a 1 close]",
        "(defstruct Box (s String))",
        "(try (read flag))",
    ] {
        assert_message(&asm, message, "compiler_typecheck");
    }
}

#[test]
fn compiler_specialize_tl_compiles_to_assembly() {
    let asm = compile_selfhost_source(
        "compiler_specialize.tl",
        "tl-compiler-specialize-compile-test",
        "compiler_specialize.s",
    );

    assert_no_todo(&asm, "compiler_specialize");

    for sym in [
        "_tl_compiler_specialize_program:",
        "_tl_compiler_specialize_needed_question:",
        "_tl_compiler_specialize_self_test:",
        "_tl_spec_rewrite_specialized_call:",
        "_tl_spec_ensure_specialization:",
        "_tl_spec_substitute_types_expr:",
        "_tl_spec_substitute_values_expr:",
    ] {
        assert_symbol(&asm, sym, "compiler_specialize");
    }

    for message in [
        "[comptime T : type]",
        "(type i64)",
        "__tl_specialized_alloc_type_i64_none",
        "cannot be used as a runtime value",
    ] {
        assert_message(&asm, message, "compiler_specialize");
    }
}

#[test]
fn compiler_typecheck_smoke_tl_compiles_to_assembly() {
    let asm = compile_selfhost_source(
        "compiler_typecheck_smoke.tl",
        "tl-compiler-typecheck-smoke-compile-test",
        "compiler_typecheck_smoke.s",
    );

    assert_no_todo(&asm, "compiler_typecheck_smoke");
    assert_eq!(
        asm.matches("\nmain:").count() + usize::from(asm.starts_with("main:")),
        1,
        "compiler_typecheck_smoke assembly must have exactly one main:\n{asm}",
    );

    for sym in [
        "_tl_compiler_typecheck_self_test:",
        "_tl_compiler_typecheck_aggregate_tests_ok_question:",
        "_tl_compiler_typecheck_nominal_tests_ok_question:",
        "_tl_compiler_typecheck_region_tests_ok_question:",
        "_tl_typecheck_compiler_source:",
        "_tl_compiler_typecheck_error_ok_question:",
        // Located-diagnostic self-test (#681): a type error carries the
        // offending declaration body's AST span.
        "_tl_compiler_typecheck_located_ok_question:",
    ] {
        assert_symbol(&asm, sym, "compiler_typecheck_smoke");
    }
}

#[test]
fn compiler_check_core_tl_compiles_to_assembly() {
    let asm = compile_selfhost_source(
        "compiler_check_core.tl",
        "tl-compiler-check-core-compile-test",
        "compiler_check_core.s",
    );

    assert_no_todo(&asm, "compiler_check_core");

    for sym in [
        "_tl_compiler_check_file:",
        "_tl_compiler_check_source:",
        "_tl_compiler_check_program:",
        "_tl_compiler_check_self_test:",
        "_tl_compiler_load_source:",
    ] {
        assert_symbol(&asm, sym, "compiler_check_core");
    }

    for message in [
        "selfhost/virtual_entry.tl",
        "docs/examples/bad_type.tl",
        "typecheck: return type mismatch",
        "compiler-check: virtual import smoke mismatch",
        "compiler-check: virtual diagnostic smoke mismatch",
        "compiler-check: seen root smoke mismatch",
    ] {
        assert_message(&asm, message, "compiler_check_core");
    }
}

#[test]
fn compiler_check_smoke_tl_compiles_to_assembly() {
    let asm = compile_selfhost_source(
        "compiler_check_smoke.tl",
        "tl-compiler-check-smoke-compile-test",
        "compiler_check_smoke.s",
    );

    assert_no_todo(&asm, "compiler_check_smoke");
    assert_eq!(
        asm.matches("\nmain:").count() + usize::from(asm.starts_with("main:")),
        1,
        "compiler_check_smoke assembly must have exactly one main:\n{asm}",
    );
    assert_symbol(
        &asm,
        "_tl_compiler_check_self_test:",
        "compiler_check_smoke",
    );
}

#[test]
fn selfhost_check_tl_compiles_to_assembly() {
    let asm = compile_selfhost_source(
        "check.tl",
        "tl-selfhost-check-compile-test",
        "selfhost_check.s",
    );

    assert_no_todo(&asm, "selfhost_check");
    assert_eq!(
        asm.matches("\nmain:").count() + usize::from(asm.starts_with("main:")),
        1,
        "selfhost_check assembly must have exactly one main:\n{asm}",
    );

    for sym in [
        "_tl_selfhost_check_config_from:",
        "_tl_selfhost_check_run_from:",
        "_tl_selfhost_check_parse_options:",
        "_tl_selfhost_check_file:",
        "_tl_compiler_check_file_with_roots:",
        "_tl_compiler_load_file_with_path",
        "_tl_compiler_load_source:",
        "_tl_typecheck_compiler_specialized_program_with_paths:",
    ] {
        assert_symbol(&asm, sym, "selfhost_check");
    }

    for message in [
        "selfhost-check: expected input path",
        "selfhost-check: --stdlib-root requires a value",
        "selfhost-check: unknown flag ",
        "selfhost-check: unexpected argument ",
        "compiler-load: cannot read import ",
        "typecheck: return type mismatch",
    ] {
        assert_message(&asm, message, "selfhost_check");
    }
}
