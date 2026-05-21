use clap::{Parser, Subcommand};
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

#[derive(Parser)]
#[command(name = "typelisp")]
#[command(about = "A typed Lisp/Scheme dialect with x86_64 backend")]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Tokenize a source file
    Tokenize {
        #[arg(value_name = "FILE")]
        file: PathBuf,
    },
    /// Parse a source file and print AST
    Parse {
        #[arg(value_name = "FILE")]
        file: PathBuf,
    },
    /// Type-check a source file
    Check {
        #[arg(value_name = "FILE")]
        file: PathBuf,
    },
    /// Compile a source file to x86_64 assembly
    Compile {
        #[arg(value_name = "FILE")]
        file: PathBuf,
        /// Output assembly file
        #[arg(short, long, value_name = "OUTPUT")]
        output: Option<PathBuf>,
    },
    /// Build and run a source file
    Run {
        #[arg(value_name = "FILE")]
        file: PathBuf,
    },
}

fn main() {
    let cli = Cli::parse();

    match cli.command {
        Commands::Tokenize { file } => {
            let source = fs::read_to_string(&file).expect("Failed to read file");
            let mut lexer = lexer::Lexer::new(&source);
            let tokens = lexer.tokenize().expect("Lexing failed");
            for tok in tokens {
                println!("{}", tok);
            }
        }
        Commands::Parse { file } => {
            let source = fs::read_to_string(&file).expect("Failed to read file");
            let prog = parse(&source).expect("Parsing failed");
            println!("{:#?}", prog);
        }
        Commands::Check { file } => {
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
        Commands::Compile { file, output } => {
            let source = fs::read_to_string(&file).expect("Failed to read file");
            let prog = parse(&source).expect("Parsing failed");
            let mut tc = TypeChecker::new();
            tc.check_program(&prog).expect("Type checking failed");

            // TODO: Lower AST to IR, optimize, then generate assembly
            // For now, generate a placeholder
            let asm = generate_placeholder_asm(&prog);

            let output_path = output.unwrap_or_else(|| file.with_extension("s"));
            fs::write(&output_path, asm).expect("Failed to write output");
            println!("Generated: {}", output_path.display());
        }
        Commands::Run { file } => {
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
    }
}

fn generate_placeholder_asm(prog: &ast::Program) -> String {
    let mut asm = String::new();
    asm.push_str("    .text\n");
    asm.push_str("    .globl main\n\n");

    // Generate simple main that returns 0
    // TODO: Actually lower the AST to IR and generate real code
    asm.push_str("main:\n");
    asm.push_str("    push %rbp\n");
    asm.push_str("    mov %rsp, %rbp\n");

    // Check if there's a main function defined
    let has_main = prog.decls.iter().any(|d| matches!(d, ast::Decl::DefFn { name, .. } if name == "main"));

    if has_main {
        asm.push_str("    # TODO: Call user-defined main\n");
    }

    asm.push_str("    xor %eax, %eax\n");
    asm.push_str("    pop %rbp\n");
    asm.push_str("    ret\n");

    asm
}
