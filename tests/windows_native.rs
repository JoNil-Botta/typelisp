#![cfg(target_os = "windows")]

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

struct Case {
    name: &'static str,
    exit_code: i32,
    stdout: &'static str,
    deps: &'static [&'static str],
    args: &'static [&'static str],
}

/// Windows exit codes that indicate a process crash rather than a clean failure.
/// 0xC0000005 (access violation, -1073741819) and 0xC000001D (illegal
/// instruction, -1073741795) are the #1204 intermittent native-segfault codes;
/// 132/134/139 cover the bash/MSYS 128+signal convention. Mirrors the crash-only
/// retry guard added for `tests/cli.rs` (#1248) and the `verify-*.sh` gates (#1247).
fn is_crash_code(code: Option<i32>) -> bool {
    matches!(
        code,
        Some(132) | Some(134) | Some(139) | Some(-1073741819) | Some(-1073741795)
    )
}

/// Re-run a native-binary spawn while it exits with a crash code, up to
/// `WINDOWS_NATIVE_TEST_ATTEMPTS` times (default 6, matching #1247). Only crashes
/// are retried; a clean non-crash exit (including a real test failure) is returned
/// immediately so genuine regressions still fail fast. Mitigates the #1204 Windows
/// segfault flake on the large selfhost smokes.
fn run_native_with_crash_retry(
    mut make: impl FnMut() -> std::process::Output,
) -> std::process::Output {
    let attempts = std::env::var("WINDOWS_NATIVE_TEST_ATTEMPTS")
        .ok()
        .and_then(|value| value.parse::<usize>().ok())
        .filter(|count| *count >= 1)
        .unwrap_or(6);
    let mut output = make();
    let mut attempt = 1;
    while attempt < attempts && is_crash_code(output.status.code()) {
        eprintln!(
            "windows_native: retrying after crash exit {:?} (attempt {}/{})",
            output.status.code(),
            attempt + 1,
            attempts
        );
        output = make();
        attempt += 1;
    }
    output
}

const TL_EMIT_PROGRAM_ASM: &str = concat!(
    "    .text\n",
    "    .globl main\n",
    "    .globl _start\n",
    "\n",
    "main:\n",
    "    push %rbp\n",
    "    mov %rsp, %rbp\n",
    "    movq $1, %rax\n",
    "    pushq %rax\n",
    "    movq $2, %rax\n",
    "    pushq %rax\n",
    "    movq $3, %rax\n",
    "    movq %rax, %rcx\n",
    "    popq %rax\n",
    "    imulq %rcx, %rax\n",
    "    movq %rax, %rcx\n",
    "    popq %rax\n",
    "    addq %rcx, %rax\n",
    "    pop %rbp\n",
    "    ret\n",
    "\n",
    "_start:\n",
    "    call main\n",
    "    movq %rax, %rdi\n",
    "    movq $60, %rax\n",
    "    syscall\n",
);

#[test]
#[ignore = "covered by scripts/verify-integration.sh in CI; too slow for default Windows cargo test"]
fn windows_target_compiles_links_and_runs_native_executables() {
    for case in native_cases() {
        run_case(&case);
    }
}

