//! Cross-platform proof that the monomorphic Maybe/Result convention witness
//! (`tests/integration/maybe_result.tl`) compiles to valid x86_64 assembly.
//!
//! refs #228: before TypeLisp has generics or `?`-style propagation, recoverable
//! outcomes are ordinary monomorphic enums handled with exhaustive `match`.

use std::fs;
use std::path::PathBuf;
use std::process::Command;

#[test]
fn maybe_result_tl_compiles_to_assembly() {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let source_path = manifest_dir
        .join("tests")
        .join("integration")
        .join("maybe_result.tl");

    let work_dir = manifest_dir
        .join("target")
        .join("maybe-result-compile-test");
    fs::create_dir_all(&work_dir).expect("create maybe_result compile test work dir");
    let asm_path = work_dir.join("maybe_result.s");

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
        "maybe_result.tl compile step failed\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr,
    );

    let asm = fs::read_to_string(&asm_path).expect("read generated maybe_result assembly");

    assert!(
        !asm.contains("# TODO"),
        "maybe_result assembly still contains a # TODO marker:\n{}",
        asm,
    );

    for sym in [
        "main:",
        "_tl_find_answer:",
        "_tl_read_small:",
        "_tl_maybe_score:",
        "_tl_result_score:",
    ] {
        assert!(
            asm.contains(sym),
            "maybe_result assembly is missing expected symbol {}:\n{}",
            sym,
            asm,
        );
    }

    assert!(
        asm.contains("call tl_alloc"),
        "returned enum values should allocate heap nodes through tl_alloc:\n{}",
        asm,
    );
    assert!(
        asm.contains("tl_string_eq:") && asm.contains("call tl_string_eq"),
        "Maybe/Result producers should compare String inputs with tl_string_eq:\n{}",
        asm,
    );
    assert!(
        asm.contains("tl_string_concat:") && asm.contains("call tl_string_concat"),
        "ErrI64 payload construction should use tl_string_concat:\n{}",
        asm,
    );
}
