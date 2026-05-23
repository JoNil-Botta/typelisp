//! Cross-platform proof that the immutable scoped String -> i64 symbol table
//! (`tests/integration/sym_i64_env.tl`) compiles to valid x86_64 assembly.
//!
//! This is the first concrete child of #42 (hash maps / symbol tables for
//! self-hosting): a functional `SymI64Env` with head-first lookup, shadowing,
//! and key equality via `string-eq`. It exercises `defenum`, recursive
//! `match`, `string-eq`, `substring`, and `string-append` in a single
//! self-contained TypeLisp module.

use std::fs;
use std::path::PathBuf;
use std::process::Command;

#[test]
fn sym_i64_env_tl_compiles_to_assembly() {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let source_path = manifest_dir
        .join("tests")
        .join("integration")
        .join("sym_i64_env.tl");

    let work_dir = manifest_dir.join("target").join("sym-i64-env-compile-test");
    fs::create_dir_all(&work_dir).expect("create sym_i64_env compile test work dir");
    let asm_path = work_dir.join("sym_i64_env.s");

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
        "sym_i64_env.tl compile step failed\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr,
    );

    let asm = fs::read_to_string(&asm_path).expect("read generated sym_i64_env assembly");

    // No stubbed-out / unimplemented constructs.
    assert!(
        !asm.contains("# TODO"),
        "sym_i64_env assembly still contains a # TODO marker:\n{}",
        asm,
    );

    // Real program entry point.
    assert!(
        asm.contains("main:"),
        "sym_i64_env assembly has no main:\n{}",
        asm
    );

    // The enum constructors heap-alloc through the runtime.
    assert!(
        asm.contains("call tl_alloc"),
        "sym_i64_env assembly does not allocate enum nodes via tl_alloc:\n{}",
        asm,
    );

    // String equality for key matching: the emit-on-demand `tl_string_eq` runtime.
    assert!(
        asm.contains("tl_string_eq:"),
        "sym_i64_env assembly is missing the tl_string_eq runtime helper (key lookup):\n{}",
        asm,
    );
    assert!(
        asm.contains("call tl_string_eq"),
        "sym_i64_env assembly shows no string-eq call (key lookup not wired):\n{}",
        asm,
    );

    // Substring-built key: the `tl_substring` runtime helper.
    assert!(
        asm.contains("tl_substring:"),
        "sym_i64_env assembly is missing the tl_substring runtime helper (substring key):\n{}",
        asm,
    );
    assert!(
        asm.contains("call tl_substring"),
        "sym_i64_env assembly shows no substring call (substring key not wired):\n{}",
        asm,
    );

    // String-append-built key: the `tl_string_concat` runtime helper.
    assert!(
        asm.contains("tl_string_concat:"),
        "sym_i64_env assembly is missing the tl_string_concat runtime helper (append key):\n{}",
        asm,
    );
    assert!(
        asm.contains("call tl_string_concat"),
        "sym_i64_env assembly shows no string-append call (append key not wired):\n{}",
        asm,
    );

    // Panic/abort path for test failures.
    assert!(
        asm.contains("call .L_tl_abort"),
        "sym_i64_env assembly is missing the panic abort path (.L_tl_abort):\n{}",
        asm,
    );

    // The API functions are emitted.
    for sym in [
        "_tl_sym_i64_empty:",
        "_tl_sym_i64_bind:",
        "_tl_sym_i64_lookup:",
        "_tl_sym_i64_contains:",
    ] {
        assert!(
            asm.contains(sym),
            "sym_i64_env assembly is missing expected API symbol {}:\n{}",
            sym,
            asm,
        );
    }

    // The `sym-i64-lookup` helper is recursive (walks the bind chain).
    assert!(
        asm.matches("call _tl_sym_i64_lookup").count() >= 2,
        "sym_i64_env assembly shows no recursive sym-i64-lookup self-call (bind-chain walk):\n{}",
        asm,
    );
}
