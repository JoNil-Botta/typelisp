use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

fn fresh_work_dir(name: &str) -> PathBuf {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("target")
        .join("package-build-tests")
        .join(format!("{}-{}", name, std::process::id()));
    let _ = fs::remove_dir_all(&root);
    fs::create_dir_all(&root).expect("create package build test dir");
    root
}

fn write_demo_package(root: &Path, package_name: &str) {
    fs::create_dir_all(root.join("src")).expect("create package src dir");
    fs::write(
        root.join("typelisp.pkg"),
        format!(
            r#"(package
  (name "{}")
  (version "0.1.0")
  (kind "bin")
  (entry "src/main.tl"))
"#,
            package_name
        ),
    )
    .expect("write package manifest");
    fs::write(
        root.join("src").join("main.tl"),
        r#"(import "math.tl")
(define (main) : i64 (- (inc 41) 42))
"#,
    )
    .expect("write package main");
    fs::write(
        root.join("src").join("math.tl"),
        "(define (inc [x : i64]) : i64 (+ x 1))\n",
    )
    .expect("write package helper");
}

fn expected_asm_path(root: &Path, package_name: &str) -> PathBuf {
    root.join("target")
        .join("typelisp")
        .join(package_name)
        .join(format!("{}.s", package_name))
}

fn expected_bin_path(root: &Path, package_name: &str) -> PathBuf {
    let file_name = if cfg!(windows) {
        format!("{}.exe", package_name)
    } else {
        package_name.to_string()
    };
    root.join("target")
        .join("typelisp")
        .join(package_name)
        .join(file_name)
}

fn host_missing_link_section() -> &'static str {
    if cfg!(windows) {
        r#"(windows-x86_64 (libs "__typelisp_missing_1516"))"#
    } else {
        r#"(linux-x86_64 (libs "__typelisp_missing_1516"))"#
    }
}

#[test]
fn package_build_manifest_path_writes_native_executable() {
    let root = fresh_work_dir("manifest-path");
    write_demo_package(&root, "demo_pkg");

    let output = Command::new(env!("CARGO_BIN_EXE_typelisp"))
        .arg("build")
        .arg("--manifest-path")
        .arg(root.join("typelisp.pkg"))
        .output()
        .expect("run typelisp build");

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        output.status.success(),
        "package build failed\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr
    );
    let bin_path = expected_bin_path(&root, "demo_pkg");
    let printed_bin_path = fs::canonicalize(&bin_path).expect("canonicalize package bin path");
    assert!(
        stdout.contains(&format!("Generated: {}", printed_bin_path.display())),
        "build stdout should name deterministic output path\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr
    );
    assert!(bin_path.exists(), "package build did not write executable");
    let run = Command::new(&bin_path)
        .output()
        .expect("run package build executable");
    assert!(
        run.status.success(),
        "package executable should exit 0\nstdout:\n{}\nstderr:\n{}",
        String::from_utf8_lossy(&run.stdout),
        String::from_utf8_lossy(&run.stderr)
    );
    let asm_path = expected_asm_path(&root, "demo_pkg");
    let asm = fs::read_to_string(&asm_path).expect("read package build assembly");
    assert!(asm.contains("main:"), "assembly missing main:\n{}", asm);
    assert!(
        asm.contains("_tl_inc:"),
        "assembly missing imported helper function:\n{}",
        asm
    );
}

#[test]
fn package_build_threads_manifest_link_inputs_to_linker() {
    let root = fresh_work_dir("manifest-link-inputs");
    fs::create_dir_all(root.join("src")).expect("create package src dir");
    fs::write(
        root.join("typelisp.pkg"),
        format!(
            r#"(package
  (name "link_inputs_pkg")
  (version "0.1.0")
  (kind "bin")
  (entry "src/main.tl")
  (link
    {}))
"#,
            host_missing_link_section()
        ),
    )
    .expect("write package manifest");
    fs::write(
        root.join("src").join("main.tl"),
        "(define (main) : i64 0)\n",
    )
    .expect("write package main");

    let output = Command::new(env!("CARGO_BIN_EXE_typelisp"))
        .arg("build")
        .arg("--manifest-path")
        .arg(root.join("typelisp.pkg"))
        .output()
        .expect("run typelisp build with missing manifest link lib");

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        !output.status.success(),
        "missing manifest link library unexpectedly succeeded\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr
    );
    assert!(
        stderr.contains("__typelisp_missing_1516") || stderr.contains("linker"),
        "stderr should show the manifest link input reached the linker\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr
    );
}

