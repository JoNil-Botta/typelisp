;; Sysroot selection for prebuilt stdlib interfaces.
(import compiler_target_cfg_core as target_cfg)
(import cli_option_core as cli)
(import compiler_build_identity as identity)
(import compiler_load)
(import compiler_embedded_stdlib as embedded)
(import compiler_tli_codec as tli_codec)
(import compiler_tli_hydrate as hydrate)
(import compiler_tli_types as tli)
(import sym_i64_env)
(import stdlib.arena)
(import stdlib.byte_buf)
(import stdlib.byte_buf_core as buf)
(import stdlib.crypto_sha256 as sha256)
(import stdlib.iterator)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.env)
(import stdlib.fs)
(import stdlib.io)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector String) as svec)

(define (tli-sysroot-cli-options) : String
  "--sysroot <dir> --no-prebuilt-stdlib")

(defstruct TliSysrootOptions
  (explicit-root String)
  (disabled bool))

(define (tli-sysroot-options) : TliSysrootOptions
  (TliSysrootOptions "" false))

(define (tli-sysroot-option!
  [options : (&mut TliSysrootOptions)]
  [args : (&mut cli.CliArgs)]) : bool
  (cond
    [(string.eq (& args.name) "--sysroot")
      (let
        [root : String (cli.cli-args-value args)]
        (cond
          [(= (string.string-length (& root)) 0)
            (cli.cli-args-fail! args "--sysroot requires a non-empty directory")]
          [(> (string.string-length (& options.explicit-root)) 0)
            (cli.cli-args-fail! args "--sysroot was provided more than once")]
          [else (set! options.explicit-root root)])
        true)]
    [(string.eq (& args.name) "--no-prebuilt-stdlib")
      (set! options.disabled true)
      true]
    [else false]))

(define (tli-sysroot-target-triple [target : target_cfg.CompilerTargetCfg]) : String
  (match target
    [(Linux) "x86_64-unknown-linux-gnu"]
    [(Windows) "x86_64-pc-windows-msvc"]))

(cfg
  windows
  (unsafe
    (extern (tli-get-module-file-name
      [module : u64]
      [buffer : (MutPtr u16)]
      [capacity : u32]) : u32 (:symbol "GetModuleFileNameW"))))

(cfg
  windows
  (unsafe
    (extern (tli-wide-char-to-multi-byte
      [code-page : u32]
      [flags : u32]
      [input : (Ptr u16)]
      [input-count : i32]
      [output : (MutPtr u8)]
      [output-count : i32]
      [default-char : u64]
      [used-default-char : u64]) : i32 (:symbol "WideCharToMultiByte"))))

(cfg
  windows
  (define (tli-executable-path) : String
    (let
      [capacity : i64 32768]
      [wide : (__tl_dyn-array u16) (__tl_make-array u16 capacity)]
      [len : i64
        (unsafe
          (cast
            (tli-get-module-file-name
              0
              (__tl_array-data wide)
              (cast capacity : u32))
            : i64))]
      (if (or (<= len 0) (>= len capacity))
        ""
        (let
          [bytes : (__tl_dyn-array u8) (__tl_make-array u8 (* len 3))]
          [size : i64
            (unsafe
              (cast
                (tli-wide-char-to-multi-byte
                  65001
                  128
                  (ptr-cast (__tl_array-data wide) : (Ptr u16))
                  (cast len : i32)
                  (__tl_array-data bytes)
                  (cast (* len 3) : i32)
                  0
                  0)
                : i64))]
          (if (<= size 0)
            ""
            (unsafe
              (string-from-bytes
                (ptr-cast (__tl_array-data bytes) : (Ptr u8))
                size))))))))

(cfg
  (not windows)
  (define (tli-executable-path) : String
    (let
      [name : (__tl_dyn-array u8) (io.c-string "/proc/self/exe")]
      [capacity : i64 4096]
      [bytes : (__tl_dyn-array u8) (__tl_make-array u8 capacity)]
      [size : i64
        (unsafe
          (syscall
            89
            (io.linux-ptr-arg (ptr-cast (__tl_array-data name) : (Ptr u8)))
            (io.linux-ptr-arg (ptr-cast (__tl_array-data bytes) : (Ptr u8)))
            capacity))]
      (if (or (<= size 0) (>= size capacity))
        ""
        (unsafe
          (string-from-bytes (ptr-cast (__tl_array-data bytes) : (Ptr u8)) size))))))

