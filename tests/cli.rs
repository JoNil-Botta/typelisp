use std::fs;
use std::io::Write;
use std::path::PathBuf;
use std::process::{Command, Output, Stdio};
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

fn typelisp_with_stdin(args: &[&str], stdin: &str) -> Output {
    let mut child = Command::new(env!("CARGO_BIN_EXE_typelisp"))
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn typelisp CLI");

    child
        .stdin
        .as_mut()
        .expect("stdin is piped")
        .write_all(stdin.as_bytes())
        .expect("write CLI stdin");

    child.wait_with_output().expect("wait for typelisp CLI")
}

fn typelisp_with_path(args: &[&str], path: &std::path::Path) -> Output {
    Command::new(env!("CARGO_BIN_EXE_typelisp"))
        .args(args)
        .env("PATH", path)
        .output()
        .expect("run typelisp CLI")
}

fn lsp_frame(payload: &str) -> String {
    format!("Content-Length: {}\r\n\r\n{}", payload.len(), payload)
}

fn lsp_messages(output: &Output) -> Vec<String> {
    let mut messages = Vec::new();
    let bytes = &output.stdout;
    let mut offset = 0;
    while offset < bytes.len() {
        let header_end = find_bytes(&bytes[offset..], b"\r\n\r\n")
            .map(|idx| offset + idx)
            .expect("LSP output frame has header terminator");
        let header = std::str::from_utf8(&bytes[offset..header_end]).expect("header is utf-8");
        let len = header
            .lines()
            .find_map(|line| line.strip_prefix("Content-Length:"))
            .expect("LSP output has Content-Length")
            .trim()
            .parse::<usize>()
            .expect("Content-Length is numeric");
        let body_start = header_end + 4;
        let body_end = body_start + len;
        assert!(
            body_end <= bytes.len(),
            "LSP frame body exceeds output length"
        );
        messages.push(String::from_utf8(bytes[body_start..body_end].to_vec()).expect("body utf-8"));
        offset = body_end;
    }
    messages
}

fn find_bytes(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack
        .windows(needle.len())
        .position(|window| window == needle)
}

fn json_string(value: &str) -> String {
    let mut out = String::from("\"");
    for ch in value.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            ch if ch.is_control() => out.push_str(&format!("\\u{:04x}", ch as u32)),
            ch => out.push(ch),
        }
    }
    out.push('"');
    out
}

fn file_uri(path: &std::path::Path) -> String {
    let path = if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir().expect("current dir").join(path)
    };
    let text = path.to_string_lossy().replace('\\', "/");
    if cfg!(windows) {
        format!("file:///{}", percent_encode_path(&text))
    } else if text.starts_with('/') {
        format!("file://{}", percent_encode_path(&text))
    } else {
        format!("file:///{}", percent_encode_path(&text))
    }
}

fn percent_encode_path(value: &str) -> String {
    let mut out = String::new();
    for byte in value.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' | b'/' | b':' => {
                out.push(byte as char)
            }
            _ => out.push_str(&format!("%{:02X}", byte)),
        }
    }
    out
}

fn lsp_initialize(id: i64) -> String {
    format!(
        r#"{{"jsonrpc":"2.0","id":{},"method":"initialize","params":{{"capabilities":{{}}}}}}"#,
        id
    )
}

fn lsp_shutdown(id: i64) -> String {
    format!(
        r#"{{"jsonrpc":"2.0","id":{},"method":"shutdown","params":null}}"#,
        id
    )
}

fn lsp_did_open(uri: &str, text: &str) -> String {
    format!(
        r#"{{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{{"textDocument":{{"uri":{},"languageId":"typelisp","version":1,"text":{}}}}}}}"#,
        json_string(uri),
        json_string(text)
    )
}

fn lsp_did_change(uri: &str, text: &str) -> String {
    format!(
        r#"{{"jsonrpc":"2.0","method":"textDocument/didChange","params":{{"textDocument":{{"uri":{},"version":2}},"contentChanges":[{{"text":{}}}]}}}}"#,
        json_string(uri),
        json_string(text)
    )
}

