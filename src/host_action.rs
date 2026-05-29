//! Private v1 host-action boundary for selfhost build/run drivers.
//!
//! Selfhost CLI drivers parse commands and generate assembly in TypeLisp, but
//! faithful child-process orchestration — toolchain/PATH lookup, temporary
//! directories, child stdio forwarding, exit-status handling, and
//! target-specific assembler/linker behavior — stays in Rust (`src/native.rs`).
//! This module defines the private protocol a selfhost driver uses to hand a
//! build/run *action plan* to the Rust host for execution.
//!
//! The format is deliberately not shell- or whitespace-tokenized: every
//! variable-length value (paths, runtime args) is netstring-encoded
//! (`<decimal-byte-length>:<bytes>`), so values containing spaces, colons, or
//! newlines round-trip exactly. This is a private compiler boundary, not a
//! public TypeLisp process-spawn/env/temp-dir API.
//!
//! ## Plan grammar (v1)
//!
//! ```text
//! typelisp-host-plan v1\n
//! action <build-source|run-source|run-assembly|run-scratch-assembly>\n
//! source <netstring>\n                ; source actions only
//! assembly <netstring>\n              ; run-assembly only
//! scratch-assembly-path <netstring>\n ; run-scratch-assembly only
//! output <netstring>\n          ; build-source only, optional
//! target <linux-x86_64|windows-x86_64>\n
//! backend-mode <scalar|avx2|avx512>\n
//! opt-level <0|1|2|3>\n          ; source actions only, optional
//! stdlib-root <netstring>\n      ; repeatable, zero or more
//! runtime-arg <netstring>\n      ; run-source/run-assembly/run-scratch-assembly
//! end\n
//! ```
//!
//! A `<netstring>` is `<decimal-byte-length>:<bytes>` followed by a newline.
//! Fixed-vocabulary fields (`action`, `target`, `backend-mode`, `opt-level`)
//! are validated against their known sets. `action`, `target`, and
//! `backend-mode` are required; `source` is required for source actions,
//! `assembly` for run-assembly, and `scratch-assembly-path` for
//! run-scratch-assembly. `opt-level` is optional and accepted only by the
//! source actions; when omitted the optimizer runs (`OptLevel::DEFAULT`).
//! Directive order after the header is free.

use crate::backend::{BackendMode, BackendTarget};
use crate::module::LoadOptions;
use crate::native::{self, NativeError, NativeRunOutput, OptLevel};
use std::{fs, path::PathBuf};

const PLAN_HEADER: &str = "typelisp-host-plan v1";

/// A parsed, validated host action ready to execute through `src/native.rs`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HostActionPlan {
    BuildSource {
        source: PathBuf,
        output: Option<PathBuf>,
        target: BackendTarget,
        stdlib_roots: Vec<PathBuf>,
        opt_level: OptLevel,
    },
    RunSource {
        source: PathBuf,
        target: BackendTarget,
        stdlib_roots: Vec<PathBuf>,
        runtime_args: Vec<String>,
        opt_level: OptLevel,
    },
    RunAssembly {
        assembly: String,
        target: BackendTarget,
        runtime_args: Vec<String>,
    },
    RunScratchAssembly {
        assembly_path: PathBuf,
        target: BackendTarget,
        runtime_args: Vec<String>,
    },
}

/// The result of executing a [`HostActionPlan`].
#[derive(Debug)]
pub enum HostActionOutcome {
    /// A build plan produced an executable at `output_path`.
    Built { output_path: PathBuf },
    /// A run plan produced child process output to forward.
    Ran(NativeRunOutput),
}

/// A malformed host-action plan. Distinct from [`NativeError`] (which is for
/// execution failures) so the CLI can report parse vs. run problems separately.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlanError {
    message: String,
}

impl PlanError {
    fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
        }
    }
}

impl std::fmt::Display for PlanError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for PlanError {}

/// Byte cursor over the plan text. Parsing is length-driven, never split on
/// whitespace, so netstring values may contain spaces/colons/newlines.
struct Cursor<'a> {
    bytes: &'a [u8],
    pos: usize,
}

