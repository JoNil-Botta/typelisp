#![cfg(target_os = "linux")]

use std::fs;
use std::path::Path;
use std::process::Command;

fn selfhost_compile_opt2(manifest_dir: &Path, work_dir: &Path, name: &str, source: &str) -> String {
    fs::create_dir_all(work_dir).expect("create aggregate optimizer test work dir");
    let source_path = work_dir.join(format!("{name}.tl"));
    let asm_path = work_dir.join(format!("{name}.s"));
    fs::write(&source_path, source).expect("write aggregate optimizer fixture");

    let output = Command::new(env!("CARGO_BIN_EXE_typelisp"))
        .current_dir(manifest_dir)
        .arg("run")
        .arg("selfhost/compile.tl")
        .arg("--stdlib-root")
        .arg(manifest_dir.join("stdlib"))
        .arg("--")
        .arg("compile")
        .arg(&source_path)
        .arg("-o")
        .arg(&asm_path)
        .arg("--opt-level")
        .arg("2")
        .arg("--stdlib-root")
        .arg(manifest_dir.join("stdlib"))
        .output()
        .expect("run selfhost compile.tl aggregate optimizer fixture");

    assert_eq!(
        output.status.code(),
        Some(0),
        "selfhost aggregate fixture {name} failed\nstdout:\n{}\nstderr:\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );

    fs::read_to_string(&asm_path).expect("read aggregate optimizer fixture assembly")
}

#[test]
fn selfhost_optimizer_stack_promotes_local_aggregates() {
    let manifest_dir = Path::new(env!("CARGO_MANIFEST_DIR"));
    let work_dir = manifest_dir
        .join("target")
        .join("integration-tests")
        .join("selfhost_optimizer_aggregate");

    let local = selfhost_compile_opt2(
        manifest_dir,
        &work_dir,
        "local_struct",
        r#"(defstruct Point (x i64) (y i64))
(define (main) : i64
  (let
    [p : Point (Point 40 2)]
    (+ (struct-get p x) (struct-get p y))))"#,
    );
    assert!(
        !local.contains("    call tl_alloc\n"),
        "local non-escaping struct should be stack-promoted:\n{local}"
    );

    let returned = selfhost_compile_opt2(
        manifest_dir,
        &work_dir,
        "returned_struct",
        r#"(defstruct Point (x i64) (y i64))
(define (mk-point) : Point
  (Point 40 2))
(define (main) : i64
  (struct-get (mk-point) y))"#,
    );
    assert!(
        returned.contains("    call tl_alloc\n"),
        "returned aggregate must remain heap allocated:\n{returned}"
    );

    let passed = selfhost_compile_opt2(
        manifest_dir,
        &work_dir,
        "passed_struct",
        r#"(defstruct Point (x i64) (y i64))
(define (point-y [p : Point]) : i64
  (struct-get p y))
(define (main) : i64
  (point-y (Point 40 2)))"#,
    );
    assert!(
        passed.contains("    call tl_alloc\n"),
        "passed aggregate must remain heap allocated:\n{passed}"
    );

    let dynamic_array = selfhost_compile_opt2(
        manifest_dir,
        &work_dir,
        "dynamic_array",
        r#"(define (main) : i64
  (let
    [items : (Array i64) (make-array i64 3)]
    (begin
      (array-set! items 2 39)
      (array-ref items 2))))"#,
    );
    assert!(
        dynamic_array.contains("    call tl_alloc\n"),
        "dynamic-array storage must remain heap allocated:\n{dynamic_array}"
    );
}
