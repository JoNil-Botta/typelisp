use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

mod ast;
mod backend;
mod diagnostic;
mod ir;
mod lexer;
mod lower;
mod module;
mod optimizer;
mod package;
mod parser;
mod runtime;
mod span;
mod typechecker;
mod types;

use ast::Program;
use backend::{BackendTarget, generate_assembly_with_spans};
use diagnostic::format_diagnostic;
use lower::{LoweredProgram, lower_program_with_spans};
use module::{
    FsSource, LoadError, LoadOptions, LoadedProgram, SourceFile, load_program,
    load_program_with_options,
};
use optimizer::Optimizer;
use package::{PackageError, discover_manifest, load_manifest};
use parser::parse;
use typechecker::TypeChecker;

const TYPELISP_STDLIB_ROOT_ENV: &str = "TYPELISP_STDLIB_ROOT";

/// Parse `source`, or print a located diagnostic (file:line:col with a source
/// snippet and caret) and exit. `file` is used for the diagnostic header.
fn parse_or_exit(source: &str, file: &str) -> Program {
    match parse(source) {
        Ok(prog) => prog,
        Err(e) => {
            eprint!("{}", format_diagnostic(&e.to_diagnostic(), source, file));
            std::process::exit(1);
        }
    }
}

fn format_diagnostic_from_sources(diag: &diagnostic::Diagnostic, sources: &[SourceFile]) -> String {
    let source = sources
        .iter()
        .find(|s| s.id == diag.span.file_id)
        .or_else(|| sources.first());

    match source {
        Some(source) => format_diagnostic(
            diag,
            &source.source_text,
            &source.path.display().to_string(),
        ),
        None => format_diagnostic(diag, "", "<unknown>"),
    }
}

fn typecheck_or_exit(prog: &Program, sources: &[SourceFile]) {
    let mut tc = TypeChecker::new();
    if let Err(e) = tc.check_program(prog) {
        eprint!(
            "{}",
            format_diagnostic_from_sources(&e.to_diagnostic(), sources)
        );
        std::process::exit(1);
    }
}

fn optimized_ir_or_exit(loaded: &LoadedProgram) -> LoweredProgram {
    typecheck_or_exit(&loaded.program, &loaded.sources);
    let mut lowered = lower_program_with_spans(&loaded.program);
    Optimizer::optimize(&mut lowered.program);
    lowered
}

fn assembly_or_exit(lowered: &LoweredProgram, sources: &[SourceFile]) -> String {
    match generate_assembly_with_spans(&lowered.program, &lowered.source_spans) {
        Ok(asm) => asm,
        Err(e) => {
            if let Some(diag) = e.to_diagnostic() {
                eprint!("{}", format_diagnostic_from_sources(&diag, sources));
            } else {
                eprintln!("Error: {}", e);
            }
            std::process::exit(1);
        }
    }
}

/// Load the module graph rooted at `entry`, concatenating all imported modules
/// into one `Program`, or print a diagnostic and exit. The returned source map
/// lets later semantic diagnostics render against the originating module.
fn load_or_exit(entry: &Path, options: &LoadOptions) -> LoadedProgram {
    let loaded = if options.stdlib_roots.is_empty() && options.package_roots.is_empty() {
        load_program(entry, &FsSource)
    } else {
        load_program_with_options(entry, &FsSource, options)
    };
    match loaded {
        Ok(loaded) => loaded,
        Err(LoadError::Io { path, source }) => {
            eprintln!("Error: cannot read module '{}': {}", path.display(), source);
            std::process::exit(1);
        }
        Err(err @ LoadError::ImportIo { .. }) => {
            eprintln!("Error: {}", err);
            std::process::exit(1);
        }
        Err(err @ LoadError::PackageImportAliasNotFound { .. }) => {
            eprintln!("Error: {}", err);
            std::process::exit(1);
        }
        Err(err @ LoadError::PackageImportInvalid { .. }) => {
            eprintln!("Error: {}", err);
            std::process::exit(1);
        }
        Err(LoadError::Parse {
            path,
            source_text,
            error,
        }) => {
            eprint!(
                "{}",
                format_diagnostic(
                    &error.to_diagnostic(),
                    &source_text,
                    &path.display().to_string()
                )
            );
            std::process::exit(1);
        }
    }
}

