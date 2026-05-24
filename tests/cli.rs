use std::fs;
use std::path::PathBuf;
use std::process::{Command, Output};
use std::time::{SystemTime, UNIX_EPOCH};

fn fixture_dir(name: &str) -> PathBuf {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system time before unix epoch")
        .as_nanos();
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("target")
        .join(format!("cli-{name}-{}-{nonce}", std::process::id()));
    fs::create_dir_all(&dir).expect("create CLI fixture directory");
    dir
}

fn typelisp(args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_typelisp"))
        .args(args)
        .output()
        .expect("run typelisp CLI")
}

fn write_main_source(dir: &std::path::Path) -> PathBuf {
    let source = dir.join("main.tl");
    fs::write(&source, "(define (main) : i64 42)\n").expect("write source");
    source
}

fn assert_backend_mode_rejected(output: &Output, mode: &str) {
    assert!(
        !output.status.success(),
        "{mode} unexpectedly succeeded\nstdout:\n{}\nstderr:\n{}",
        stdout(output),
        stderr(output)
    );
    assert_eq!(stdout(output), "", "{mode} wrote stdout");
    assert!(
        stderr(output).contains(&format!(
            "backend mode {mode} is not implemented yet; scalar is the only supported backend mode"
        )),
        "{mode} stderr:\n{}",
        stderr(output)
    );
}

fn assert_doctest_temp_cleaned(source: &std::path::Path) {
    let temp_parent = source
        .parent()
        .expect("source has parent")
        .join(".typelisp-doctest");
    assert!(
        !temp_parent.exists(),
        "doctest temp directory was not cleaned: {}",
        temp_parent.display()
    );
}

#[test]
fn debug_tokenize_matches_top_level_alias() {
    let dir = fixture_dir("debug-tokenize");
    let source = dir.join("main.tl");
    fs::write(&source, "(define (main) : i64 42)\n").expect("write source");
    let source_arg = source.to_str().expect("source path is utf-8");

    let alias = typelisp(&["tokenize", source_arg]);
    let debug = typelisp(&["debug", "tokenize", source_arg]);

    assert!(alias.status.success(), "alias stderr:\n{}", stderr(&alias));
    assert!(debug.status.success(), "debug stderr:\n{}", stderr(&debug));
    assert_eq!(debug.stdout, alias.stdout);
    assert_eq!(debug.stderr, alias.stderr);
}

#[test]
fn debug_check_matches_top_level_alias_with_stdlib_root() {
    let dir = fixture_dir("debug-check");
    let app_dir = dir.join("app");
    let root_dir = dir.join("root");
    fs::create_dir_all(&app_dir).expect("create app dir");
    fs::create_dir_all(&root_dir).expect("create stdlib root dir");

    fs::write(root_dir.join("helper.tl"), "(define (helper) : i64 42)\n").expect("write helper");
    let source = app_dir.join("main.tl");
    fs::write(
        &source,
        "(import \"stdlib/helper.tl\")\n(define (main) : i64 (helper))\n",
    )
    .expect("write source");

    let source_arg = source.to_str().expect("source path is utf-8");
    let root_arg = root_dir.to_str().expect("root path is utf-8");
    let alias = typelisp(&["check", source_arg, "--stdlib-root", root_arg]);
    let debug = typelisp(&["debug", "check", source_arg, "--stdlib-root", root_arg]);

    assert!(alias.status.success(), "alias stderr:\n{}", stderr(&alias));
    assert!(debug.status.success(), "debug stderr:\n{}", stderr(&debug));
    assert_eq!(debug.stdout, alias.stdout);
    assert_eq!(debug.stderr, alias.stderr);
    assert_eq!(stdout(&debug), "Type checking passed!\n");
}

