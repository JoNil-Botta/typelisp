//! Module-graph loader for multi-file TypeLisp programs (#44, chunk 1).
//!
//! TypeLisp uses *whole-program* compilation: there is no separate-compilation
//! linker. The loader starts at an entry file, discovers `(import "path")`
//! directives, resolves each path **relative to the importing file**, and
//! depth-first loads the reachable modules. A canonical-path visited-set
//! deduplicates modules reached more than once (diamond imports) and makes
//! import cycles terminate harmlessly. Every loaded module's real (non-import)
//! declarations are concatenated, in imported-before-importer order, into a
//! single [`Program`] which then flows through the *unchanged*
//! `typecheck -> lower -> codegen` pipeline.
//!
//! The file-read and path-canonicalization steps are abstracted behind the
//! [`ModuleSource`] trait so the graph logic (dedup, cycles, ordering, relative
//! resolution) is unit-testable with an in-memory file map, requiring no real
//! filesystem. The driver uses [`FsSource`], backed by `std::fs`/`std::path`.

use crate::ast::{Decl, Program};
use crate::parser::{ParseError, parse_with_file_id};
use std::collections::HashSet;
use std::io;
use std::path::{Path, PathBuf};

/// Abstraction over the filesystem so the loader can be driven by an in-memory
/// map in tests. The driver uses [`FsSource`]; tests use a `HashMap`-backed
/// source (see the test module).
pub trait ModuleSource {
    /// Read the full source text of the file at `path`.
    fn read(&self, path: &Path) -> io::Result<String>;

    /// Resolve `path` to a canonical key used for the dedup visited-set. Two
    /// import paths that name the same module must canonicalize equal.
    fn canonicalize(&self, path: &Path) -> io::Result<PathBuf>;
}

/// Real filesystem module source backed by `std::fs` / `std::path`.
pub struct FsSource;

impl ModuleSource for FsSource {
    fn read(&self, path: &Path) -> io::Result<String> {
        std::fs::read_to_string(path)
    }

    fn canonicalize(&self, path: &Path) -> io::Result<PathBuf> {
        std::fs::canonicalize(path)
    }
}

/// One source file loaded into a whole-program compilation.
#[derive(Debug, Clone)]
pub struct SourceFile {
    pub id: u32,
    pub path: PathBuf,
    pub source_text: String,
}

/// Result of loading a TypeLisp module graph.
#[derive(Debug, Clone)]
pub struct LoadedProgram {
    pub program: Program,
    #[allow(dead_code)]
    pub entry: PathBuf,
    pub sources: Vec<SourceFile>,
}

/// An error from loading the module graph.
#[derive(Debug)]
pub enum LoadError {
    /// A module file could not be read (missing import, permission, etc.).
    /// Carries the path as written/resolved and the underlying I/O error.
    Io { path: PathBuf, source: io::Error },
    /// An imported module could not be canonicalized or read. Carries both the
    /// import as written and the filesystem path it resolved to.
    ImportIo {
        importer: PathBuf,
        import_path: String,
        resolved_path: PathBuf,
        source: io::Error,
    },
    /// A module failed to parse. Carries the canonical path of the offending
    /// module (so the driver can render the diagnostic against its source) and
    /// the parse error itself.
    Parse {
        path: PathBuf,
        source_text: String,
        error: Box<ParseError>,
    },
}

impl std::fmt::Display for LoadError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            LoadError::Io { path, source } => {
                write!(f, "cannot read module '{}': {}", path.display(), source)
            }
            LoadError::ImportIo {
                importer,
                import_path,
                resolved_path,
                source,
            } => write!(
                f,
                "cannot read import \"{}\" from '{}' (resolved '{}'): {}",
                import_path,
                importer.display(),
                resolved_path.display(),
                source
            ),
            LoadError::Parse { path, error, .. } => {
                write!(f, "in module '{}': {}", path.display(), error)
            }
        }
    }
}

/// Resolve an import path written inside `importer` (the canonical path of the
/// file containing the `(import ...)`) to a path relative to that file's
/// directory. Absolute import paths are returned unchanged.
fn resolve_import(importer: &Path, import_path: &str) -> PathBuf {
    let p = Path::new(import_path);
    if p.is_absolute() {
        return p.to_path_buf();
    }
    match importer.parent() {
        Some(dir) => dir.join(p),
        None => p.to_path_buf(),
    }
}

#[derive(Debug, Clone)]
struct ImportContext {
    importer: PathBuf,
    import_path: String,
    resolved_path: PathBuf,
}