fn print_usage() {
    eprintln!("typelisp — A typed Lisp/Scheme dialect with x86_64 backend");
    eprintln!();
    eprintln!("Usage:");
    eprintln!("    typelisp debug tokenize <file.tl>    Show tokens");
    eprintln!("    typelisp debug parse <file.tl>       Show AST");
    eprintln!("    typelisp debug check <file.tl> [--stdlib-root <dir>...]");
    eprintln!("    typelisp compile <file.tl> [-o <file>] [--emit-ir] [--stdlib-root <dir>...]");
    eprintln!("    typelisp run <file.tl> [--stdlib-root <dir>...] [-- args...]");
    eprintln!("    typelisp build [--manifest-path <typelisp.pkg>] [--stdlib-root <dir>...]");
    eprintln!();
    eprintln!("Compatibility aliases:");
    eprintln!("    typelisp tokenize <file.tl>");
    eprintln!("    typelisp parse <file.tl>");
    eprintln!("    typelisp check <file.tl> [--stdlib-root <dir>...]");
    eprintln!();
    eprintln!("    --emit-ir                      Emit intermediate representation");
    eprintln!("    --manifest-path <file>         Package manifest for build");
    eprintln!("    --stdlib-root <dir>            Search root for stdlib/... imports");
    eprintln!("    TYPELISP_STDLIB_ROOT           Optional fallback root for stdlib/... imports");
    eprintln!();
    eprintln!("Options for compile:");
    eprintln!("    -o <file>                      Output assembly file");
    eprintln!("Options for build:");
    eprintln!("    --manifest-path <file>         Defaults to nearest typelisp.pkg upward");
}

fn print_debug_usage() {
    eprintln!("Usage:");
    eprintln!("    typelisp debug tokenize <file.tl>    Show tokens");
    eprintln!("    typelisp debug parse <file.tl>       Show AST");
    eprintln!("    typelisp debug check <file.tl> [--stdlib-root <dir>...]");
}

fn missing_option_value(option: &str) -> ! {
    eprintln!("Error: {} requires a value", option);
    std::process::exit(1);
}

fn missing_file_argument(usage: fn()) -> ! {
    eprintln!("Error: missing file argument");
    usage();
    std::process::exit(1);
}

fn command_file_arg(args: &[String], file_index: usize, usage: fn()) -> PathBuf {
    if args.len() <= file_index {
        missing_file_argument(usage);
    }
    PathBuf::from(&args[file_index])
}

fn run_tokenize_command(args: &[String], file_index: usize, usage: fn()) {
    let file = command_file_arg(args, file_index, usage);
    let source = fs::read_to_string(&file).expect("Failed to read file");
    let mut lexer = lexer::Lexer::new(&source);
    let tokens = lexer.tokenize().expect("Lexing failed");
    for tok in tokens {
        println!("{}", tok);
    }
}

fn run_parse_command(args: &[String], file_index: usize, usage: fn()) {
    let file = command_file_arg(args, file_index, usage);
    let source = fs::read_to_string(&file).expect("Failed to read file");
    let prog = parse_or_exit(&source, &file.display().to_string());
    println!("{:#?}", prog);
}

fn run_check_command(args: &[String], file_index: usize, usage: fn()) {
    let file = command_file_arg(args, file_index, usage);
    let options = parse_stdlib_roots(args, file_index + 1);
    let loaded = load_or_exit(&file, &options);
    typecheck_or_exit(&loaded.program, &loaded.sources);
    println!("Type checking passed!");
}

fn run_debug_command(args: &[String]) {
    if args.len() < 3 {
        eprintln!("Error: missing debug subcommand");
        print_debug_usage();
        std::process::exit(1);
    }

    match args[2].as_str() {
        "tokenize" => run_tokenize_command(args, 3, print_debug_usage),
        "parse" => run_parse_command(args, 3, print_debug_usage),
        "check" => run_check_command(args, 3, print_debug_usage),
        "help" | "--help" | "-h" => print_debug_usage(),
        subcommand => {
            eprintln!("Unknown debug command: {}", subcommand);
            print_debug_usage();
            std::process::exit(1);
        }
    }
}