#[test]
fn compile_accepts_explicit_scalar_backend_mode() {
    let dir = fixture_dir("backend-mode-scalar");
    let source = write_main_source(&dir);
    let output_path = dir.join("main.s");
    let source_arg = source.to_str().expect("source path is utf-8");
    let output_arg = output_path.to_str().expect("output path is utf-8");

    let output = typelisp(&[
        "compile",
        source_arg,
        "--backend-mode",
        "scalar",
        "-o",
        output_arg,
    ]);

    assert!(output.status.success(), "stderr:\n{}", stderr(&output));
    assert_eq!(stderr(&output), "");
    assert!(output_path.exists(), "compile did not write assembly");
    let asm = fs::read_to_string(&output_path).expect("read assembly");
    assert!(asm.contains("main:"), "assembly:\n{}", asm);
}

#[test]
fn compile_rejects_unimplemented_backend_modes() {
    for mode in ["avx2", "avx512"] {
        let dir = fixture_dir(&format!("backend-mode-{mode}"));
        let source = write_main_source(&dir);
        let source_arg = source.to_str().expect("source path is utf-8");

        let output = typelisp(&["compile", source_arg, "--backend-mode", mode]);

        assert_backend_mode_rejected(&output, mode);
    }
}

#[test]
fn compile_rejects_unknown_backend_mode() {
    let dir = fixture_dir("backend-mode-unknown");
    let source = write_main_source(&dir);
    let source_arg = source.to_str().expect("source path is utf-8");

    let output = typelisp(&["compile", source_arg, "--backend-mode", "neon"]);

    assert!(!output.status.success());
    assert_eq!(stdout(&output), "");
    assert!(
        stderr(&output)
            .contains("Error: unknown backend mode 'neon'. Expected scalar, avx2, or avx512"),
        "stderr:\n{}",
        stderr(&output)
    );
}

#[test]
fn run_accepts_backend_mode_flag_and_rejects_unimplemented_modes() {
    let dir = fixture_dir("backend-mode-run");
    let source = write_main_source(&dir);
    let source_arg = source.to_str().expect("source path is utf-8");

    let output = typelisp(&["run", source_arg, "--backend-mode", "avx2", "--", "arg"]);

    assert_backend_mode_rejected(&output, "avx2");
}

#[test]
fn build_accepts_backend_mode_flag_and_rejects_unimplemented_modes() {
    let dir = fixture_dir("backend-mode-build");
    let src_dir = dir.join("src");
    fs::create_dir_all(&src_dir).expect("create package src dir");
    fs::write(
        dir.join("typelisp.pkg"),
        r#"(package
  (name "backend_mode_build")
  (version "0.1.0")
  (entry "src/main.tl"))
"#,
    )
    .expect("write package manifest");
    fs::write(src_dir.join("main.tl"), "(define (main) : i64 42)\n").expect("write package source");
    let manifest = dir.join("typelisp.pkg");
    let manifest_arg = manifest.to_str().expect("manifest path is utf-8");

    let output = typelisp(&[
        "build",
        "--manifest-path",
        manifest_arg,
        "--backend-mode",
        "avx512",
    ]);

    assert_backend_mode_rejected(&output, "avx512");
}

#[test]
fn debug_usage_errors_are_specific() {
    let missing = typelisp(&["debug"]);
    assert!(!missing.status.success());
    let missing_stderr = stderr(&missing);
    assert!(missing_stderr.contains("Error: missing debug subcommand"));
    assert!(missing_stderr.contains("typelisp debug tokenize <file.tl>"));

    let unknown = typelisp(&["debug", "wat"]);
    assert!(!unknown.status.success());
    let unknown_stderr = stderr(&unknown);
    assert!(unknown_stderr.contains("Unknown debug command: wat"));
    assert!(unknown_stderr.contains("typelisp debug check <file.tl>"));
}

