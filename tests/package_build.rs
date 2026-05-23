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
fn package_build_with_dependencies_and_pkg_imports() {
    let root = fresh_work_dir("pkg-deps");

    // Create a dependency package: math
    let math_root = root.join("math");
    fs::create_dir_all(math_root.join("src")).expect("create math src dir");
    fs::write(
        math_root.join("typelisp.pkg"),
        r#"(package (name "math") (version "0.1.0") (entry "src/lib.tl"))"#,
    )
    .expect("write math manifest");
    fs::write(
        math_root.join("src").join("lib.tl"),
        "(define (add [a : i64] [b : i64]) : i64 (+ a b))\n",
    )
    .expect("write math lib");

    // Create the app package that depends on math
    let app_root = root.join("app");
    fs::create_dir_all(app_root.join("src")).expect("create app src dir");
    fs::write(
        app_root.join("typelisp.pkg"),
        r#"(package
  (name "app")
  (version "0.1.0")
  (entry "src/main.tl")
  (dependencies (math "../math")))
"#,
    )
    .expect("write app manifest");
    fs::write(
        app_root.join("src").join("main.tl"),
        r#"(import "pkg:math/src/lib.tl")
(define (main) : i64 (add 40 2))
"#,
    )
    .expect("write app main");

    let output = Command::new(env!("CARGO_BIN_EXE_typelisp"))
        .arg("build")
        .arg("--manifest-path")
        .arg(app_root.join("typelisp.pkg"))
        .output()
        .expect("run typelisp build with pkg deps");

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        output.status.success(),
        "pkg-dep build failed\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr
    );

    let asm_path = expected_asm_path(&app_root, "app");
    assert!(asm_path.exists(), "pkg-dep build did not write assembly");
    let asm = fs::read_to_string(&asm_path).expect("read pkg-dep assembly");
    assert!(asm.contains("main:"), "assembly missing main:\n{}", asm);
    assert!(
        asm.contains("_tl_add:"),
        "assembly missing imported pkg function:\n{}",
        asm
    );
}

#[test]
fn package_build_reports_unknown_pkg_alias() {
    let root = fresh_work_dir("pkg-alias-missing");
    fs::create_dir_all(root.join("src")).expect("create app src dir");
    fs::write(
        root.join("typelisp.pkg"),
        r#"(package
  (name "app")
  (version "0.1.0")
  (entry "src/main.tl"))
"#,
    )
    .expect("write app manifest");
    fs::write(
        root.join("src").join("main.tl"),
        r#"(import "pkg:nope/src/lib.tl")
(define (main) : i64 42)
"#,
    )
    .expect("write app main");

    let output = Command::new(env!("CARGO_BIN_EXE_typelisp"))
        .arg("build")
        .arg("--manifest-path")
        .arg(root.join("typelisp.pkg"))
        .output()
        .expect("run typelisp build with unknown alias");

    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        !output.status.success(),
        "build with unknown alias unexpectedly succeeded"
    );
    assert!(
        stderr.contains("unknown dependency alias 'nope'"),
        "stderr missing unknown alias diagnostic:\n{}",
        stderr
    );
}

#[test]
fn package_build_flat_namespace_collides_across_pkg_deps() {
    let root = fresh_work_dir("flat-collision");

    // dep package defines `dup`
    let dep_root = root.join("dep");
    fs::create_dir_all(dep_root.join("src")).expect("create dep src dir");
    fs::write(
        dep_root.join("typelisp.pkg"),
        r#"(package (name "dep") (version "0.1.0") (entry "src/lib.tl"))"#,
    )
    .expect("write dep manifest");
    fs::write(
        dep_root.join("src").join("lib.tl"),
        "(define (dup) : i64 100)\n",
    )
    .expect("write dep lib");

    // app package also defines `dup`
    let app_root = root.join("app");
    fs::create_dir_all(app_root.join("src")).expect("create app src dir");
    fs::write(
        app_root.join("typelisp.pkg"),
        r#"(package
  (name "app")
  (version "0.1.0")
  (entry "src/main.tl")
  (dependencies (dep "../dep")))
"#,
    )
    .expect("write app manifest");
    fs::write(
        app_root.join("src").join("main.tl"),
        r#"(import "pkg:dep/src/lib.tl")
(define (dup) : i64 200)
"#,
    )
    .expect("write app main");

    let output = Command::new(env!("CARGO_BIN_EXE_typelisp"))
        .arg("build")
        .arg("--manifest-path")
        .arg(app_root.join("typelisp.pkg"))
        .output()
        .expect("run typelisp build with collision");

    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        !output.status.success(),
        "build with flat collision unexpectedly succeeded"
    );
    assert!(
        stderr.contains("duplicate top-level name 'dup'"),
        "stderr missing duplicate diagnostic:\n{}",
        stderr
    );
}