impl<'a> Cursor<'a> {
    fn new(bytes: &'a [u8]) -> Self {
        Self { bytes, pos: 0 }
    }

    fn at_end(&self) -> bool {
        self.pos >= self.bytes.len()
    }

    fn peek(&self) -> Option<u8> {
        self.bytes.get(self.pos).copied()
    }

    /// Reads up to (but not consuming) the next space or newline.
    fn read_word(&mut self) -> &'a [u8] {
        let start = self.pos;
        while let Some(b) = self.peek() {
            if b == b' ' || b == b'\r' || b == b'\n' {
                break;
            }
            self.pos += 1;
        }
        &self.bytes[start..self.pos]
    }

    /// Reads the rest of the current line, consuming the terminating newline.
    fn read_to_line_end(&mut self) -> String {
        let start = self.pos;
        while let Some(b) = self.peek() {
            if b == b'\n' {
                break;
            }
            self.pos += 1;
        }
        let end = if self.pos > start && self.bytes[self.pos - 1] == b'\r' {
            self.pos - 1
        } else {
            self.pos
        };
        let value = String::from_utf8_lossy(&self.bytes[start..end]).into_owned();
        if self.peek() == Some(b'\n') {
            self.pos += 1;
        }
        value
    }

    fn expect_space(&mut self, keyword: &str) -> Result<(), PlanError> {
        if self.peek() == Some(b' ') {
            self.pos += 1;
            Ok(())
        } else {
            Err(PlanError::new(format!(
                "host-action directive '{keyword}' requires a value"
            )))
        }
    }

    /// Reads a `<decimal-length>:<bytes>\n` netstring value.
    fn read_netstring(&mut self, keyword: &str) -> Result<String, PlanError> {
        let mut len: usize = 0;
        let mut saw_digit = false;
        while let Some(b) = self.peek() {
            if b.is_ascii_digit() {
                let digit = usize::from(b - b'0');
                len = len
                    .checked_mul(10)
                    .and_then(|v| v.checked_add(digit))
                    .ok_or_else(|| {
                        PlanError::new(format!(
                            "host-action directive '{keyword}' has an overflowing netstring length"
                        ))
                    })?;
                saw_digit = true;
                self.pos += 1;
            } else {
                break;
            }
        }
        if !saw_digit {
            return Err(PlanError::new(format!(
                "host-action directive '{keyword}' expected a netstring length"
            )));
        }
        if self.peek() != Some(b':') {
            return Err(PlanError::new(format!(
                "host-action directive '{keyword}' expected ':' after netstring length"
            )));
        }
        self.pos += 1;
        let end = self.pos.checked_add(len).filter(|e| *e <= self.bytes.len());
        let end = end.ok_or_else(|| {
            PlanError::new(format!(
                "host-action directive '{keyword}' netstring length {len} exceeds remaining input"
            ))
        })?;
        let value = std::str::from_utf8(&self.bytes[self.pos..end]).map_err(|_| {
            PlanError::new(format!(
                "host-action directive '{keyword}' netstring value is not valid UTF-8"
            ))
        })?;
        let value = value.to_string();
        self.pos = end;
        if self.peek() == Some(b'\r') {
            self.pos += 1;
        }
        if self.peek() != Some(b'\n') {
            return Err(PlanError::new(format!(
                "host-action directive '{keyword}' netstring must be terminated by a newline"
            )));
        }
        self.pos += 1;
        Ok(value)
    }
}

fn set_once<T>(slot: &mut Option<T>, value: T, keyword: &str) -> Result<(), PlanError> {
    if slot.is_some() {
        return Err(PlanError::new(format!(
            "host-action directive '{keyword}' was provided more than once"
        )));
    }
    *slot = Some(value);
    Ok(())
}