fn load_options_with_env_stdlib_root(mut stdlib_roots: Vec<PathBuf>) -> LoadOptions {
    match env::var_os(TYPELISP_STDLIB_ROOT_ENV) {
        Some(env_root) if !env_root.as_os_str().is_empty() => {
            stdlib_roots.push(PathBuf::from(env_root));
        }
        _ => {}
    }

    LoadOptions {
        stdlib_roots,
        ..LoadOptions::default()
    }
}

fn parse_stdlib_roots(args: &[String], mut i: usize) -> LoadOptions {
    let mut stdlib_roots = Vec::new();
    while i < args.len() {
        if args[i] == "--stdlib-root" {
            if i + 1 >= args.len() {
                missing_option_value("--stdlib-root");
            }
            stdlib_roots.push(PathBuf::from(&args[i + 1]));
            i += 2;
        } else {
            eprintln!("Warning: unknown flag: {}", args[i]);
            i += 1;
        }
    }
    load_options_with_env_stdlib_root(stdlib_roots)
}

fn parse_run_options(args: &[String], mut i: usize) -> (LoadOptions, Vec<String>) {
    let mut stdlib_roots = Vec::new();
    let mut runtime_args = Vec::new();
    while i < args.len() {
        if args[i] == "--" {
            runtime_args.extend(args[i + 1..].iter().cloned());
            break;
        } else if args[i] == "--stdlib-root" {
            if i + 1 >= args.len() {
                missing_option_value("--stdlib-root");
            }
            stdlib_roots.push(PathBuf::from(&args[i + 1]));
            i += 2;
        } else {
            runtime_args.extend(args[i..].iter().cloned());
            break;
        }
    }
    (
        load_options_with_env_stdlib_root(stdlib_roots),
        runtime_args,
    )
}

fn parse_build_options(args: &[String], mut i: usize) -> (Option<PathBuf>, LoadOptions) {
    let mut manifest_path = None;
    let mut stdlib_roots = Vec::new();

    while i < args.len() {
        if args[i] == "--manifest-path" {
            if i + 1 >= args.len() {
                missing_option_value("--manifest-path");
            }
            if manifest_path.is_some() {
                eprintln!("Error: --manifest-path was provided more than once");
                std::process::exit(1);
            }
            manifest_path = Some(PathBuf::from(&args[i + 1]));
            i += 2;
        } else if args[i] == "--stdlib-root" {
            if i + 1 >= args.len() {
                missing_option_value("--stdlib-root");
            }
            stdlib_roots.push(PathBuf::from(&args[i + 1]));
            i += 2;
        } else {
            eprintln!("Error: unknown build flag: {}", args[i]);
            std::process::exit(1);
        }
    }

    (
        manifest_path,
        load_options_with_env_stdlib_root(stdlib_roots),
    )
}

fn package_or_exit<T>(result: Result<T, PackageError>) -> T {
    match result {
        Ok(value) => value,
        Err(err) => {
            eprintln!("Error: {}", err);
            std::process::exit(1);
        }
    }
}

#[cfg(target_os = "windows")]
const WINDOWS_CLI_STACK_SIZE: usize = 16 * 1024 * 1024;

#[cfg(target_os = "windows")]
fn main() {
    std::thread::Builder::new()
        .name("typelisp-cli".to_string())
        .stack_size(WINDOWS_CLI_STACK_SIZE)
        .spawn(run_cli)
        .expect("failed to spawn typelisp CLI thread")
        .join()
        .expect("typelisp CLI thread panicked");
}

#[cfg(not(target_os = "windows"))]
fn main() {
    run_cli();
}

