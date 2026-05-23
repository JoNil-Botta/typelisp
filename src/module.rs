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
use std::collections::{BTreeMap, HashSet};
use std::io;
use std::path::{Component, Path, PathBuf};

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

/// Optional module-loader behavior. The default keeps imports as plain
/// importer-relative or absolute filesystem paths.
#[derive(Debug, Clone, Default)]
pub struct LoadOptions {
    pub stdlib_roots: Vec<PathBuf>,
    pub package_roots: BTreeMap<String, PathBuf>,
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
    /// An imported module could not be canonicalized or read. Carries the
    /// import directive context so diagnostics can explain what was requested
    /// and which filesystem path the loader tried.
    ImportIo {
        importer: PathBuf,
        import_path: String,
        resolved_path: PathBuf,
        searched_stdlib_roots: Vec<PathBuf>,
        source: io::Error,
    },
    /// A `pkg:<alias>/...` import referenced an alias absent from the current
    /// package manifest dependency roots.
    PackageImportAliasNotFound {
        importer: PathBuf,
        import_path: String,
        alias: String,
        known_aliases: Vec<String>,
    },
    /// A `pkg:` import used the reserved prefix but not the required
    /// `pkg:<alias>/<path>` shape.
    PackageImportInvalid {
        importer: PathBuf,
        import_path: String,
        message: String,
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
                searched_stdlib_roots,
                source,
            } => {
                let base = if let Some(alias) = package_import_alias(import_path) {
                    format!(
                        "cannot read package import \"{}\" from '{}' (alias `{}`, resolved '{}'): {}",
                        import_path,
                        importer.display(),
                        alias,
                        resolved_path.display(),
                        source
                    )
                } else {
                    format!(
                        "cannot read import \"{}\" from '{}' (resolved '{}'): {}",
                        import_path,
                        importer.display(),
                        resolved_path.display(),
                        source
                    )
                };
                if searched_stdlib_roots.is_empty() {
                    write!(f, "{}", base)
                } else {
                    let roots = searched_stdlib_roots
                        .iter()
                        .map(|root| root.display().to_string())
                        .collect::<Vec<_>>()
                        .join(", ");
                    write!(f, "{}; searched stdlib roots: {}", base, roots)
                }
            }
            LoadError::PackageImportAliasNotFound {
                importer,
                import_path,
                alias,
                known_aliases,
            } => {
                let known = if known_aliases.is_empty() {
                    "none".to_string()
                } else {
                    known_aliases.join(", ")
                };
                write!(
                    f,
                    "cannot resolve package import \"{}\" from '{}' (alias `{}`): no dependency with that alias; known package aliases: {}",
                    import_path,
                    importer.display(),
                    alias,
                    known
                )
            }
            LoadError::PackageImportInvalid {
                importer,
                import_path,
                message,
            } => {
                write!(
                    f,
                    "cannot resolve package import \"{}\" from '{}': {}",
                    import_path,
                    importer.display(),
                    message
                )
            }
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
struct ImportRequest {
    importer: PathBuf,
    import_path: String,
    resolved_path: PathBuf,
    searched_stdlib_roots: Vec<PathBuf>,
}

fn io_load_error(path: &Path, source: io::Error, request: Option<&ImportRequest>) -> LoadError {
    match request {
        Some(request) => LoadError::ImportIo {
            importer: request.importer.clone(),
            import_path: request.import_path.clone(),
            resolved_path: request.resolved_path.clone(),
            searched_stdlib_roots: request.searched_stdlib_roots.clone(),
            source,
        },
        None => LoadError::Io {
            path: path.to_path_buf(),
            source,
        },
    }
}

fn stdlib_import_suffix(import_path: &str) -> Option<PathBuf> {
    let path = Path::new(import_path);
    if path.is_absolute() {
        return None;
    }
    match path.strip_prefix("stdlib") {
        Ok(suffix) if !suffix.as_os_str().is_empty() => Some(suffix.to_path_buf()),
        _ => None,
    }
}

fn package_import_parts(import_path: &str) -> Option<Result<(&str, &str), String>> {
    let rest = import_path.strip_prefix("pkg:")?;
    let Some((alias, suffix)) = rest.split_once('/') else {
        return Some(Err(
            "package imports must use `pkg:<alias>/<path>`".to_string()
        ));
    };
    if alias.is_empty() {
        return Some(Err("package import alias must not be empty".to_string()));
    }
    if suffix.is_empty() {
        return Some(Err("package import path must not be empty".to_string()));
    }
    if !alias
        .chars()
        .all(|ch| ch.is_ascii_alphanumeric() || ch == '-' || ch == '_')
    {
        return Some(Err(
            "package import alias may only contain ASCII letters, digits, '-' and '_'".to_string(),
        ));
    }
    Some(Ok((alias, suffix)))
}

fn package_import_alias(import_path: &str) -> Option<&str> {
    let Ok((alias, _)) = package_import_parts(import_path)? else {
        return None;
    };
    Some(alias)
}

fn is_safe_stdlib_root_suffix(suffix: &Path) -> bool {
    suffix
        .components()
        .all(|component| matches!(component, Component::Normal(_)))
}

fn is_safe_package_import_suffix(suffix: &Path) -> bool {
    !suffix.as_os_str().is_empty()
        && suffix
            .components()
            .all(|component| matches!(component, Component::Normal(_)))
}

fn resolve_import_canonical(
    importer: &Path,
    import_path: &str,
    src: &dyn ModuleSource,
    options: &LoadOptions,
) -> Result<(PathBuf, ImportRequest), LoadError> {
    if let Some(package_import) = package_import_parts(import_path) {
        let (alias, suffix) =
            package_import.map_err(|message| LoadError::PackageImportInvalid {
                importer: importer.to_path_buf(),
                import_path: import_path.to_string(),
                message,
            })?;
        return resolve_package_import_canonical(
            importer,
            import_path,
            alias,
            suffix,
            src,
            options,
        );
    }

    let primary_target = resolve_import(importer, import_path);
    let stdlib_suffix = stdlib_import_suffix(import_path);
    let searched_stdlib_roots = if stdlib_suffix.is_some() {
        options.stdlib_roots.clone()
    } else {
        Vec::new()
    };
    let primary_request = ImportRequest {
        importer: importer.to_path_buf(),
        import_path: import_path.to_string(),
        resolved_path: primary_target.clone(),
        searched_stdlib_roots: searched_stdlib_roots.clone(),
    };

    match src.canonicalize(&primary_target) {
        Ok(primary_canon) => {
            if let Some(suffix) = &stdlib_suffix
                && !options.stdlib_roots.is_empty()
            {
                match src.read(&primary_canon) {
                    Ok(_) => return Ok((primary_canon, primary_request)),
                    Err(primary_read_error) => {
                        if let Some(resolved) = try_stdlib_roots(
                            importer,
                            import_path,
                            suffix,
                            src,
                            &searched_stdlib_roots,
                        ) {
                            return Ok(resolved);
                        }
                        return Err(io_load_error(
                            &primary_target,
                            primary_read_error,
                            Some(&primary_request),
                        ));
                    }
                }
            }
            Ok((primary_canon, primary_request))
        }
        Err(primary_error) => {
            if let Some(suffix) = stdlib_suffix
                && let Some(resolved) =
                    try_stdlib_roots(importer, import_path, &suffix, src, &searched_stdlib_roots)
            {
                return Ok(resolved);
            }
            Err(io_load_error(
                &primary_target,
                primary_error,
                Some(&primary_request),
            ))
        }
    }
}

fn resolve_package_import_canonical(
    importer: &Path,
    import_path: &str,
    alias: &str,
    suffix: &str,
    src: &dyn ModuleSource,
    options: &LoadOptions,
) -> Result<(PathBuf, ImportRequest), LoadError> {
    let Some(root) = options.package_roots.get(alias) else {
        return Err(LoadError::PackageImportAliasNotFound {
            importer: importer.to_path_buf(),
            import_path: import_path.to_string(),
            alias: alias.to_string(),
            known_aliases: options.package_roots.keys().cloned().collect(),
        });
    };

    let suffix = Path::new(suffix);
    let target = root.join(suffix);
    let request = ImportRequest {
        importer: importer.to_path_buf(),
        import_path: import_path.to_string(),
        resolved_path: target.clone(),
        searched_stdlib_roots: Vec::new(),
    };

    if !is_safe_package_import_suffix(suffix) {
        return Err(io_load_error(
            &target,
            io::Error::new(
                io::ErrorKind::InvalidInput,
                "package import path must stay below the dependency root",
            ),
            Some(&request),
        ));
    }

    let canon = src
        .canonicalize(&target)
        .map_err(|err| io_load_error(&target, err, Some(&request)))?;
    Ok((canon, request))
}

fn try_stdlib_roots(
    importer: &Path,
    import_path: &str,
    suffix: &Path,
    src: &dyn ModuleSource,
    searched_stdlib_roots: &[PathBuf],
) -> Option<(PathBuf, ImportRequest)> {
    if !is_safe_stdlib_root_suffix(suffix) {
        return None;
    }

    for root in searched_stdlib_roots {
        let target = root.join(suffix);
        let request = ImportRequest {
            importer: importer.to_path_buf(),
            import_path: import_path.to_string(),
            resolved_path: target.clone(),
            searched_stdlib_roots: searched_stdlib_roots.to_vec(),
        };
        let Ok(canon) = src.canonicalize(&target) else {
            continue;
        };
        if src.read(&canon).is_ok() {
            return Some((canon, request));
        }
    }
    None
}

/// Load the module graph rooted at `entry`, returning a single combined
/// `Program` whose `decls` are every reachable module's non-import declarations
/// in imported-before-importer (post-order DFS) order, plus the canonical path
/// of the entry module (for diagnostics).
///
/// `src` supplies file reads and canonicalization, making the loader testable
/// without a real filesystem.
pub fn load_program(entry: &Path, src: &dyn ModuleSource) -> Result<LoadedProgram, LoadError> {
    load_program_with_options(entry, src, &LoadOptions::default())
}

/// Load the module graph with explicit loader options.
pub fn load_program_with_options(
    entry: &Path,
    src: &dyn ModuleSource,
    options: &LoadOptions,
) -> Result<LoadedProgram, LoadError> {
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
        options,
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
    request: Option<&ImportRequest>,
    options: &LoadOptions,
) -> Result<(), LoadError> {
    // Mark visited *before* recursing so a cycle back to this module is a no-op.
    if !visited.insert(canon.to_path_buf()) {
        return Ok(());
    }

    let text = src
        .read(canon)
        .map_err(|e| io_load_error(canon, e, request))?;
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
            let (target_canon, request) =
                resolve_import_canonical(canon, import_path, src, options)?;
            load_module(
                &target_canon,
                src,
                visited,
                decls,
                sources,
                Some(&request),
                options,
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
    use std::collections::{BTreeMap, HashMap};

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

    fn package_roots(entries: &[(&str, &str)]) -> BTreeMap<String, PathBuf> {
        entries
            .iter()
            .map(|(alias, path)| ((*alias).to_string(), PathBuf::from(path)))
            .collect()
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
    fn absolute_import_resolution_is_unchanged() {
        let absolute = std::env::current_dir()
            .unwrap()
            .join("target")
            .join("module-test-absolute.tl");
        let import_literal = absolute.to_string_lossy().replace('\\', "\\\\");
        let entry = format!("(import \"{}\")\n(define (e) : i64 (abs))", import_literal);
        let absolute_key = absolute.to_string_lossy().to_string();
        let src = MapSource::new(&[
            (absolute_key.as_str(), "(define (abs) : i64 9)"),
            ("entry.tl", entry.as_str()),
        ]);

        let loaded = load_program(Path::new("entry.tl"), &src).unwrap();
        assert_eq!(decl_names(&loaded.program), vec!["abs", "e"]);
    }

    #[test]
    fn stdlib_root_suffix_accepts_only_normal_components() {
        assert!(is_safe_stdlib_root_suffix(Path::new("string.tl")));
        assert!(is_safe_stdlib_root_suffix(Path::new("text/string.tl")));
        assert!(!is_safe_stdlib_root_suffix(Path::new("../outside.tl")));
        assert!(!is_safe_stdlib_root_suffix(Path::new("./string.tl")));
        assert!(!is_safe_stdlib_root_suffix(Path::new("/string.tl")));

        #[cfg(windows)]
        assert!(!is_safe_stdlib_root_suffix(Path::new(r"C:\string.tl")));
    }

    #[test]
    fn stdlib_import_uses_configured_root_after_local_miss() {
        let src = MapSource::new(&[
            (
                "work/main.tl",
                "(import \"stdlib/string.tl\")\n(define (main) : i64 (std))",
            ),
            ("repo-stdlib/string.tl", "(define (std) : i64 42)"),
        ]);
        let options = LoadOptions {
            stdlib_roots: vec![PathBuf::from("repo-stdlib")],
            ..LoadOptions::default()
        };

        let loaded = load_program_with_options(Path::new("work/main.tl"), &src, &options).unwrap();
        assert_eq!(decl_names(&loaded.program), vec!["std", "main"]);
        assert!(
            loaded
                .sources
                .iter()
                .any(|source| source.path == PathBuf::from("repo-stdlib/string.tl"))
        );
    }

    #[test]
    fn local_stdlib_import_shadows_configured_root() {
        let src = MapSource::new(&[
            (
                "work/main.tl",
                "(import \"stdlib/string.tl\")\n(define (main) : i64 (local))",
            ),
            ("work/stdlib/string.tl", "(define (local) : i64 1)"),
            ("repo-stdlib/string.tl", "(define (root) : i64 2)"),
        ]);
        let options = LoadOptions {
            stdlib_roots: vec![PathBuf::from("repo-stdlib")],
            ..LoadOptions::default()
        };

        let loaded = load_program_with_options(Path::new("work/main.tl"), &src, &options).unwrap();
        assert_eq!(decl_names(&loaded.program), vec!["local", "main"]);
        assert!(
            !loaded
                .sources
                .iter()
                .any(|source| source.path == PathBuf::from("repo-stdlib/string.tl"))
        );
    }

    #[test]
    fn local_stdlib_parent_dir_import_still_resolves_relative_to_importer() {
        let src = MapSource::new(&[
            (
                "work/main.tl",
                "(import \"stdlib/../outside.tl\")\n(define (main) : i64 (outside))",
            ),
            ("work/outside.tl", "(define (outside) : i64 42)"),
            ("repo-stdlib/outside.tl", "(define (root) : i64 1)"),
        ]);
        let options = LoadOptions {
            stdlib_roots: vec![PathBuf::from("repo-stdlib")],
            ..LoadOptions::default()
        };

        let loaded = load_program_with_options(Path::new("work/main.tl"), &src, &options).unwrap();
        assert_eq!(decl_names(&loaded.program), vec!["outside", "main"]);
        assert!(
            loaded
                .sources
                .iter()
                .any(|source| source.path == PathBuf::from("work/outside.tl"))
        );
        assert!(
            !loaded
                .sources
                .iter()
                .any(|source| source.path == PathBuf::from("repo-stdlib/outside.tl"))
        );
    }

    #[test]
    fn stdlib_root_rejects_parent_dir_suffix_escape() {
        let src = MapSource::new(&[
            (
                "work/main.tl",
                "(import \"stdlib/../outside.tl\")\n(define (main) : i64 (outside))",
            ),
            ("outside.tl", "(define (outside) : i64 42)"),
        ]);
        let options = LoadOptions {
            stdlib_roots: vec![PathBuf::from("repo-stdlib")],
            ..LoadOptions::default()
        };

        let err = load_program_with_options(Path::new("work/main.tl"), &src, &options).unwrap_err();
        match &err {
            LoadError::ImportIo {
                importer,
                import_path,
                resolved_path,
                searched_stdlib_roots,
                source,
            } => {
                assert_eq!(importer, &PathBuf::from("work/main.tl"));
                assert_eq!(import_path, "stdlib/../outside.tl");
                assert_eq!(
                    resolved_path,
                    &PathBuf::from("work")
                        .join("stdlib")
                        .join("..")
                        .join("outside.tl")
                );
                assert_eq!(searched_stdlib_roots, &vec![PathBuf::from("repo-stdlib")]);
                assert_eq!(source.kind(), io::ErrorKind::NotFound);
            }
            other => panic!("expected ImportIo error, got {:?}", other),
        }

        let rendered = err.to_string();
        assert!(
            rendered.contains("stdlib/../outside.tl"),
            "diagnostic should include requested import:\n{}",
            rendered
        );
        assert!(
            rendered.contains("searched stdlib roots"),
            "diagnostic should still identify searched roots:\n{}",
            rendered
        );
    }

    #[test]
    fn stdlib_root_import_dedups_with_relative_path_to_same_file() {
        let src = MapSource::new(&[
            (
                "work/main.tl",
                "(import \"stdlib/string.tl\")\n(import \"dep.tl\")\n(define (main) : i64 (std))",
            ),
            (
                "work/dep.tl",
                "(import \"../repo-stdlib/string.tl\")\n(define (dep) : i64 (std))",
            ),
            ("repo-stdlib/string.tl", "(define (std) : i64 42)"),
        ]);
        let options = LoadOptions {
            stdlib_roots: vec![PathBuf::from("repo-stdlib")],
            ..LoadOptions::default()
        };

        let loaded = load_program_with_options(Path::new("work/main.tl"), &src, &options).unwrap();
        let names = decl_names(&loaded.program);
        assert_eq!(names.iter().filter(|name| *name == "std").count(), 1);
        assert_eq!(names, vec!["std", "dep", "main"]);
    }

    #[test]
    fn pkg_import_resolves_from_dependency_root() {
        let src = MapSource::new(&[
            (
                "app/src/main.tl",
                "(import \"pkg:math/src/lib.tl\")\n(define (main) : i64 (add-one 41))",
            ),
            (
                "deps/math/src/lib.tl",
                "(define (add-one [x : i64]) : i64 (+ x 1))",
            ),
        ]);
        let options = LoadOptions {
            package_roots: package_roots(&[("math", "deps/math")]),
            ..LoadOptions::default()
        };

        let loaded = load_program_with_options(Path::new("app/src/main.tl"), &src, &options)
            .expect("load package import");
        assert_eq!(decl_names(&loaded.program), vec!["add-one", "main"]);
        assert!(
            loaded
                .sources
                .iter()
                .any(|source| source.path == PathBuf::from("deps/math/src/lib.tl"))
        );
    }

    #[test]
    fn pkg_import_dedups_with_relative_path_to_same_file() {
        let src = MapSource::new(&[
            (
                "main.tl",
                "(import \"pkg:math/src/lib.tl\")\n(import \"deps/math/src/lib.tl\")\n(define (main) : i64 (answer))",
            ),
            ("deps/math/src/lib.tl", "(define (answer) : i64 42)"),
        ]);
        let options = LoadOptions {
            package_roots: package_roots(&[("math", "deps/math")]),
            ..LoadOptions::default()
        };

        let loaded = load_program_with_options(Path::new("main.tl"), &src, &options)
            .expect("load deduped package import");
        let names = decl_names(&loaded.program);
        assert_eq!(names.iter().filter(|name| *name == "answer").count(), 1);
        assert_eq!(names, vec!["answer", "main"]);
    }

    #[test]
    fn pkg_import_reports_missing_alias() {
        let src = MapSource::new(&[(
            "app/src/main.tl",
            "(import \"pkg:math/src/lib.tl\")\n(define (main) : i64 0)",
        )]);
        let options = LoadOptions {
            package_roots: package_roots(&[("util", "deps/util")]),
            ..LoadOptions::default()
        };

        let err = load_program_with_options(Path::new("app/src/main.tl"), &src, &options)
            .expect_err("missing package alias should fail");
        match &err {
            LoadError::PackageImportAliasNotFound {
                importer,
                import_path,
                alias,
                known_aliases,
            } => {
                assert_eq!(importer, &PathBuf::from("app/src/main.tl"));
                assert_eq!(import_path, "pkg:math/src/lib.tl");
                assert_eq!(alias, "math");
                assert_eq!(known_aliases, &vec!["util".to_string()]);
            }
            other => panic!("expected PackageImportAliasNotFound, got {:?}", other),
        }

        let rendered = err.to_string();
        assert!(
            rendered.contains("pkg:math/src/lib.tl"),
            "diagnostic should include requested package import:\n{}",
            rendered
        );
        assert!(
            rendered.contains("alias `math`"),
            "diagnostic should include missing alias:\n{}",
            rendered
        );
        assert!(
            rendered.contains("known package aliases: util"),
            "diagnostic should include searched aliases:\n{}",
            rendered
        );
    }

    #[test]
    fn pkg_import_reports_missing_dependency_file() {
        let src = MapSource::new(&[(
            "app/src/main.tl",
            "(import \"pkg:math/src/missing.tl\")\n(define (main) : i64 0)",
        )]);
        let options = LoadOptions {
            package_roots: package_roots(&[("math", "deps/math")]),
            ..LoadOptions::default()
        };

        let err = load_program_with_options(Path::new("app/src/main.tl"), &src, &options)
            .expect_err("missing dependency file should fail");
        match &err {
            LoadError::ImportIo {
                importer,
                import_path,
                resolved_path,
                searched_stdlib_roots,
                source,
            } => {
                assert_eq!(importer, &PathBuf::from("app/src/main.tl"));
                assert_eq!(import_path, "pkg:math/src/missing.tl");
                assert_eq!(resolved_path, &PathBuf::from("deps/math/src/missing.tl"));
                assert!(searched_stdlib_roots.is_empty());
                assert_eq!(source.kind(), io::ErrorKind::NotFound);
            }
            other => panic!("expected ImportIo, got {:?}", other),
        }

        let rendered = err.to_string();
        let rendered_normalized = rendered.replace('\\', "/");
        assert!(
            rendered_normalized.contains("deps/math/src/missing.tl"),
            "diagnostic should include resolved dependency path:\n{}",
            rendered
        );
        assert!(
            rendered.contains("alias `math`"),
            "diagnostic should include package alias:\n{}",
            rendered
        );
    }

    #[test]
    fn pkg_import_rejects_parent_dir_escape_from_dependency_root() {
        let src = MapSource::new(&[(
            "app/src/main.tl",
            "(import \"pkg:math/../outside.tl\")\n(define (main) : i64 0)",
        )]);
        let options = LoadOptions {
            package_roots: package_roots(&[("math", "deps/math")]),
            ..LoadOptions::default()
        };

        let err = load_program_with_options(Path::new("app/src/main.tl"), &src, &options)
            .expect_err("package import escape should fail");
        match &err {
            LoadError::ImportIo { source, .. } => {
                assert_eq!(source.kind(), io::ErrorKind::InvalidInput);
            }
            other => panic!("expected ImportIo, got {:?}", other),
        }
        assert!(
            err.to_string()
                .contains("must stay below the dependency root"),
            "diagnostic should explain package-root escape:\n{}",
            err
        );
    }

    #[test]
    fn pkg_imported_names_share_flat_namespace() {
        let src = MapSource::new(&[
            (
                "app/src/main.tl",
                "(import \"pkg:math/src/lib.tl\")\n(define (dup) : i64 2)\n(define (main) : i64 (dup))",
            ),
            ("deps/math/src/lib.tl", "(define (dup) : i64 1)"),
        ]);
        let options = LoadOptions {
            package_roots: package_roots(&[("math", "deps/math")]),
            ..LoadOptions::default()
        };

        let loaded = load_program_with_options(Path::new("app/src/main.tl"), &src, &options)
            .expect("load package import");
        let mut tc = TypeChecker::new();
        let err = tc
            .check_program(&loaded.program)
            .expect_err("duplicate name across package import should fail");
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
        assert_eq!(source.path, PathBuf::from("app/src/main.tl"));
        let rendered_normalized = rendered.replace('\\', "/");
        assert!(
            rendered_normalized.contains("--> app/src/main.tl:2:"),
            "diagnostic should point at colliding local definition:\n{}",
            rendered
        );
    }

    #[test]
    fn missing_import_reports_import_context() {
        let src = MapSource::new(&[("entry.tl", "(import \"nope.tl\")\n(define (e) : i64 1)")]);
        let err = load_program(Path::new("entry.tl"), &src).unwrap_err();
        match err {
            LoadError::ImportIo {
                importer,
                import_path,
                resolved_path,
                searched_stdlib_roots,
                source,
            } => {
                assert_eq!(importer, PathBuf::from("entry.tl"));
                assert_eq!(import_path, "nope.tl");
                assert_eq!(resolved_path, PathBuf::from("nope.tl"));
                assert!(searched_stdlib_roots.is_empty());
                assert_eq!(source.kind(), io::ErrorKind::NotFound);
            }
            other => panic!("expected ImportIo error, got {:?}", other),
        }
    }

    #[test]
    fn missing_stdlib_import_reports_import_context() {
        let src = MapSource::new(&[(
            "work/main.tl",
            "(import \"stdlib/string.tl\")\n(define (main) : i64 0)",
        )]);
        let err = load_program(Path::new("work/main.tl"), &src).unwrap_err();
        let (importer_display, resolved_display) = match &err {
            LoadError::ImportIo {
                importer,
                import_path,
                resolved_path,
                searched_stdlib_roots,
                source,
            } => {
                assert_eq!(importer, &PathBuf::from("work/main.tl"));
                assert_eq!(import_path, "stdlib/string.tl");
                assert_eq!(resolved_path, &PathBuf::from("work/stdlib/string.tl"));
                assert!(searched_stdlib_roots.is_empty());
                assert_eq!(source.kind(), io::ErrorKind::NotFound);
                (
                    importer.display().to_string(),
                    resolved_path.display().to_string(),
                )
            }
            other => panic!("expected ImportIo error, got {:?}", other),
        };

        let rendered = err.to_string();
        assert!(
            rendered.contains("stdlib/string.tl"),
            "diagnostic should include requested import:\n{}",
            rendered
        );
        assert!(
            rendered.contains(&importer_display),
            "diagnostic should include importer path:\n{}",
            rendered
        );
        assert!(
            rendered.contains(&resolved_display),
            "diagnostic should include resolved path:\n{}",
            rendered
        );
        assert!(
            rendered.contains("cannot read import"),
            "diagnostic should identify the import failure:\n{}",
            rendered
        );
    }

    #[test]
    fn missing_stdlib_import_reports_searched_roots() {
        let src = MapSource::new(&[(
            "work/main.tl",
            "(import \"stdlib/string.tl\")\n(define (main) : i64 0)",
        )]);
        let options = LoadOptions {
            stdlib_roots: vec![PathBuf::from("repo-stdlib")],
            ..LoadOptions::default()
        };
        let err = load_program_with_options(Path::new("work/main.tl"), &src, &options).unwrap_err();

        match &err {
            LoadError::ImportIo {
                importer,
                import_path,
                resolved_path,
                searched_stdlib_roots,
                source,
            } => {
                assert_eq!(importer, &PathBuf::from("work/main.tl"));
                assert_eq!(import_path, "stdlib/string.tl");
                assert_eq!(resolved_path, &PathBuf::from("work/stdlib/string.tl"));
                assert_eq!(searched_stdlib_roots, &vec![PathBuf::from("repo-stdlib")]);
                assert_eq!(source.kind(), io::ErrorKind::NotFound);
            }
            other => panic!("expected ImportIo error, got {:?}", other),
        };

        let rendered = err.to_string();
        let rendered_normalized = rendered.replace('\\', "/");
        assert!(
            rendered_normalized.contains("work/stdlib/string.tl"),
            "diagnostic should include importer-relative resolved path:\n{}",
            rendered
        );
        assert!(
            rendered.contains("searched stdlib roots"),
            "diagnostic should identify stdlib roots:\n{}",
            rendered
        );
        assert!(
            rendered.contains("repo-stdlib"),
            "diagnostic should include searched root:\n{}",
            rendered
        );
    }

    #[test]
    fn import_read_failure_reports_import_context() {
        struct ReadFailingImportSource;

        impl ModuleSource for ReadFailingImportSource {
            fn read(&self, path: &Path) -> io::Result<String> {
                match normalize(path).to_str() {
                    Some("entry.tl") => {
                        Ok("(import \"blocked.tl\")\n(define (main) : i64 0)".to_string())
                    }
                    _ => Err(io::Error::new(
                        io::ErrorKind::PermissionDenied,
                        "blocked read",
                    )),
                }
            }

            fn canonicalize(&self, path: &Path) -> io::Result<PathBuf> {
                Ok(normalize(path))
            }
        }

        let src = ReadFailingImportSource;
        let err = load_program(Path::new("entry.tl"), &src).unwrap_err();
        match err {
            LoadError::ImportIo {
                importer,
                import_path,
                resolved_path,
                searched_stdlib_roots,
                source,
            } => {
                assert_eq!(importer, PathBuf::from("entry.tl"));
                assert_eq!(import_path, "blocked.tl");
                assert_eq!(resolved_path, PathBuf::from("blocked.tl"));
                assert!(searched_stdlib_roots.is_empty());
                assert_eq!(source.kind(), io::ErrorKind::PermissionDenied);
                assert_eq!(source.to_string(), "blocked read");
            }
            other => panic!("expected ImportIo error, got {:?}", other),
        }
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