#[test]
fn package_build_discovers_manifest_by_walking_upward() {
    let root = fresh_work_dir("discover-upward");
    write_demo_package(&root, "walk_pkg");
    let nested = root.join("src").join("nested").join("deeper");
    fs::create_dir_all(&nested).expect("create nested cwd");

    let output = Command::new(env!("CARGO_BIN_EXE_typelisp"))
        .arg("build")
        .current_dir(&nested)
        .output()
        .expect("run typelisp build with discovery");

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        output.status.success(),
        "package discovery build failed\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr
    );
    let asm_path = expected_asm_path(&root, "walk_pkg");
    assert!(asm_path.exists(), "discovered build did not write assembly");
}

#[test]
fn package_build_reports_manifest_parse_errors() {
    let root = fresh_work_dir("parse-error");
    fs::write(
        root.join("typelisp.pkg"),
        r#"(package
  (name "bad_pkg")
  (version "0.1.0")
  (kind "bin")
  (entry "src/main.tl")
  (deps "not-yet"))
"#,
    )
    .expect("write invalid manifest");

    let output = Command::new(env!("CARGO_BIN_EXE_typelisp"))
        .arg("build")
        .arg("--manifest-path")
        .arg(root.join("typelisp.pkg"))
        .output()
        .expect("run typelisp build with invalid manifest");

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        !output.status.success(),
        "invalid manifest unexpectedly succeeded\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr
    );
    assert!(
        stderr.contains("unknown manifest field `deps`"),
        "stderr missing unknown field diagnostic\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr
    );
}

#[test]
fn package_build_resolves_path_dependency_import() {
    let root = fresh_work_dir("path-dependency");
    let dep_root = root.join("vendor").join("math");
    fs::create_dir_all(root.join("src")).expect("create package src dir");
    fs::create_dir_all(dep_root.join("src")).expect("create dependency src dir");
    fs::write(
        root.join("typelisp.pkg"),
        r#"(package
  (name "pkg_dep_app")
  (version "0.1.0")
  (kind "bin")
  (entry "src/main.tl")
  (dependencies
    (math "vendor/math")))
"#,
    )
    .expect("write package manifest");
    fs::write(
        root.join("src").join("main.tl"),
        r#"(import "pkg:math/src/lib.tl")
(define (main) : i64 (add-one 41))
"#,
    )
    .expect("write package main");
    fs::write(
        dep_root.join("src").join("lib.tl"),
        "(define (add-one [x : i64]) : i64 (+ x 1))\n",
    )
    .expect("write dependency module");

    let output = Command::new(env!("CARGO_BIN_EXE_typelisp"))
        .arg("build")
        .arg("--manifest-path")
        .arg(root.join("typelisp.pkg"))
        .output()
        .expect("run typelisp build with path dependency");

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        output.status.success(),
        "package dependency build failed\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr
    );
    let asm = fs::read_to_string(expected_asm_path(&root, "pkg_dep_app"))
        .expect("read package build assembly");
    assert!(asm.contains("main:"), "assembly missing main:\n{}", asm);
    assert!(
        asm.contains("_tl_add_one:"),
        "assembly missing imported dependency function:\n{}",
        asm
    );
}

