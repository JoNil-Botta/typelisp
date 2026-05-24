use crate::backend::{
    BackendMode, BackendOs, BackendTarget, generate_assembly_with_spans_for_target,
};
use crate::diagnostic::{self, format_diagnostic};
use crate::lower::{LowerMode, LoweredProgram, lower_program_with_spans_for_mode};
use crate::module::{
    FsSource, LoadError, LoadOptions, LoadedProgram, SourceFile, load_program,
    load_program_with_options,
};
use crate::optimizer::Optimizer;
use crate::typechecker::TypeChecker;
use std::env;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitStatus};
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Debug, Clone)]
pub struct NativeError {
    message: String,
}

impl NativeError {
    fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
        }
    }

    pub fn user_message(&self) -> &str {
        &self.message
    }
}

impl std::fmt::Display for NativeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for NativeError {}

#[derive(Debug)]
pub struct NativeRunOutput {
    pub status: ExitStatus,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
    #[allow(dead_code)]
    pub artifact_dir: Option<PathBuf>,
}

struct NativeTempDir {
    path: PathBuf,
}

impl NativeTempDir {
    fn new(prefix: &str) -> Result<Self, NativeError> {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|err| NativeError::new(format!("Error: system clock error: {}", err)))?
            .as_nanos();
        let base = env::temp_dir();
        for attempt in 0..100 {
            let path = base.join(format!(
                "{}-{}-{}-{}",
                prefix,
                std::process::id(),
                nanos,
                attempt
            ));
            match fs::create_dir(&path) {
                Ok(()) => return Ok(Self { path }),
                Err(err) if err.kind() == io::ErrorKind::AlreadyExists => continue,
                Err(err) => {
                    return Err(NativeError::new(format!(
                        "Error: failed to create temporary native run directory '{}': {}",
                        path.display(),
                        err
                    )));
                }
            }
        }
        Err(NativeError::new(format!(
            "Error: failed to create unique temporary native run directory under '{}'",
            base.display()
        )))
    }
}

impl Drop for NativeTempDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.path);
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

fn load_source(entry: &Path, options: &LoadOptions) -> Result<LoadedProgram, NativeError> {
    let loaded = if options.stdlib_roots.is_empty() && options.package_roots.is_empty() {
        load_program(entry, &FsSource)
    } else {
        load_program_with_options(entry, &FsSource, options)
    };

    loaded.map_err(|err| match err {
        LoadError::Parse {
            path,
            source_text,
            error,
        } => NativeError::new(format_diagnostic(
            &error.to_diagnostic(),
            &source_text,
            &path.display().to_string(),
        )),
        LoadError::Io { path, source } => NativeError::new(format!(
            "Error: cannot read module '{}': {}",
            path.display(),
            source
        )),
        other => NativeError::new(format!("Error: {}", other)),
    })
}

fn lower_mode_for_backend(mode: BackendMode) -> LowerMode {
    match mode {
        BackendMode::Scalar => LowerMode::Scalar,
        BackendMode::Avx2 => LowerMode::Avx2,
        BackendMode::Avx512 => LowerMode::Avx512,
    }
}

fn optimized_ir(loaded: &LoadedProgram, mode: BackendMode) -> Result<LoweredProgram, NativeError> {
    let mut tc = TypeChecker::new();
    if let Err(err) = tc.check_program(&loaded.program) {
        return Err(NativeError::new(format_diagnostic_from_sources(
            &err.to_diagnostic(),
            &loaded.sources,
        )));
    }

    let mut lowered =
        lower_program_with_spans_for_mode(&loaded.program, lower_mode_for_backend(mode));
    Optimizer::optimize(&mut lowered.program);
    Ok(lowered)
}

pub fn source_assembly(
    file: &Path,
    options: &LoadOptions,
    target: BackendTarget,
) -> Result<String, NativeError> {
    let loaded = load_source(file, options)?;
    let lowered = optimized_ir(&loaded, target.mode)?;
    match generate_assembly_with_spans_for_target(&lowered.program, &lowered.source_spans, target) {
        Ok(asm) => Ok(asm),
        Err(err) => {
            if let Some(diag) = err.to_diagnostic() {
                Err(NativeError::new(format_diagnostic_from_sources(
                    &diag,
                    &loaded.sources,
                )))
            } else {
                Err(NativeError::new(format!("Error: {}", err)))
            }
        }
    }
}