/// Parses a private host-action plan. Returns a [`PlanError`] for any
/// malformed, incomplete, or inconsistent plan.
pub fn parse_plan(text: &str) -> Result<HostActionPlan, PlanError> {
    let mut cursor = Cursor::new(text.as_bytes());
    let header = cursor.read_to_line_end();
    if header != PLAN_HEADER {
        return Err(PlanError::new(format!(
            "host-action plan must start with {PLAN_HEADER:?}, got {header:?}"
        )));
    }

    let mut action: Option<String> = None;
    let mut source: Option<PathBuf> = None;
    let mut assembly: Option<String> = None;
    let mut scratch_assembly_path: Option<PathBuf> = None;
    let mut output: Option<PathBuf> = None;
    let mut target_name: Option<String> = None;
    let mut mode_name: Option<String> = None;
    let mut opt_level_name: Option<String> = None;
    let mut stdlib_roots: Vec<PathBuf> = Vec::new();
    let mut runtime_args: Vec<String> = Vec::new();

    loop {
        if cursor.at_end() {
            return Err(PlanError::new(
                "host-action plan ended before its 'end' directive",
            ));
        }
        let keyword = String::from_utf8_lossy(cursor.read_word()).into_owned();
        match keyword.as_str() {
            "end" => {
                // `end` takes no value; consume an optional trailing newline.
                if cursor.peek() == Some(b'\r') {
                    cursor.pos += 1;
                }
                if cursor.peek() == Some(b'\n') {
                    cursor.pos += 1;
                }
                break;
            }
            "action" => {
                cursor.expect_space(&keyword)?;
                set_once(&mut action, cursor.read_to_line_end(), "action")?;
            }
            "target" => {
                cursor.expect_space(&keyword)?;
                set_once(&mut target_name, cursor.read_to_line_end(), "target")?;
            }
            "backend-mode" => {
                cursor.expect_space(&keyword)?;
                set_once(&mut mode_name, cursor.read_to_line_end(), "backend-mode")?;
            }
            "opt-level" => {
                cursor.expect_space(&keyword)?;
                set_once(&mut opt_level_name, cursor.read_to_line_end(), "opt-level")?;
            }
            "source" => {
                cursor.expect_space(&keyword)?;
                let value = cursor.read_netstring(&keyword)?;
                set_once(&mut source, PathBuf::from(value), "source")?;
            }
            "assembly" => {
                cursor.expect_space(&keyword)?;
                set_once(&mut assembly, cursor.read_netstring(&keyword)?, "assembly")?;
            }
            "scratch-assembly-path" => {
                cursor.expect_space(&keyword)?;
                let value = cursor.read_netstring(&keyword)?;
                set_once(
                    &mut scratch_assembly_path,
                    PathBuf::from(value),
                    "scratch-assembly-path",
                )?;
            }
            "output" => {
                cursor.expect_space(&keyword)?;
                let value = cursor.read_netstring(&keyword)?;
                set_once(&mut output, PathBuf::from(value), "output")?;
            }
            "stdlib-root" => {
                cursor.expect_space(&keyword)?;
                stdlib_roots.push(PathBuf::from(cursor.read_netstring(&keyword)?));
            }
            "runtime-arg" => {
                cursor.expect_space(&keyword)?;
                runtime_args.push(cursor.read_netstring(&keyword)?);
            }
            "" => {
                return Err(PlanError::new(
                    "host-action plan has an empty directive line",
                ));
            }
            other => {
                return Err(PlanError::new(format!(
                    "unknown host-action directive '{other}'"
                )));
            }
        }
    }

    // Reject trailing content so a truncated/garbled tail is not silently ignored.
    while let Some(b) = cursor.peek() {
        if b != b'\n' && b != b'\r' && b != b' ' {
            return Err(PlanError::new(
                "unexpected trailing data after 'end' directive",
            ));
        }
        cursor.pos += 1;
    }

    let action = action.ok_or_else(|| PlanError::new("host-action plan is missing 'action'"))?;
    let target_name =
        target_name.ok_or_else(|| PlanError::new("host-action plan is missing 'target'"))?;
    let mode_name =
        mode_name.ok_or_else(|| PlanError::new("host-action plan is missing 'backend-mode'"))?;

    let base_target = BackendTarget::parse(&target_name).ok_or_else(|| {
        PlanError::new(format!(
            "unknown target '{target_name}'; expected linux-x86_64 or windows-x86_64"
        ))
    })?;
    let mode = BackendMode::parse(&mode_name).ok_or_else(|| {
        PlanError::new(format!(
            "unknown backend mode '{mode_name}'; expected scalar, avx2, or avx512"
        ))
    })?;
    let target = base_target.with_mode(mode);

    // `opt-level` is optional; an omitted directive preserves the prior
    // always-optimize behavior via `OptLevel::DEFAULT`. Only source build/run
    // honor it; the assembly actions reject it below.
    let opt_level = match &opt_level_name {
        None => None,
        Some(text) => Some(
            text.parse::<u8>()
                .ok()
                .and_then(OptLevel::from_u8)
                .ok_or_else(|| {
                    PlanError::new(format!(
                        "unknown opt level '{text}'; expected 0, 1, 2, or 3"
                    ))
                })?,
        ),
    };

    match action.as_str() {
        "build-source" => {
            let source =
                source.ok_or_else(|| PlanError::new("host-action plan is missing 'source'"))?;
            if assembly.is_some() {
                return Err(PlanError::new(
                    "host-action 'build-source' does not accept an 'assembly' directive",
                ));
            }
            if scratch_assembly_path.is_some() {
                return Err(PlanError::new(
                    "host-action 'build-source' does not accept a 'scratch-assembly-path' directive",
                ));
            }
            if !runtime_args.is_empty() {
                return Err(PlanError::new(
                    "host-action 'build-source' does not accept 'runtime-arg' directives",
                ));
            }
            Ok(HostActionPlan::BuildSource {
                source,
                output,
                target,
                stdlib_roots,
                opt_level: opt_level.unwrap_or(OptLevel::DEFAULT),
            })
        }
        "run-source" => {
            let source =
                source.ok_or_else(|| PlanError::new("host-action plan is missing 'source'"))?;
            if assembly.is_some() {
                return Err(PlanError::new(
                    "host-action 'run-source' does not accept an 'assembly' directive",
                ));
            }
            if scratch_assembly_path.is_some() {
                return Err(PlanError::new(
                    "host-action 'run-source' does not accept a 'scratch-assembly-path' directive",
                ));
            }
            if output.is_some() {
                return Err(PlanError::new(
                    "host-action 'run-source' does not accept an 'output' directive",
                ));
            }
            Ok(HostActionPlan::RunSource {
                source,
                target,
                stdlib_roots,
                runtime_args,
                opt_level: opt_level.unwrap_or(OptLevel::DEFAULT),
            })
        }
        "run-assembly" => {
            if source.is_some() {
                return Err(PlanError::new(
                    "host-action 'run-assembly' does not accept a 'source' directive",
                ));
            }
            if opt_level_name.is_some() {
                return Err(PlanError::new(
                    "host-action 'run-assembly' does not accept an 'opt-level' directive",
                ));
            }
            if output.is_some() {
                return Err(PlanError::new(
                    "host-action 'run-assembly' does not accept an 'output' directive",
                ));
            }
            if !stdlib_roots.is_empty() {
                return Err(PlanError::new(
                    "host-action 'run-assembly' does not accept 'stdlib-root' directives",
                ));
            }
            let assembly =
                assembly.ok_or_else(|| PlanError::new("host-action plan is missing 'assembly'"))?;
            Ok(HostActionPlan::RunAssembly {
                assembly,
                target,
                runtime_args,
            })
        }
        "run-scratch-assembly" => {
            if source.is_some() {
                return Err(PlanError::new(
                    "host-action 'run-scratch-assembly' does not accept a 'source' directive",
                ));
            }
            if opt_level_name.is_some() {
                return Err(PlanError::new(
                    "host-action 'run-scratch-assembly' does not accept an 'opt-level' directive",
                ));
            }
            if assembly.is_some() {
                return Err(PlanError::new(
                    "host-action 'run-scratch-assembly' does not accept an 'assembly' directive",
                ));
            }
            if output.is_some() {
                return Err(PlanError::new(
                    "host-action 'run-scratch-assembly' does not accept an 'output' directive",
                ));
            }
            if !stdlib_roots.is_empty() {
                return Err(PlanError::new(
                    "host-action 'run-scratch-assembly' does not accept 'stdlib-root' directives",
                ));
            }
            let assembly_path = scratch_assembly_path.ok_or_else(|| {
                PlanError::new("host-action plan is missing 'scratch-assembly-path'")
            })?;
            Ok(HostActionPlan::RunScratchAssembly {
                assembly_path,
                target,
                runtime_args,
            })
        }
        other => Err(PlanError::new(format!(
            "unknown host action '{other}'; expected build-source, run-source, run-assembly, or run-scratch-assembly"
        ))),
    }
}

