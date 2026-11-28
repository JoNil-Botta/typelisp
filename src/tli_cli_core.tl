(import package_profile_core as pkg_profile)

;; Sysroot selection for prebuilt stdlib interfaces.
(import compiler_cfg_core as cfg_core)
(import compiler_target_cfg_core as target_cfg)
(import cli_option_core as cli)
(import compiler_build_identity as identity)
(import compiler_load)
(import compiler_embedded_stdlib as embedded)
(import compiler_tli_codec as tli_codec)
(import compiler_tli_hydrate as hydrate)
(import compiler_tli_types as tli)
(import tlci_core as tlci)
(import package_source_core)
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

(define (tli-sysroot-env-stdlib-root) : String
  (match (env.get "TYPELISP_STDLIB_ROOT")
    [(EnvSomeString value) value]
    [(EnvNoString) ""]))

(define (tli-sysroot-env-sysroot) : String
  (match (env.get "TYPELISP_SYSROOT")
    [(EnvSomeString value) value]
    [(EnvNoString) ""]))

(define (tli-sysroot-target-eq?
  [a : (& target_cfg.CompilerTargetCfg)]
  [b : target_cfg.CompilerTargetCfg]) : bool
  (match a
    [(Linux)
      (match b
        [(Linux) true]
        [(Windows) false])]
    [(Windows)
      (match b
        [(Linux) false]
        [(Windows) true])]))

(define (tli-sysroot-copy-string-slice
  [items : (& items (__tl_dyn-array String))]
  [count : i64]) : (__tl_dyn-array String)
  (let
    [out : (__tl_dyn-array String) (__tl_make-array String count)]
    (for [i (iterator.range 0 count)]
      (set! (array-ref out i) (string.copy (& (array-ref items i)))))
    out))

(define (tli-sysroot-string-slice-eq?
  [a : (& a (__tl_dyn-array String))]
  [a-len : i64]
  [b : (& b (__tl_dyn-array String))]
  [b-len : i64]) : bool
  (when (!= a-len b-len) (return false))
  (for [i (iterator.range 0 a-len)]
    (when
      (not (string.eq (& (array-ref a i)) (& (array-ref b i))))
      (return false)))
  true)

;; Uncached filesystem probe for `--stdlib-root` and `TYPELISP_STDLIB_ROOT`.
(define (tli-sysroot-stdlib-roots-override-uncached?
  [roots : (& roots (__tl_dyn-array String))]
  [count : i64]
  [env-root : (& str)]) : bool
  (for [i (iterator.range 0 count)]
    (let
      [root : String (string.copy (& (array-ref roots i)))]
      (when
        (> (string.string-length (& root)) 0)
        (when (tli-sysroot-dir-overrides-stdlib? (& root)) (return true))
        (let
          [sub : String (fs.path-join (& root) "stdlib")]
          (when (tli-sysroot-dir-overrides-stdlib? (& sub)) (return true))))))
  (if (= (string.string-length env-root) 0)
    false
    (let
      [sub : String (fs.path-join env-root "stdlib")]
      (or
        (tli-sysroot-dir-overrides-stdlib? env-root)
        (tli-sysroot-dir-overrides-stdlib? (& sub))))))

;; Batch-scoped cache for `tli-sysroot-stdlib-roots-override?` and opened
;; stdlib `TliCatalog`s (including lazily decoded `TliModuleRecord`s). All
;; cached payloads live in `tli-batch-cache-arena` and are destroyed cleanly
;; by `tli-batch-cache-end!` when the batch completes.
(define tli-batch-cache-max-slots : i64
  4)
(define tli-batch-cache-max-extra-slots : i64
  16)

(defenum TliBatchCatalogOutcome
  (Inactive)
  (Error String)
  (Active
    tli_codec.TliDirectory
    (Array u8 32)
    String
    String
    (__tl_dyn-array tli.TliModuleRecord)
    (__tl_dyn-array bool)
    (__tl_dyn-array i64)))

(defstruct TliBatchCatalogEntry
  (sysroot-disabled bool)
  (sysroot-explicit String)
  (sysroot-env String)
  (stdlib-roots (__tl_dyn-array String))
  (stdlib-env String)
  (target target_cfg.CompilerTargetCfg)
  (opt-level i64)
  (cfg-digest (Array u8 32))
  (require-archive bool)
  (outcome TliBatchCatalogOutcome))

(defenum TliBatchExtraOutcome
  (Error String)
  (Active
    tli_codec.TliDirectory
    (Array u8 32)
    (__tl_dyn-array tli.TliModuleRecord)
    (__tl_dyn-array bool)
    (__tl_dyn-array i64)))

(defstruct TliBatchExtraEntry
  (path String)
  (target target_cfg.CompilerTargetCfg)
  (cfg-digest (Array u8 32))
  (outcome TliBatchExtraOutcome))

(defstruct TliBatchCacheBox
  (override-valid bool)
  (override-roots (__tl_dyn-array String))
  (override-env String)
  (override-result bool)
  (catalog-count i64)
  (catalog-slots (__tl_dyn-array TliBatchCatalogEntry))
  (extra-count i64)
  (extra-slots (__tl_dyn-array TliBatchExtraEntry)))

(define tli-batch-cache-enabled : bool
  false)
(define tli-batch-cache-arena : i64
  0)
(define tli-batch-cache-box-addr : i64
  0)
(cfg
  test
  (define tli-batch-override-hit-count : i64
    0))
(cfg
  test
  (define tli-batch-override-miss-count : i64
    0))
(cfg
  test
  (define tli-batch-catalog-hit-count : i64
    0))
(cfg
  test
  (define tli-batch-catalog-miss-count : i64
    0))

(cfg
  test
  (define (tli-batch-cache-test-override-hits) : i64
    tli-batch-override-hit-count))

(cfg
  test
  (define (tli-batch-cache-test-override-misses) : i64
    tli-batch-override-miss-count))

(cfg
  test
  (define (tli-batch-cache-test-catalog-hits) : i64
    tli-batch-catalog-hit-count))

(cfg
  test
  (define (tli-batch-cache-test-catalog-misses) : i64
    tli-batch-catalog-miss-count))

(define (tli-batch-cache-arena-handle) : i64
  tli-batch-cache-arena)

(define (tli-batch-cache-end!) : unit
  (set! tli-batch-cache-enabled false)
  (set! tli-batch-cache-box-addr 0)
  (when
    (> tli-batch-cache-arena 0)
    (let
      [owner : i64 tli-batch-cache-arena]
      (set! tli-batch-cache-arena 0)
      (unsafe
        ;; lint-allow: raw-arena-op -- releases batch-scoped TLI cache arena deterministically at batch end.
        (arena.tl_arena_destroy owner)))))

(define (tli-batch-cache-begin!) : unit
  (tli-batch-cache-end!)
  (set! tli-batch-cache-enabled true)
  (cfg
    test
    (begin
      (set! tli-batch-override-hit-count 0)
      (set! tli-batch-override-miss-count 0)
      (set! tli-batch-catalog-hit-count 0)
      (set! tli-batch-catalog-miss-count 0))))