fn create_parent_dirs(path: &Path, context: &str) -> Result<(), NativeError> {
    if let Some(parent) = path.parent().filter(|p| !p.as_os_str().is_empty()) {
        fs::create_dir_all(parent).map_err(|err| {
            NativeError::new(format!(
                "Error: failed to create {} directory '{}': {}",
                context,
                parent.display(),
                err
            ))
        })?;
    }
    Ok(())
}

fn write_file(path: &Path, text: impl AsRef<[u8]>, context: &str) -> Result<(), NativeError> {
    create_parent_dirs(path, context)?;
    fs::write(path, text).map_err(|err| {
        NativeError::new(format!(
            "Error: failed to write {} '{}': {}",
            context,
            path.display(),
            err
        ))
    })
}

fn command_status(
    mut command: Command,
    role: &str,
    target: BackendTarget,
) -> Result<ExitStatus, NativeError> {
    let tool = command.get_program().to_string_lossy().into_owned();
    command.status().map_err(|err| {
        NativeError::new(format!(
            "Error: failed to run {} '{}' for target {}: {}",
            role, tool, target, err
        ))
    })
}

fn assemble_and_link(
    asm_path: &Path,
    obj_path: &Path,
    bin_path: &Path,
    target: BackendTarget,
) -> Result<(), NativeError> {
    let toolchain = target.toolchain();

    create_parent_dirs(obj_path, "object output")?;
    let mut assembler = Command::new(toolchain.assembler);
    match target.os {
        BackendOs::Linux => {
            assembler.arg(asm_path).arg("-o").arg(obj_path);
        }
        BackendOs::Windows => {
            assembler
                .arg("--target=x86_64-pc-windows-msvc")
                .arg("-c")
                .arg(asm_path)
                .arg("-o")
                .arg(obj_path);
        }
    }
    let status = command_status(assembler, "assembler", target)?;
    if !status.success() {
        return Err(NativeError::new(format!(
            "Error: assembler '{}' failed for target {} with status {}",
            toolchain.assembler, target, status
        )));
    }

    create_parent_dirs(bin_path, "executable output")?;
    let mut linker = Command::new(toolchain.linker);
    match target.os {
        BackendOs::Linux => {
            linker.arg(obj_path).arg("-o").arg(bin_path);
            if let Some(dynamic_linker) = toolchain.dynamic_linker {
                linker.arg("-dynamic-linker").arg(dynamic_linker);
            }
        }
        BackendOs::Windows => {
            linker
                .arg("/NOLOGO")
                .arg(obj_path)
                .arg(format!("/OUT:{}", bin_path.display()))
                .arg("/SUBSYSTEM:CONSOLE");
        }
    }
    for lib in toolchain.libraries {
        linker.arg(lib);
    }
    let status = command_status(linker, "linker", target)?;
    if !status.success() {
        return Err(NativeError::new(format!(
            "Error: linker '{}' failed for target {} with status {}",
            toolchain.linker, target, status
        )));
    }

    Ok(())
}

pub fn default_executable_path(file: &Path, target: BackendTarget) -> PathBuf {
    match target.executable_extension() {
        Some(extension) => file.with_extension(extension),
        None => file.with_extension(""),
    }
}

fn default_artifact_paths(
    file: &Path,
    output: Option<PathBuf>,
    target: BackendTarget,
) -> (PathBuf, PathBuf, PathBuf) {
    (
        file.with_extension("s"),
        file.with_extension(target.object_extension()),
        output.unwrap_or_else(|| default_executable_path(file, target)),
    )
}

pub fn compile_source_to_executable(
    file: &Path,
    options: &LoadOptions,
    target: BackendTarget,
    asm_path: &Path,
    obj_path: &Path,
    bin_path: &Path,
) -> Result<(), NativeError> {
    let asm = source_assembly(file, options, target)?;
    write_file(asm_path, asm, "assembly output")?;
    assemble_and_link(asm_path, obj_path, bin_path, target)
}

pub fn build_source_executable(
    file: &Path,
    options: &LoadOptions,
    output: Option<PathBuf>,
    target: BackendTarget,
) -> Result<PathBuf, NativeError> {
    let (asm_path, obj_path, bin_path) = default_artifact_paths(file, output, target);
    compile_source_to_executable(file, options, target, &asm_path, &obj_path, &bin_path)?;
    Ok(bin_path)
}

fn run_executable(
    bin_path: &Path,
    runtime_args: &[String],
    target: BackendTarget,
) -> Result<std::process::Output, NativeError> {
    let mut command = Command::new(bin_path);
    command.args(runtime_args);
    command.output().map_err(|err| {
        NativeError::new(format!(
            "Error: failed to run executable '{}' for target {}: {}",
            bin_path.display(),
            target,
            err
        ))
    })
}

