;; Exhaustive ID enumeration and runtime feature selection for x86-64 templates.
(import compiler_x64_executable_template as x64)
(import stdlib.io)

(defstruct CompilerX64TemplateFeatures
  (alloc bool)
  (region-mark bool)
  (region-reset bool)
  (profile bool)
  (startup-profile bool)
  (tlci-macro-entry bool)
  (arena-debug bool)
  (backtrace bool)
  (leaf-mask i64))

(defstruct CompilerX64ExecutableTemplateIdList
  (slots (__tl_dyn-array x64.CompilerX64ExecutableTemplateId))
  (len i64))

(define (compiler-x64-template-id-list-ref
  [ids : (& ids CompilerX64ExecutableTemplateIdList)]
  [index : i64]) : x64.CompilerX64ExecutableTemplateId
  (unsafe
    (ptr-read (ptr-offset (__tl_array-data ids.slots) index))))

(define (compiler-x64-template-id-from-index [index : i64]) : x64.CompilerX64ExecutableTemplateId
  (if (or (< index 0) (>= index 84))
    (io.panic "x64 executable template: id index is out of range")
    (unsafe
      (ptr-read
        (ptr-cast
          (ptr-addr-of index)
          : (Ptr x64.CompilerX64ExecutableTemplateId))))))

(define (compiler-x64-template-all-ids) : CompilerX64ExecutableTemplateIdList
  (let
    [ids : CompilerX64ExecutableTemplateIdList
      (CompilerX64ExecutableTemplateIdList
        (__tl_make-array x64.CompilerX64ExecutableTemplateId 96)
        0)]
    [index : i64 0]
    (begin
      (while (< index 84)
        (begin
          (compiler-x64-template-id-list-push!
            (&mut ids)
            (compiler-x64-template-id-from-index index))
          (set! index (+ index 1))))
      ids)))

(define (compiler-x64-template-id-list-push!
  [ids : (&mut ids CompilerX64ExecutableTemplateIdList)]
  [id : x64.CompilerX64ExecutableTemplateId]) : unit
  (begin
    (set! (array-ref ids.slots ids.len) id)
    (set! ids.len (+ ids.len 1))))

(define (compiler-x64-template-select-four
  [plain : x64.CompilerX64ExecutableTemplateId]
  [debug : x64.CompilerX64ExecutableTemplateId]
  [profile : x64.CompilerX64ExecutableTemplateId]
  [profile-debug : x64.CompilerX64ExecutableTemplateId]
  [profile? : bool]
  [debug? : bool]) : x64.CompilerX64ExecutableTemplateId
  (if profile?
    (if debug?
      profile-debug
      profile)
    (if debug?
      debug
      plain)))