(defenum TliSysroot
  (Disabled)
  (Missing)
  (Found String))

(define (tli-sysroot-bundle-path [dir : (& str)]) : String
  (fs.path-join dir "stdlib.tli"))

(define (tli-sysroot-archive-path [dir : (& str)]) : String
  (fs.path-join dir "libstdlib.a"))

(define (tli-sysroot-archive-exists? [dir : (& str)]) : bool
  (let
    [path : String (tli-sysroot-archive-path dir)]
    (match (fs.try-file-kind (& path))
      [(OkFsFileKind kind) (fs.file-kind-regular? kind)]
      [_ false])))

(define (tli-sysroot-options-clone [options : (& TliSysrootOptions)]) : TliSysrootOptions
  (TliSysrootOptions (string.copy (& options.explicit-root)) options.disabled))

(define (tli-sysroot-options-explicit? [options : (& TliSysrootOptions)]) : bool
  (> (string.string-length (& options.explicit-root)) 0))

;; Return true when `full` cannot be read or differs from `expected` once
;; inline tests are blanked, matching the loader's embedded-stdlib equivalence.
(define (tli-sysroot-file-overrides-expected?
  [full : (& str)]
  [expected : (& str)]) : bool
  (match (io.try-read-file full)
    [(OkIoBytes actual)
      (let
        [actual-text : String (byte_buf.to-string actual)]
        (not
          (embedded.compiler-embedded-stdlib-source-matches-blanked?
            (& actual-text)
            expected)))]
    [(ErrIoBytes _) true]))

;; Check whether `dir`/`suffix` exists and differs from `expected` once inline
;; tests are blanked.
(define (tli-sysroot-dir-overrides-module?
  [dir : (& str)]
  [suffix : (& str)]
  [expected : (& str)]) : bool
  (let
    [full : String (fs.path-join dir suffix)]
    (match (io.try-file-exists? (& full))
      [(OkIoBool exists?)
        (if exists?
          (tli-sysroot-file-overrides-expected? (& full) expected)
          false)]
      [(ErrIoBool _) true])))

;; Check whether a single directory overrides any embedded stdlib source file
;; with contents that differ from it once inline tests are blanked. Probe the
;; canonical embedded suffix list in fixed order (never host directory order)
;; and decode an embedded payload only when the candidate path exists on disk.
(define (tli-sysroot-dir-overrides-stdlib? [dir : (& str)]) : bool
  (match (fs.try-file-kind dir)
    [(OkFsFileKind kind)
      (when (not (fs.file-kind-directory? kind)) (return false))]
    [_ (return false)])
  (let
    [count : i64 (embedded.compiler-embedded-stdlib-suffix-count)]
    (for [i (iterator.range 0 count)]
      (let
        [suffix : String (embedded.compiler-embedded-stdlib-suffix-at i)]
        [full : String (fs.path-join dir (& suffix))]
        (match (io.try-file-exists? (& full))
          [(OkIoBool exists?)
            (when
              exists?
              (match (embedded.compiler-embedded-stdlib-lookup
                (string.copy (& suffix)))
                [(CompilerEmbeddedStdlibSomeSource expected)
                  (when
                    (tli-sysroot-file-overrides-expected? (& full) (& expected))
                    (return true))]
                [(CompilerEmbeddedStdlibNoSource) unit]))]
          [(ErrIoBool _) (return true)])))
    false))

;; Fast check: zero filesystem calls when no `--stdlib-root` or
;; `TYPELISP_STDLIB_ROOT` is configured. When configured, disable prebuilt
;; stdlib if any root overrides an embedded stdlib file with modified bytes.
(define (tli-sysroot-stdlib-roots-override? [stdlib-roots : (& svec.Vec)]) : bool
  (let
    [count : i64 (svec.len stdlib-roots)]
    (for [i (iterator.range 0 count)]
      (let
        [root : String (svec.get stdlib-roots i "")]
        (when
          (> (string.string-length (& root)) 0)
          (when (tli-sysroot-dir-overrides-stdlib? (& root)) (return true))
          (let
            [sub : String (fs.path-join (& root) "stdlib")]
            (when (tli-sysroot-dir-overrides-stdlib? (& sub)) (return true))))))
    (match (env.get "TYPELISP_STDLIB_ROOT")
      [(EnvNoString) false]
      [(EnvSomeString root)
        (if (= (string.string-length (& root)) 0)
          false
          (let
            [sub : String (fs.path-join (& root) "stdlib")]
            (or
              (tli-sysroot-dir-overrides-stdlib? (& root))
              (tli-sysroot-dir-overrides-stdlib? (& sub)))))])))