#[test]
fn doc_test_checks_module_and_item_examples() {
    let dir = fixture_dir("doc-test-pass");
    let source = dir.join("docs.tl");
    fs::write(
        &source,
        r#";;;; Module docs.
;;;; ```typelisp
;;;; (define (main) : i64 42)
;;;; ```

;;; Item docs.
;;; ```tl
;;; (define answer : i64 42)
;;; ```
(define documented : i64 1)

; Ordinary comments are not docs, so this failing block is ignored.
; ```typelisp
; (define (bad) : i64 true)
; ```
"#,
    )
    .expect("write doctest source");

    let source_arg = source.to_str().expect("source path is utf-8");
    let output = typelisp(&["doc", "--test", source_arg]);

    assert!(output.status.success(), "stderr:\n{}", stderr(&output));
    assert_eq!(stdout(&output), "Doc tests passed: 2 example(s)\n");
    assert_doctest_temp_cleaned(&source);
}

#[test]
fn doc_test_accepts_expected_type_errors() {
    let dir = fixture_dir("doc-test-expected-error");
    let source = dir.join("docs.tl");
    fs::write(
        &source,
        r#";;;; Expected error.
;;;; ```typelisp expect-error
;;;; (define (bad) : i64 true)
;;;; ```
"#,
    )
    .expect("write doctest source");

    let source_arg = source.to_str().expect("source path is utf-8");
    let output = typelisp(&["doc", "--test", source_arg]);

    assert!(output.status.success(), "stderr:\n{}", stderr(&output));
    assert_eq!(stdout(&output), "Doc tests passed: 1 example(s)\n");
    assert_doctest_temp_cleaned(&source);
}

#[test]
fn doc_test_reports_unexpected_type_errors() {
    let dir = fixture_dir("doc-test-type-error");
    let source = dir.join("docs.tl");
    fs::write(
        &source,
        r#";;;; Unexpected error.
;;;; ```typelisp
;;;; (define (bad) : i64 true)
;;;; ```
"#,
    )
    .expect("write doctest source");

    let source_arg = source.to_str().expect("source path is utf-8");
    let output = typelisp(&["doc", "--test", source_arg]);
    let stderr = stderr(&output);

    assert!(!output.status.success(), "stdout:\n{}", stdout(&output));
    assert!(stderr.contains("doc tests failed"), "stderr:\n{}", stderr);
    assert!(
        stderr.contains("was expected to pass"),
        "stderr:\n{}",
        stderr
    );
    assert!(stderr.contains("error[E0200]"), "stderr:\n{}", stderr);
    assert_doctest_temp_cleaned(&source);
}

#[test]
fn doc_test_reports_malformed_examples() {
    let dir = fixture_dir("doc-test-malformed");
    let source = dir.join("docs.tl");
    fs::write(
        &source,
        r#";;;; Bad fence.
;;;; ```typelisp maybe
;;;; (define (main) : i64 0)
;;;; ```
"#,
    )
    .expect("write doctest source");

    let source_arg = source.to_str().expect("source path is utf-8");
    let output = typelisp(&["doc", "--test", source_arg]);
    let stderr = stderr(&output);

    assert!(!output.status.success(), "stdout:\n{}", stdout(&output));
    assert!(
        stderr.contains("unsupported TypeLisp doctest option `maybe`"),
        "stderr:\n{}",
        stderr
    );
    assert_doctest_temp_cleaned(&source);
}

#[test]
fn doc_test_passes_when_docs_have_no_examples() {
    let dir = fixture_dir("doc-test-empty");
    let source = dir.join("docs.tl");
    fs::write(
        &source,
        r#";;;; Docs without fenced examples.
;;; Item docs without fenced examples.
(define documented : i64 1)
"#,
    )
    .expect("write doctest source");

    let source_arg = source.to_str().expect("source path is utf-8");
    let output = typelisp(&["doc", "--test", source_arg]);

    assert!(output.status.success(), "stderr:\n{}", stderr(&output));
    assert_eq!(stdout(&output), "Doc tests passed: 0 example(s)\n");
    assert_doctest_temp_cleaned(&source);
}

fn stdout(output: &Output) -> String {
    String::from_utf8_lossy(&output.stdout).into_owned()
}

fn stderr(output: &Output) -> String {
    String::from_utf8_lossy(&output.stderr).into_owned()
}