pub fn run_source_file(
    file: &Path,
    options: &LoadOptions,
    runtime_args: &[String],
    target: BackendTarget,
) -> Result<NativeRunOutput, NativeError> {
    let bin_path = build_source_executable(file, options, None, target)?;
    let output = run_executable(&bin_path, runtime_args, target)?;
    Ok(NativeRunOutput {
        status: output.status,
        stdout: output.stdout,
        stderr: output.stderr,
        artifact_dir: None,
    })
}

pub fn run_source_file_in_temp_dir(
    file: &Path,
    options: &LoadOptions,
    runtime_args: &[String],
    target: BackendTarget,
) -> Result<NativeRunOutput, NativeError> {
    let temp = NativeTempDir::new("typelisp-native-run")?;
    let stem = file.file_stem().unwrap_or(std::ffi::OsStr::new("out"));
    let asm_path = temp.path.join(format!("{}.s", stem.to_string_lossy()));
    let obj_path = temp.path.join(format!(
        "{}.{}",
        stem.to_string_lossy(),
        target.object_extension()
    ));
    let bin_path = match target.executable_extension() {
        Some(ext) => temp
            .path
            .join(format!("{}.{}", stem.to_string_lossy(), ext)),
        None => temp.path.join(stem),
    };
    compile_source_to_executable(file, options, target, &asm_path, &obj_path, &bin_path)?;
    let output = run_executable(&bin_path, runtime_args, target)?;
    Ok(NativeRunOutput {
        status: output.status,
        stdout: output.stdout,
        stderr: output.stderr,
        artifact_dir: None,
    })
}

#[allow(dead_code)]
pub fn run_scratch_source(
    source: &str,
    options: &LoadOptions,
    runtime_args: &[String],
    target: BackendTarget,
) -> Result<NativeRunOutput, NativeError> {
    let temp = NativeTempDir::new("typelisp-native-run")?;
    let source_path = temp.path.join("scratch.tl");
    let asm_path = temp.path.join("scratch.s");
    let obj_path = temp
        .path
        .join(format!("scratch.{}", target.object_extension()));
    let bin_name = match target.executable_extension() {
        Some(extension) => format!("scratch.{}", extension),
        None => "scratch".to_string(),
    };
    let bin_path = temp.path.join(bin_name);

    write_file(&source_path, source, "scratch source")?;
    compile_source_to_executable(
        &source_path,
        options,
        target,
        &asm_path,
        &obj_path,
        &bin_path,
    )?;
    let output = run_executable(&bin_path, runtime_args, target)?;
    let artifact_dir = Some(temp.path.clone());
    Ok(NativeRunOutput {
        status: output.status,
        stdout: output.stdout,
        stderr: output.stderr,
        artifact_dir,
    })
}

#[allow(dead_code)]
fn _assert_send_sync()
where
    NativeError: Send + Sync,
{
}

#[cfg(test)]
mod tests {
    use super::*;

    fn host_target() -> BackendTarget {
        #[cfg(target_os = "windows")]
        {
            BackendTarget::windows_x86_64()
        }
        #[cfg(not(target_os = "windows"))]
        {
            BackendTarget::linux_x86_64_system_v()
        }
    }

    #[test]
    fn default_source_executable_path_uses_target_extension() {
        let file = Path::new("examples/main.tl");

        assert_eq!(
            default_executable_path(file, BackendTarget::linux_x86_64_system_v()),
            PathBuf::from("examples/main")
        );
        assert_eq!(
            default_executable_path(file, BackendTarget::windows_x86_64()),
            PathBuf::from("examples/main.exe")
        );
    }

    #[cfg(any(target_os = "linux", target_os = "windows"))]
    #[test]
    fn scratch_source_runs_and_cleans_temp_artifacts() {
        let output = run_scratch_source(
            r#"(define (main) : i64 (begin (print-string "scratch") 9))"#,
            &LoadOptions::default(),
            &[],
            host_target(),
        )
        .unwrap();

        assert_eq!(output.status.code(), Some(9));
        assert_eq!(String::from_utf8_lossy(&output.stdout), "scratch");
        assert_eq!(String::from_utf8_lossy(&output.stderr), "");
        let artifact_dir = output
            .artifact_dir
            .expect("scratch run reports artifact dir");
        assert!(
            !artifact_dir.exists(),
            "scratch artifact directory was not cleaned: {}",
            artifact_dir.display()
        );
    }
}