(defenum TliSysrootOpenCatalog
  (Active hydrate.TliCatalog String String)
  (Inactive)
  (Error String))

;; Open a job-scoped TliCatalog in the caller's current arena when prebuilt
;; stdlib is eligible for this invocation. Returns Active(catalog, sysroot-dir,
;; archive-path), Inactive (clean source fallback), or Error (explicit bad
;; sysroot).
(define (tli-sysroot-open-catalog
  [options : (& TliSysrootOptions)]
  [_entry-path : (& str)]
  [target : target_cfg.CompilerTargetCfg]
  [stdlib-roots : (& svec.Vec)]
  [cfgs : sym_i64_env.SymI64Env]
  [_opt-level : i64]
  [require-archive : bool]) : TliSysrootOpenCatalog
  (cfg (not embedded-stdlib-tlci) (return Inactive))
  (when options.disabled (return Inactive))
  ;; Settle every sysroot-independent fallback before discovery: discovery
  ;; reads the executable path, so its cost depends on where the compiler is
  ;; installed, and a job that keeps the source stdlib must not pay it.
  (when (tli-sysroot-stdlib-roots-override? stdlib-roots) (return Inactive))
  (match (tli-sysroot-discover options target)
    [(Disabled) Inactive]
    [(Missing) Inactive]
    [(Found dir)
      (let
        [explicit? : bool (tli-sysroot-options-explicit? options)]
        [bundle-path : String (tli-sysroot-bundle-path (& dir))]
        [archive-path : String (tli-sysroot-archive-path (& dir))]
        [triple : String (tli-sysroot-target-triple target)]
        (when
          (and require-archive (not (tli-sysroot-archive-exists? (& dir))))
          (if explicit?
            (return
              (Error
                (str_cat.str-cat
                  "sysroot: missing prebuilt stdlib archive: "
                  archive-path
                  "\n")))
            (return Inactive)))
        (match (tli-inspect-read-file (& bundle-path))
          [(Err error)
            (if explicit?
              (Error (str_cat.str-cat "sysroot: " bundle-path ": " error "\n"))
              Inactive)]
          [(Ok bytes)
            (let
              [build : String (identity.compiler-build-producer-identity)]
              [cfg-digest : (Array u8 32) (hydrate.tli-hydrate-cfg-digest cfgs)]
              (match (hydrate.tli-catalog-open-lazy
                (& bytes)
                (& build)
                (& triple)
                (& cfg-digest))
                [(Err error)
                  (if explicit?
                    (Error
                      (str_cat.str-cat
                        "sysroot: "
                        bundle-path
                        ": "
                        error.message
                        " at byte "
                        (string.int->string error.offset)
                        "\n"))
                    Inactive)]
                [(Ok catalog)
                  (cond
                    [(=
                        (bit-and
                          catalog.directory.flags
                          tli.tli-is-stdlib-bundle)
                        0)
                      (if explicit?
                        (Error
                          (str_cat.str-cat
                            "sysroot: "
                            bundle-path
                            ": expected a stdlib TLI bundle\n"))
                        Inactive)]
                    [(=
                        (bit-and
                          catalog.directory.flags
                          tli.tli-has-tlci-companion)
                        0)
                      Inactive]
                    [else
                      ;; Probe stdlib.core_macros to verify cfg fingerprint match
                      ;; before committing to the prebuilt sysroot (every command
                      ;; loads core_macros as part of its prelude).
                      (match (hydrate.tli-catalog-hydrate!
                        (&mut catalog)
                        "stdlib.core_macros")
                        [(Ok _) (Active catalog dir archive-path)]
                        [(Err failure)
                          (match failure.kind
                            [(CfgFingerprintMismatch) Inactive]
                            [_
                              (if explicit?
                                (Error
                                  (str_cat.str-cat
                                    "sysroot: "
                                    bundle-path
                                    ": "
                                    failure.message
                                    "\n"))
                                Inactive)])])])]))]))]))