#[test]
fn package_build_reports_missing_package_alias() {
    let root = fresh_work_dir("missing-package-alias");
    fs::create_dir_all(root.join("src")).expect("create package src dir");
    fs::write(
        root.join("typelisp.pkg"),
        r#"(package
  (name "missing_alias")
  (version "0.1.0")
  (kind "bin")
  (entry "src/main.tl"))
"#,
    )
    .expect("write package manifest");
    fs::write(
        root.join("src").join("main.tl"),
        r#"(import "pkg:math/src/lib.tl")
(define (main) : i64 0)
"#,
    )
    .expect("write package main");

    let output = Command::new(env!("CARGO_BIN_EXE_typelisp"))
        .arg("build")
        .arg("--manifest-path")
        .arg(root.join("typelisp.pkg"))
        .output()
        .expect("run typelisp build with missing package alias");

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        !output.status.success(),
        "missing alias build unexpectedly succeeded\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr
    );
    assert!(
        stderr.contains("pkg:math/src/lib.tl"),
        "stderr missing package import\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr
    );
    assert!(
        stderr.contains("alias `math`"),
        "stderr missing package alias\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr
    );
}

#[test]
fn package_build_reports_missing_dependency_file() {
    let root = fresh_work_dir("missing-dependency-file");
    fs::create_dir_all(root.join("src")).expect("create package src dir");
    fs::create_dir_all(root.join("vendor").join("math")).expect("create dependency root");
    fs::write(
        root.join("typelisp.pkg"),
        r#"(package
  (name "missing_dep_file")
  (version "0.1.0")
  (kind "bin")
  (entry "src/main.tl")
  (dependencies
    (math "vendor/math")))
"#,
    )
    .expect("write package manifest");
    fs::write(
        root.join("src").join("main.tl"),
        r#"(import "pkg:math/src/missing.tl")
(define (main) : i64 0)
"#,
    )
    .expect("write package main");

    let output = Command::new(env!("CARGO_BIN_EXE_typelisp"))
        .arg("build")
        .arg("--manifest-path")
        .arg(root.join("typelisp.pkg"))
        .output()
        .expect("run typelisp build with missing dependency file");

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    let stderr_normalized = stderr.replace('\\', "/");
    assert!(
        !output.status.success(),
        "missing dependency file build unexpectedly succeeded\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr
    );
    assert!(
        stderr.contains("pkg:math/src/missing.tl"),
        "stderr missing package import\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr
    );
    assert!(
        stderr.contains("alias `math`"),
        "stderr missing package alias\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr
    );
    assert!(
        stderr_normalized.contains("vendor/math/src/missing.tl"),
        "stderr missing resolved dependency path\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr
    );
}

/// Writes a package whose `main` is a constant-foldable multiply (`(* 6 7)`).
/// At the default opt level the IR optimizer folds it to a constant `mov`;
/// at `--opt-level 0` the optimizer is skipped, so the emitted assembly still
/// contains the `imul`. That difference makes opt-level forwarding observable.
fn write_foldable_package(root: &Path, package_name: &str) {
    fs::create_dir_all(root.join("src")).expect("create package src dir");
    fs::write(
        root.join("typelisp.pkg"),
        format!(
            r#"(package
  (name "{}")
  (version "0.1.0")
  (kind "bin")
  (entry "src/main.tl"))
"#,
            package_name
        ),
    )
    .expect("write package manifest");
    fs::write(
        root.join("src").join("main.tl"),
        "(define (main) : i64 (* 6 7))\n",
    )
    .expect("write package main");
}

#[test]
fn package_build_opt_level_zero_skips_optimizer() {
    let root = fresh_work_dir("opt-level-zero");
    write_foldable_package(&root, "opt_zero_pkg");
    let manifest = root.join("typelisp.pkg");
    let asm_path = expected_asm_path(&root, "opt_zero_pkg");

    // Default build optimizes: `(* 6 7)` folds to a constant, no `imul`.
    let default_build = Command::new(env!("CARGO_BIN_EXE_typelisp"))
        .arg("build")
        .arg("--manifest-path")
        .arg(&manifest)
        .output()
        .expect("run default package build");
    assert!(
        default_build.status.success(),
        "default package build failed\nstderr:\n{}",
        String::from_utf8_lossy(&default_build.stderr)
    );
    let default_asm = fs::read_to_string(&asm_path).expect("read default package assembly");
    assert!(
        !default_asm.contains("imul"),
        "default (optimized) build should fold the multiply away\n{}",
        default_asm
    );

    // `--opt-level 0` skips the optimizer, so the multiply survives as `imul`.
    let o0_build = Command::new(env!("CARGO_BIN_EXE_typelisp"))
        .arg("build")
        .arg("--manifest-path")
        .arg(&manifest)
        .arg("--opt-level")
        .arg("0")
        .output()
        .expect("run --opt-level 0 package build");
    assert!(
        o0_build.status.success(),
        "--opt-level 0 package build failed\nstderr:\n{}",
        String::from_utf8_lossy(&o0_build.stderr)
    );
    let o0_asm = fs::read_to_string(&asm_path).expect("read --opt-level 0 package assembly");
    assert!(
        o0_asm.contains("imul"),
        "--opt-level 0 build should keep the unoptimized multiply\n{}",
        o0_asm
    );
}