(define (tli-batch-cache-ensure-box!) : i64
  (when (!= tli-batch-cache-box-addr 0) (return tli-batch-cache-box-addr))
  (let
    [enclosing : i64 (arena.tl_arena_current)]
    [cache-arena : i64
      (if (> tli-batch-cache-arena 0)
        tli-batch-cache-arena
        (arena.tl_arena_make))]
    (set! tli-batch-cache-arena cache-arena)
    (unsafe
      ;; lint-allow: raw-arena-op -- allocate batch-scoped TLI cache box inside its dedicated arena.
      (arena.tl_arena_set cache-arena))
    (let
      [cell : (__tl_dyn-array TliBatchCacheBox)
        (__tl_make-array
          (TliBatchCacheBox
            false
            (__tl_make-array String 0)
            ""
            false
            0
            (__tl_make-array TliBatchCatalogEntry tli-batch-cache-max-slots)
            0
            (__tl_make-array TliBatchExtraEntry tli-batch-cache-max-extra-slots)))]
      [addr : i64
        (unsafe
          (cast (ptr->int (__tl_array-data cell)) : i64))]
      (unsafe
        ;; lint-allow: raw-arena-op -- restore caller arena after batch cache box allocation.
        (arena.tl_arena_set enclosing))
      (set! tli-batch-cache-box-addr addr)
      addr)))

(define (tli-sysroot-stdlib-roots-override-cached?
  [roots : (& (__tl_dyn-array String))]
  [count : i64]
  [env-root : (& str)]) : bool
  (unless
    tli-batch-cache-enabled
    (return (tli-sysroot-stdlib-roots-override-uncached? roots count env-root)))
  (let
    [addr : i64 (tli-batch-cache-ensure-box!)]
    (unsafe
      (let
        [p-ro : (Ptr TliBatchCacheBox)
          (int->ptr (cast addr : u64) : (Ptr TliBatchCacheBox))]
        [holder : TliBatchCacheBox (ptr-read p-ro)]
        (when
          (and
            holder.override-valid
            (string.eq (& holder.override-env) env-root)
            (tli-sysroot-string-slice-eq?
              (& holder.override-roots)
              (array-length holder.override-roots)
              roots
              count))
          (cfg test (+= tli-batch-override-hit-count 1))
          (return holder.override-result))))
    (cfg test (+= tli-batch-override-miss-count 1))
    (let
      [result : bool
        (if (and (= count 0) (= (string.string-length env-root) 0))
          false
          (with-scratch
            (tli-sysroot-stdlib-roots-override-uncached? roots count env-root)))]
      [enclosing : i64 (arena.tl_arena_current)]
      (unsafe
        ;; lint-allow: raw-arena-op -- store cached override key strings in the batch cache arena.
        (arena.tl_arena_set tli-batch-cache-arena))
      (let
        [copied-roots : (__tl_dyn-array String)
          (tli-sysroot-copy-string-slice roots count)]
        [copied-env : String (string.copy env-root)]
        (unsafe
          ;; lint-allow: raw-arena-op -- restore caller arena after caching override result.
          (arena.tl_arena_set enclosing)
          (let
            [p-ro : (Ptr TliBatchCacheBox)
              (int->ptr (cast addr : u64) : (Ptr TliBatchCacheBox))]
            [p-rw : (MutPtr TliBatchCacheBox)
              (int->ptr (cast addr : u64) : (MutPtr TliBatchCacheBox))]
            [holder : TliBatchCacheBox (ptr-read p-ro)]
            (match holder
              [(TliBatchCacheBox _ _ _ _ cat-count cat-slots ex-count ex-slots)
                (ptr-write!
                  p-rw
                  (TliBatchCacheBox
                    true
                    copied-roots
                    copied-env
                    result
                    cat-count
                    cat-slots
                    ex-count
                    ex-slots))]))))
      result)))

;; Fast check: zero filesystem calls when no `--stdlib-root` or
;; `TYPELISP_STDLIB_ROOT` is configured. When configured, disable prebuilt
;; stdlib if any root overrides an embedded stdlib file with modified bytes.
(define (tli-sysroot-stdlib-roots-override? [stdlib-roots : (& svec.Vec)]) : bool
  (let
    [env-root : String (tli-sysroot-env-stdlib-root)]
    (tli-sysroot-stdlib-roots-override-cached?
      (& stdlib-roots.slots)
      (svec.len stdlib-roots)
      (& env-root))))

(defenum TliSysrootOpenCatalog
  (Active hydrate.TliCatalog String String)
  (Inactive)
  (Error String))

;; Open a job-scoped TliCatalog in the caller's current arena using a
;; precomputed stdlib-scoped cfg digest.
(define (tli-sysroot-open-catalog-with-digest
  [options : (& TliSysrootOptions)]
  [target : target_cfg.CompilerTargetCfg]
  [roots : (& (__tl_dyn-array String))]
  [roots-len : i64]
  [env-stdlib-root : (& str)]
  [cfg-digest : (& (Array u8 32))]
  [require-archive : bool]
  [override-checked : bool]) : TliSysrootOpenCatalog
  (cfg (not embedded-stdlib-tlci) (return Inactive))
  (when options.disabled (return Inactive))
  ;; Settle every sysroot-independent fallback before discovery: discovery
  ;; reads the executable path, so its cost depends on where the compiler is
  ;; installed, and a job that keeps the source stdlib must not pay it.
  (when
    (and
      (not override-checked)
      (tli-sysroot-stdlib-roots-override-cached?
        roots
        roots-len
        env-stdlib-root))
    (return Inactive))
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
        (match (tli-sysroot-directory (& bundle-path) (& triple) false)
          [(Err message)
            (if explicit?
              (Error
                (str_cat.str-cat "sysroot: " bundle-path ": " message "\n"))
              Inactive)]
          [(Ok directory)
            (when
              (= (bit-and directory.flags tli.tli-has-tlci-companion) 0)
              (return Inactive))
            (match (hydrate.tli-catalog-open-from-directory
              (tli_codec.TliDirectoryResult.Ok directory)
              cfg-digest)
              [(Err error)
                (if explicit?
                  (Error
                    (str_cat.str-cat
                      "sysroot: "
                      bundle-path
                      ": "
                      (tli-sysroot-decode-message (& error))
                      "\n"))
                  Inactive)]
              [(Ok catalog)
                ;; Every command loads core_macros as part of its prelude.
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
                          Inactive)])])])]))]))

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
  (let
    [env-stdlib-root : String (tli-sysroot-env-stdlib-root)]
    [cfg-digest : (Array u8 32) (hydrate.tli-hydrate-stdlib-cfg-digest cfgs)]
    (tli-sysroot-open-catalog-with-digest
      options
      target
      (& stdlib-roots.slots)
      (svec.len stdlib-roots)
      (& env-stdlib-root)
      (& cfg-digest)
      require-archive
      false)))