fn io_error(path: PathBuf, source: io::Error, import: Option<&ImportContext>) -> LoadError {
    match import {
        Some(import) => LoadError::ImportIo {
            importer: import.importer.clone(),
            import_path: import.import_path.clone(),
            resolved_path: import.resolved_path.clone(),
            source,
        },
        None => LoadError::Io { path, source },
    }
}

/// Load the module graph rooted at `entry`, returning a single combined
/// `Program` whose `decls` are every reachable module's non-import declarations
/// in imported-before-importer (post-order DFS) order, plus the canonical path
/// of the entry module (for diagnostics).
///
/// `src` supplies file reads and canonicalization, making the loader testable
/// without a real filesystem.
pub fn load_program(entry: &Path, src: &dyn ModuleSource) -> Result<LoadedProgram, LoadError> {
    let entry_canon = src.canonicalize(entry).map_err(|e| LoadError::Io {
        path: entry.to_path_buf(),
        source: e,
    })?;

    let mut visited: HashSet<PathBuf> = HashSet::new();
    let mut decls: Vec<Decl> = Vec::new();
    let mut sources: Vec<SourceFile> = Vec::new();
    load_module(
        &entry_canon,
        src,
        &mut visited,
        &mut decls,
        &mut sources,
        None,
    )?;
    Ok(LoadedProgram {
        program: Program { decls },
        entry: entry_canon,
        sources,
    })
}