fn lsp_did_close(uri: &str) -> String {
    format!(
        r#"{{"jsonrpc":"2.0","method":"textDocument/didClose","params":{{"textDocument":{{"uri":{}}}}}}}"#,
        json_string(uri)
    )
}

fn run_lsp(messages: &[String]) -> Output {
    let input = messages
        .iter()
        .map(|message| lsp_frame(message))
        .collect::<String>();
    typelisp_with_stdin(&["lsp"], &input)
}

fn write_main_source(dir: &std::path::Path) -> PathBuf {
    let source = dir.join("main.tl");
    fs::write(&source, "(define (main) : i64 42)\n").expect("write source");
    source
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
fn repl_is_listed_in_usage() {
    let output = typelisp(&["--help"]);

    assert!(output.status.success(), "stderr:\n{}", stderr(&output));
    assert!(stderr(&output).contains("typelisp repl"));
}

#[test]
fn lsp_is_listed_in_usage() {
    let output = typelisp(&["--help"]);

    assert!(output.status.success(), "stderr:\n{}", stderr(&output));
    assert!(stderr(&output).contains("typelisp lsp"));
}

#[test]
fn fmt_is_listed_in_usage() {
    let output = typelisp(&["--help"]);

    assert!(output.status.success(), "stderr:\n{}", stderr(&output));
    assert!(stderr(&output).contains("typelisp fmt"));
}

#[test]
fn lsp_initialize_shutdown_exit_over_stdio() {
    let output = run_lsp(&[
        lsp_initialize(1),
        r#"{"jsonrpc":"2.0","method":"initialized","params":{}}"#.to_string(),
        lsp_shutdown(2),
        r#"{"jsonrpc":"2.0","method":"exit"}"#.to_string(),
    ]);

    assert!(output.status.success(), "stderr:\n{}", stderr(&output));
    assert_eq!(stderr(&output), "");
    let messages = lsp_messages(&output);
    assert_eq!(messages.len(), 2, "messages: {messages:#?}");
    assert!(messages[0].contains(r#""id":1"#), "{}", messages[0]);
    assert!(
        messages[0].contains(r#""textDocumentSync":{"openClose":true,"change":1}"#),
        "{}",
        messages[0]
    );
    assert!(
        messages[1].contains(r#""id":2,"result":null"#),
        "{}",
        messages[1]
    );
}

#[test]
fn lsp_publishes_parse_and_type_diagnostics() {
    let dir = fixture_dir("lsp-diagnostics");
    let parse_uri = file_uri(&dir.join("parse_error.tl"));
    let type_uri = file_uri(&dir.join("type_error.tl"));
    let output = run_lsp(&[
        lsp_initialize(1),
        lsp_did_open(&parse_uri, "(define (main) : i64\n"),
        lsp_did_open(&type_uri, "(define (main) : i64 true)\n"),
        lsp_shutdown(2),
        r#"{"jsonrpc":"2.0","method":"exit"}"#.to_string(),
    ]);

    assert!(output.status.success(), "stderr:\n{}", stderr(&output));
    assert_eq!(stderr(&output), "");
    let messages = lsp_messages(&output);
    let parse_diag = messages
        .iter()
        .find(|message| message.contains(&parse_uri) && message.contains(r#""code":"E0100""#))
        .expect("missing parse diagnostic");
    assert!(
        parse_diag.contains("unexpected token"),
        "parse diagnostic: {parse_diag}"
    );
    let type_diag = messages
        .iter()
        .find(|message| message.contains(&type_uri) && message.contains(r#""code":"E0200""#))
        .expect("missing type diagnostic");
    assert!(
        type_diag.contains(r#""range":{"start":{"line":0,"character":"#)
            || type_diag.contains(r#""range":{"start":{"line":0,"character":0}"#),
        "type diagnostic range should be zero-based: {type_diag}"
    );
    assert!(
        type_diag.contains("expected i64"),
        "type diagnostic: {type_diag}"
    );
}

#[test]
fn lsp_clears_diagnostics_after_clean_change_and_close() {
    let dir = fixture_dir("lsp-clear");
    let uri = file_uri(&dir.join("main.tl"));
    let output = run_lsp(&[
        lsp_initialize(1),
        lsp_did_open(&uri, "(define (main) : i64 true)\n"),
        lsp_did_change(&uri, "(define (main) : i64 0)\n"),
        lsp_did_close(&uri),
        lsp_shutdown(2),
        r#"{"jsonrpc":"2.0","method":"exit"}"#.to_string(),
    ]);

    assert!(output.status.success(), "stderr:\n{}", stderr(&output));
    assert_eq!(stderr(&output), "");
    let messages = lsp_messages(&output);
    assert!(
        messages
            .iter()
            .any(|message| message.contains(&uri) && message.contains(r#""code":"E0200""#)),
        "messages: {messages:#?}"
    );
    let clears = messages
        .iter()
        .filter(|message| message.contains(&uri) && message.contains(r#""diagnostics":[]"#))
        .count();
    assert_eq!(clears, 2, "messages: {messages:#?}");
}

#[test]
fn lsp_checks_imports_relative_to_open_document() {
    let dir = fixture_dir("lsp-imports");
    fs::write(dir.join("lib.tl"), "(define imported : i64 41)\n").expect("write imported module");
    let uri = file_uri(&dir.join("main.tl"));
    let output = run_lsp(&[
        lsp_initialize(1),
        lsp_did_open(
            &uri,
            "(import \"lib.tl\")\n(define (main) : i64 imported)\n",
        ),
        lsp_shutdown(2),
        r#"{"jsonrpc":"2.0","method":"exit"}"#.to_string(),
    ]);

    assert!(output.status.success(), "stderr:\n{}", stderr(&output));
    assert_eq!(stderr(&output), "");
    let messages = lsp_messages(&output);
    assert!(
        messages
            .iter()
            .any(|message| message.contains(&uri) && message.contains(r#""diagnostics":[]"#)),
        "messages: {messages:#?}"
    );
}

#[test]
fn lsp_clears_stale_import_diagnostics_after_root_change() {
    let dir = fixture_dir("lsp-import-clear-change");
    let lib_path = dir.join("lib.tl");
    fs::write(&lib_path, "(define imported : i64 true)\n").expect("write imported module");
    let uri = file_uri(&dir.join("main.tl"));
    let lib_uri = file_uri(&lib_path);
    let output = run_lsp(&[
        lsp_initialize(1),
        lsp_did_open(&uri, "(import \"lib.tl\")\n(define (main) : i64 0)\n"),
        lsp_did_change(&uri, "(define (main) : i64 0)\n"),
        lsp_shutdown(2),
        r#"{"jsonrpc":"2.0","method":"exit"}"#.to_string(),
    ]);

    assert!(output.status.success(), "stderr:\n{}", stderr(&output));
    assert_eq!(stderr(&output), "");
    let messages = lsp_messages(&output);
    assert!(
        messages
            .iter()
            .any(|message| message.contains(&lib_uri) && message.contains(r#""code":"E0200""#)),
        "messages: {messages:#?}"
    );
    let import_clears = messages
        .iter()
        .filter(|message| message.contains(&lib_uri) && message.contains(r#""diagnostics":[]"#))
        .count();
    assert_eq!(import_clears, 1, "messages: {messages:#?}");
}

#[test]
fn lsp_clears_import_diagnostics_on_root_close() {
    let dir = fixture_dir("lsp-import-clear-close");
    let lib_path = dir.join("lib.tl");
    fs::write(&lib_path, "(define imported : i64 true)\n").expect("write imported module");
    let uri = file_uri(&dir.join("main.tl"));
    let lib_uri = file_uri(&lib_path);
    let output = run_lsp(&[
        lsp_initialize(1),
        lsp_did_open(&uri, "(import \"lib.tl\")\n(define (main) : i64 0)\n"),
        lsp_did_close(&uri),
        lsp_shutdown(2),
        r#"{"jsonrpc":"2.0","method":"exit"}"#.to_string(),
    ]);

    assert!(output.status.success(), "stderr:\n{}", stderr(&output));
    assert_eq!(stderr(&output), "");
    let messages = lsp_messages(&output);
    assert!(
        messages
            .iter()
            .any(|message| message.contains(&lib_uri) && message.contains(r#""code":"E0200""#)),
        "messages: {messages:#?}"
    );
    let import_clears = messages
        .iter()
        .filter(|message| message.contains(&lib_uri) && message.contains(r#""diagnostics":[]"#))
        .count();
    assert_eq!(import_clears, 1, "messages: {messages:#?}");
}

#[test]
fn lsp_keeps_shared_import_diagnostics_after_one_root_change() {
    let dir = fixture_dir("lsp-import-clear-shared");
    let lib_path = dir.join("lib.tl");
    fs::write(&lib_path, "(define imported : i64 true)\n").expect("write imported module");
    let root_a_uri = file_uri(&dir.join("main_a.tl"));
    let root_b_uri = file_uri(&dir.join("main_b.tl"));
    let lib_uri = file_uri(&lib_path);
    let output = run_lsp(&[
        lsp_initialize(1),
        lsp_did_open(
            &root_a_uri,
            "(import \"lib.tl\")\n(define (main) : i64 0)\n",
        ),
        lsp_did_open(
            &root_b_uri,
            "(import \"lib.tl\")\n(define (main) : i64 0)\n",
        ),
        lsp_did_change(&root_a_uri, "(define (main) : i64 0)\n"),
        lsp_shutdown(2),
        r#"{"jsonrpc":"2.0","method":"exit"}"#.to_string(),
    ]);

    assert!(output.status.success(), "stderr:\n{}", stderr(&output));
    assert_eq!(stderr(&output), "");
    let messages = lsp_messages(&output);
    let import_diagnostics = messages
        .iter()
        .filter(|message| message.contains(&lib_uri) && message.contains(r#""code":"E0200""#))
        .count();
    assert_eq!(import_diagnostics, 2, "messages: {messages:#?}");
    let import_clears = messages
        .iter()
        .filter(|message| message.contains(&lib_uri) && message.contains(r#""diagnostics":[]"#))
        .count();
    assert_eq!(import_clears, 0, "messages: {messages:#?}");
}

#[test]
fn repl_help_and_exit_from_piped_stdin() {
    let output = typelisp_with_stdin(&["repl"], ".help\n.exit\n");

    assert!(output.status.success(), "stderr:\n{}", stderr(&output));
    assert_eq!(stderr(&output), "");
    let stdout = stdout(&output);
    assert!(
        stdout.contains("TypeLisp REPL commands:"),
        "stdout:\n{}",
        stdout
    );
    assert!(stdout.contains(".help"), "stdout:\n{}", stdout);
    assert!(stdout.contains(".exit"), "stdout:\n{}", stdout);
}

#[test]
fn repl_eof_exits_cleanly() {
    let output = typelisp_with_stdin(&["repl"], "");

    assert!(output.status.success(), "stderr:\n{}", stderr(&output));
    assert_eq!(stdout(&output), "");
    assert_eq!(stderr(&output), "");
}

#[test]
fn repl_unknown_dot_command_reports_and_continues() {
    let output = typelisp_with_stdin(&["repl"], ".wat\n.help\n.exit\n");

    assert!(output.status.success(), "stderr:\n{}", stderr(&output));
    assert!(stdout(&output).contains("TypeLisp REPL commands:"));
    assert!(
        stderr(&output).contains("Unknown REPL command: .wat"),
        "stderr:\n{}",
        stderr(&output)
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
fn compile_accepts_avx2_backend_mode_for_scalar_program() {
    let dir = fixture_dir("backend-mode-avx2");
    let source = write_main_source(&dir);
    let output_path = dir.join("main.s");
    let source_arg = source.to_str().expect("source path is utf-8");
    let output_arg = output_path.to_str().expect("output path is utf-8");

    let output = typelisp(&[
        "compile",
        source_arg,
        "--backend-mode",
        "avx2",
        "-o",
        output_arg,
    ]);

    assert!(output.status.success(), "stderr:\n{}", stderr(&output));
    assert_eq!(stderr(&output), "");
    let asm = fs::read_to_string(&output_path).expect("read assembly");
    assert!(asm.contains("main:"), "assembly:\n{}", asm);
    assert!(asm.contains("vzeroupper"), "assembly:\n{}", asm);
}

#[test]
fn compile_accepts_windows_target_aliases() {
    for target in ["windows-x86_64", "windows_x86_64"] {
        let dir = fixture_dir(&format!("target-{target}"));
        let source = dir.join("main.tl");
        fs::write(
            &source,
            r#"(define (main) : i64
  (begin
    (print-string "hi")
    42))
"#,
        )
        .expect("write source");
        let output_path = dir.join("main.s");
        let source_arg = source.to_str().expect("source path is utf-8");
        let output_arg = output_path.to_str().expect("output path is utf-8");

        let output = typelisp(&["compile", source_arg, "--target", target, "-o", output_arg]);

        assert!(
            output.status.success(),
            "{target} failed\nstdout:\n{}\nstderr:\n{}",
            stdout(&output),
            stderr(&output)
        );
        assert_eq!(stderr(&output), "", "{target} stderr");
        let asm = fs::read_to_string(&output_path).expect("read assembly");
        assert!(
            asm.contains("    .globl main"),
            "{target} assembly:\n{}",
            asm
        );
        assert!(
            !asm.contains("    .globl _start"),
            "{target} assembly:\n{}",
            asm
        );
        assert!(
            asm.contains("    .extern _write"),
            "{target} assembly:\n{}",
            asm
        );
        assert!(
            asm.contains("    sub $32, %rsp"),
            "{target} assembly:\n{}",
            asm
        );
    }
}

#[test]
fn target_flags_reject_unknown_target_across_commands() {
    let dir = fixture_dir("target-unknown");
    let source = write_main_source(&dir);
    let source_arg = source.to_str().expect("source path is utf-8");

    for args in [
        vec!["compile", source_arg, "--target", "plan9-x86_64"],
        vec!["build", source_arg, "--target", "plan9-x86_64"],
        vec!["run", source_arg, "--target", "plan9-x86_64"],
    ] {
        let output = typelisp(&args);

        assert!(
            !output.status.success(),
            "{args:?} unexpectedly succeeded\nstdout:\n{}\nstderr:\n{}",
            stdout(&output),
            stderr(&output)
        );
        assert_eq!(stdout(&output), "", "{args:?} wrote stdout");
        assert!(
            stderr(&output).contains(
                "Error: unknown target 'plan9-x86_64'. Expected linux-x86_64 or windows-x86_64"
            ),
            "{args:?} stderr:\n{}",
            stderr(&output)
        );
    }
}

#[test]
fn compile_accepts_implemented_backend_modes() {
    for mode in ["scalar", "avx2", "avx512"] {
        let dir = fixture_dir(&format!("backend-mode-{mode}-ok"));
        let source = write_main_source(&dir);
        let source_arg = source.to_str().expect("source path is utf-8");

        let output = typelisp(&["compile", source_arg, "--backend-mode", mode]);

        assert!(
            output.status.success(),
            "mode {mode} should succeed\nstdout:\n{}\nstderr:\n{}",
            stdout(&output),
            stderr(&output)
        );
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

#[cfg(target_os = "linux")]
#[test]
fn run_accepts_backend_mode_flag_with_avx512() {
    let dir = fixture_dir("backend-mode-run-avx512");
    let source = write_main_source(&dir);
    let source_arg = source.to_str().expect("source path is utf-8");

    let output = typelisp(&["run", source_arg, "--backend-mode", "avx512", "--", "arg"]);

    assert_eq!(
        stderr(&output),
        "",
        "avx512 run should have no errors for scalar IR"
    );
    assert_eq!(
        output.status.code(),
        Some(42),
        "avx512 run should return program exit code 42"
    );
}

#[cfg(any(target_os = "linux", target_os = "windows"))]
#[test]
fn run_forwards_child_output_and_status() {
    let dir = fixture_dir("run-forward-output");
    let source = dir.join("main.tl");
    fs::write(
        &source,
        r#"(define (main) : i64
  (begin
    (print-string "hello")
    7))
"#,
    )
    .expect("write source");
    let source_arg = source.to_str().expect("source path is utf-8");
    let mut args = vec!["run", source_arg];
    if cfg!(target_os = "windows") {
        args.push("--target");
        args.push("windows-x86_64");
    }

    let output = typelisp(&args);

    assert_eq!(
        output.status.code(),
        Some(7),
        "run exited unexpectedly\nstdout:\n{}\nstderr:\n{}",
        stdout(&output),
        stderr(&output)
    );
    assert_eq!(stdout(&output), "hello");
    assert_eq!(stderr(&output), "");
}

#[test]
fn build_accepts_backend_mode_flag_with_avx512() {
    let dir = fixture_dir("backend-mode-build-avx512");
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

    assert!(
        output.status.success(),
        "avx512 build should succeed for scalar IR\nstdout:\n{}\nstderr:\n{}",
        stdout(&output),
        stderr(&output)
    );
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
fn check_rejects_unsupported_type_kind_before_backend() {
    let dir = fixture_dir("unsupported-type-kind");
    let source = dir.join("main.tl");
    fs::write(&source, "(define (f [T : type]) : i64 0)\n").expect("write source");
    let source_arg = source.to_str().expect("source path is utf-8");

    let output = typelisp(&["check", source_arg]);

    assert!(!output.status.success());
    assert_eq!(stdout(&output), "");
    let stderr = stderr(&output);
    assert!(
        stderr.contains("unsupported type kind 'type'"),
        "stderr:\n{}",
        stderr
    );
    assert!(
        stderr.contains("comptime type values are not implemented yet"),
        "stderr:\n{}",
        stderr
    );
    assert!(
        !stderr.contains("backend:"),
        "type kind should fail before backend validation:\n{}",
        stderr
    );
}

#[test]
fn check_reports_explicit_unsupported_float_cast_diagnostic() {
    let dir = fixture_dir("unsupported-float-cast");
    let source = dir.join("main.tl");
    fs::write(&source, "(define (main) : i64 (cast 3.5 : i64))\n").expect("write source");
    let source_arg = source.to_str().expect("source path is utf-8");

    let output = typelisp(&["check", source_arg]);

    assert!(!output.status.success());
    assert_eq!(stdout(&output), "");
    let stderr = stderr(&output);
    assert!(
        stderr.contains("floating-point casts are not supported yet"),
        "stderr:\n{}",
        stderr
    );
    assert!(
        stderr.contains("casts currently support integer/char conversions only"),
        "stderr:\n{}",
        stderr
    );
    assert!(stderr.contains("got f64 -> i64"), "stderr:\n{}", stderr);
    assert!(stderr.contains("error[E0200]"), "stderr:\n{}", stderr);
}

#[cfg(target_os = "linux")]
#[test]
fn build_source_accepts_avx512_backend_mode() {
    let dir = fixture_dir("backend-mode-source-build-avx512");
    let source = write_main_source(&dir);
    let source_arg = source.to_str().expect("source path is utf-8");

    let output = typelisp(&["build", source_arg, "--backend-mode", "avx512"]);

    assert!(
        output.status.success(),
        "avx512 build source should succeed for scalar IR\nstdout:\n{}\nstderr:\n{}",
        stdout(&output),
        stderr(&output)
    );
}

#[test]
fn build_source_reports_missing_assembler_with_target_and_tool() {
    let dir = fixture_dir("build-missing-assembler");
    let empty_path = dir.join("empty-path");
    fs::create_dir_all(&empty_path).expect("create empty PATH dir");
    let source = write_main_source(&dir);
    let source_arg = source.to_str().expect("source path is utf-8");

    let output = typelisp_with_path(&["build", source_arg], &empty_path);

    assert!(!output.status.success());
    assert_eq!(stdout(&output), "");
    assert!(
        stderr(&output).contains("Error: failed to run assembler 'as' for target linux-x86_64:"),
        "stderr:\n{}",
        stderr(&output)
    );
}

#[test]
fn build_source_missing_output_value_is_error() {
    let dir = fixture_dir("build-missing-output-value");
    let source = dir.join("main.tl");
    fs::write(&source, "(define (main) : i64 42)\n").expect("write source");
    let source_arg = source.to_str().expect("source path is utf-8");

    let output = typelisp(&["build", source_arg, "-o"]);

    assert!(!output.status.success());
    assert!(stderr(&output).contains("Error: -o requires a value"));
}

#[test]
fn build_output_without_source_file_is_error() {
    let dir = fixture_dir("build-output-without-source");
    let output_arg = dir
        .join("app")
        .to_str()
        .expect("output path is utf-8")
        .to_string();

    let output = typelisp(&["build", "-o", &output_arg]);

    assert!(!output.status.success());
    assert!(stderr(&output).contains("Error: build -o requires a source file argument"));
}

#[test]
fn build_source_missing_file_reports_module_error() {
    let dir = fixture_dir("build-missing-source");
    let missing_arg = dir
        .join("missing.tl")
        .to_str()
        .expect("missing source path is utf-8")
        .to_string();

    let output = typelisp(&["build", &missing_arg]);

    assert!(!output.status.success());
    assert!(stderr(&output).contains("Error: cannot read module"));
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

#[test]
#[cfg(target_os = "linux")]
fn fmt_formats_source_files_in_place() {
    let dir = fixture_dir("fmt-in-place");
    let first = dir.join("first.tl");
    let second = dir.join("second.tl");
    let source = r#"(define (main [x : i64]) : i64 (begin (print-string "x") x))"#;
    let expected = r#"(define (main [x : i64]) : i64
  (begin
    (print-string "x")
    x))"#;
    fs::write(&first, source).expect("write first source");
    fs::write(&second, source).expect("write second source");

    let output = typelisp(&["fmt", first.to_str().unwrap(), second.to_str().unwrap()]);

    assert!(output.status.success(), "stderr:\n{}", stderr(&output));
    assert_eq!(stdout(&output), "");
    assert_eq!(stderr(&output), "");
    assert_eq!(
        fs::read_to_string(&first).expect("read first source"),
        expected
    );
    assert_eq!(
        fs::read_to_string(&second).expect("read second source"),
        expected
    );

    let check = typelisp(&["fmt", "--check", first.to_str().unwrap()]);
    assert!(check.status.success(), "stderr:\n{}", stderr(&check));
    assert_eq!(stdout(&check), "");
    assert_eq!(stderr(&check), "");
}

#[test]
#[cfg(target_os = "linux")]
fn fmt_check_reports_changes_without_writing() {
    let dir = fixture_dir("fmt-check");
    let source = dir.join("main.tl");
    let original = r#"(define (main [x : i64]) : i64 (begin (print-string "x") x))"#;
    fs::write(&source, original).expect("write source");

    let output = typelisp(&["fmt", "--check", source.to_str().unwrap()]);

    assert!(!output.status.success(), "stdout:\n{}", stdout(&output));
    assert_eq!(stdout(&output), "");
    assert!(
        stderr(&output).contains("fmt: would reformat"),
        "stderr:\n{}",
        stderr(&output)
    );
    assert_eq!(
        fs::read_to_string(&source).expect("read source after check"),
        original
    );
}

#[test]
#[cfg(target_os = "linux")]
fn doc_generates_markdown_for_source_file() {
    let dir = fixture_dir("doc-generate");
    let source = dir.join("simple.tl");
    fs::write(
        &source,
        r#";;;; Module docs.

;;; Item docs.
(define answer : i64 42)
"#,
    )
    .expect("write doc source");

    let source_arg = source.to_str().expect("source path is utf-8");
    let output = typelisp(&["doc", source_arg]);

    assert!(output.status.success(), "stderr:\n{}", stderr(&output));
    let expected_md = dir.join("simple.md");
    assert!(expected_md.is_file(), "expected output markdown file");
    let md = fs::read_to_string(&expected_md).expect("read output markdown");
    assert!(
        md.contains("Module docs."),
        "expected module docs in markdown"
    );
    assert!(md.contains("answer"), "expected item name in markdown");
    assert!(
        stdout(&output).contains("Generated:"),
        "expected success message"
    );
}

#[test]
#[cfg(target_os = "linux")]
fn doc_generates_markdown_with_custom_output() {
    let dir = fixture_dir("doc-generate-custom");
    let source = dir.join("input.tl");
    let out = dir.join("custom.md");
    fs::write(
        &source,
        r#";;; Single item.
(define x : i64 1)
"#,
    )
    .expect("write doc source");

    let output = typelisp(&["doc", source.to_str().unwrap(), "-o", out.to_str().unwrap()]);

    assert!(output.status.success(), "stderr:\n{}", stderr(&output));
    assert!(out.is_file(), "expected custom output markdown file");
    let md = fs::read_to_string(&out).expect("read output markdown");
    assert!(md.contains("x"), "expected item name in markdown");
}

#[test]
#[cfg(target_os = "linux")]
fn doc_generates_module_graph_navigation() {
    let dir = fixture_dir("doc-module-graph");
    let stdlib_root = dir.join("repo-stdlib");
    fs::create_dir_all(&stdlib_root).expect("create stdlib root");

    let local = dir.join("local.tl");
    fs::write(
        &local,
        r#";;;; Local module docs.

;;; Local answer docs.
(define local-answer : i64 7)
"#,
    )
    .expect("write local doc source");

    let stdlib = stdlib_root.join("docfixture.tl");
    fs::write(
        &stdlib,
        r#";;;; Stdlib module docs.

;;; Stdlib answer docs.
(define stdlib-answer : i64 35)
"#,
    )
    .expect("write stdlib doc source");

    let entry = dir.join("entry.tl");
    fs::write(
        &entry,
        r#";;;; Entry module docs.

(import "local.tl")
(import "local.tl")
(import "stdlib/docfixture.tl")

;;; Entry docs.
(define (main) : i64 (+ local-answer stdlib-answer))
"#,
    )
    .expect("write entry doc source");

    let out = dir.join("graph.md");
    let output = typelisp(&[
        "doc",
        entry.to_str().unwrap(),
        "-o",
        out.to_str().unwrap(),
        "--stdlib-root",
        stdlib_root.to_str().unwrap(),
    ]);

    assert!(output.status.success(), "stderr:\n{}", stderr(&output));
    let md = fs::read_to_string(&out).expect("read generated graph markdown");
    let entry_path = fs::canonicalize(&entry)
        .expect("canonicalize entry")
        .display()
        .to_string();
    let local_path = fs::canonicalize(&local)
        .expect("canonicalize local")
        .display()
        .to_string();
    let stdlib_path = fs::canonicalize(&stdlib)
        .expect("canonicalize stdlib")
        .display()
        .to_string();

    assert!(
        md.contains("## Modules"),
        "expected module navigation:\n{md}"
    );
    assert!(
        md.contains(&format!("- [{entry_path}](#")),
        "expected entry module nav link:\n{md}"
    );
    assert!(
        md.contains(&format!("Source: `{local_path}`")),
        "expected local source path:\n{md}"
    );
    assert!(
        md.contains(&format!("Source: `{stdlib_path}`")),
        "expected stdlib source path:\n{md}"
    );
    assert!(
        md.contains("Entry module docs.")
            && md.contains("Local module docs.")
            && md.contains("Stdlib module docs."),
        "expected docs from entry, local, and stdlib modules:\n{md}"
    );
    assert_eq!(
        md.matches("Local module docs.").count(),
        1,
        "repeated import should not duplicate local docs:\n{md}"
    );

    let entry_idx = md.find(&format!("## {entry_path}")).expect("entry section");
    let local_idx = md.find(&format!("## {local_path}")).expect("local section");
    let stdlib_idx = md
        .find(&format!("## {stdlib_path}"))
        .expect("stdlib section");
    assert!(
        entry_idx < local_idx && local_idx < stdlib_idx,
        "expected stable loader source order:\n{md}"
    );
}

#[test]
fn doc_generate_missing_file_shows_usage() {
    let output = typelisp(&["doc"]);
    assert!(!output.status.success(), "expected failure on missing arg");
    let stderr = stderr(&output);
    assert!(
        stderr.contains("Usage:"),
        "expected usage text in stderr, got:\n{}",
        stderr
    );
    assert!(
        stderr.contains("typelisp doc <file.tl>"),
        "expected doc usage in stderr, got:\n{}",
        stderr
    );
}

fn stdout(output: &Output) -> String {
    String::from_utf8_lossy(&output.stdout).into_owned()
}

fn stderr(output: &Output) -> String {
    String::from_utf8_lossy(&output.stderr).into_owned()
}
