use std::fs;
use std::path::PathBuf;
use std::process::Command;

fn compile_source(work_name: &str, file_name: &str, source: &str) -> std::process::Output {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let work_dir = manifest_dir.join("target").join(work_name);
    fs::create_dir_all(&work_dir).expect("create backend diagnostics work dir");
    let source_path = work_dir.join(file_name);
    fs::write(&source_path, source).expect("write backend diagnostics source");

    Command::new(env!("CARGO_BIN_EXE_typelisp"))
        .arg("compile")
        .arg(&source_path)
        .output()
        .expect("run typelisp compile")
}

#[test]
fn fixed_array_return_backend_rejection_renders_source_diagnostic() {
    // Scalar `f32` is now codegen'd, so this exercises the backend
    // source-diagnostic pipeline against a return type that REMAINS
    // unsupported (a by-value fixed array).
    let output = compile_source(
        "backend-diagnostics-array",
        "array_return.tl",
        "(define (main) : (Array i64 3)\n  (array 1 2 3))",
    );

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        !output.status.success(),
        "compile unexpectedly succeeded\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr
    );
    assert_eq!(stdout, "", "failed compile should not write stdout");
    assert!(
        stderr.contains(
            "error[E0300]: backend: function 'main' uses an unsupported construct (return type (Array i64 3))"
        ),
        "stderr did not keep backend validation detail:\n{}",
        stderr
    );
    assert!(
        stderr.contains("array_return.tl:2:"),
        "diagnostic should point at source line 2:\n{}",
        stderr
    );
    assert!(
        stderr.contains(" 2 |   (array 1 2 3)"),
        "diagnostic should include the offending source line:\n{}",
        stderr
    );
    assert!(
        stderr.contains("^"),
        "diagnostic should include a caret:\n{}",
        stderr
    );
}

#[test]
fn aggregate_backend_rejection_renders_source_diagnostic() {
    let output = compile_source(
        "backend-diagnostics-tuple",
        "tuple_return.tl",
        "(define (make_pair [a : i64] [b : bool]) : (Tuple i64 bool)\n  (tuple a b))",
    );

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        !output.status.success(),
        "compile unexpectedly succeeded\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr
    );
    assert_eq!(stdout, "", "failed compile should not write stdout");
    assert!(
        stderr.contains("return type (Tuple i64 bool)"),
        "stderr did not keep aggregate backend detail:\n{}",
        stderr
    );
    assert!(
        stderr.contains("tuple_return.tl:2:"),
        "diagnostic should point at tuple expression line:\n{}",
        stderr
    );
    assert!(
        stderr.contains(" 2 |   (tuple a b)"),
        "diagnostic should include the tuple expression:\n{}",
        stderr
    );
    assert!(
        stderr.contains("^"),
        "diagnostic should include a caret:\n{}",
        stderr
    );
}