(define (tli-batch-catalog-entry-matches?
  [entry : (& TliBatchCatalogEntry)]
  [options : (& TliSysrootOptions)]
  [env-sysroot : (& str)]
  [roots : (& (__tl_dyn-array String))]
  [roots-len : i64]
  [env-stdlib-root : (& str)]
  [target : target_cfg.CompilerTargetCfg]
  [opt-level : i64]
  [cfg-digest : (& (Array u8 32))]
  [require-archive : bool]) : bool
  (and
    (= entry.sysroot-disabled options.disabled)
    (= entry.opt-level opt-level)
    (= entry.require-archive require-archive)
    (tli-sysroot-target-eq? (& entry.target) target)
    (string.eq (& entry.sysroot-explicit) (& options.explicit-root))
    (string.eq (& entry.sysroot-env) env-sysroot)
    (string.eq (& entry.stdlib-env) env-stdlib-root)
    (tli_codec.tli-digest-eq? (& entry.cfg-digest) cfg-digest)
    (tli-sysroot-string-slice-eq?
      (& entry.stdlib-roots)
      (array-length entry.stdlib-roots)
      roots
      roots-len)))

(cfg
  embedded-stdlib-tlci
  (define (tli-embedded-stdlib-tlci-enabled?) : bool
    true))

(cfg
  (not embedded-stdlib-tlci)
  (define (tli-embedded-stdlib-tlci-enabled?) : bool
    false))

(define (tli-batch-cache-lookup-or-open!
  [options : (& TliSysrootOptions)]
  [target : target_cfg.CompilerTargetCfg]
  [roots : (& (__tl_dyn-array String))]
  [roots-len : i64]
  [cfg-digest : (& (Array u8 32))]
  [opt-level : i64]
  [require-archive : bool]) : i64
  (let
    [addr : i64 (tli-batch-cache-ensure-box!)]
    [env-sysroot : String (tli-sysroot-env-sysroot)]
    [env-stdlib-root : String (tli-sysroot-env-stdlib-root)]
    [existing-count : i64
      (unsafe
        (let
          [p-ro : (Ptr TliBatchCacheBox)
            (int->ptr (cast addr : u64) : (Ptr TliBatchCacheBox))]
          [holder : TliBatchCacheBox (ptr-read p-ro)]
          (for [i (iterator.range 0 holder.catalog-count)]
            (when
              (tli-batch-catalog-entry-matches?
                (& (array-ref holder.catalog-slots i))
                options
                (& env-sysroot)
                roots
                roots-len
                (& env-stdlib-root)
                target
                opt-level
                cfg-digest
                require-archive)
              (cfg test (+= tli-batch-catalog-hit-count 1))
              (return i)))
          holder.catalog-count))]
    (when (>= existing-count tli-batch-cache-max-slots) (return -1))
    (cfg test (+= tli-batch-catalog-miss-count 1))
    ;; Probe stdlib-root overrides in the caller's scratch arena before
    ;; switching into `tli-batch-cache-arena`, so temporary file/embedded
    ;; stdlib reads never pin MiB of scratch bytes in the batch-lifetime arena.
    (let
      [override? : bool
        (and
          (tli-embedded-stdlib-tlci-enabled?)
          (not options.disabled)
          (tli-sysroot-stdlib-roots-override-cached?
            roots
            roots-len
            (& env-stdlib-root)))]
      [enclosing : i64 (arena.tl_arena_current)]
      (unsafe
        ;; lint-allow: raw-arena-op -- open cached stdlib catalog inside the batch cache arena.
        (arena.tl_arena_set tli-batch-cache-arena))
      (let
        [opened : TliSysrootOpenCatalog
          (if override?
            TliSysrootOpenCatalog.Inactive
            (tli-sysroot-open-catalog-with-digest
              options
              target
              roots
              roots-len
              (& env-stdlib-root)
              cfg-digest
              require-archive
              true))]
        [outcome : TliBatchCatalogOutcome
          (match opened
            [(Inactive) TliBatchCatalogOutcome.Inactive]
            [(Error message) (TliBatchCatalogOutcome.Error message)]
            [(Active catalog sysroot-dir archive-path)
              (let
                [decoded : (__tl_dyn-array bool)
                  (hydrate.tli-catalog-decoded-flags (& catalog))]
                [owned-cell : (__tl_dyn-array i64)
                  (__tl_make-array catalog.owned-bytes)]
                (TliBatchCatalogOutcome.Active
                  catalog.directory
                  catalog.cfg-digest
                  sysroot-dir
                  archive-path
                  catalog.records
                  decoded
                  owned-cell))])]
        [entry : TliBatchCatalogEntry
          (TliBatchCatalogEntry
            options.disabled
            (string.copy (& options.explicit-root))
            (string.copy (& env-sysroot))
            (tli-sysroot-copy-string-slice roots roots-len)
            (string.copy (& env-stdlib-root))
            target
            opt-level
            (deref cfg-digest)
            require-archive
            outcome)]
        (unsafe
          ;; lint-allow: raw-arena-op -- restore caller arena after storing batch cache entry.
          (arena.tl_arena_set enclosing)
          (let
            [p-ro : (Ptr TliBatchCacheBox)
              (int->ptr (cast addr : u64) : (Ptr TliBatchCacheBox))]
            [p-rw : (MutPtr TliBatchCacheBox)
              (int->ptr (cast addr : u64) : (MutPtr TliBatchCacheBox))]
            [holder : TliBatchCacheBox (ptr-read p-ro)]
            (match holder
              [(TliBatchCacheBox
                ov-valid
                ov-roots
                ov-env
                ov-res
                cat-count
                cat-slots
                ex-count
                ex-slots)
                (set! (array-ref cat-slots cat-count) entry)
                (ptr-write!
                  p-rw
                  (TliBatchCacheBox
                    ov-valid
                    ov-roots
                    ov-env
                    ov-res
                    (+ cat-count 1)
                    cat-slots
                    ex-count
                    ex-slots))])))
        existing-count))))

;; Pre-warm the batch TLI cache before entry 0 of `compile --batch` without
;; touching intern tables, so persistent sysroot bytes sit in the entry-0
;; live baseline rather than appearing as post-entry-0 drift.
(define (tli-batch-extra-entry-matches?
  [entry : (& TliBatchExtraEntry)]
  [path : (& str)]
  [target : target_cfg.CompilerTargetCfg]
  [cfg-digest : (& (Array u8 32))]) : bool
  (and
    (string.eq (& entry.path) path)
    (tli-sysroot-target-eq? (& entry.target) target)
    (tli_codec.tli-digest-eq? (& entry.cfg-digest) cfg-digest)))