#[test]
fn selfhost_backend_windows_runtime_helpers_emit_assemble_link_and_run() {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let work_dir = manifest_dir
        .join("target")
        .join("windows-native-tests")
        .join("selfhost_backend_runtime_helpers");
    fs::create_dir_all(&work_dir).expect("create selfhost Windows runtime helper test dir");
    let fixture_path = copy_selfhost_tl_sources(&manifest_dir, &work_dir);

    let asm_path = work_dir.join("runtime_helpers.s");
    let obj_path = work_dir.join("runtime_helpers.obj");
    let bin_path = work_dir.join("runtime_helpers.exe");

    let output = Command::new(env!("CARGO_BIN_EXE_typelisp"))
        .arg("run")
        .arg(&fixture_path)
        .arg("--target")
        .arg("windows-x86_64")
        .arg("--")
        .arg(&asm_path)
        .arg("windows-x86_64")
        .output()
        .expect("run selfhost backend runtime fixture for Windows target");
    assert_eq!(
        output.status.code(),
        Some(0),
        "selfhost Windows runtime fixture failed\nstdout:\n{}\nstderr:\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );

    let asm = fs::read_to_string(&asm_path)
        .expect("read selfhost Windows runtime helper assembly")
        .replace("\r\n", "\n")
        .replace('\r', "\n");
    for snippet in [
        ".globl main\n",
        ".globl tl_alloc\n",
        "\ntl_alloc:\n",
        ".globl tl_oob_abort\n",
        "\ntl_oob_abort:\n",
        ".globl tl_substring\n",
        "\ntl_substring:\n",
        ".globl tl_string_concat\n",
        "\ntl_string_concat:\n",
        ".globl tl_string_eq\n",
        "\ntl_string_eq:\n",
        ".L_tl_string_eq_word_loop:\n",
        "    shrq $3, %r10\n",
        "    cmpq (%r8), %rax\n",
        ".L_tl_string_eq_tail_loop:\n",
        ".globl tl_string_to_int\n",
        "\ntl_string_to_int:\n",
        ".globl tl_int_to_string\n",
        "\ntl_int_to_string:\n",
        ".globl tl_print_err\n",
        "\ntl_print_err:\n",
        "\n.L_tl_arg_count:\n",
        "\n.L_tl_arg:\n",
        "\n.L_tl_read_file:\n",
        "\n.L_tl_write_file:\n",
        "\n.L_tl_file_exists:\n",
        "\n.L_tl_abort:\n",
        "\n.L_tl_read_stdin_line:\n",
        "\n.L_tl_read_stdin_bytes:\n",
        "\n.L_tl_stdin_eof:\n",
        "\n.L_tl_flush_stdout:\n",
        "\ntl_process_output:\n",
        ".L_tl_process_make_error_win:\n",
        "process: runtime execution is not supported on this target",
        "\n.L_tl_argc:\n",
        "\n.L_tl_argv:\n",
        "    movq %rcx, .L_tl_argc(%rip)\n",
        "    movq %rdx, .L_tl_argv(%rip)\n",
        "    rep movsb\n",
        "    .extern VirtualAlloc\n",
        "    .extern _write\n",
        "    .extern exit\n",
        "    .extern _read\n",
        "    .extern fflush\n",
        "    .extern _open\n",
        "    .extern _lseeki64\n",
        "    .extern _close\n",
        "    .extern _access\n",
        "    call VirtualAlloc\n",
        "    call _write\n",
        "    call _read\n",
        "    call fflush\n",
        "    call _open\n",
        "    call _lseeki64\n",
        "    call _close\n",
        "    call _access\n",
        "    call .L_tl_abort\n",
        "    movq $0x8000, %rdx\n",
        "    movq $0x8301, %rdx\n",
        "    movq $0x180, %r8\n",
        "    movq %rcx, %rbx\n",
        "    movq %r12, %rcx\n",
        "    movq %rcx, %r10\n",
        "    call SystemFunction036\n",
    ] {
        assert!(
            asm.contains(snippet),
            "selfhost Windows runtime helper assembly missing {:?}:\n{}",
            snippet,
            asm
        );
    }
    assert!(!asm.contains("    syscall"), "asm:\n{}", asm);
    assert!(!asm.contains("\n_start:"), "asm:\n{}", asm);
    assert!(asm.contains("tl_current_arena:"), "asm:\n{}", asm);
    assert!(
        asm.matches("    rep movsb\n").count() >= 10,
        "selfhost Windows runtime helper assembly should bulk-copy string and path payloads:\n{}",
        asm
    );
    for old_loop in [
        ".L_tl_substring_copy_loop:\n",
        ".L_tl_string_concat_copy_a:\n",
        ".L_tl_string_concat_copy_b:\n",
        "path_copy_loop:",
        "path_copy_done:",
    ] {
        assert!(
            !asm.contains(old_loop),
            "selfhost Windows runtime helper assembly should not use byte copy loop {old_loop:?}:\n{asm}"
        );
    }
    for helper in [
        ".extern tl_alloc\n",
        ".extern tl_oob_abort\n",
        ".extern tl_substring\n",
        ".extern tl_string_concat\n",
        ".extern tl_string_eq\n",
        ".extern tl_string_to_int\n",
        ".extern tl_int_to_string\n",
        ".extern tl_print_err\n",
        ".extern .L_tl_arg_count\n",
        ".extern .L_tl_arg\n",
        ".extern .L_tl_read_file\n",
        ".extern .L_tl_write_file\n",
        ".extern .L_tl_file_exists\n",
        ".extern .L_tl_abort\n",
        ".extern .L_tl_read_stdin_line\n",
        ".extern .L_tl_read_stdin_bytes\n",
        ".extern .L_tl_stdin_eof\n",
        ".extern .L_tl_flush_stdout\n",
        ".extern tl_process_output\n",
        ".extern tl_random_system_seed\n",
    ] {
        assert!(
            !asm.contains(helper),
            "runtime helper should be defined inline, not extern: {helper}\n{asm}"
        );
    }

    let status = Command::new("clang")
        .arg("--target=x86_64-pc-windows-msvc")
        .arg("-c")
        .arg(&asm_path)
        .arg("-o")
        .arg(&obj_path)
        .status()
        .expect("assemble selfhost Windows runtime helper output");
    assert!(
        status.success(),
        "assembling selfhost Windows runtime helper output failed"
    );

    let status = Command::new("lld-link")
        .arg("/NOLOGO")
        .arg(&obj_path)
        .arg(format!("/OUT:{}", bin_path.display()))
        .arg("/SUBSYSTEM:CONSOLE")
        .arg("msvcrt.lib")
        .arg("legacy_stdio_definitions.lib")
        .arg("advapi32.lib")
        .status()
        .expect("link selfhost Windows runtime helper output");
    assert!(
        status.success(),
        "linking selfhost Windows runtime helper output failed"
    );

    let output = run_native_with_crash_retry(|| {
        Command::new(&bin_path)
            .output()
            .expect("run selfhost Windows runtime helper binary")
    });
    assert_eq!(
        output.status.code(),
        Some(42),
        "selfhost Windows runtime helper binary exited unexpectedly\nstdout:\n{}\nstderr:\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
}

#[test]
fn selfhost_compile_driver_runs_as_windows_native_executable() {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let driver_source = manifest_dir.join("selfhost").join("compile.tl");
    let work_dir = manifest_dir
        .join("target")
        .join("windows-native-tests")
        .join("selfhost_compile_driver");
    fs::create_dir_all(&work_dir).expect("create selfhost compile driver test dir");

    let driver_bin = work_dir.join("selfhost-compile.exe");
    let build = Command::new(env!("CARGO_BIN_EXE_typelisp"))
        .arg("build")
        .arg(&driver_source)
        .arg("-o")
        .arg(&driver_bin)
        .arg("--target")
        .arg("windows-x86_64")
        .output()
        .expect("build selfhost compile driver for Windows");
    assert!(
        build.status.success(),
        "selfhost compile driver Windows build failed\nstdout:\n{}\nstderr:\n{}",
        String::from_utf8_lossy(&build.stdout),
        String::from_utf8_lossy(&build.stderr)
    );

    let source = work_dir.join("main.tl");
    let asm_path = work_dir.join("main.s");
    fs::write(&source, "(define (main) : i64 42)\n").expect("write source");
    let output = Command::new(&driver_bin)
        .arg(&source)
        .arg("-o")
        .arg(&asm_path)
        .output()
        .expect("run selfhost compile driver for Windows");
    assert!(
        output.status.success(),
        "selfhost compile driver failed\nstdout:\n{}\nstderr:\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(String::from_utf8_lossy(&output.stdout), "");
    assert_eq!(String::from_utf8_lossy(&output.stderr), "");
    let asm = fs::read_to_string(&asm_path).expect("read emitted assembly");
    assert!(asm.contains(".globl main\n"), "assembly:\n{asm}");
    assert!(asm.contains("main:\n"), "assembly:\n{asm}");
    assert!(
        asm.contains(".globl _start\n"),
        "default selfhost compile output should stay on the Linux entry path:\n{asm}"
    );

    let explicit_linux_asm = work_dir.join("main-linux.s");
    let explicit_linux = Command::new(&driver_bin)
        .arg(&source)
        .arg("--target")
        .arg("linux-x86_64")
        .arg("-o")
        .arg(&explicit_linux_asm)
        .output()
        .expect("run selfhost compile driver for explicit Linux target");
    assert!(
        explicit_linux.status.success(),
        "selfhost compile driver explicit Linux target failed\nstdout:\n{}\nstderr:\n{}",
        String::from_utf8_lossy(&explicit_linux.stdout),
        String::from_utf8_lossy(&explicit_linux.stderr)
    );
    assert_eq!(String::from_utf8_lossy(&explicit_linux.stdout), "");
    assert_eq!(String::from_utf8_lossy(&explicit_linux.stderr), "");
    let explicit_linux_text =
        fs::read_to_string(&explicit_linux_asm).expect("read explicit Linux assembly");
    assert_eq!(
        explicit_linux_text, asm,
        "explicit Linux target should match default selfhost compile output"
    );

    let windows_asm = work_dir.join("main-windows.s");
    let windows = Command::new(&driver_bin)
        .arg(&source)
        .arg("--target")
        .arg("windows-x86_64")
        .arg("-o")
        .arg(&windows_asm)
        .output()
        .expect("run selfhost compile driver for Windows target");
    assert!(
        windows.status.success(),
        "selfhost compile driver Windows target failed\nstdout:\n{}\nstderr:\n{}",
        String::from_utf8_lossy(&windows.stdout),
        String::from_utf8_lossy(&windows.stderr)
    );
    assert_eq!(String::from_utf8_lossy(&windows.stdout), "");
    assert_eq!(String::from_utf8_lossy(&windows.stderr), "");
    let windows_text = fs::read_to_string(&windows_asm).expect("read Windows assembly");
    assert!(
        windows_text.contains(".globl main\n"),
        "Windows assembly:\n{windows_text}"
    );
    assert!(
        !windows_text.contains(".globl _start\n"),
        "Windows assembly should not emit Linux _start:\n{windows_text}"
    );

    let bad_target_asm = work_dir.join("bad-target.s");
    let bad_target = Command::new(&driver_bin)
        .arg(&source)
        .arg("--target")
        .arg("plan9-x86_64")
        .arg("-o")
        .arg(&bad_target_asm)
        .output()
        .expect("run selfhost compile driver for invalid target");
    assert!(!bad_target.status.success());
    assert_eq!(String::from_utf8_lossy(&bad_target.stdout), "");
    let bad_target_stderr = String::from_utf8_lossy(&bad_target.stderr);
    assert!(
        bad_target_stderr.contains(
            "Error: unknown target 'plan9-x86_64'. Expected linux-x86_64 or windows-x86_64"
        ),
        "stderr:\n{bad_target_stderr}"
    );
    assert!(
        !bad_target_asm.exists(),
        "invalid target should not write assembly"
    );

    let comptime_type_source = work_dir.join("comptime-type.tl");
    let comptime_type_asm = work_dir.join("comptime-type.s");
    fs::write(
        &comptime_type_source,
        "(define (alloc [comptime T : type] [n : i64]) : (Array i64) (make-array T n))
(define (main) : (Array i64) (alloc (type i64) 4))
",
    )
    .expect("write comptime type source");
    let comptime_type = Command::new(&driver_bin)
        .arg(&comptime_type_source)
        .arg("-o")
        .arg(&comptime_type_asm)
        .output()
        .expect("run selfhost compile driver on comptime type source");
    assert!(
        comptime_type.status.success(),
        "selfhost compile driver rejected comptime type source\nstdout:\n{}\nstderr:\n{}",
        String::from_utf8_lossy(&comptime_type.stdout),
        String::from_utf8_lossy(&comptime_type.stderr)
    );
    let comptime_type_text =
        fs::read_to_string(&comptime_type_asm).expect("read comptime type assembly");
    assert!(
        comptime_type_text.contains("__tl_specialized_alloc_type_i64_none"),
        "assembly:\n{comptime_type_text}"
    );

    let bad_source = work_dir.join("bad.tl");
    let bad_asm = work_dir.join("bad.s");
    fs::write(&bad_source, "(define (main) : i64 true)\n").expect("write bad source");
    let _ = fs::remove_file(&bad_asm);
    let bad = Command::new(&driver_bin)
        .arg(&bad_source)
        .arg("-o")
        .arg(&bad_asm)
        .output()
        .expect("run selfhost compile driver on invalid source");
    assert!(!bad.status.success());
    assert_eq!(String::from_utf8_lossy(&bad.stdout), "");
    let bad_stderr = String::from_utf8_lossy(&bad.stderr);
    assert!(
        bad_stderr.contains("typecheck: return type mismatch"),
        "stderr:\n{bad_stderr}"
    );
    assert!(
        !bad_asm.exists(),
        "failing selfhost compile should not write assembly"
    );
}

// #1270: this compile-heavy selfhost backend fixture currently exhausts the
// Windows crash retry guard when run through `typelisp run`.
#[test]
#[ignore = "#1270: selfhost backend driver fixture segfaults on Windows"]
fn selfhost_backend_windows_driver_primitives_emit_assemble_link_and_run() {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let work_dir = manifest_dir
        .join("target")
        .join("windows-native-tests")
        .join("selfhost_backend_driver_primitives");
    fs::create_dir_all(&work_dir).expect("create selfhost Windows driver primitive test dir");
    let _runtime_fixture_path = copy_selfhost_tl_sources(&manifest_dir, &work_dir);
    let fixture_path = work_dir
        .join("selfhost")
        .join("compiler_backend_windows_driver_fixture.tl");

    let asm_path = work_dir.join("driver_primitives.s");
    let obj_path = work_dir.join("driver_primitives.obj");
    let bin_path = work_dir.join("driver_primitives.exe");
    let input_path = work_dir.join("input.txt");
    let output_path = work_dir.join("output.txt");
    fs::write(&input_path, "41").expect("write Windows driver primitive input");
    let _ = fs::remove_file(&output_path);

    let output = run_native_with_crash_retry(|| {
        Command::new(env!("CARGO_BIN_EXE_typelisp"))
            .arg("run")
            .arg(&fixture_path)
            .arg("--target")
            .arg("windows-x86_64")
            .arg("--")
            .arg(&asm_path)
            .output()
            .expect("run selfhost backend driver primitive fixture for Windows target")
    });
    assert_eq!(
        output.status.code(),
        Some(0),
        "selfhost Windows driver primitive fixture failed\nstdout:\n{}\nstderr:\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );

    let asm = fs::read_to_string(&asm_path)
        .expect("read selfhost Windows driver primitive assembly")
        .replace("\r\n", "\n")
        .replace('\r', "\n");
    for snippet in [
        ".globl main\n",
        ".L_tl_arg_count:\n",
        ".L_tl_arg:\n",
        ".L_tl_read_file:\n",
        ".L_tl_write_file:\n",
        ".L_tl_file_exists:\n",
        "tl_print_err:\n",
        "tl_string_eq:\n",
        "tl_string_to_int:\n",
        "tl_int_to_string:\n",
        "    movq %rcx, .L_tl_argc(%rip)\n",
        "    movq %rdx, .L_tl_argv(%rip)\n",
        "    .extern _open\n",
        "    .extern _lseeki64\n",
        "    .extern _close\n",
        "    .extern _access\n",
        "    call _open\n",
        "    call _lseeki64\n",
        "    call _read\n",
        "    call _write\n",
        "    call _close\n",
        "    call _access\n",
    ] {
        assert!(
            asm.contains(snippet),
            "selfhost Windows driver primitive assembly missing {:?}:\n{}",
            snippet,
            asm
        );
    }
    assert!(!asm.contains("    syscall"), "asm:\n{}", asm);
    assert!(!asm.contains("\n_start:"), "asm:\n{}", asm);
    for helper in [
        ".extern .L_tl_arg_count\n",
        ".extern .L_tl_arg\n",
        ".extern .L_tl_read_file\n",
        ".extern .L_tl_write_file\n",
        ".extern .L_tl_file_exists\n",
        ".extern tl_print_err\n",
        ".extern tl_string_eq\n",
        ".extern tl_string_to_int\n",
        ".extern tl_int_to_string\n",
    ] {
        assert!(
            !asm.contains(helper),
            "runtime helper should be defined inline, not extern: {helper}\n{asm}"
        );
    }

    let status = Command::new("clang")
        .arg("--target=x86_64-pc-windows-msvc")
        .arg("-c")
        .arg(&asm_path)
        .arg("-o")
        .arg(&obj_path)
        .status()
        .expect("assemble selfhost Windows driver primitive output");
    assert!(
        status.success(),
        "assembling selfhost Windows driver primitive output failed"
    );

    let status = Command::new("lld-link")
        .arg("/NOLOGO")
        .arg(&obj_path)
        .arg(format!("/OUT:{}", bin_path.display()))
        .arg("/SUBSYSTEM:CONSOLE")
        .arg("msvcrt.lib")
        .arg("legacy_stdio_definitions.lib")
        .status()
        .expect("link selfhost Windows driver primitive output");
    assert!(
        status.success(),
        "linking selfhost Windows driver primitive output failed"
    );

    let output = run_native_with_crash_retry(|| {
        Command::new(&bin_path)
            .arg(&input_path)
            .arg(&output_path)
            .output()
            .expect("run selfhost Windows driver primitive binary")
    });
    assert_eq!(
        output.status.code(),
        Some(42),
        "selfhost Windows driver primitive binary exited unexpectedly\nstdout:\n{}\nstderr:\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(
        fs::read_to_string(&output_path).expect("read driver primitive output"),
        "42"
    );
    assert_eq!(String::from_utf8_lossy(&output.stderr), "ok");
}

fn copy_selfhost_tl_sources(manifest_dir: &Path, work_dir: &Path) -> PathBuf {
    let src_dir = manifest_dir.join("selfhost");
    let dst_dir = work_dir.join("selfhost");
    fs::create_dir_all(&dst_dir).expect("create isolated selfhost source dir");

    for entry in fs::read_dir(&src_dir).expect("read selfhost source dir") {
        let entry = entry.expect("read selfhost source entry");
        let path = entry.path();
        if path.extension().and_then(|ext| ext.to_str()) != Some("tl") {
            continue;
        }
        fs::copy(&path, dst_dir.join(entry.file_name())).expect("copy selfhost source file");
    }

    dst_dir.join("compiler_backend_runtime_fixture.tl")
}

fn native_cases() -> Vec<Case> {
    vec![
        case("hello", 42, ""),
        case("arithmetic", 47, ""),
        case("fixed_array", 42, ""),
        case_with_deps("format_doc_integration", 42, "", &["format_doc.tl"]),
        case_with_deps(
            "format_cst_integration",
            42,
            "",
            &["format_cst.tl", "format_tokens.tl"],
        ),
        case_with_deps(
            "format_core_integration",
            42,
            "",
            &[
                "format_core.tl",
                "format_cst.tl",
                "format_tokens.tl",
                "format_doc.tl",
            ],
        ),
        case_with_deps(
            "format_rules_integration",
            42,
            "",
            &[
                "format_rules.tl",
                "format_cst.tl",
                "format_tokens.tl",
                "format_doc.tl",
            ],
        ),
        case("factorial", 120, ""),
        case("fibonacci", 13, ""),
        case("global_initializer", 120, ""),
        case("aggregate_globals", 42, ""),
        case("control_flow", 15, ""),
        case("cond", 42, ""),
        case("spmd_foreach", 42, ""),
        case("functions", 32, ""),
        case("function_pointer_values", 42, ""),
        case("lambda_lift", 42, ""),
        case("lambda_aggregate_returns", 42, ""),
        case("print", 0, "42\nfalse\n"),
        case("print_char", 0, "A\n"),
        case("print_string", 0, "hello\nworld\n"),
        case("unit_functions", 7, ""),
        case("unit_main", 0, ""),
        case("tl_alloc", 0, ""),
        case("many_args", 36, ""),
        case("narrow_div_mod", 30, ""),
        case("overflow_casts", 0, ""),
        case("string_length", 5, ""),
        case(
            "string_eq",
            0,
            "true\ntrue\ntrue\nfalse\nfalse\ntrue\nfalse\n",
        ),
        case("string_match", 42, ""),
        case("substring", 55, ""),
        case(
            "string_append",
            0,
            "[]\nright\nleft\nfoobar\nabcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ\n",
        ),
        case_with_deps("modules_main", 30, "", &["modules_helper.tl"]),
        case("enum_match", 42, ""),
        case("tuple_values", 42, ""),
        case("nullary_variant_call", 42, ""),
        case("lexer", 12, ""),
        case("enum_string_payload", 5, ""),
        case("maybe_result", 65, ""),
        case("tree", 3, ""),
        case("parser", 14, ""),
        case_with_deps("calc", 14, "", &["token.tl"]),
        case_with_deps(
            "tl_emit",
            0,
            TL_EMIT_PROGRAM_ASM,
            &["emit_core.tl", "ast_types.tl", "sym_i64_env.tl"],
        ),
        case_with_deps(
            "tl_ast",
            685,
            "",
            &["ast_types.tl", "read.tl", "lex.tl", "token.tl"],
        ),
        case_with_deps("tl_lexer", 19, "", &["lex.tl", "token.tl"]),
        case_with_deps("tl_reader", 62, "", &["lex.tl", "token.tl"]),
        case_with_deps(
            "tl_eval",
            30,
            "hello world3233\n25\n15\n2\n10\n1\n0\n1\n3\n(1 2 3)(1 (2 3) 4)(10 . 20)(1 2 . 3)(1 4 9 16)(1 2)",
            &["read.tl", "lex.tl", "token.tl"],
        ),
        case("nested_eval", 7, ""),
        case_with_deps(
            "sym_i64_env",
            0,
            "PASS: empty-miss\nPASS: single-hit-contains\nPASS: single-hit-value\nPASS: single-miss\nPASS: shadow-newest\nPASS: outer-preserved-a\nPASS: outer-no-b\nPASS: inner-sees-a\nPASS: inner-sees-b\nPASS: substring-key-hit\nPASS: append-key-hit\nPASS: chain-x\nPASS: chain-y\nPASS: chain-z\nAll sym-i64-env tests passed.\n",
            &["sym_i64_env_core.tl"],
        ),
        case_with_deps("text_buf", 0, "left-right\n", &["text_buf_core.tl"]),
        case_with_deps(
            "stdlib_string",
            42,
            "hello|\nhello|\nhello|\nfound\n|empty-left\n|empty-right\n|all-space\ncontains\nmissing\nhippo\nabx\n",
            &["stdlib/string.tl"],
        ),
        case_with_deps("stdlib_test", 42, "", &["stdlib/test.tl"]),
        case_with_deps("stdlib_io", 42, "", &["stdlib/io.tl"]),
        case_with_deps(
            "process_runtime",
            42,
            "",
            &["stdlib/process.tl", "stdlib/test.tl"],
        ),
        case_with_deps("stdlib_text_buf", 42, "", &["stdlib/text_buf.tl"]),
        case_with_deps(
            "compiler_parse_smoke",
            42,
            "",
            &[
                "compiler_parse_core.tl",
                "compiler_ast_types.tl",
                "compiler_diagnostic.tl",
                "sym_i64_env.tl",
                "read.tl",
                "lex.tl",
                "token.tl",
            ],
        ),
        case_with_deps(
            "compiler_symbols_smoke",
            42,
            "",
            &[
                "compiler_symbols.tl",
                "compiler_parse_core.tl",
                "compiler_ast_types.tl",
                "compiler_diagnostic.tl",
                "sym_i64_env.tl",
                "read.tl",
                "lex.tl",
                "token.tl",
            ],
        ),
        case_with_deps(
            "compiler_typecheck_smoke",
            42,
            "",
            &[
                "compiler_typecheck.tl",
                "compiler_specialize.tl",
                "compiler_ctfe.tl",
                "compiler_symbols.tl",
                "compiler_parse_core.tl",
                "compiler_ast_types.tl",
                "compiler_diagnostic.tl",
                "sym_i64_env.tl",
                "read.tl",
                "lex.tl",
                "token.tl",
            ],
        ),
        case_with_deps(
            "compiler_typecheck_reflection_smoke",
            42,
            "",
            &[
                "compiler_typecheck.tl",
                "compiler_specialize.tl",
                "compiler_ctfe.tl",
                "compiler_symbols.tl",
                "compiler_parse_core.tl",
                "compiler_ast_types.tl",
                "compiler_diagnostic.tl",
                "sym_i64_env.tl",
                "read.tl",
                "lex.tl",
                "token.tl",
            ],
        ),
        case_with_deps(
            "compiler_specialize_smoke",
            42,
            "",
            &[
                "compiler_specialize.tl",
                "compiler_ctfe.tl",
                "compiler_parse_core.tl",
                "compiler_ast_types.tl",
                "compiler_diagnostic.tl",
                "sym_i64_env.tl",
                "read.tl",
                "lex.tl",
                "token.tl",
            ],
        ),
        case_with_deps(
            "compiler_check_smoke",
            42,
            "",
            &[
                "compiler_check_core.tl",
                "compiler_load.tl",
                "compiler_typecheck.tl",
                "compiler_specialize.tl",
                "compiler_ctfe.tl",
                "compiler_symbols.tl",
                "compiler_parse_core.tl",
                "compiler_ast_types.tl",
                "compiler_diagnostic.tl",
                "sym_i64_env.tl",
                "read.tl",
                "lex.tl",
                "token.tl",
            ],
        ),
        case_with_deps(
            "compiler_lower_smoke",
            42,
            "",
            &[
                "compiler_lower.tl",
                "compiler_ctfe.tl",
                "compiler_specialize.tl",
                "compiler_typecheck.tl",
                "compiler_ir_types.tl",
                "compiler_symbols.tl",
                "compiler_parse_core.tl",
                "compiler_ast_types.tl",
                "compiler_diagnostic.tl",
                "sym_i64_env.tl",
                "read.tl",
                "lex.tl",
                "token.tl",
            ],
        ),
        case_with_deps(
            "compiler_liveness_smoke",
            42,
            "",
            &[
                "compiler_liveness.tl",
                "compiler_ir_types.tl",
                "compiler_ast_types.tl",
            ],
        ),
        case_with_deps(
            "compiler_backend_smoke",
            42,
            "",
            &[
                "compiler_backend.tl",
                "compiler_backend_tests.tl",
                "compiler_optimize.tl",
                "compiler_regalloc.tl",
                "compiler_liveness.tl",
                "compiler_lower.tl",
                "compiler_ctfe.tl",
                "compiler_specialize.tl",
                "compiler_typecheck.tl",
                "compiler_ir_types.tl",
                "compiler_symbols.tl",
                "compiler_parse_core.tl",
                "compiler_ast_types.tl",
                "compiler_diagnostic.tl",
                "sym_i64_env.tl",
                "read.tl",
                "lex.tl",
                "token.tl",
                "text_buf.tl",
            ],
        ),
        case_with_deps(
            "doc_extract_smoke",
            42,
            "",
            &["doc_extract.tl", "format_tokens.tl"],
        ),
        case_with_deps(
            "doc_test_smoke",
            42,
            "",
            &[
                "doc_test.tl",
                "build_run_core.tl",
                "compiler_driver_core.tl",
                "compiler_backend.tl",
                "compiler_optimize.tl",
                "compiler_regalloc.tl",
                "compiler_liveness.tl",
                "compiler_lower.tl",
                "compiler_check_core.tl",
                "compiler_load.tl",
                "compiler_typecheck.tl",
                "compiler_specialize.tl",
                "compiler_ctfe.tl",
                "compiler_ir_types.tl",
                "compiler_symbols.tl",
                "compiler_parse_core.tl",
                "compiler_ast_types.tl",
                "compiler_diagnostic.tl",
                "sym_i64_env.tl",
                "text_buf.tl",
                "read.tl",
                "lex.tl",
                "token.tl",
                "stdlib/fs.tl",
                "stdlib/env.tl",
                "stdlib/io.tl",
                "stdlib/string.tl",
                "stdlib/process.tl",
            ],
        ),
        case_with_deps(
            "doc_render_smoke",
            42,
            "",
            &["doc_render.tl", "doc_extract.tl", "format_tokens.tl"],
        ),
        case_with_deps(
            "doc_html_smoke",
            42,
            "",
            &[
                "doc_html.tl",
                "doc_render.tl",
                "doc_extract.tl",
                "format_tokens.tl",
            ],
        ),
        case_with_args("argv", 7, "alpha\n", &["alpha", "beta"]),
        // refs #538: fixtures mirrored from tests/integration.rs so the Windows
        // native suite tracks the Linux integration suite. Exit codes/deps match
        // the corresponding `Case` in integration.rs. (`with_arena_*` stay
        // Linux-only by design — region reclaim is linux-x86_64 System V only.)
        case("comptime_scalar", 3, ""),
        case("f32_scalar", 42, ""),
        case("spmd_reduce_scalar", 42, ""),
        case("lambda_capture_scalar", 42, ""),
        case("lambda_capture_tuple", 42, ""),
        case("lambda_capture_aggregate", 42, ""),
        case("lambda_capture_struct_enum", 42, ""),
        case("lambda_capture_nested_aggregate", 42, ""),
        case("lambda_capture_fixed_array", 42, ""),
        case("lambda_capture_fixed_array_aggregate", 42, ""),
        case_with_deps("lex_span_smoke", 42, "", &["lex.tl", "token.tl"]),
        case_with_deps(
            "compiler_optimize_smoke",
            42,
            "",
            &[
                "compiler_optimize.tl",
                "compiler_ir_types.tl",
                "compiler_ast_types.tl",
            ],
        ),
        case_with_deps(
            "compiler_regalloc_smoke",
            42,
            "",
            &[
                "compiler_regalloc.tl",
                "compiler_liveness.tl",
                "compiler_ir_types.tl",
                "compiler_ast_types.tl",
            ],
        ),
    ]
}

fn case(name: &'static str, exit_code: i32, stdout: &'static str) -> Case {
    Case {
        name,
        exit_code,
        stdout,
        deps: &[],
        args: &[],
    }
}

fn case_with_deps(
    name: &'static str,
    exit_code: i32,
    stdout: &'static str,
    deps: &'static [&'static str],
) -> Case {
    Case {
        name,
        exit_code,
        stdout,
        deps,
        args: &[],
    }
}

fn case_with_args(
    name: &'static str,
    exit_code: i32,
    stdout: &'static str,
    args: &'static [&'static str],
) -> Case {
    Case {
        name,
        exit_code,
        stdout,
        deps: &[],
        args,
    }
}

fn run_case(case: &Case) {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let source_path = source_path_for_case(&manifest_dir, case.name);
    let work_dir = case_work_dir(&manifest_dir, case);
    fs::create_dir_all(&work_dir).expect("create Windows native test work dir");
    let work_path = work_dir.join(format!("{}.tl", case.name));
    copy_tl_source(&source_path, &work_path);

    let source_dir = source_path.parent().expect("case source path has parent");
    copy_case_deps(&manifest_dir, source_dir, &work_dir, case.deps);

    let output = run_native_with_crash_retry(|| {
        Command::new(env!("CARGO_BIN_EXE_typelisp"))
            .arg("run")
            .arg(&work_path)
            .arg("--target")
            .arg("windows-x86_64")
            .args(case.args)
            .output()
            .expect("run typelisp Windows native case")
    });

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert_eq!(
        output.status.code(),
        Some(case.exit_code),
        "{} exited unexpectedly\nstdout:\n{}\nstderr:\n{}",
        case.name,
        stdout,
        stderr,
    );
    let expected_stdout = case.stdout.replace('\n', "\r\n");
    assert_eq!(
        stdout, expected_stdout,
        "{} stdout differed\nstderr:\n{}",
        case.name, stderr,
    );
    assert_eq!(stderr, "", "{} wrote stderr", case.name);
}

fn case_work_dir(manifest_dir: &Path, case: &Case) -> PathBuf {
    let case_dir = manifest_dir
        .join("target")
        .join("windows-native-tests")
        .join(case.name);
    if case.deps.iter().any(|dep| *dep == "build_run_core.tl") {
        case_dir.join("selfhost")
    } else {
        case_dir
    }
}

fn source_path_for_case(manifest_dir: &Path, name: &str) -> PathBuf {
    let integration_path = manifest_dir
        .join("tests")
        .join("integration")
        .join(format!("{name}.tl"));
    if integration_path.exists() {
        return integration_path;
    }

    let selfhost_file = match name {
        "tl_ast" => "ast.tl",
        "tl_emit" => "emit.tl",
        "tl_eval" => "eval.tl",
        "tl_lexer" => "lexer.tl",
        "tl_reader" => "reader.tl",
        "compiler_parse_smoke" => "compiler_parse_smoke.tl",
        "compiler_symbols_smoke" => "compiler_symbols_smoke.tl",
        "compiler_typecheck_smoke" => "compiler_typecheck_smoke.tl",
        "compiler_typecheck_reflection_smoke" => "compiler_typecheck_reflection_smoke.tl",
        "compiler_specialize_smoke" => "compiler_specialize_smoke.tl",
        "compiler_check_smoke" => "compiler_check_smoke.tl",
        "compiler_lower_smoke" => "compiler_lower_smoke.tl",
        "compiler_liveness_smoke" => "compiler_liveness_smoke.tl",
        "compiler_optimize_smoke" => "compiler_optimize_smoke.tl",
        "compiler_regalloc_smoke" => "compiler_regalloc_smoke.tl",
        "compiler_backend_smoke" => "compiler_backend_smoke.tl",
        "lex_span_smoke" => "lex_span_smoke.tl",
        "doc_extract_smoke" => "doc_extract_smoke.tl",
        "doc_test_smoke" => "doc_test_smoke.tl",
        "doc_render_smoke" => "doc_render_smoke.tl",
        "doc_html_smoke" => "doc_html_smoke.tl",
        _ => panic!("no TypeLisp source path configured for Windows native case {name}"),
    };
    manifest_dir.join("selfhost").join(selfhost_file)
}

fn dep_source_path(manifest_dir: &Path, source_dir: &Path, dep: &str) -> PathBuf {
    match dep {
        "sym_i64_env_core.tl" => manifest_dir.join("selfhost").join("sym_i64_env.tl"),
        "format_doc.tl" => manifest_dir.join("selfhost").join("format_doc.tl"),
        "format_cst.tl" => manifest_dir.join("selfhost").join("format_cst.tl"),
        "format_core.tl" => manifest_dir.join("selfhost").join("format_core.tl"),
        "format_rules.tl" => manifest_dir.join("selfhost").join("format_rules.tl"),
        "format_tokens.tl" => manifest_dir.join("selfhost").join("format_tokens.tl"),
        "text_buf_core.tl" => manifest_dir.join("selfhost").join("text_buf.tl"),
        _ if dep.starts_with("stdlib/") => manifest_dir.join(dep),
        _ => source_dir.join(dep),
    }
}

fn copy_case_deps(manifest_dir: &Path, source_dir: &Path, work_dir: &Path, deps: &[&str]) {
    for dep in deps {
        let dep_src = dep_source_path(manifest_dir, source_dir, dep);
        let dep_dst = work_dir.join(dep);
        copy_tl_source_mkdirs(&dep_src, &dep_dst);
        if dep.starts_with("stdlib/")
            && work_dir.file_name().and_then(|name| name.to_str()) == Some("selfhost")
        {
            if let Some(parent) = work_dir.parent() {
                copy_tl_source_mkdirs(&dep_src, &parent.join(dep));
            }
        }
    }
}

fn copy_tl_source_mkdirs(source: &Path, dest: &Path) {
    if let Some(parent) = dest.parent() {
        fs::create_dir_all(parent).expect("create dep work dir");
    }
    copy_tl_source(source, dest);
}

fn copy_tl_source(source: &Path, dest: &Path) {
    let text = fs::read_to_string(source)
        .unwrap_or_else(|err| panic!("read TypeLisp source {}: {}", source.display(), err));
    let normalized = text.replace("\r\n", "\n").replace('\r', "\n");
    fs::write(dest, normalized)
        .unwrap_or_else(|err| panic!("write TypeLisp source {}: {}", dest.display(), err));
}