fn run_cli() {
    let args: Vec<String> = env::args().collect();

    if args.len() < 2 {
        print_usage();
        std::process::exit(1);
    }

    let command = &args[1];

    match command.as_str() {
        "tokenize" => {
            run_tokenize_command(&args, 2, print_usage);
        }
        "parse" => {
            run_parse_command(&args, 2, print_usage);
        }
        "check" => {
            run_check_command(&args, 2, print_usage);
        }
        "debug" => {
            run_debug_command(&args);
        }
        "compile" => {
            if args.len() < 3 {
                eprintln!("Error: missing file argument");
                print_usage();
                std::process::exit(1);
            }
            let file = PathBuf::from(&args[2]);
            let mut output = None;
            let mut emit_ir = false;
            let mut stdlib_roots = Vec::new();

            // Parse compile flags.
            let mut i = 3;
            while i < args.len() {
                if args[i] == "-o" && i + 1 < args.len() {
                    output = Some(PathBuf::from(&args[i + 1]));
                    i += 2;
                } else if args[i] == "-o" {
                    missing_option_value("-o");
                } else if args[i] == "--emit-ir" {
                    emit_ir = true;
                    i += 1;
                } else if args[i] == "--stdlib-root" {
                    if i + 1 >= args.len() {
                        missing_option_value("--stdlib-root");
                    }
                    stdlib_roots.push(PathBuf::from(&args[i + 1]));
                    i += 2;
                } else {
                    eprintln!("Warning: unknown flag: {}", args[i]);
                    i += 1;
                }
            }

            let options = load_options_with_env_stdlib_root(stdlib_roots);
            let loaded = load_or_exit(&file, &options);
            let lowered = optimized_ir_or_exit(&loaded);

            if emit_ir {
                let ir_text = format!("{:#?}", lowered.program);
                let output_path = output.unwrap_or_else(|| file.with_extension("ir"));
                fs::write(&output_path, ir_text).expect("Failed to write output");
                println!("Generated: {}", output_path.display());
            } else {
                let asm = assembly_or_exit(&lowered, &loaded.sources);
                let output_path = output.unwrap_or_else(|| file.with_extension("s"));
                fs::write(&output_path, asm).expect("Failed to write output");
                println!("Generated: {}", output_path.display());
            }
        }
        "build" => {
            let (manifest_path, mut options) = parse_build_options(&args, 2);
            let manifest_path = match manifest_path {
                Some(path) => path,
                None => {
                    let cwd = env::current_dir().unwrap_or_else(|err| {
                        eprintln!("Error: cannot read current directory: {}", err);
                        std::process::exit(1);
                    });
                    package_or_exit(discover_manifest(&cwd))
                }
            };
            let manifest = package_or_exit(load_manifest(&manifest_path));
            options.package_roots = manifest.dependencies.clone();
            let loaded = load_or_exit(&manifest.entry_path(), &options);
            let lowered = optimized_ir_or_exit(&loaded);
            let asm = assembly_or_exit(&lowered, &loaded.sources);
            let output_path = manifest.output_asm_path();
            if let Some(parent) = output_path.parent() {
                fs::create_dir_all(parent).expect("Failed to create package output directory");
            }
            fs::write(&output_path, asm).expect("Failed to write package assembly");
            println!("Generated: {}", output_path.display());
        }
        "run" => {
            if args.len() < 3 {
                eprintln!("Error: missing file argument");
                print_usage();
                std::process::exit(1);
            }
            let file = PathBuf::from(&args[2]);
            let (options, runtime_args) = parse_run_options(&args, 3);
            let loaded = load_or_exit(&file, &options);
            let lowered = optimized_ir_or_exit(&loaded);
            let asm = assembly_or_exit(&lowered, &loaded.sources);
            let target = BackendTarget::default();
            let toolchain = target.toolchain();
            let asm_path = file.with_extension("s");
            fs::write(&asm_path, asm).expect("Failed to write assembly");

            let obj_path = file.with_extension("o");
            let bin_path = file.with_extension("");

            // Assemble
            let status = Command::new(toolchain.assembler)
                .arg(&asm_path)
                .arg("-o")
                .arg(&obj_path)
                .status()
                .expect("Failed to run assembler");
            if !status.success() {
                eprintln!("Assembly failed");
                std::process::exit(1);
            }

            // Link
            let mut linker = Command::new(toolchain.linker);
            linker.arg(&obj_path).arg("-o").arg(&bin_path);
            if let Some(dynamic_linker) = toolchain.dynamic_linker {
                linker.arg("-dynamic-linker").arg(dynamic_linker);
            }
            for lib in toolchain.libraries {
                linker.arg(lib);
            }
            let status = linker.status().expect("Failed to run linker");
            if !status.success() {
                eprintln!("Linking failed");
                std::process::exit(1);
            }

            // Run
            let status = Command::new(&bin_path)
                .args(&runtime_args)
                .status()
                .expect("Failed to run binary");
            std::process::exit(status.code().unwrap_or(1));
        }
        "help" | "--help" | "-h" => {
            print_usage();
        }
        _ => {
            eprintln!("Unknown command: {}", command);
            print_usage();
            std::process::exit(1);
        }
    }
}