;; Sysroot options of the running command; every compile it starts opens the
;; prebuilt stdlib catalog with them.
(define tli-active-sysroot-options-state : TliSysrootOptions
  (tli-sysroot-options))

(define (tli-set-active-sysroot-options! [options : (& TliSysrootOptions)]) : unit
  (set! tli-active-sysroot-options-state (tli-sysroot-options-clone options)))

(define (tli-reset-active-sysroot-options!) : unit
  (set! tli-active-sysroot-options-state (tli-sysroot-options)))

(define (tli-active-sysroot-options) : TliSysrootOptions
  (tli-sysroot-options-clone (& tli-active-sysroot-options-state)))

(defenum ResultTliCatalogOpen
  (Ok)
  (Err String))

;; Attach the active options' catalog to `load-state` in its own arena, or
;; leave the session without one when prebuilt stdlib is inactive.
(define (tli-open-catalog-for-session!
  [load-state : (& compiler_load.CompilerLoadSessionState)]
  [entry-path : (& str)]
  [target : target_cfg.CompilerTargetCfg]
  [stdlib-roots : (& svec.Vec)]
  [cfgs : sym_i64_env.SymI64Env]
  [opt-level : i64]
  [require-archive : bool]) : ResultTliCatalogOpen
  (compiler_load.compiler-load-session-state-tli-release! load-state)
  (let
    [enclosing : i64 (arena.tl_arena_current)]
    [tli-arena : i64 (arena.tl_arena_make)]
    (unsafe
      ;; lint-allow: raw-arena-op -- moved from the audited compiler_driver_core module.
      (arena.tl_arena_set tli-arena))
    (let
      [opened : TliSysrootOpenCatalog
        (tli-sysroot-open-catalog
          (& tli-active-sysroot-options-state)
          entry-path
          target
          stdlib-roots
          cfgs
          opt-level
          require-archive)]
      (unsafe
        ;; lint-allow: raw-arena-op -- moved from the audited compiler_driver_core module.
        (arena.tl_arena_set enclosing))
      (match opened
        [(Active catalog sysroot-dir archive-path)
          (compiler_load.compiler-load-session-state-tli-attach!
            load-state
            tli-arena
            sysroot-dir
            archive-path
            catalog)
          ResultTliCatalogOpen.Ok]
        [(Inactive)
          (unsafe
            ;; lint-allow: raw-arena-op -- moved from the audited compiler_driver_core module.
            (arena.tl_arena_destroy tli-arena))
          ResultTliCatalogOpen.Ok]
        [(Error message)
          (let
            [owned-message : String (string.copy (& message))]
            (unsafe
              ;; lint-allow: raw-arena-op -- moved from the audited compiler_driver_core module.
              (arena.tl_arena_destroy tli-arena))
            (ResultTliCatalogOpen.Err owned-message))]))))

(define (tli-sysroot-target-dir [root : (& str)] [target : (& str)]) : String
  (let
    [lib : String (fs.path-join root "lib")]
    (fs.path-join (& lib) target)))

(define (tli-sysroot-bundle-exists? [dir : (& str)]) : bool
  (let
    [path : String (tli-sysroot-bundle-path dir)]
    (match (fs.try-file-kind (& path))
      [(OkFsFileKind kind) (fs.file-kind-regular? kind)]
      [_ false])))

;; Explicit selection is authoritative, including when its bundle is missing.
;; Probe neighboring installations in order only when selection is automatic.
(define (tli-sysroot-resolve
  [options : (& TliSysrootOptions)]
  [environment : (& str)]
  [executable : (& str)]
  [target : (& str)]) : TliSysroot
  (cond
    [options.disabled Disabled]
    [(> (string.string-length (& options.explicit-root)) 0)
      (Found (tli-sysroot-target-dir (& options.explicit-root) target))]
    [(string.eq environment "none") Disabled]
    [(> (string.string-length environment) 0)
      (Found (tli-sysroot-target-dir environment target))]
    [(= (string.string-length executable) 0) Missing]
    [else
      (let
        [exe-dir : String (fs.dirname executable)]
        [nearby : String (tli-sysroot-target-dir (& exe-dir) target)]
        (if (tli-sysroot-bundle-exists? (& nearby))
          (Found nearby)
          (let
            [parent : String (fs.dirname (& exe-dir))]
            [adjacent : String (tli-sysroot-target-dir (& parent) target)]
            (if (tli-sysroot-bundle-exists? (& adjacent))
              (Found adjacent)
              Missing))))]))