(define (tli-batch-cache-lookup-or-open-extra!
  [path : (& str)]
  [target : target_cfg.CompilerTargetCfg]
  [cfg-digest : (& (Array u8 32))]) : i64
  (let
    [addr : i64 (tli-batch-cache-ensure-box!)]
    [existing-count : i64
      (unsafe
        (let
          [p-ro : (Ptr TliBatchCacheBox)
            (int->ptr (cast addr : u64) : (Ptr TliBatchCacheBox))]
          [holder : TliBatchCacheBox (ptr-read p-ro)]
          (for [i (iterator.range 0 holder.extra-count)]
            (when
              (tli-batch-extra-entry-matches?
                (& (array-ref holder.extra-slots i))
                path
                target
                cfg-digest)
              (return i)))
          holder.extra-count))]
    (when (>= existing-count tli-batch-cache-max-extra-slots) (return -1))
    (let
      [triple : String (tli-sysroot-target-triple target)]
      [build : String (identity.compiler-build-producer-identity)]
      [enclosing : i64 (arena.tl_arena_current)]
      (unsafe
        ;; lint-allow: raw-arena-op -- open cached extra TLI bundle inside the batch cache arena.
        (arena.tl_arena_set tli-batch-cache-arena))
      (let
        [outcome : TliBatchExtraOutcome
          (match (tli-inspect-read-file path)
            [(Err error)
              (TliBatchExtraOutcome.Error
                (str_cat.str-cat
                  "extra tli: cannot read '"
                  (string.copy path)
                  "': "
                  error
                  "\n"))]
            [(Ok bytes)
              (match (tli_codec.tli-decode-directory-for-snapshot
                bytes
                (& build)
                (& triple)
                true)
                [(Err failure)
                  (TliBatchExtraOutcome.Error
                    (str_cat.str-cat
                      "extra tli: "
                      (string.copy path)
                      ": "
                      (string.copy (& failure.message))
                      " at byte "
                      (string.int->string failure.offset)
                      "\n"))]
                [(Ok directory)
                  (if (!= (bit-and directory.flags tli.tli-is-stdlib-bundle) 0)
                    (TliBatchExtraOutcome.Error
                      (str_cat.str-cat
                        "extra tli: "
                        (string.copy path)
                        ": unexpected stdlib bundle flag\n"))
                    (let
                      [count : i64 (array-length directory.entries)]
                      [owned : i64
                        (+
                          directory.owned-bytes
                          80
                          (*
                            count
                            (+
                              32
                              (comptime (size-of (type tli.TliModuleRecord))))))]
                      (if (> owned tli_codec.tli-max-owned-bytes)
                        (TliBatchExtraOutcome.Error
                          (str_cat.str-cat
                            "extra tli: "
                            (string.copy path)
                            ": TLI catalog exceeds the owned-byte limit\n"))
                        (TliBatchExtraOutcome.Active
                          directory
                          (deref cfg-digest)
                          (__tl_make-array tli.TliModuleRecord count)
                          (__tl_make-array bool count)
                          (__tl_make-array owned)))))])])]
        [entry : TliBatchExtraEntry
          (TliBatchExtraEntry
            (string.copy path)
            target
            (deref cfg-digest)
            outcome)]
        (unsafe
          ;; lint-allow: raw-arena-op -- restore caller arena after storing extra batch cache entry.
          (arena.tl_arena_set enclosing)
          (let
            [p-ro : (Ptr TliBatchCacheBox)
              (int->ptr (cast addr : u64) : (Ptr TliBatchCacheBox))]
            [p-rw : (MutPtr TliBatchCacheBox)
              (int->ptr (cast addr : u64) : (MutPtr TliBatchCacheBox))]
            [holder : TliBatchCacheBox (ptr-read p-ro)]
            (match holder
              [(TliBatchCacheBox
                ov-valid
                ov-roots
                ov-env
                ov-res
                cat-count
                cat-slots
                ex-count
                ex-slots)
                (set! (array-ref ex-slots ex-count) entry)
                (ptr-write!
                  p-rw
                  (TliBatchCacheBox
                    ov-valid
                    ov-roots
                    ov-env
                    ov-res
                    cat-count
                    cat-slots
                    (+ ex-count 1)
                    ex-slots))])))
        existing-count))))

(define tli-active-extra-tli-paths-state : svec.Vec
  (svec.new))

(define (tli-set-active-extra-tli-paths! [paths : (& svec.Vec)]) : unit
  (let
    [copy : svec.Vec (svec.new)]
    (for [i (iterator.range 0 (svec.len paths))]
      (svec.push-ref! (&mut copy) (string.copy (& (array-ref paths.slots i)))))
    (set! tli-active-extra-tli-paths-state copy)))

(define (tli-reset-active-extra-tli-paths!) : unit
  (set! tli-active-extra-tli-paths-state (svec.new)))

(define (tli-batch-cache-warm-for-names!
  [target : target_cfg.CompilerTargetCfg]
  [roots : (& (__tl_dyn-array String))]
  [roots-len : i64]
  [user-cfg-names : (& (__tl_dyn-array String))]
  [user-cfg-count : i64]
  [debug-info? : bool]
  [opt-level : i64]
  [require-archive : bool]) : unit
  (when
    tli-batch-cache-enabled
    (let
      [is-windows : bool
        (match target
          [(Windows) true]
          [(Linux) false])]
      [effective-cfgs : (__tl_dyn-array String)
        (__tl_make-array String (+ user-cfg-count 1))]
      [effective-cfg-count : i64 0]
      (for [i (iterator.range 0 user-cfg-count)]
        (let
          [name : String (string.copy (& (array-ref user-cfg-names i)))]
          (unless
            (string.eq (& name) "compiler-backtrace")
            (set! (array-ref effective-cfgs effective-cfg-count) name)
            (+= effective-cfg-count 1))))
      (when
        debug-info?
        (set!
          (array-ref effective-cfgs effective-cfg-count)
          "compiler-backtrace")
        (+= effective-cfg-count 1))
      (let
        [cfg-digest : (Array u8 32)
          (hydrate.tli-hydrate-stdlib-cfg-digest-for-names
            is-windows
            (& effective-cfgs)
            effective-cfg-count)]
        (tli-batch-cache-lookup-or-open!
          (& tli-active-sysroot-options-state)
          target
          roots
          roots-len
          (& cfg-digest)
          opt-level
          require-archive)
        (let
          [extra-count : i64 (svec.len (& tli-active-extra-tli-paths-state))]
          (when
            (> extra-count 0)
            (let
              [extra-digest : (Array u8 32)
                (hydrate.tli-hydrate-cfg-digest-for-names
                  is-windows
                  (& effective-cfgs)
                  effective-cfg-count)]
              (for [i (iterator.range 0 extra-count)]
                (tli-batch-cache-lookup-or-open-extra!
                  (& (array-ref tli-active-extra-tli-paths-state.slots i))
                  target
                  (& extra-digest))
                unit)))))
      unit)))

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