/// Depth-first load a single module and its (transitive) imports into `decls`.
///
/// The `visited` set is keyed on canonical path. A module already in `visited`
/// (whether fully loaded or currently on the DFS stack) is skipped, which both
/// deduplicates diamonds and breaks import cycles without infinite recursion.
/// Imports are visited *before* the module's own decls are appended, so the
/// final order is imported-before-importer.
fn load_module(
    canon: &Path,
    src: &dyn ModuleSource,
    visited: &mut HashSet<PathBuf>,
    decls: &mut Vec<Decl>,
    sources: &mut Vec<SourceFile>,
    import_context: Option<&ImportContext>,
) -> Result<(), LoadError> {
    // Mark visited *before* recursing so a cycle back to this module is a no-op.
    if !visited.insert(canon.to_path_buf()) {
        return Ok(());
    }

    let text = src
        .read(canon)
        .map_err(|e| io_error(canon.to_path_buf(), e, import_context))?;
    let file_id = sources.len() as u32;
    sources.push(SourceFile {
        id: file_id,
        path: canon.to_path_buf(),
        source_text: text.clone(),
    });
    let prog = parse_with_file_id(&text, file_id).map_err(|e| LoadError::Parse {
        path: canon.to_path_buf(),
        source_text: text.clone(),
        error: Box::new(e),
    })?;

    // First resolve & recurse into imports (so imported decls land first), then
    // append this module's real declarations, stripping the import directives.
    for decl in &prog.decls {
        if let Decl::Import(import_path) = decl {
            let target = resolve_import(canon, import_path);
            let import_context = ImportContext {
                importer: canon.to_path_buf(),
                import_path: import_path.clone(),
                resolved_path: target.clone(),
            };
            let target_canon = src.canonicalize(&target).map_err(|e| LoadError::ImportIo {
                importer: import_context.importer.clone(),
                import_path: import_context.import_path.clone(),
                resolved_path: import_context.resolved_path.clone(),
                source: e,
            })?;
            let import_context = ImportContext {
                resolved_path: target_canon.clone(),
                ..import_context
            };
            load_module(
                &target_canon,
                src,
                visited,
                decls,
                sources,
                Some(&import_context),
            )?;
        }
    }

    for decl in prog.decls {
        if !matches!(decl, Decl::Import(_)) {
            decls.push(decl);
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ast::Decl;
    use crate::diagnostic::format_diagnostic;
    use crate::typechecker::TypeChecker;
    use std::collections::HashMap;

    /// In-memory module source for tests. Paths are normalized logically
    /// (lexically, without touching disk) so relative imports resolve and the
    /// dedup visited-set works without a real filesystem.
    struct MapSource {
        files: HashMap<PathBuf, String>,
    }

    impl MapSource {
        fn new(files: &[(&str, &str)]) -> Self {
            MapSource {
                files: files
                    .iter()
                    .map(|(p, s)| (normalize(Path::new(p)), s.to_string()))
                    .collect(),
            }
        }
    }

    /// Lexically normalize a path: collapse `.` and `foo/..` segments without
    /// consulting the filesystem. Good enough to make `a/../b.tl` and `b.tl`
    /// dedup to one key in tests.
    fn normalize(path: &Path) -> PathBuf {
        let mut out: Vec<std::ffi::OsString> = Vec::new();
        for comp in path.components() {
            use std::path::Component;
            match comp {
                Component::CurDir => {}
                Component::ParentDir => {
                    out.pop();
                }
                Component::Normal(s) => out.push(s.to_os_string()),
                Component::RootDir => out.push(std::ffi::OsString::from("/")),
                Component::Prefix(p) => out.push(p.as_os_str().to_os_string()),
            }
        }
        let mut pb = PathBuf::new();
        for s in out {
            pb.push(s);
        }
        pb
    }

    impl ModuleSource for MapSource {
        fn read(&self, path: &Path) -> io::Result<String> {
            let key = normalize(path);
            self.files.get(&key).cloned().ok_or_else(|| {
                io::Error::new(io::ErrorKind::NotFound, format!("{}", path.display()))
            })
        }

        fn canonicalize(&self, path: &Path) -> io::Result<PathBuf> {
            let key = normalize(path);
            if self.files.contains_key(&key) {
                Ok(key)
            } else {
                Err(io::Error::new(
                    io::ErrorKind::NotFound,
                    format!("{}", path.display()),
                ))
            }
        }
    }

    struct ReadFailsSource {
        files: HashMap<PathBuf, String>,
        unreadable: PathBuf,
    }

    impl ReadFailsSource {
        fn new(files: &[(&str, &str)], unreadable: &str) -> Self {
            Self {
                files: files
                    .iter()
                    .map(|(p, s)| (normalize(Path::new(p)), s.to_string()))
                    .collect(),
                unreadable: normalize(Path::new(unreadable)),
            }
        }
    }

    impl ModuleSource for ReadFailsSource {
        fn read(&self, path: &Path) -> io::Result<String> {
            let key = normalize(path);
            if key == self.unreadable {
                return Err(io::Error::new(
                    io::ErrorKind::PermissionDenied,
                    format!("permission denied for {}", path.display()),
                ));
            }
            self.files
                .get(&key)
                .cloned()
                .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, path.display().to_string()))
        }

        fn canonicalize(&self, path: &Path) -> io::Result<PathBuf> {
            let key = normalize(path);
            if self.files.contains_key(&key) {
                Ok(key)
            } else {
                Err(io::Error::new(
                    io::ErrorKind::NotFound,
                    path.display().to_string(),
                ))
            }
        }
    }

    /// Collect the names of the def/deffn/extern decls in load order.
    fn decl_names(prog: &Program) -> Vec<String> {
        prog.decls
            .iter()
            .filter_map(|d| match d {
                Decl::Def { name, .. }
                | Decl::DefFn { name, .. }
                | Decl::Extern { name, .. }
                | Decl::DefEnum { name, .. }
                | Decl::DefStruct { name, .. } => Some(name.clone()),
                Decl::Import(_) => None,
            })
            .collect()
    }

    #[test]
    fn single_import_concatenates_both_modules() {
        let src = MapSource::new(&[
            ("a.tl", "(define (a) : i64 1)"),
            ("b.tl", "(import \"a.tl\")\n(define (b) : i64 (a))"),
        ]);
        let loaded = load_program(Path::new("b.tl"), &src).unwrap();
        assert_eq!(loaded.entry, PathBuf::from("b.tl"));
        // Imports are stripped; imported-before-importer order.
        assert_eq!(decl_names(&loaded.program), vec!["a", "b"]);
        // No Import decls survive into the combined program.
        assert!(
            !loaded
                .program
                .decls
                .iter()
                .any(|d| matches!(d, Decl::Import(_)))
        );
    }

    #[test]
    fn transitive_imports_a_b_c() {
        // entry imports b, b imports c. Order: c, b, entry.
        let src = MapSource::new(&[
            ("c.tl", "(define (c) : i64 3)"),
            ("b.tl", "(import \"c.tl\")\n(define (b) : i64 (c))"),
            ("entry.tl", "(import \"b.tl\")\n(define (e) : i64 (b))"),
        ]);
        let loaded = load_program(Path::new("entry.tl"), &src).unwrap();
        assert_eq!(decl_names(&loaded.program), vec!["c", "b", "e"]);
    }

    #[test]
    fn diamond_dedup_loads_shared_module_once() {
        // a imports b and c; b imports d; c imports d. d must appear once.
        let src = MapSource::new(&[
            ("d.tl", "(define (d) : i64 4)"),
            ("b.tl", "(import \"d.tl\")\n(define (b) : i64 (d))"),
            ("c.tl", "(import \"d.tl\")\n(define (c) : i64 (d))"),
            (
                "a.tl",
                "(import \"b.tl\")\n(import \"c.tl\")\n(define (a) : i64 (+ (b) (c)))",
            ),
        ]);
        let loaded = load_program(Path::new("a.tl"), &src).unwrap();
        let names = decl_names(&loaded.program);
        assert_eq!(names.iter().filter(|n| *n == "d").count(), 1, "{:?}", names);
        // d before b and c; b and c before a.
        assert_eq!(names, vec!["d", "b", "c", "a"]);
    }

    #[test]
    fn cycle_terminates_and_loads_each_once() {
        // a imports b, b imports a. Must terminate; each decl once.
        let src = MapSource::new(&[
            ("a.tl", "(import \"b.tl\")\n(define (a) : i64 1)"),
            ("b.tl", "(import \"a.tl\")\n(define (b) : i64 2)"),
        ]);
        let loaded = load_program(Path::new("a.tl"), &src).unwrap();
        let names = decl_names(&loaded.program);
        assert_eq!(names.iter().filter(|n| *n == "a").count(), 1);
        assert_eq!(names.iter().filter(|n| *n == "b").count(), 1);
        assert_eq!(names.len(), 2);
    }

    #[test]
    fn relative_path_resolution_uses_importer_directory() {
        // entry in src/ imports lib/helper.tl relative to src/.
        let src = MapSource::new(&[
            (
                "src/main.tl",
                "(import \"lib/helper.tl\")\n(define (m) : i64 (h))",
            ),
            ("src/lib/helper.tl", "(define (h) : i64 7)"),
        ]);
        let loaded = load_program(Path::new("src/main.tl"), &src).unwrap();
        assert_eq!(decl_names(&loaded.program), vec!["h", "m"]);
    }

    #[test]
    fn relative_parent_dir_dedups_with_direct_path() {
        // Reaching the same file via `a/../shared.tl` and `shared.tl` must
        // dedup to one module thanks to canonicalization/normalization.
        let src = MapSource::new(&[
            ("shared.tl", "(define (s) : i64 0)"),
            (
                "a.tl",
                "(import \"sub/../shared.tl\")\n(define (a) : i64 (s))",
            ),
            (
                "entry.tl",
                "(import \"shared.tl\")\n(import \"a.tl\")\n(define (e) : i64 (s))",
            ),
        ]);
        let loaded = load_program(Path::new("entry.tl"), &src).unwrap();
        let names = decl_names(&loaded.program);
        assert_eq!(names.iter().filter(|n| *n == "s").count(), 1, "{:?}", names);
    }

    #[test]
    fn missing_import_is_an_import_io_error() {
        let src = MapSource::new(&[("entry.tl", "(import \"nope.tl\")\n(define (e) : i64 1)")]);
        let err = load_program(Path::new("entry.tl"), &src).unwrap_err();
        let rendered = err.to_string();
        match err {
            LoadError::ImportIo {
                importer,
                import_path,
                resolved_path,
                source,
            } => {
                assert_eq!(importer, PathBuf::from("entry.tl"));
                assert_eq!(import_path, "nope.tl");
                assert_eq!(resolved_path, PathBuf::from("nope.tl"));
                assert_eq!(source.kind(), io::ErrorKind::NotFound);
            }
            other => panic!("expected ImportIo error, got {:?}", other),
        }
        assert!(
            rendered.contains("cannot read import \"nope.tl\" from 'entry.tl'"),
            "display should include import and importer: {}",
            rendered
        );
        assert!(
            rendered.contains("resolved 'nope.tl'"),
            "display should include resolved path: {}",
            rendered
        );
    }

    #[test]
    fn missing_stdlib_import_reports_request_importer_and_resolved_path() {
        let src = MapSource::new(&[(
            "project/main.tl",
            "(import \"stdlib/string.tl\")\n(define (main) : i64 0)",
        )]);
        let err = load_program(Path::new("project/main.tl"), &src).unwrap_err();
        let rendered = err.to_string();
        match err {
            LoadError::ImportIo {
                importer,
                import_path,
                resolved_path,
                source,
            } => {
                assert_eq!(importer, PathBuf::from("project/main.tl"));
                assert_eq!(import_path, "stdlib/string.tl");
                assert_eq!(resolved_path, PathBuf::from("project/stdlib/string.tl"));
                assert_eq!(source.kind(), io::ErrorKind::NotFound);
            }
            other => panic!("expected ImportIo error, got {:?}", other),
        }
        let importer_display = PathBuf::from("project")
            .join("main.tl")
            .display()
            .to_string();
        for expected in [
            "stdlib/string.tl",
            &importer_display,
            "resolved '",
            "project",
            "stdlib",
            "string.tl",
        ] {
            assert!(
                rendered.contains(expected),
                "display should include {:?}: {}",
                expected,
                rendered
            );
        }
    }

    #[test]
    fn unreadable_import_reports_context_after_canonicalization() {
        let src = ReadFailsSource::new(
            &[
                ("entry.tl", "(import \"lib.tl\")\n(define (entry) : i64 0)"),
                ("lib.tl", "(define (lib) : i64 1)"),
            ],
            "lib.tl",
        );
        let err = load_program(Path::new("entry.tl"), &src).unwrap_err();
        let rendered = err.to_string();
        match err {
            LoadError::ImportIo {
                importer,
                import_path,
                resolved_path,
                source,
            } => {
                assert_eq!(importer, PathBuf::from("entry.tl"));
                assert_eq!(import_path, "lib.tl");
                assert_eq!(resolved_path, PathBuf::from("lib.tl"));
                assert_eq!(source.kind(), io::ErrorKind::PermissionDenied);
            }
            other => panic!("expected ImportIo error, got {:?}", other),
        }
        assert!(
            rendered.contains("permission denied for lib.tl"),
            "display should include underlying I/O error: {}",
            rendered
        );
    }

    #[test]
    fn missing_entry_is_an_io_error() {
        let src = MapSource::new(&[]);
        let err = load_program(Path::new("ghost.tl"), &src).unwrap_err();
        assert!(matches!(err, LoadError::Io { .. }));
    }

    #[test]
    fn parse_error_in_imported_module_is_reported_with_its_path() {
        let src = MapSource::new(&[
            ("bad.tl", "(define ("),
            ("entry.tl", "(import \"bad.tl\")\n(define (e) : i64 1)"),
        ]);
        let err = load_program(Path::new("entry.tl"), &src).unwrap_err();
        match err {
            LoadError::Parse { path, .. } => assert_eq!(path, PathBuf::from("bad.tl")),
            other => panic!("expected Parse error, got {:?}", other),
        }
    }

    #[test]
    fn type_error_in_imported_module_keeps_imported_source_file() {
        let src = MapSource::new(&[
            ("bad.tl", "(define (bad) : i64 true)"),
            (
                "entry.tl",
                "(import \"bad.tl\")\n(define (main) : i64 (bad))",
            ),
        ]);
        let loaded = load_program(Path::new("entry.tl"), &src).unwrap();
        let mut tc = TypeChecker::new();
        let err = tc.check_program(&loaded.program).unwrap_err();
        let source = loaded
            .sources
            .iter()
            .find(|source| source.id == err.span.file_id)
            .expect("diagnostic span file id must resolve");
        let rendered = format_diagnostic(
            &err.to_diagnostic(),
            &source.source_text,
            &source.path.display().to_string(),
        );

        assert_eq!(source.path, PathBuf::from("bad.tl"));
        assert!(
            rendered.contains("--> bad.tl:1:"),
            "diagnostic should point at imported file:\n{}",
            rendered
        );
        assert!(
            rendered.contains(" 1 | (define (bad) : i64 true)"),
            "diagnostic should render imported source:\n{}",
            rendered
        );
    }

    #[test]
    fn duplicate_name_in_imported_module_keeps_duplicate_source_file() {
        let src = MapSource::new(&[
            ("a.tl", "(define (dup) : i64 1)"),
            ("b.tl", "(define (dup) : i64 2)"),
            (
                "entry.tl",
                "(import \"a.tl\")\n(import \"b.tl\")\n(define (main) : i64 (dup))",
            ),
        ]);
        let loaded = load_program(Path::new("entry.tl"), &src).unwrap();
        let mut tc = TypeChecker::new();
        let err = tc.check_program(&loaded.program).unwrap_err();
        let source = loaded
            .sources
            .iter()
            .find(|source| source.id == err.span.file_id)
            .expect("diagnostic span file id must resolve");
        let rendered = format_diagnostic(
            &err.to_diagnostic(),
            &source.source_text,
            &source.path.display().to_string(),
        );

        assert!(err.msg.contains("duplicate top-level name 'dup'"));
        assert_eq!(source.path, PathBuf::from("b.tl"));
        assert!(
            rendered.contains("--> b.tl:1:"),
            "diagnostic should point at duplicate imported file:\n{}",
            rendered
        );
    }
}