(define (tli-sysroot-discover
  [options : (& TliSysrootOptions)]
  [target : target_cfg.CompilerTargetCfg]) : TliSysroot
  (let
    [environment : String
      (match (env.get "TYPELISP_SYSROOT")
        [(EnvSomeString value) value]
        [(EnvNoString) ""])]
    [triple : String (tli-sysroot-target-triple target)]
    [exe : String
      (if (and
        (not options.disabled)
        (= (string.string-length (& options.explicit-root)) 0)
        (= (string.string-length (& environment)) 0))
        (tli-executable-path)
        "")]
    (tli-sysroot-resolve options (& environment) (& exe) (& triple))))

(defenum TliInspectSysroot
  (Path String String)
  (Err String))

(define (tli-inspect-sysroot-path [start : i64] [count : i64]) : TliInspectSysroot
  (let
    [spec : String
      (str_cat.str-cat "--target <target> " (tli-sysroot-cli-options))]
    [args : cli.CliArgs (cli.cli-args "inspect" spec start count)]
    [options : TliSysrootOptions (tli-sysroot-options)]
    [target : target_cfg.CompilerTargetCfg
      (target_cfg.compiler-target-cfg-host)]
    (while (cli.cli-args-next! (&mut args))
      (cond
        [(tli-sysroot-option! (&mut options) (&mut args)) unit]
        [(string.eq (& args.name) "--target")
          (match (cli.cli-option-target (cli.cli-args-value (& args)))
            [(Ok parsed) (set! target parsed)]
            [(Err message) (cli.cli-args-fail! (&mut args) message)])]
        [else
          (cli.cli-args-fail-arg! (&mut args) "inspect: unexpected argument ")]))
    (if args.failed
      (Err args.error)
      (match (tli-sysroot-discover (& options) target)
        [(Found dir)
          (Path
            (tli-sysroot-bundle-path (& dir))
            (tli-sysroot-target-triple target))]
        [(Disabled) (Err "inspect: prebuilt stdlib disabled")]
        [(Missing) (Err "inspect: no prebuilt stdlib sysroot found")]))))

(define (tli-inspect-sysroot-flag? [arg : (& str)]) : bool
  (or
    (string.eq arg "--sysroot")
    (string.eq arg "--no-prebuilt-stdlib")
    (string.eq arg "--target")))

(defenum TliInspectBytes
  (Ok (__tl_dyn-array u8))
  (Err String))

(define (tli-inspect-read-handle [handle : io.FileHandle]) : TliInspectBytes
  (let
    [out : buf.ByteBufBuilder (buf.byte-buf-builder-new)]
    [eof : bool false]
    (while (not eof)
      (let
        [remaining : i64 (+ 1 (- tli_codec.tli-max-file-bytes out.len))]
        [size : i64
          (if (< remaining 65536)
            remaining
            65536)]
        (match (io.file-read-chunk handle size)
          [(ErrIoRead error) (return (Err (io.error-message error)))]
          [(OkIoRead chunk)
            (set! eof chunk.eof)
            (let
              [bytes : (__tl_dyn-array u8) (byte_buf.to-array chunk.bytes)]
              (when
                (>= (array-length bytes) remaining)
                (return (Err "TLI file limit exceeded")))
              (when
                (and (not eof) (= (array-length bytes) 0))
                (return (Err "TLI file read returned no data")))
              (buf.byte-buf-builder-append-array (&mut out) (& bytes)))])))
    (Ok (buf.byte-buf-builder-finish-array (& out)))))

(define (tli-inspect-read-file [path : (& str)]) : TliInspectBytes
  (match (io.file-open path (io.OpenMode.OpenRead))
    [(ErrIoFile error) (Err (io.error-message error))]
    [(OkIoFile handle)
      (let
        [result : TliInspectBytes (tli-inspect-read-handle handle)]
        (io.file-close handle)
        result)]))

(define (tli-inspect-decode-error
  [path : (& str)]
  [error : (& tli.TliDecodeFailure)]) : i64
  (io.print-error
    (str_cat.str-cat
      "inspect: "
      (string.copy path)
      ": "
      (string.copy (& error.message))
      " at byte "
      (string.int->string error.offset)
      "\n"))
  1)