;; Open one metadata-only `--extra-tli <path>` bundle (`require-archive=false`)
;; and attach it to `load-state`, reusing `tli-batch-cache-arena` during
;; `compile --batch`.
(define (tli-open-extra-tli-file-for-session!
  [load-state : (& compiler_load.CompilerLoadSessionState)]
  [tli-path : (& str)]
  [target : target_cfg.CompilerTargetCfg]
  [cfgs : sym_i64_env.SymI64Env]) : ResultTliCatalogOpen
  (let
    [cfg-digest : (Array u8 32) (hydrate.tli-hydrate-cfg-digest cfgs)]
    (when
      tli-batch-cache-enabled
      (let
        [slot : i64
          (tli-batch-cache-lookup-or-open-extra! tli-path target (& cfg-digest))]
        (when
          (>= slot 0)
          (let
            [addr : i64 tli-batch-cache-box-addr]
            (return
              (unsafe
                (let
                  [p-ro : (Ptr TliBatchCacheBox)
                    (int->ptr (cast addr : u64) : (Ptr TliBatchCacheBox))]
                  [holder : TliBatchCacheBox (ptr-read p-ro)]
                  [entry : TliBatchExtraEntry
                    (ptr-read
                      (ptr-offset
                        (ptr-cast
                          (__tl_array-data holder.extra-slots)
                          : (Ptr TliBatchExtraEntry))
                        slot))]
                  (match entry.outcome
                    [(Error message)
                      (ResultTliCatalogOpen.Err (string.copy (& message)))]
                    [(Active directory digest records decoded owned-cell)
                      (match (compiler_load.compiler-load-session-state-tli-attach-borrowed-bundle!
                        load-state
                        tli-batch-cache-arena
                        false
                        ""
                        ""
                        ""
                        ""
                        directory
                        (& digest)
                        cfgs
                        records
                        decoded
                        owned-cell)
                        [(Ok _) ResultTliCatalogOpen.Ok]
                        [(Err msg)
                          (ResultTliCatalogOpen.Err
                            (str_cat.str-cat
                              "extra tli: "
                              (string.copy tli-path)
                              ": "
                              msg
                              "\n"))])]))))))))
    (let
      [triple : String (tli-sysroot-target-triple target)]
      [build : String (identity.compiler-build-producer-identity)]
      [enclosing : i64 (arena.tl_arena_current)]
      [bundle-arena : i64 (arena.tl_arena_make)]
      (unsafe
        ;; lint-allow: raw-arena-op -- per-bundle arena destroyed deterministically at job end.
        (arena.tl_arena_set bundle-arena))
      (let
        [result : ResultTliCatalogOpen
          (match (tli-inspect-read-file tli-path)
            [(Err error)
              (ResultTliCatalogOpen.Err
                (str_cat.str-cat
                  "extra tli: cannot read '"
                  (string.copy tli-path)
                  "': "
                  error
                  "\n"))]
            [(Ok bytes)
              (match (tli_codec.tli-decode-directory-for-snapshot
                bytes
                (& build)
                (& triple)
                true)
                [(Err failure)
                  (ResultTliCatalogOpen.Err
                    (str_cat.str-cat
                      "extra tli: "
                      (string.copy tli-path)
                      ": "
                      (string.copy (& failure.message))
                      " at byte "
                      (string.int->string failure.offset)
                      "\n"))]
                [(Ok directory)
                  (if (!= (bit-and directory.flags tli.tli-is-stdlib-bundle) 0)
                    (ResultTliCatalogOpen.Err
                      (str_cat.str-cat
                        "extra tli: "
                        (string.copy tli-path)
                        ": unexpected stdlib bundle flag\n"))
                    (match (compiler_load.compiler-load-session-state-tli-attach-bundle!
                      load-state
                      bundle-arena
                      false
                      ""
                      ""
                      ""
                      ""
                      (tlci.tlci-spmd-callables-empty)
                      directory
                      (& cfg-digest)
                      cfgs)
                      [(Ok _) ResultTliCatalogOpen.Ok]
                      [(Err msg)
                        (ResultTliCatalogOpen.Err
                          (str_cat.str-cat
                            "extra tli: "
                            (string.copy tli-path)
                            ": "
                            msg
                            "\n"))]))])])]
        (unsafe
          ;; lint-allow: raw-arena-op -- restore caller arena.
          (arena.tl_arena_set enclosing))
        (match result
          [(Ok) ResultTliCatalogOpen.Ok]
          [(Err msg)
            (let
              [owned-msg : String (string.copy (& msg))]
              (unsafe
                ;; lint-allow: raw-arena-op -- destroy failed bundle arena.
                (arena.tl_arena_destroy bundle-arena))
              (ResultTliCatalogOpen.Err owned-msg))])))))

(define (tli-open-extra-tli-bundles-for-session!
  [load-state : (& compiler_load.CompilerLoadSessionState)]
  [target : target_cfg.CompilerTargetCfg]
  [cfgs : sym_i64_env.SymI64Env]) : ResultTliCatalogOpen
  (let
    [count : i64 (svec.len (& tli-active-extra-tli-paths-state))]
    (for [i (iterator.range 0 count)]
      (match (tli-open-extra-tli-file-for-session!
        load-state
        (& (array-ref tli-active-extra-tli-paths-state.slots i))
        target
        cfgs)
        [(Err msg)
          (compiler_load.compiler-load-session-state-tli-release! load-state)
          (return (ResultTliCatalogOpen.Err msg))]
        [(Ok) unit]))
    ResultTliCatalogOpen.Ok))

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
  ;; A prebuilt stdlib serves stdlib modules without reading a configured root,
  ;; and a source under one still has the stdlib provider (#8733).
  (compiler_load.compiler-load-session-state-note-configured-stdlib-roots!
    load-state
    stdlib-roots)
  (when
    tli-batch-cache-enabled
    (let
      [cfg-digest : (Array u8 32) (hydrate.tli-hydrate-stdlib-cfg-digest cfgs)]
      [slot : i64
        (tli-batch-cache-lookup-or-open!
          (& tli-active-sysroot-options-state)
          target
          (& stdlib-roots.slots)
          (svec.len stdlib-roots)
          (& cfg-digest)
          opt-level
          require-archive)]
      (when
        (>= slot 0)
        (let
          [addr : i64 tli-batch-cache-box-addr]
          [stdlib-res : ResultTliCatalogOpen
            (unsafe
              (let
                [p-ro : (Ptr TliBatchCacheBox)
                  (int->ptr (cast addr : u64) : (Ptr TliBatchCacheBox))]
                [holder : TliBatchCacheBox (ptr-read p-ro)]
                [entry : TliBatchCatalogEntry
                  (ptr-read
                    (ptr-offset
                      (ptr-cast
                        (__tl_array-data holder.catalog-slots)
                        : (Ptr TliBatchCatalogEntry))
                      slot))]
                (match entry.outcome
                  [(Inactive) ResultTliCatalogOpen.Ok]
                  [(Error message)
                    (ResultTliCatalogOpen.Err (string.copy (& message)))]
                  [(Active
                    directory
                    digest
                    _sysroot-dir
                    archive-path
                    records
                    decoded
                    owned-cell)
                    (compiler_load.compiler-load-session-state-tli-attach-stdlib!
                      load-state
                      tli-batch-cache-arena
                      false
                      (string.copy (& archive-path))
                      directory
                      (& digest)
                      cfgs
                      records
                      decoded
                      owned-cell)
                    ResultTliCatalogOpen.Ok])))]
          (return
            (match stdlib-res
              [(Err msg) (ResultTliCatalogOpen.Err msg)]
              [(Ok)
                (tli-open-extra-tli-bundles-for-session! load-state target cfgs)]))))))
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
            catalog
            cfgs)
          (tli-open-extra-tli-bundles-for-session! load-state target cfgs)]
        [(Inactive)
          (unsafe
            ;; lint-allow: raw-arena-op -- moved from the audited compiler_driver_core module.
            (arena.tl_arena_destroy tli-arena))
          (tli-open-extra-tli-bundles-for-session! load-state target cfgs)]
        [(Error message)
          (let
            [owned-message : String (string.copy (& message))]
            (unsafe
              ;; lint-allow: raw-arena-op -- moved from the audited compiler_driver_core module.
              (arena.tl_arena_destroy tli-arena))
            (ResultTliCatalogOpen.Err owned-message))]))))

(define (tli-package-archive-path
  [profile : pkg_profile.PackageProfile]
  [manifest-dir : (& str)]
  [package-name : (& str)]
  [target : target_cfg.CompilerTargetCfg]) : String
  (let
    [file : String
      (match target
        [(Linux) (str_cat.str-cat "lib" (string.copy package-name) ".a")]
        [(Windows) (str_cat.str-cat (string.copy package-name) ".lib")])]
    [tdir : String (fs.path-join manifest-dir "target")]
    [pdir : String
      (fs.path-join (& tdir) (& (pkg_profile.package-profile-name profile)))]
    (fs.path-join (& pdir) (& file))))

