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

#[cfg(target_os = "linux")]
#[test]
fn build_source_writes_default_executable_without_running() {
    let dir = fixture_dir("build-source-default");
    let source = dir.join("main.tl");
    fs::write(
        &source,
        r#"(define (main) : i64
  (begin
    (print-string "should not run during build")
    7))
"#,
    )
    .expect("write source");
    let exe = source.with_extension("");
    let source_arg = source.to_str().expect("source path is utf-8");

    let output = typelisp(&["build", source_arg]);
    let stdout = stdout(&output);
    let stderr = stderr(&output);

    assert!(
        output.status.success(),
        "source build failed\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr
    );
    assert!(exe.exists(), "default executable was not written");
    assert!(
        stdout.contains(&format!("Generated: {}", exe.display())),
        "stdout missing executable path:\n{}",
        stdout
    );
    assert!(
        !stdout.contains("should not run during build"),
        "build unexpectedly ran the program:\n{}",
        stdout
    );

    let run = Command::new(&exe).output().expect("run built executable");
    assert_eq!(run.status.code(), Some(7), "built executable exit code");
}

#[cfg(target_os = "linux")]
#[test]
fn build_source_respects_o_output_path() {
    let dir = fixture_dir("build-source-output");
    let source = dir.join("main.tl");
    let exe = dir.join("custom-program");
    fs::write(&source, "(define (main) : i64 0)\n").expect("write source");
    let source_arg = source.to_str().expect("source path is utf-8");
    let exe_arg = exe.to_str().expect("exe path is utf-8");

    let output = typelisp(&["build", source_arg, "-o", exe_arg]);
    let stdout = stdout(&output);
    let stderr = stderr(&output);

    assert!(
        output.status.success(),
        "custom source build failed\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr
    );
    assert!(exe.exists(), "custom executable was not written");
    assert!(
        stdout.contains(&format!("Generated: {}", exe.display())),
        "stdout missing custom executable path:\n{}",
        stdout
    );
}

#[test]
fn build_source_reports_missing_source_file() {
    let dir = fixture_dir("build-source-missing");
    let missing = dir.join("missing.tl");
    let missing_arg = missing.to_str().expect("missing path is utf-8");

    let output = typelisp(&["build", missing_arg]);
    let stderr = stderr(&output);

    assert!(!output.status.success(), "stdout:\n{}", stdout(&output));
    assert!(
        stderr.contains("cannot read module"),
        "stderr missing read diagnostic:\n{}",
        stderr
    );
}

#[test]
fn build_source_reports_missing_o_value() {
    let dir = fixture_dir("build-source-missing-o");
    let source = dir.join("main.tl");
    fs::write(&source, "(define (main) : i64 0)\n").expect("write source");
    let source_arg = source.to_str().expect("source path is utf-8");

    let output = typelisp(&["build", source_arg, "-o"]);
    let stderr = stderr(&output);

    assert!(!output.status.success(), "stdout:\n{}", stdout(&output));
    assert!(
        stderr.contains("Error: -o requires a value"),
        "stderr missing -o diagnostic:\n{}",
        stderr
    );
}

#[test]
fn build_o_without_source_does_not_shadow_package_build() {
    let dir = fixture_dir("build-output-without-source");
    let exe = dir.join("out");
    let exe_arg = exe.to_str().expect("exe path is utf-8");

    let output = typelisp(&["build", "-o", exe_arg]);
    let stderr = stderr(&output);

    assert!(!output.status.success(), "stdout:\n{}", stdout(&output));
    assert!(
        stderr.contains("Error: -o requires a source file"),
        "stderr missing source-file diagnostic:\n{}",
        stderr
    );
}

fn stdout(output: &Output) -> String {
    String::from_utf8_lossy(&output.stdout).into_owned()
}

fn stderr(output: &Output) -> String {
    String::from_utf8_lossy(&output.stderr).into_owned()
}