(define (tli-inspect-write [line : String]) : unit
  (io.stdout-write (byte_buf.str-as-bytes (& line))))

(define (tli-inspect-render-entry [entry : (& tli.TliDirectoryEntry)]) : unit
  (tli-inspect-write
    (str_cat.str-cat
      "  "
      (string.copy (& entry.name))
      ": flags="
      (string.int->string entry.flags)
      " offset="
      (string.int->string entry.record-offset)
      " bytes="
      (string.int->string entry.record-len)
      " sha256="
      (sha256.to-hex (& (sha256.Sha256Digest entry.module-sha256)))
      "\n")))

(define (tli-inspect-render-directory [directory : (& tli_codec.TliDirectory)]) : i64
  (tli-inspect-write
    (str_cat.str-cat
      "format: tli\nschema-version: "
      (string.int->string directory.schema-version)
      "\nflags: "
      (string.int->string directory.flags)
      "\ncompiler-build: "
      (string.copy (& directory.compiler-build))
      "\ntarget-triple: "
      (string.copy (& directory.target-triple))
      "\nbyte-length: "
      (string.int->string (array-length directory.bytes))
      "\ncontent-sha256: "
      (sha256.to-hex (& (sha256.Sha256Digest directory.content-sha256)))
      "\nmodules: "
      (string.int->string (array-length directory.entries))
      "\n"))
  (for [index (iterator.range 0 (array-length directory.entries))]
    (tli-inspect-render-entry (& (array-ref directory.entries index))))
  0)

(define (tli-inspect-render-bytes
  [path : (& path str)]
  [bytes : (& bytes (__tl_dyn-array u8))]) : i64
  (match (tli_codec.tli-decode-directory bytes)
    [(Err error) (tli-inspect-decode-error path (& error))]
    [(Ok directory) (tli-inspect-render-directory (& directory))]))

(defenum TliSysrootDirectory
  (Ok tli_codec.TliDirectory)
  (Err String))

;; Inspect and build preflight share the same bounded read and compatibility
;; checks. Build integration can hydrate roots using its actual cfg fingerprint.
(define (tli-sysroot-directory [path : (& path str)] [triple : (& triple str)]) : TliSysrootDirectory
  (match (tli-inspect-read-file path)
    [(Err error) (Err error)]
    [(Ok bytes)
      (let
        [build : String (identity.compiler-build-producer-identity)]
        (match (hydrate.tli-catalog-open-directory (& bytes) (& build) triple)
          [(Err error)
            (Err
              (string.concat3-borrowed
                (& error.message)
                " at byte "
                (& (string.int->string error.offset))))]
          [(Ok directory)
            (if (= (bit-and directory.flags tli.tli-is-stdlib-bundle) 0)
              (Err "expected a stdlib TLI bundle")
              (Ok directory))]))]))

(define (tli-build-sysroot-error-in-job
  [options : (& TliSysrootOptions)]
  [target : target_cfg.CompilerTargetCfg]) : String
  (match (tli-sysroot-discover options target)
    [(Found dir)
      (let
        [path : String (tli-sysroot-bundle-path (& dir))]
        [triple : String (tli-sysroot-target-triple target)]
        (match (tli-sysroot-directory (& path) (& triple))
          [(Ok _) ""]
          [(Err message) (str_cat.str-cat "build: " path ": " message "\n")]))]
    [_ ""]))

(define (tli-build-sysroot-error
  [options : (& TliSysrootOptions)]
  [target : target_cfg.CompilerTargetCfg]) : String
  (with-scratch (tli-build-sysroot-error-in-job options target)))

(define (tli-inspect-sysroot-in-job [idx : i64] [count : i64]) : i64
  (match (tli-inspect-sysroot-path idx count)
    [(Err message)
      (io.print-error (str_cat.str-cat message "\n"))
      1]
    [(Path path triple)
      (match (tli-sysroot-directory (& path) (& triple))
        [(Err error)
          (io.print-error (str_cat.str-cat "inspect: " path ": " error "\n"))
          1]
        [(Ok directory) (tli-inspect-render-directory (& directory))])]))

(define (tli-inspect-sysroot [idx : i64] [count : i64]) : i64
  (with-arena tli-job (tli-inspect-sysroot-in-job idx count)))