(defenum ResultTliSpmdCallables
  (Ok tlci.TlciSpmdCallables)
  (Err String))

(define (tli-load-package-spmd-callables
  [tlci-path : (& str)]
  [manifest-dir : (& str)]
  [package-name : (& str)]
  [package-version : (& str)]
  [target-arena : i64]) : ResultTliSpmdCallables
  (match (tli-inspect-read-file tlci-path)
    [(Err error)
      (ResultTliSpmdCallables.Err
        (str_cat.str-cat
          "package tli: missing companion tlci '"
          (string.copy tlci-path)
          "': "
          error
          "\n"))]
    [(Ok bytes)
      ;; The image is parsed and authenticated in scratch; only the cloned-out
      ;; callable metadata reaches the bundle arena.
      (in-arena
        (unsafe
          ;; lint-allow: raw-arena-op -- companion metadata lives in the bundle arena.
          (arena.from-raw-handle target-arena))
        (with-scratch
          ;; Metadata parsing interns names; the scratch arena owns the image.
          (unsafe
            (tli-admit-package-spmd-callables
              (& bytes)
              tlci-path
              manifest-dir
              package-name
              package-version))))]))

(define (clone-result-tli-spmd-callables
  [value : (& value ResultTliSpmdCallables)]) : ResultTliSpmdCallables
  (match value
    [(Ok callables)
      (ResultTliSpmdCallables.Ok
        (compiler_load.compiler-load-copy-spmd-callables callables))]
    [(Err message) (ResultTliSpmdCallables.Err (string.copy message))]))

(define (tli-package-companion-error [tlci-path : (& str)] [detail : String]) : ResultTliSpmdCallables
  (ResultTliSpmdCallables.Err
    (str_cat.str-cat
      "package tli: companion tlci '"
      (string.copy tlci-path)
      "' "
      detail
      "\n")))

;; A companion is admitted only when this compiler produced it, it names the
;; dependency's package identity, and its source binding matches the
;; dependency's current source set.
(define (tli-admit-package-spmd-callables
  [bytes : (& (__tl_dyn-array u8))]
  [tlci-path : (& str)]
  [manifest-dir : (& str)]
  [package-name : (& str)]
  [package-version : (& str)]) : ResultTliSpmdCallables
  (match (tlci.tlci-parse-image bytes)
    [(Err message)
      (tli-package-companion-error
        tlci-path
        (str_cat.str-cat "is invalid: " message))]
    [(Ok image)
      (let
        [producer : String (identity.compiler-build-producer-identity)]
        (cond
          [(not (string.eq (& image.compiler-build-hash) (& producer)))
            (tli-package-companion-error
              tlci-path
              "was produced by a different compiler")]
          [(or
              (not (string.eq (& image.metadata.package-name) package-name))
              (not
                (string.eq (& image.metadata.package-version) package-version)))
            (tli-package-companion-error tlci-path "identity mismatch")]
          [else
            (match (tli-package-source-digest manifest-dir)
              [(Err message) (tli-package-companion-error tlci-path message)]
              [(Ok digest)
                (match (tlci.tlci-package-source-binding-admit
                  (& image.rodata)
                  digest)
                  [(Match _)
                    (ResultTliSpmdCallables.Ok image.metadata.spmd-callables)]
                  [_
                    (tli-package-companion-error
                      tlci-path
                      "is not bound to the dependency's current sources")])])]))]))

(define (tli-package-source-digest [manifest-dir : (& str)]) : ResultTliPackageSourceDigest
  (match (package_source_core.package-source-discover-for
    "build"
    (compiler_load.compiler-load-join-root-path
      (string.copy manifest-dir)
      "typelisp.pkg")
    true)
    [(Err message) (ResultTliPackageSourceDigest.Err message)]
    [(Ok source-set)
      (match (package_source_core.package-source-set-digest source-set)
        [(Err message) (ResultTliPackageSourceDigest.Err message)]
        [(Ok digest) (ResultTliPackageSourceDigest.Ok digest)])]))

(defenum ResultTliPackageSourceDigest
  (Ok i64)
  (Err String))

