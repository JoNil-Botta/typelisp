use std::env;
use std::fs;
use std::path::PathBuf;
use std::process::Command;

mod ast;
mod backend;
mod diagnostic;
mod ir;
mod lexer;
mod lower;
mod module;
mod optimizer;
mod parser;
mod runtime;
mod span;
mod typechecker;
mod types;

use ast::Program;
use backend::generate_assembly;
use diagnostic::format_diagnostic;
use lower::lower_program;
use module::{FsSource, LoadError, load_program};
use optimizer::Optimizer;
use parser::parse;
use typechecker::TypeChecker;

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

fn typecheck_or_exit(prog: &Program, source: &str, file: &str) {
    let mut tc = TypeChecker::new();
    if let Err(e) = tc.check_program(prog) {
        eprint!("{}", format_diagnostic(&e.to_diagnostic(), source, file));
        std::process::exit(1);
    }
}

/// Load the module graph rooted at `entry`, concatenating all imported modules
/// into one `Program`, or print a diagnostic and exit. Returns the combined
/// program plus the entry module's `(path, source)` for downstream diagnostics.
///
/// Cross-module diagnostics (a type error pointing at the right *imported*
/// file) are deferred to a later chunk (`file_id` on `Span`); the typecheck
/// stage currently renders against the entry source. Parse errors, however,
/// already point at the correct module because the loader carries the failing
/// module's path + source.
fn load_or_exit(entry: &PathBuf) -> (Program, String) {
    match load_program(entry, &FsSource) {
        Ok((prog, _entry_canon)) => {
            let entry_source = fs::read_to_string(entry).expect("Failed to read file");
            (prog, entry_source)
        }
        Err(LoadError::Io { path, source }) => {
            eprintln!("Error: cannot read module '{}': {}", path.display(), source);
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
    eprintln!("    typelisp tokenize <file.tl>    Show tokens");
    eprintln!("    typelisp parse <file.tl>       Show AST");
    eprintln!("    typelisp check <file.tl>       Type check");
    eprintln!("    typelisp compile <file.tl>     Generate assembly");
    eprintln!("    typelisp run <file.tl>         Compile and execute");
    eprintln!();
    eprintln!("    --emit-ir                      Emit intermediate representation");
    eprintln!();
    eprintln!("Options for compile:");
    eprintln!("    -o <file>                      Output assembly file");
    eprintln!();
    eprintln!("No third-party dependencies. Built with std only.");
}

fn main() {
    let args: Vec<String> = env::args().collect();

    if args.len() < 2 {
        print_usage();
        std::process::exit(1);
    }

    let command = &args[1];

    match command.as_str() {
        "tokenize" => {
            if args.len() < 3 {
                eprintln!("Error: missing file argument");
                print_usage();
                std::process::exit(1);
            }
            let file = PathBuf::from(&args[2]);
            let source = fs::read_to_string(&file).expect("Failed to read file");
            let mut lexer = lexer::Lexer::new(&source);
            let tokens = lexer.tokenize().expect("Lexing failed");
            for tok in tokens {
                println!("{}", tok);
            }
        }
        "parse" => {
            if args.len() < 3 {
                eprintln!("Error: missing file argument");
                print_usage();
                std::process::exit(1);
            }
            let file = PathBuf::from(&args[2]);
            let source = fs::read_to_string(&file).expect("Failed to read file");
            let prog = parse_or_exit(&source, &file.display().to_string());
            println!("{:#?}", prog);
        }
        "check" => {
            if args.len() < 3 {
                eprintln!("Error: missing file argument");
                print_usage();
                std::process::exit(1);
            }
            let file = PathBuf::from(&args[2]);
            let (prog, source) = load_or_exit(&file);
            typecheck_or_exit(&prog, &source, &file.display().to_string());
            println!("Type checking passed!");
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

            // Parse -o and --emit-ir flags
            let mut i = 3;
            while i < args.len() {
                if args[i] == "-o" && i + 1 < args.len() {
                    output = Some(PathBuf::from(&args[i + 1]));
                    i += 2;
                } else if args[i] == "--emit-ir" {
                    emit_ir = true;
                    i += 1;
                } else {
                    eprintln!("Warning: unknown flag: {}", args[i]);
                    i += 1;
                }
            }

            let (prog, source) = load_or_exit(&file);
            typecheck_or_exit(&prog, &source, &file.display().to_string());

            if emit_ir {
                let mut ir_prog = lower_program(&prog);
                Optimizer::optimize(&mut ir_prog);
                let ir_text = format!("{:#?}", ir_prog);
                let output_path = output.unwrap_or_else(|| file.with_extension("ir"));
                fs::write(&output_path, ir_text).expect("Failed to write output");
                println!("Generated: {}", output_path.display());
            } else {
                let mut ir_prog = lower_program(&prog);
                Optimizer::optimize(&mut ir_prog);
                let asm = match generate_assembly(&ir_prog) {
                    Ok(asm) => asm,
                    Err(e) => {
                        eprintln!("Error: {}", e);
                        std::process::exit(1);
                    }
                };
                let output_path = output.unwrap_or_else(|| file.with_extension("s"));
                fs::write(&output_path, asm).expect("Failed to write output");
                println!("Generated: {}", output_path.display());
            }
        }
        "run" => {
            if args.len() < 3 {
                eprintln!("Error: missing file argument");
                print_usage();
                std::process::exit(1);
            }
            let file = PathBuf::from(&args[2]);
            let (prog, source) = load_or_exit(&file);
            typecheck_or_exit(&prog, &source, &file.display().to_string());

            let mut ir_prog = lower_program(&prog);
            Optimizer::optimize(&mut ir_prog);
            let asm = match generate_assembly(&ir_prog) {
                Ok(asm) => asm,
                Err(e) => {
                    eprintln!("Error: {}", e);
                    std::process::exit(1);
                }
            };
            let asm_path = file.with_extension("s");
            fs::write(&asm_path, asm).expect("Failed to write assembly");

            let obj_path = file.with_extension("o");
            let bin_path = file.with_extension("");

            // Assemble
            let status = Command::new("as")
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
            let status = Command::new("ld")
                .arg(&obj_path)
                .arg("-o")
                .arg(&bin_path)
                .arg("-dynamic-linker")
                .arg("/lib64/ld-linux-x86-64.so.2")
                .arg("-lc")
                .status()
                .expect("Failed to run linker");
            if !status.success() {
                eprintln!("Linking failed");
                std::process::exit(1);
            }

            // Run
            let status = Command::new(&bin_path)
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
