use std::env;
use std::fs;
use std::path::PathBuf;
use std::process::Command;

mod ast;
mod backend;
mod ir;
mod lexer;
mod optimizer;
mod parser;
mod runtime;
mod typechecker;
mod types;

use parser::parse;
use typechecker::TypeChecker;

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
            let prog = parse(&source).expect("Parsing failed");
            println!("{:#?}", prog);
        }
        "check" => {
            if args.len() < 3 {
                eprintln!("Error: missing file argument");
                print_usage();
                std::process::exit(1);
            }
            let file = PathBuf::from(&args[2]);
            let source = fs::read_to_string(&file).expect("Failed to read file");
            let prog = parse(&source).expect("Parsing failed");
            let mut tc = TypeChecker::new();
            match tc.check_program(&prog) {
                Ok(()) => println!("Type checking passed!"),
                Err(e) => {
                    eprintln!("Type error: {}", e);
                    std::process::exit(1);
                }
            }
        }
        "compile" => {
            if args.len() < 3 {
                eprintln!("Error: missing file argument");
                print_usage();
                std::process::exit(1);
            }
            let file = PathBuf::from(&args[2]);
            let mut output = None;

            // Parse -o flag
            let mut i = 3;
            while i < args.len() {
                if args[i] == "-o" && i + 1 < args.len() {
                    output = Some(PathBuf::from(&args[i + 1]));
                    i += 2;
                } else {
                    eprintln!("Warning: unknown flag: {}", args[i]);
                    i += 1;
                }
            }

            let source = fs::read_to_string(&file).expect("Failed to read file");
            let prog = parse(&source).expect("Parsing failed");
            let mut tc = TypeChecker::new();
            tc.check_program(&prog).expect("Type checking failed");

            let asm = generate_placeholder_asm(&prog);

            let output_path = output.unwrap_or_else(|| file.with_extension("s"));
            fs::write(&output_path, asm).expect("Failed to write output");
            println!("Generated: {}", output_path.display());
        }
        "run" => {
            if args.len() < 3 {
                eprintln!("Error: missing file argument");
                print_usage();
                std::process::exit(1);
            }
            let file = PathBuf::from(&args[2]);
            let source = fs::read_to_string(&file).expect("Failed to read file");
            let prog = parse(&source).expect("Parsing failed");
            let mut tc = TypeChecker::new();
            tc.check_program(&prog).expect("Type checking failed");

            let asm = generate_placeholder_asm(&prog);
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

fn generate_placeholder_asm(prog: &ast::Program) -> String {
    let mut asm = String::new();
    asm.push_str("    .text\n");
    asm.push_str("    .globl main\n\n");

    // Check if there's a main function defined
    let has_main = prog
        .decls
        .iter()
        .any(|d| matches!(d, ast::Decl::DefFn { name, .. } if name == "main"));

    if has_main {
        asm.push_str("    # TODO: Call user-defined main\n");
    }

    asm.push_str("main:\n");
    asm.push_str("    push %rbp\n");
    asm.push_str("    mov %rsp, %rbp\n");
    asm.push_str("    xor %eax, %eax\n");
    asm.push_str("    pop %rbp\n");
    asm.push_str("    ret\n");

    asm
}