(define (compiler-x64-runtime-template-selection
  [target : x64.CompilerX64TemplateTarget]
  [features : (& features CompilerX64TemplateFeatures)]) : CompilerX64ExecutableTemplateIdList
  (let
    [ids : CompilerX64ExecutableTemplateIdList
      (CompilerX64ExecutableTemplateIdList
        (__tl_make-array x64.CompilerX64ExecutableTemplateId 20)
        0)]
    (begin
      (match target
        [(LinuxX64)
          (begin
            (compiler-x64-template-id-list-push!
              (&mut ids)
              (LinuxRuntimeMemcpy))
            (when
              (!= (bit-and features.leaf-mask 4) 0)
              (compiler-x64-template-id-list-push!
                (&mut ids)
                (LinuxRuntimeCopyFwd)))
            (when
              (!= (bit-and features.leaf-mask 8) 0)
              (compiler-x64-template-id-list-push!
                (&mut ids)
                (LinuxRuntimeCopy8Fwd)))
            (when
              (!= (bit-and features.leaf-mask 1) 0)
              (compiler-x64-template-id-list-push!
                (&mut ids)
                (LinuxRuntimeMemchr)))
            (compiler-x64-template-id-list-push!
              (&mut ids)
              (LinuxRuntimeArrayZero))
            (when
              (!= (bit-and features.leaf-mask 16) 0)
              (compiler-x64-template-id-list-push!
                (&mut ids)
                (LinuxRuntimeMemFill8)))
            (when
              (!= (bit-and features.leaf-mask 2) 0)
              (compiler-x64-template-id-list-push!
                (&mut ids)
                (LinuxRuntimeTlciImage)))
            (when
              features.tlci-macro-entry
              (compiler-x64-template-id-list-push!
                (&mut ids)
                (LinuxRuntimeTlciMacro)))
            (when
              features.backtrace
              (compiler-x64-template-id-list-push!
                (&mut ids)
                (LinuxRuntimeBacktrace)))
            (compiler-x64-template-id-list-push!
              (&mut ids)
              (compiler-x64-template-select-four
                (LinuxRuntimeArena)
                (LinuxRuntimeArenaDebug)
                (LinuxRuntimeArenaProfile)
                (LinuxRuntimeArenaProfileDebug)
                features.profile
                features.arena-debug))
            (when
              features.profile
              (compiler-x64-template-id-list-push! (&mut ids) (CommonProfile)))
            (when
              features.startup-profile
              (compiler-x64-template-id-list-push!
                (&mut ids)
                (CommonStartupProfile)))
            (when
              features.alloc
              (compiler-x64-template-id-list-push!
                (&mut ids)
                (compiler-x64-template-select-four
                  (LinuxRuntimeAlloc)
                  (LinuxRuntimeAllocDebug)
                  (LinuxRuntimeAllocProfile)
                  (LinuxRuntimeAllocProfileDebug)
                  features.profile
                  features.arena-debug)))
            (when
              features.region-mark
              (compiler-x64-template-id-list-push!
                (&mut ids)
                (LinuxRuntimeRegionMark)))
            (when
              features.region-reset
              (compiler-x64-template-id-list-push!
                (&mut ids)
                (compiler-x64-template-select-four
                  (LinuxRuntimeRegionReset)
                  (LinuxRuntimeRegionResetDebug)
                  (LinuxRuntimeRegionResetProfile)
                  (LinuxRuntimeRegionResetProfileDebug)
                  features.profile
                  features.arena-debug))))]
        [(WindowsX64)
          (begin
            (compiler-x64-template-id-list-push!
              (&mut ids)
              (WindowsRuntimeMemcpy))
            (compiler-x64-template-id-list-push!
              (&mut ids)
              (WindowsRuntimeMemchr))
            (compiler-x64-template-id-list-push!
              (&mut ids)
              (WindowsRuntimeArrayZero))
            (compiler-x64-template-id-list-push!
              (&mut ids)
              (WindowsRuntimeMemFill8))
            (compiler-x64-template-id-list-push!
              (&mut ids)
              (WindowsRuntimeTlciImage))
            (when
              features.tlci-macro-entry
              (compiler-x64-template-id-list-push!
                (&mut ids)
                (WindowsRuntimeTlciMacro)))
            (compiler-x64-template-id-list-push!
              (&mut ids)
              (compiler-x64-template-select-four
                (WindowsRuntimeArena)
                (WindowsRuntimeArenaDebug)
                (WindowsRuntimeArenaProfile)
                (WindowsRuntimeArenaProfileDebug)
                features.profile
                features.arena-debug))
            (when
              features.profile
              (compiler-x64-template-id-list-push! (&mut ids) (CommonProfile)))
            (when
              features.startup-profile
              (compiler-x64-template-id-list-push!
                (&mut ids)
                (CommonStartupProfile)))
            (when
              features.alloc
              (compiler-x64-template-id-list-push!
                (&mut ids)
                (compiler-x64-template-select-four
                  (WindowsRuntimeAlloc)
                  (WindowsRuntimeAllocDebug)
                  (WindowsRuntimeAllocProfile)
                  (WindowsRuntimeAllocProfileDebug)
                  features.profile
                  features.arena-debug)))
            (when
              features.region-mark
              (compiler-x64-template-id-list-push!
                (&mut ids)
                (WindowsRuntimeRegionMark)))
            (when
              features.region-reset
              (compiler-x64-template-id-list-push!
                (&mut ids)
                (compiler-x64-template-select-four
                  (WindowsRuntimeRegionReset)
                  (WindowsRuntimeRegionResetDebug)
                  (WindowsRuntimeRegionResetProfile)
                  (WindowsRuntimeRegionResetProfileDebug)
                  features.profile
                  features.arena-debug)))
            (compiler-x64-template-id-list-push!
              (&mut ids)
              (WindowsRuntimeThread))
            (when
              features.backtrace
              (compiler-x64-template-id-list-push!
                (&mut ids)
                (WindowsRuntimeBacktrace)))
            (compiler-x64-template-id-list-push!
              (&mut ids)
              (if features.startup-profile
                (WindowsRuntimeLibcShimStartupProfile)
                (WindowsRuntimeLibcShim))))]
        [(AnyX64) unit])
      ids)))

(define (compiler-x64-template-selection-unique?
  [ids : (& ids CompilerX64ExecutableTemplateIdList)]) : bool
  (let
    [outer : i64 0]
    [ok : bool true]
    (begin
      (while (and ok (< outer ids.len))
        (let
          [inner : i64 (+ outer 1)]
          (begin
            (while (and ok (< inner ids.len))
              (begin
                (when
                  (=
                    (x64.compiler-x64-template-enum-tag
                      (compiler-x64-template-id-list-ref ids outer))
                    (x64.compiler-x64-template-enum-tag
                      (compiler-x64-template-id-list-ref ids inner)))
                  (set! ok false))
                (set! inner (+ inner 1))))
            (set! outer (+ outer 1)))))
      ok)))