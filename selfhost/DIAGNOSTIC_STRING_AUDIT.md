# Selfhost diagnostic String-result audit

This note records how the remaining selfhost `Err... String` result families
should be treated after the canonical `CompilerDiagnostic` work from
[#1580](https://github.com/JoNil-Botta/typelisp/issues/1580). It is the
follow-up audit requested by
[#1582](https://github.com/JoNil-Botta/typelisp/issues/1582); it is guidance
for staged migration, not a requirement to delete every string error family in
one change.

## Classification

| Area | Current examples | Classification | Policy |
| --- | --- | --- | --- |
| Parser helpers | `ResultAstExpr`, `ResultAstExprList`, `ResultAstProgram`, and other `ErrAst... String` families in `selfhost/compiler_parse_core.tl` | Internal helper bridged to diagnostics | These may stay string while every public parse boundary converts failures through `CompilerDiagnostic` variants such as `ErrAstProgramDiagnostic` and preserves source path/span metadata. Prefer migrating one boundary at a time when adding labels, notes, help, or codes. |
| Typechecker helpers | `ResultTcType`, `ResultTcUnit`, `ResultTcMove`, `ResultTcBorrowCheck`, and other `ErrTc... String` families in `selfhost/compiler_typecheck_core.tl` | Internal helper bridged to diagnostics | These may stay string while declaration, expression, and lower/typecheck boundaries attach spans and metadata before surfacing errors. New source-facing typecheck behavior should return or adapt to `CompilerDiagnostic` at the boundary instead of exposing plain strings. |
| Package manifest parsing | `ErrCompilerPkgManifest String`, `ErrPkgString String`, `ErrCompilerPkgKind String`, and `ErrCompilerPkgDeps String` in `selfhost/compiler_load.tl` | Should become `CompilerDiagnostic` | Manifest errors are source/file-facing. The existing `ErrCompilerPkgManifestDiagnostic CompilerDiagnostic` path is the preferred public shape; remaining string helpers should only be private parsing details and should be retired as manifest spans, field paths, labels, and help text are added. |
| Package resolution and load graph | `ErrPkgResolve String`, package entry/load errors, package source failures, and manifest-originated failures in `selfhost/compiler_load.tl` and `selfhost/package_source_core.tl` | Mixed: operational strings or diagnostics adapters | Missing files, missing package roots, cache failures, and dependency graph operational failures may remain plain operational/tool errors. Any failure whose primary location is a package manifest or source file should preserve the manifest/source path and route through `CompilerDiagnostic` or an explicit adapter. |
| Build/run/check/test/doc CLI config | `ErrBuildConfig String`, `ErrRunCliConfig String`, `ErrSelfhostCheckConfig String`, `ErrTestConfig String`, `ErrDocTestCliConfig String`, and related command option errors in `selfhost/build_cli_core.tl`, `selfhost/run_cli_core.tl`, `selfhost/check_cli_core.tl`, `selfhost/test_cli_core.tl`, and `selfhost/doc_cli_core.tl` | Intentionally plain operational/config error | Command-line misuse, missing flag values, unknown target names, host command failures, and profile/config selection errors do not need compiler source diagnostics. Keep them plain unless they are reporting a concrete source or manifest location. |
| Build/run tool execution | `ErrSourceToolCommand String`, `ErrSourceToolTarget String`, `ErrSourceToolBackendMode String`, and link/input errors in `selfhost/build_run_core.tl` | Intentionally plain operational/config error | These are tool orchestration errors. They may render domain or stdlib failures as strings at the CLI boundary. If an execution error originates from source diagnostics produced by compile/load, preserve and render the diagnostic instead of flattening it early. |
| Stdlib IO/process/MSVC adapters | `ErrIoString IoError` in `stdlib/io.tl` and `stdlib/fs.tl`, `ErrProcessOutput ProcessError` in `stdlib/process.tl`, and `ErrMsvcTool MsvcError` in `stdlib/msvc.tl` | Structured stdlib/tool error | These are already structured domain errors, not compiler diagnostics. Keep the domain types and render/adapt them at CLI/tool boundaries. Do not force host IO, process, or MSVC discovery failures into `CompilerDiagnostic` unless a caller can tie them to a TypeLisp source location. |
| Documentation tests | `DocTestError` and `DocTestErrorList` in `selfhost/doc_test.tl` | Structured tool error | The line-numbered doctest error model is a tool-specific structured error. Keep it separate from compiler diagnostics unless doctest extraction starts reporting TypeLisp source spans or compiler diagnostic metadata directly. |

## Migration policy

- Public source-facing compiler errors should be `CompilerDiagnostic` or pass
  through an explicit adapter that preserves path, span, category, code, labels,
  notes, and help where available.
- Internal parser/typechecker helpers may continue to return `String` when all
  callers immediately attach source context before reporting the error outside
  the module or pipeline phase.
- Operational CLI/config/tooling failures may remain plain strings. Examples
  include argv validation, missing flag values, unknown host targets, cache
  setup, process execution, and linker/MSVC discovery errors.
- Structured stdlib/tool errors should remain domain-specific, with rendering
  or diagnostic adaptation performed only at the boundary that has enough
  context.
- Package manifest and load errors are the highest-priority remaining migration
  area because they are user-authored file content. New source-facing
  package/load/tool errors should use `CompilerDiagnostic` or an explicit
  diagnostic adapter first, rather than adding new public `Err... String`
  variants.
- Migrate helper families in small PRs by boundary. A good migration unit is a
  public parse/typecheck/load entry point plus the tests that prove path/span
  metadata survives through that boundary.

## Audit status

This audit is intentionally a checked-in policy note. It classifies the current
families and identifies the migration order; implementation PRs should handle
one boundary at a time.