(define (tli-dep-cfgs-without-test [cfgs : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (cfg_core.compiler-cfg-remove-id cfgs (hydrate.tli-hydrate-name "test")))

(define (tli-open-package-bundle-for-session!
  [load-state : (& compiler_load.CompilerLoadSessionState)]
  [manifest-dir : (& str)]
  [package-name : (& str)]
  [package-version : (& str)]
  [target : target_cfg.CompilerTargetCfg]
  [cfgs : sym_i64_env.SymI64Env]
  [require-archive : bool]) : ResultTliCatalogOpen
  (let
    [canonical-root : String
      (compiler_load.compiler-load-canonical-path manifest-dir)]
    (when
      (compiler_load.compiler-load-session-state-tli-has-package-root?
        load-state
        (& canonical-root))
      (return ResultTliCatalogOpen.Ok))
    (let
      [tli-path : String
        (compiler_load.compiler-load-package-tli-path
          (compiler_load.compiler-load-session-package-profile load-state)
          (string.copy manifest-dir)
          (string.copy package-name))]
      [archive-path : String
        (tli-package-archive-path
          (compiler_load.compiler-load-session-package-profile load-state)
          manifest-dir
          package-name
          target)]
      [triple : String (tli-sysroot-target-triple target)]
      (when
        (and
          require-archive
          (not
            (match (fs.try-file-kind (& archive-path))
              [(OkFsFileKind kind) (fs.file-kind-regular? kind)]
              [_ false])))
        (return
          (ResultTliCatalogOpen.Err
            (str_cat.str-cat
              "package tli: missing prebuilt library archive: "
              archive-path
              "\n"))))
      (let
        [enclosing : i64 (arena.tl_arena_current)]
        [bundle-arena : i64 (arena.tl_arena_make)]
        (unsafe
          ;; lint-allow: raw-arena-op -- per-bundle arena destroyed deterministically at job end.
          (arena.tl_arena_set bundle-arena))
        (let
          [result : ResultTliCatalogOpen
            (match (tli-inspect-read-file (& tli-path))
              [(Err error)
                (ResultTliCatalogOpen.Err
                  (str_cat.str-cat
                    "package tli: cannot read '"
                    (string.copy (& tli-path))
                    "': "
                    error
                    "\n"))]
              [(Ok bytes)
                (let
                  [build : String (identity.compiler-build-producer-identity)]
                  [dep-cfgs : sym_i64_env.SymI64Env
                    (tli-dep-cfgs-without-test cfgs)]
                  [cfg-digest : (Array u8 32)
                    (hydrate.tli-hydrate-cfg-digest dep-cfgs)]
                  (match (tli_codec.tli-decode-directory-for-snapshot
                    bytes
                    (& build)
                    (& triple)
                    true)
                    [(Err failure)
                      (ResultTliCatalogOpen.Err
                        (str_cat.str-cat
                          "package tli: "
                          (string.copy (& tli-path))
                          ": "
                          (string.copy (& failure.message))
                          " at byte "
                          (string.int->string failure.offset)
                          "\n"))]
                    [(Ok directory)
                      (if (!=
                        (bit-and directory.flags tli.tli-is-stdlib-bundle)
                        0)
                        (ResultTliCatalogOpen.Err
                          (str_cat.str-cat
                            "package tli: "
                            (string.copy (& tli-path))
                            ": unexpected stdlib bundle flag\n"))
                        (let
                          [has-companion : bool
                            (!=
                              (bit-and
                                directory.flags
                                tli.tli-has-tlci-companion)
                              0)]
                          [spmd-res : ResultTliSpmdCallables
                            (if has-companion
                              (let
                                [tlci-path : String
                                  (compiler_load.compiler-load-package-tlci-path
                                    (compiler_load.compiler-load-session-package-profile
                                      load-state)
                                    (string.copy manifest-dir)
                                    (string.copy package-name))]
                                (tli-load-package-spmd-callables
                                  (& tlci-path)
                                  manifest-dir
                                  package-name
                                  package-version
                                  bundle-arena))
                              (ResultTliSpmdCallables.Ok
                                (tlci.tlci-spmd-callables-empty)))]
                          (match spmd-res
                            [(Err msg) (ResultTliCatalogOpen.Err msg)]
                            [(Ok spmd-callables)
                              (match (compiler_load.compiler-load-session-state-tli-attach-bundle!
                                load-state
                                bundle-arena
                                false
                                (string.copy package-name)
                                (string.copy package-version)
                                (string.copy (& canonical-root))
                                (string.copy (& archive-path))
                                spmd-callables
                                directory
                                (& cfg-digest)
                                dep-cfgs)
                                [(Ok _) ResultTliCatalogOpen.Ok]
                                [(Err msg)
                                  (ResultTliCatalogOpen.Err
                                    (str_cat.str-cat
                                      "package tli: "
                                      (string.copy (& tli-path))
                                      ": "
                                      msg
                                      "\n"))])])))]))])]
          (unsafe
            ;; lint-allow: raw-arena-op -- restore caller arena.
            (arena.tl_arena_set enclosing))
          (match result
            [(Ok) ResultTliCatalogOpen.Ok]
            [(Err msg)
              (let
                [owned-msg : String (string.copy (& msg))]
                (unsafe
                  ;; lint-allow: raw-arena-op -- destroy failed bundle arena.
                  (arena.tl_arena_destroy bundle-arena))
                (ResultTliCatalogOpen.Err owned-msg))]))))))

(define (tli-svec-contains? [items : (& svec.Vec)] [target : (& str)]) : bool
  (for [i (iterator.range 0 (svec.len items))]
    (when (string.eq (& (array-ref items.slots i)) target) (return true)))
  false)

(define (tli-open-transitive-deps-walk!
  [load-state : (& compiler_load.CompilerLoadSessionState)]
  [manifest-dir : (& str)]
  [deps : (& compiler_load.CompilerPkgDeps)]
  [target : target_cfg.CompilerTargetCfg]
  [cfgs : sym_i64_env.SymI64Env]
  [require-archive : bool]
  [visited : (&mut svec.Vec)]) : ResultTliCatalogOpen
  (let
    [count : i64 (compiler_load.compiler-pkg-dep-list-count (& deps.ordered))]
    (for [i (iterator.range 0 count)]
      (let
        [dep : compiler_load.CompilerPkgDep
          (compiler_load.compiler-pkg-dep-list-at (& deps.ordered) i)]
        [dep-dir : String
          (compiler_load.compiler-load-normalize-path
            (if (compiler_load.compiler-load-absolute-path? (& dep.path))
              (string.copy (& dep.path))
              (compiler_load.compiler-load-join-root-path
                (string.copy manifest-dir)
                (string.copy (& dep.path)))))]
        [canonical : String
          (compiler_load.compiler-load-canonical-path (& dep-dir))]
        (unless
          (tli-svec-contains? visited (& canonical))
          (svec.push-ref! visited (string.copy (& canonical)))
          (let
            [mpath : String
              (compiler_load.compiler-load-join-root-path
                (string.copy (& dep-dir))
                "typelisp.pkg")]
            (match (compiler_load.compiler-load-session-try-read-input-text
              (& mpath))
              [(ErrIoString error)
                (return
                  (ResultTliCatalogOpen.Err
                    (str_cat.str-cat
                      "package tli: cannot read manifest '"
                      mpath
                      "': "
                      (io.error-message error)
                      "\n")))]
              [(OkIoString text)
                (match (compiler_load.compiler-load-parse-manifest-diagnostic-infer-kind
                  (string.copy (& mpath))
                  (& text))
                  [(Err _)
                    (return
                      (ResultTliCatalogOpen.Err
                        (str_cat.str-cat
                          "package tli: invalid manifest '"
                          mpath
                          "'\n")))]
                  [(Ok manifest)
                    (match (tli-open-transitive-deps-walk!
                      load-state
                      (& dep-dir)
                      (& manifest.deps)
                      target
                      cfgs
                      require-archive
                      visited)
                      [(Err msg) (return (ResultTliCatalogOpen.Err msg))]
                      [(Ok)
                        (match (tli-open-package-bundle-for-session!
                          load-state
                          (& dep-dir)
                          (& manifest.name)
                          (& manifest.version)
                          target
                          cfgs
                          require-archive)
                          [(Err msg) (return (ResultTliCatalogOpen.Err msg))]
                          [(Ok) unit])])])])))))
    ResultTliCatalogOpen.Ok))

(define (tli-open-transitive-package-deps-for-session!
  [load-state : (& compiler_load.CompilerLoadSessionState)]
  [manifest-dir : (& str)]
  [deps : (& compiler_load.CompilerPkgDeps)]
  [target : target_cfg.CompilerTargetCfg]
  [cfgs : sym_i64_env.SymI64Env]
  [require-archive : bool]) : ResultTliCatalogOpen
  (when
    (compiler_load.compiler-load-session-state-dependency-tlci-force-source?
      load-state)
    (return ResultTliCatalogOpen.Ok))
  (let
    [visited : svec.Vec (svec.new)]
    (tli-open-transitive-deps-walk!
      load-state
      manifest-dir
      deps
      target
      cfgs
      require-archive
      (&mut visited))))

(define (tli-check-overlay-dep-tlci-walk!
  [profile : pkg_profile.PackageProfile]
  [manifest-dir : (& str)]
  [deps : (& compiler_load.CompilerPkgDeps)]
  [visited : (&mut svec.Vec)]) : ResultTliCatalogOpen
  (let
    [count : i64 (compiler_load.compiler-pkg-dep-list-count (& deps.ordered))]
    (for [i (iterator.range 0 count)]
      (let
        [dep : compiler_load.CompilerPkgDep
          (compiler_load.compiler-pkg-dep-list-at (& deps.ordered) i)]
        [dep-dir : String
          (compiler_load.compiler-load-normalize-path
            (if (compiler_load.compiler-load-absolute-path? (& dep.path))
              (string.copy (& dep.path))
              (compiler_load.compiler-load-join-root-path
                (string.copy manifest-dir)
                (string.copy (& dep.path)))))]
        [canonical : String
          (compiler_load.compiler-load-canonical-path (& dep-dir))]
        (unless
          (tli-svec-contains? visited (& canonical))
          (svec.push-ref! visited (string.copy (& canonical)))
          (let
            [mpath : String
              (compiler_load.compiler-load-join-root-path
                (string.copy (& dep-dir))
                "typelisp.pkg")]
            (match (compiler_load.compiler-load-session-try-read-input-text
              (& mpath))
              [(ErrIoString _) unit]
              [(OkIoString text)
                (match (compiler_load.compiler-load-parse-manifest-diagnostic-infer-kind
                  (string.copy (& mpath))
                  (& text))
                  [(Err _) unit]
                  [(Ok manifest)
                    (match (tli-check-overlay-dep-tlci-walk!
                      profile
                      (& dep-dir)
                      (& manifest.deps)
                      visited)
                      [(Err msg) (return (ResultTliCatalogOpen.Err msg))]
                      [(Ok)
                        (let
                          [tlci-path : String
                            (compiler_load.compiler-load-package-tlci-path
                              profile
                              (string.copy (& dep-dir))
                              (string.copy (& manifest.name)))]
                          (when
                            (io.file-exists? (string.copy (& tlci-path)))
                            (match (compiler_load.compiler-load-session-try-read-input-text
                              (& tlci-path))
                              [(ErrIoString error)
                                (return
                                  (ResultTliCatalogOpen.Err
                                    (str_cat.str-cat
                                      "compiler-load: cannot read dependency tlci '"
                                      tlci-path
                                      "': "
                                      (io.error-message error))))]
                              [(OkIoString contents)
                                (match (tlci.tlci-parse-image
                                  (& (tlci.tlci-string->bytes (& contents))))
                                  [(Err message)
                                    (return
                                      (ResultTliCatalogOpen.Err
                                        (str_cat.str-cat
                                          "compiler-load: invalid dependency tlci '"
                                          tlci-path
                                          "': "
                                          message)))]
                                  [(Ok _) unit])])))])])])))))
    ResultTliCatalogOpen.Ok))

(define (tli-check-overlay-package-dep-tlci!
  [profile : pkg_profile.PackageProfile]
  [manifest-dir : (& str)]
  [deps : (& compiler_load.CompilerPkgDeps)]) : ResultTliCatalogOpen
  (let
    [visited : svec.Vec (svec.new)]
    (tli-check-overlay-dep-tlci-walk! profile manifest-dir deps (&mut visited))))

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

(define (tli-inspect-read-handle [handle : io.FileHandle] [size-hint : i64]) : TliInspectBytes
  (let
    [out : buf.ByteBufBuilder
      (buf.byte-buf-builder-with-capacity
        (if (and (>= size-hint 0) (<= size-hint tli_codec.tli-max-file-bytes))
          size-hint
          0))]
    [eof : bool false]
    (while (not eof)
      (let
        [remaining : i64 (+ 1 (- tli_codec.tli-max-file-bytes out.len))]
        [space : i64 (- (array-length out.slots) out.len)]
        [capacity : i64
          (if (= space 0)
            1
            space)]
        [available : i64
          (if (< remaining capacity)
            remaining
            capacity)]
        [size : i64
          (if (< available 65536)
            available
            65536)]
        [overflow-byte : i64 -1]
        [error : String
          (with-scratch
            (match (io.file-read-chunk handle size)
              [(ErrIoRead error) (io.error-message error)]
              [(OkIoRead chunk)
                (set! eof chunk.eof)
                (cond
                  [(>= chunk.bytes.len remaining) "TLI file limit exceeded"]
                  [(= chunk.bytes.len 0)
                    (if eof
                      ""
                      "TLI file read returned no data")]
                  [(= space 0)
                    (set!
                      overflow-byte
                      (cast (array-ref chunk.bytes.slots 0) : i64))
                    ""]
                  [else
                    ;; The read fits the remaining capacity. Only the
                    ;; temporary chunk belongs to the scratch arena.
                    (unsafe
                      (string.string-runtime-copy-bytes!
                        (ptr-offset (__tl_array-data out.slots) out.len)
                        (ptr-cast
                          (__tl_array-data chunk.bytes.slots)
                          : (Ptr u8))
                        chunk.bytes.len))
                    (+= out.len chunk.bytes.len)
                    ""])]))]
        (when (> (string.string-length (& error)) 0) (return (Err error)))
        ;; A consumed hint (or a stream with no size) grows only after a
        ;; successful read, so EOF never forces a copy of an exact snapshot.
        (when
          (>= overflow-byte 0)
          (buf.byte-buf-builder-push (&mut out) (cast overflow-byte : u8)))))
    (Ok
      (if (= out.len (array-length out.slots))
        out.slots
        (buf.byte-buf-builder-finish-array (& out))))))

(define (tli-inspect-read-file [path : (& str)]) : TliInspectBytes
  (match (io.file-open path (io.OpenMode.OpenRead))
    [(ErrIoFile error) (Err (io.error-message error))]
    [(OkIoFile handle)
      (let
        ;; The path's size is only a capacity hint. The stream itself is
        ;; bounded and read to EOF even if the path changes after open.
        [result : TliInspectBytes
          (tli-inspect-read-handle handle (fs.file-size path))]
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
      (string.int->string (array-length (array-ref directory.snapshot 0)))
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

(define (tli-sysroot-decode-message [error : (& tli.TliDecodeFailure)]) : String
  (string.concat3-borrowed
    (& error.message)
    " at byte "
    (& (string.int->string error.offset))))

(define (tli-sysroot-directory
  [path : (& path str)]
  [triple : (& triple str)]
  [verify-content? : bool]) : TliSysrootDirectory
  (match (tli-inspect-read-file path)
    [(Err error) (Err error)]
    [(Ok bytes)
      (let
        [build : String (identity.compiler-build-producer-identity)]
        (match (tli_codec.tli-decode-directory-for-snapshot
          bytes
          (& build)
          triple
          verify-content?)
          [(Err error) (Err (tli-sysroot-decode-message (& error)))]
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
        [message : String
          (match (tli-sysroot-directory (& path) (& triple) false)
            [(Err error) error]
            [(Ok directory)
              (let
                [cfg-digest : (Array u8 32) (make-array u8 32)]
                (match (hydrate.tli-catalog-open-from-directory
                  (tli_codec.TliDirectoryResult.Ok directory)
                  (& cfg-digest))
                  [(Err error) (tli-sysroot-decode-message (& error))]
                  [(Ok catalog)
                    ;; The compile job checks cfgs using its effective options.
                    (match (hydrate.tli-catalog-check-prelude catalog)
                      [(Ok _) ""]
                      [(Err error) (tli-sysroot-decode-message (& error))])]))])]
        (if (= (string.string-length (& message)) 0)
          ""
          (str_cat.str-cat "build: " path ": " message "\n")))]
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
      (match (tli-sysroot-directory (& path) (& triple) true)
        [(Err error)
          (io.print-error (str_cat.str-cat "inspect: " path ": " error "\n"))
          1]
        [(Ok directory) (tli-inspect-render-directory (& directory))])]))

(define (tli-inspect-sysroot [idx : i64] [count : i64]) : i64
  (with-arena tli-job (tli-inspect-sysroot-in-job idx count)))