fn load_options(stdlib_roots: &[PathBuf]) -> LoadOptions {
    // The selfhost planner is responsible for resolving and including every
    // stdlib root (including any from the environment) in the plan, so the host
    // boundary does not consult the environment again. Embedded stdlib fallback
    // remains available after the explicit plan roots.
    LoadOptions {
        stdlib_roots: stdlib_roots.to_vec(),
        ..LoadOptions::default()
    }
}

/// Executes a parsed plan through the existing native build/run logic.
pub fn execute_plan(plan: &HostActionPlan) -> Result<HostActionOutcome, NativeError> {
    match plan {
        HostActionPlan::BuildSource {
            source,
            output,
            target,
            stdlib_roots,
            opt_level,
        } => {
            let options = load_options(stdlib_roots);
            let output_path = native::build_source_executable(
                source,
                &options,
                output.clone(),
                *target,
                *opt_level,
            )?;
            Ok(HostActionOutcome::Built { output_path })
        }
        HostActionPlan::RunSource {
            source,
            target,
            stdlib_roots,
            runtime_args,
            opt_level,
        } => {
            let options = load_options(stdlib_roots);
            let output =
                native::run_source_file(source, &options, runtime_args, *target, *opt_level)?;
            Ok(HostActionOutcome::Ran(output))
        }
        HostActionPlan::RunAssembly {
            assembly,
            target,
            runtime_args,
        } => {
            let output = native::run_assembly_in_temp_dir(assembly, runtime_args, *target)?;
            Ok(HostActionOutcome::Ran(output))
        }
        HostActionPlan::RunScratchAssembly {
            assembly_path,
            target,
            runtime_args,
        } => {
            let assembly = fs::read_to_string(assembly_path).map_err(|err| {
                NativeError::new(format!(
                    "Error: failed to read scratch assembly '{}': {}",
                    assembly_path.display(),
                    err
                ))
            })?;
            let _ = fs::remove_file(assembly_path);
            let output = native::run_assembly_in_temp_dir(&assembly, runtime_args, *target)?;
            Ok(HostActionOutcome::Ran(output))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::backend::{BackendMode, BackendTarget};

    fn netstring(value: &str) -> String {
        format!("{}:{}", value.len(), value)
    }

    #[test]
    fn parses_build_source_plan() {
        let plan = format!(
            "typelisp-host-plan v1\n\
             action build-source\n\
             source {}\n\
             output {}\n\
             target linux-x86_64\n\
             backend-mode scalar\n\
             end\n",
            netstring("src/main.tl"),
            netstring("build/out")
        );
        let parsed = parse_plan(&plan).expect("plan parses");
        assert_eq!(
            parsed,
            HostActionPlan::BuildSource {
                source: PathBuf::from("src/main.tl"),
                output: Some(PathBuf::from("build/out")),
                target: BackendTarget::linux_x86_64_system_v(),
                stdlib_roots: Vec::new(),
                opt_level: OptLevel::DEFAULT,
            }
        );
    }

    #[test]
    fn parses_crlf_plan_output() {
        let plan = format!(
            "typelisp-host-plan v1\r\n\
             action build-source\r\n\
             source {}\r\n\
             output {}\r\n\
             target linux-x86_64\r\n\
             backend-mode scalar\r\n\
             end\r\n",
            netstring("src/main.tl"),
            netstring("build/out")
        );
        let parsed = parse_plan(&plan).expect("CRLF plan parses");
        assert_eq!(
            parsed,
            HostActionPlan::BuildSource {
                source: PathBuf::from("src/main.tl"),
                output: Some(PathBuf::from("build/out")),
                target: BackendTarget::linux_x86_64_system_v(),
                stdlib_roots: Vec::new(),
                opt_level: OptLevel::DEFAULT,
            }
        );
    }

    #[test]
    fn parses_run_source_plan_with_mode_and_roots() {
        let plan = format!(
            "typelisp-host-plan v1\n\
             action run-source\n\
             source {}\n\
             target windows-x86_64\n\
             backend-mode avx2\n\
             stdlib-root {}\n\
             stdlib-root {}\n\
             runtime-arg {}\n\
             end\n",
            netstring("app.tl"),
            netstring("std"),
            netstring("vendor/std"),
            netstring("--name=value")
        );
        let parsed = parse_plan(&plan).expect("plan parses");
        assert_eq!(
            parsed,
            HostActionPlan::RunSource {
                source: PathBuf::from("app.tl"),
                target: BackendTarget::windows_x86_64().with_mode(BackendMode::Avx2),
                stdlib_roots: vec![PathBuf::from("std"), PathBuf::from("vendor/std")],
                runtime_args: vec!["--name=value".to_string()],
                opt_level: OptLevel::DEFAULT,
            }
        );
    }

    #[test]
    fn parses_run_assembly_plan_with_runtime_arg() {
        let asm = ".globl main\nmain:\n    movq $0, %rax\n    ret\n";
        let plan = format!(
            "typelisp-host-plan v1\n\
             action run-assembly\n\
             assembly {}\n\
             target windows-x86_64\n\
             backend-mode avx2\n\
             runtime-arg {}\n\
             end\n",
            netstring(asm),
            netstring("--case=smoke")
        );
        let parsed = parse_plan(&plan).expect("plan parses");
        assert_eq!(
            parsed,
            HostActionPlan::RunAssembly {
                assembly: asm.to_string(),
                target: BackendTarget::windows_x86_64().with_mode(BackendMode::Avx2),
                runtime_args: vec!["--case=smoke".to_string()],
            }
        );
    }

    #[test]
    fn parses_build_source_opt_level() {
        let plan = format!(
            "typelisp-host-plan v1\n\
             action build-source\n\
             source {}\n\
             target linux-x86_64\n\
             backend-mode scalar\n\
             opt-level 0\n\
             end\n",
            netstring("src/main.tl")
        );
        let parsed = parse_plan(&plan).expect("plan parses");
        match parsed {
            HostActionPlan::BuildSource { opt_level, .. } => {
                assert_eq!(opt_level, OptLevel::O0);
                assert!(!opt_level.runs_optimizer());
            }
            other => panic!("expected build-source, got {other:?}"),
        }
    }

    #[test]
    fn build_source_opt_level_defaults_when_omitted() {
        let plan = format!(
            "typelisp-host-plan v1\n\
             action build-source\n\
             source {}\n\
             target linux-x86_64\n\
             backend-mode scalar\n\
             end\n",
            netstring("src/main.tl")
        );
        let parsed = parse_plan(&plan).expect("plan parses");
        match parsed {
            HostActionPlan::BuildSource { opt_level, .. } => {
                assert_eq!(opt_level, OptLevel::DEFAULT);
                assert!(opt_level.runs_optimizer());
            }
            other => panic!("expected build-source, got {other:?}"),
        }
    }

    #[test]
    fn parses_run_source_opt_level() {
        let plan = format!(
            "typelisp-host-plan v1\n\
             action run-source\n\
             source {}\n\
             target linux-x86_64\n\
             backend-mode scalar\n\
             opt-level 3\n\
             end\n",
            netstring("app.tl")
        );
        let parsed = parse_plan(&plan).expect("plan parses");
        match parsed {
            HostActionPlan::RunSource { opt_level, .. } => assert_eq!(opt_level, OptLevel::O3),
            other => panic!("expected run-source, got {other:?}"),
        }
    }

    #[test]
    fn rejects_invalid_opt_level() {
        let plan = format!(
            "typelisp-host-plan v1\n\
             action build-source\n\
             source {}\n\
             target linux-x86_64\n\
             backend-mode scalar\n\
             opt-level 9\n\
             end\n",
            netstring("src/main.tl")
        );
        let err = parse_plan(&plan).expect_err("invalid opt level is rejected");
        assert!(
            err.to_string().contains("unknown opt level '9'"),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn rejects_duplicate_opt_level() {
        let plan = format!(
            "typelisp-host-plan v1\n\
             action build-source\n\
             source {}\n\
             target linux-x86_64\n\
             backend-mode scalar\n\
             opt-level 1\n\
             opt-level 2\n\
             end\n",
            netstring("src/main.tl")
        );
        let err = parse_plan(&plan).expect_err("duplicate opt level is rejected");
        assert!(
            err.to_string().contains("opt-level"),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn run_assembly_rejects_opt_level() {
        let plan = format!(
            "typelisp-host-plan v1\n\
             action run-assembly\n\
             assembly {}\n\
             target linux-x86_64\n\
             backend-mode scalar\n\
             opt-level 1\n\
             end\n",
            netstring(".globl main\nmain:\n    ret\n")
        );
        let err = parse_plan(&plan).expect_err("run-assembly rejects opt-level");
        assert!(
            err.to_string().contains("does not accept an 'opt-level'"),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn parses_run_scratch_assembly_plan() {
        let plan = format!(
            "typelisp-host-plan v1\n\
             action run-scratch-assembly\n\
             scratch-assembly-path {}\n\
             target linux-x86_64\n\
             backend-mode scalar\n\
             runtime-arg {}\n\
             end\n",
            netstring("target/inline test.s"),
            netstring("--case=smoke")
        );
        let parsed = parse_plan(&plan).expect("plan parses");
        assert_eq!(
            parsed,
            HostActionPlan::RunScratchAssembly {
                assembly_path: PathBuf::from("target/inline test.s"),
                target: BackendTarget::linux_x86_64_system_v(),
                runtime_args: vec!["--case=smoke".to_string()],
            }
        );
    }

    #[test]
    fn netstring_values_preserve_spaces_colons_and_newlines() {
        let weird_path = "my dir/a:b file.tl";
        let weird_arg = "first line\nsecond: word";
        let plan = format!(
            "typelisp-host-plan v1\n\
             action run-source\n\
             source {}\n\
             target linux-x86_64\n\
             backend-mode scalar\n\
             runtime-arg {}\n\
             end\n",
            netstring(weird_path),
            netstring(weird_arg),
        );
        let parsed = parse_plan(&plan).expect("plan parses");
        match parsed {
            HostActionPlan::RunSource {
                source,
                runtime_args,
                ..
            } => {
                assert_eq!(source, PathBuf::from(weird_path));
                assert_eq!(runtime_args, vec![weird_arg.to_string()]);
            }
            other => panic!("expected run-source, got {other:?}"),
        }
    }

    #[test]
    fn rejects_missing_header() {
        let err = parse_plan("action build-source\nend\n").unwrap_err();
        assert!(err.to_string().contains("must start with"), "{err}");
    }

    #[test]
    fn rejects_missing_required_fields() {
        let plan = "typelisp-host-plan v1\naction build-source\ntarget linux-x86_64\nbackend-mode scalar\nend\n";
        let err = parse_plan(plan).unwrap_err();
        assert!(err.to_string().contains("missing 'source'"), "{err}");
    }

    #[test]
    fn rejects_unknown_action() {
        let plan = format!(
            "typelisp-host-plan v1\naction frobnicate\nsource {}\ntarget linux-x86_64\nbackend-mode scalar\nend\n",
            netstring("x.tl")
        );
        let err = parse_plan(&plan).unwrap_err();
        assert!(err.to_string().contains("unknown host action"), "{err}");
    }

    #[test]
    fn rejects_unknown_target_and_mode() {
        let bad_target = format!(
            "typelisp-host-plan v1\naction build-source\nsource {}\ntarget sparc\nbackend-mode scalar\nend\n",
            netstring("x.tl")
        );
        assert!(
            parse_plan(&bad_target)
                .unwrap_err()
                .to_string()
                .contains("unknown target"),
        );
        let bad_mode = format!(
            "typelisp-host-plan v1\naction build-source\nsource {}\ntarget linux-x86_64\nbackend-mode sse\nend\n",
            netstring("x.tl")
        );
        assert!(
            parse_plan(&bad_mode)
                .unwrap_err()
                .to_string()
                .contains("unknown backend mode"),
        );
    }

    #[test]
    fn rejects_build_source_with_runtime_arg() {
        let plan = format!(
            "typelisp-host-plan v1\naction build-source\nsource {}\ntarget linux-x86_64\nbackend-mode scalar\nruntime-arg {}\nend\n",
            netstring("x.tl"),
            netstring("oops")
        );
        let err = parse_plan(&plan).unwrap_err();
        assert!(
            err.to_string().contains("does not accept 'runtime-arg'"),
            "{err}"
        );
    }

    #[test]
    fn rejects_run_source_with_output() {
        let plan = format!(
            "typelisp-host-plan v1\naction run-source\nsource {}\noutput {}\ntarget linux-x86_64\nbackend-mode scalar\nend\n",
            netstring("x.tl"),
            netstring("out")
        );
        let err = parse_plan(&plan).unwrap_err();
        assert!(
            err.to_string().contains("does not accept an 'output'"),
            "{err}"
        );
    }

    #[test]
    fn rejects_truncated_netstring() {
        // Length claims 99 bytes but the input ends after only a few.
        let plan = "typelisp-host-plan v1\naction build-source\nsource 99:short\n";
        let err = parse_plan(plan).unwrap_err();
        assert!(err.to_string().contains("exceeds remaining input"), "{err}");
    }

    #[test]
    fn rejects_netstring_without_newline_terminator() {
        // 5:hello immediately followed by another directive char, no newline.
        let plan = "typelisp-host-plan v1\naction build-source\nsource 5:hellotarget\nbackend-mode scalar\nend\n";
        let err = parse_plan(plan).unwrap_err();
        assert!(err.to_string().contains("terminated by a newline"), "{err}");
    }

    #[test]
    fn rejects_duplicate_directive() {
        let plan = format!(
            "typelisp-host-plan v1\naction build-source\nsource {}\nsource {}\ntarget linux-x86_64\nbackend-mode scalar\nend\n",
            netstring("a.tl"),
            netstring("b.tl")
        );
        let err = parse_plan(&plan).unwrap_err();
        assert!(err.to_string().contains("more than once"), "{err}");
    }

    #[test]
    fn rejects_unknown_directive() {
        let plan = "typelisp-host-plan v1\naction build-source\nwidgets 3\nend\n";
        let err = parse_plan(plan).unwrap_err();
        assert!(
            err.to_string().contains("unknown host-action directive"),
            "{err}"
        );
    }

    #[test]
    fn rejects_plan_without_end() {
        let plan = format!(
            "typelisp-host-plan v1\naction build-source\nsource {}\ntarget linux-x86_64\nbackend-mode scalar\n",
            netstring("x.tl")
        );
        let err = parse_plan(&plan).unwrap_err();
        assert!(err.to_string().contains("ended before"), "{err}");
    }
}
