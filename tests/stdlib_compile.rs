use std::fs;
use std::path::PathBuf;
use std::process::Command;

#[test]
fn stdlib_test_tl_compiles_to_assembly() {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let source_path = manifest_dir.join("stdlib").join("test.tl");

    let work_dir = manifest_dir.join("target").join("stdlib-test-compile-test");
    fs::create_dir_all(&work_dir).expect("create stdlib test compile work dir");
    let asm_path = work_dir.join("test.s");

    let output = Command::new(env!("CARGO_BIN_EXE_typelisp"))
        .arg("compile")
        .arg(&source_path)
        .arg("--stdlib-root")
        .arg(manifest_dir.join("stdlib"))
        .arg("-o")
        .arg(&asm_path)
        .output()
        .expect("run typelisp compile");

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        output.status.success(),
        "stdlib/test.tl compile step failed\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr,
    );

    let asm = fs::read_to_string(&asm_path).expect("read generated stdlib test assembly");

    assert!(
        !asm.contains("# TODO"),
        "stdlib/test assembly still contains a # TODO marker:\n{}",
        asm,
    );

    for sym in [
        "_tl_assert_true:",
        "_tl_assert_false:",
        "_tl_assert_bool_eq:",
        "_tl_assert_i64_eq:",
        "_tl_assert_char_eq:",
        "_tl_assert_string_eq:",
        "tl_abort:",
        "tl_string_eq:",
    ] {
        assert!(
            asm.contains(sym),
            "stdlib/test assembly is missing expected symbol {}:\n{}",
            sym,
            asm,
        );
    }
}