#[test]
fn package_build_accepts_explicit_default_opt_level() {
    let root = fresh_work_dir("opt-level-two");
    write_foldable_package(&root, "opt_two_pkg");

    let output = Command::new(env!("CARGO_BIN_EXE_typelisp"))
        .arg("build")
        .arg("--manifest-path")
        .arg(root.join("typelisp.pkg"))
        .arg("--opt-level")
        .arg("2")
        .output()
        .expect("run --opt-level 2 package build");

    assert!(
        output.status.success(),
        "--opt-level 2 package build failed\nstderr:\n{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let asm =
        fs::read_to_string(expected_asm_path(&root, "opt_two_pkg")).expect("read package assembly");
    assert!(
        !asm.contains("imul"),
        "--opt-level 2 should optimize like the default\n{}",
        asm
    );
}

#[test]
fn package_build_rejects_invalid_opt_level() {
    let root = fresh_work_dir("opt-level-invalid");
    write_foldable_package(&root, "opt_invalid_pkg");

    let output = Command::new(env!("CARGO_BIN_EXE_typelisp"))
        .arg("build")
        .arg("--manifest-path")
        .arg(root.join("typelisp.pkg"))
        .arg("--opt-level")
        .arg("9")
        .output()
        .expect("run invalid --opt-level package build");

    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        !output.status.success(),
        "invalid --opt-level unexpectedly succeeded\nstderr:\n{}",
        stderr
    );
    assert!(
        stderr.contains("unknown opt level '9'; expected 0, 1, 2, or 3"),
        "stderr missing invalid opt-level diagnostic\nstderr:\n{}",
        stderr
    );
}

#[test]
fn package_build_rejects_duplicate_opt_level() {
    let root = fresh_work_dir("opt-level-duplicate");
    write_foldable_package(&root, "opt_dup_pkg");

    let output = Command::new(env!("CARGO_BIN_EXE_typelisp"))
        .arg("build")
        .arg("--manifest-path")
        .arg(root.join("typelisp.pkg"))
        .arg("--opt-level")
        .arg("1")
        .arg("--opt-level")
        .arg("2")
        .output()
        .expect("run duplicate --opt-level package build");

    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        !output.status.success(),
        "duplicate --opt-level unexpectedly succeeded\nstderr:\n{}",
        stderr
    );
    assert!(
        stderr.contains("--opt-level was provided more than once"),
        "stderr missing duplicate opt-level diagnostic\nstderr:\n{}",
        stderr
    );
}

#[test]
fn package_build_rejects_missing_opt_level_value() {
    let root = fresh_work_dir("opt-level-missing");
    write_foldable_package(&root, "opt_missing_pkg");

    let output = Command::new(env!("CARGO_BIN_EXE_typelisp"))
        .arg("build")
        .arg("--manifest-path")
        .arg(root.join("typelisp.pkg"))
        .arg("--opt-level")
        .output()
        .expect("run missing --opt-level value package build");

    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        !output.status.success(),
        "missing --opt-level value unexpectedly succeeded\nstderr:\n{}",
        stderr
    );
    assert!(
        stderr.contains("--opt-level requires a value"),
        "stderr missing missing-value diagnostic\nstderr:\n{}",
        stderr
    );
}
