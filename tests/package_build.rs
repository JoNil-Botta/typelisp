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
  (entry "src/main.tl"))
"#,
            package_name
        ),
    )
    .expect("write package manifest");
    fs::write(
        root.join("src").join("main.tl"),
        r#"(import "math.tl")
(define (main) : i64 (inc 41))
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

#[test]
fn package_build_manifest_path_writes_deterministic_assembly() {
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
    let asm_path = expected_asm_path(&root, "demo_pkg");
    let printed_asm_path = fs::canonicalize(&asm_path).expect("canonicalize package asm path");
    assert!(
        stdout.contains(&format!("Generated: {}", printed_asm_path.display())),
        "build stdout should name deterministic output path\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr
    );
    let asm = fs::read_to_string(&asm_path).expect("read package build assembly");
    assert!(asm.contains("main:"), "assembly missing main:\n{}", asm);
    assert!(
        asm.contains("_tl_inc:"),
        "assembly missing imported helper function:\n{}",
        asm
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
