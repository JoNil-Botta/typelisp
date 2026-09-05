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
  (backtrace bool))

(defstruct CompilerX64ExecutableTemplateIdList
  (slots (__tl_dyn-array x64.CompilerX64ExecutableTemplateId))
  (len i64))

(define (compiler-x64-template-id-list-ref
  [ids : (& ids CompilerX64ExecutableTemplateIdList)]
  [index : i64]) : x64.CompilerX64ExecutableTemplateId
  (unsafe
    (ptr-read (ptr-offset (__tl_array-data ids.slots) index))))

(define (compiler-x64-template-id-from-index [index : i64]) : x64.CompilerX64ExecutableTemplateId
  (if (or (< index 0) (>= index 82))
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
      (while (< index 82)
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
        [(x64.CompilerX64TemplateTarget.LinuxX64)
          (begin
            (compiler-x64-template-id-list-push!
              (&mut ids)
              (x64.CompilerX64ExecutableTemplateId.LinuxRuntimeMemcpy))
            (compiler-x64-template-id-list-push!
              (&mut ids)
              (x64.CompilerX64ExecutableTemplateId.LinuxRuntimeMemchr))
            (compiler-x64-template-id-list-push!
              (&mut ids)
              (x64.CompilerX64ExecutableTemplateId.LinuxRuntimeArrayZero))
            (compiler-x64-template-id-list-push!
              (&mut ids)
              (x64.CompilerX64ExecutableTemplateId.LinuxRuntimeMemFill8))
            (compiler-x64-template-id-list-push!
              (&mut ids)
              (x64.CompilerX64ExecutableTemplateId.LinuxRuntimeTlciImage))
            (when
              features.tlci-macro-entry
              (compiler-x64-template-id-list-push!
                (&mut ids)
                (x64.CompilerX64ExecutableTemplateId.LinuxRuntimeTlciMacro)))
            (when
              features.backtrace
              (compiler-x64-template-id-list-push!
                (&mut ids)
                (x64.CompilerX64ExecutableTemplateId.LinuxRuntimeBacktrace)))
            (compiler-x64-template-id-list-push!
              (&mut ids)
              (compiler-x64-template-select-four
                (x64.CompilerX64ExecutableTemplateId.LinuxRuntimeArena)
                (x64.CompilerX64ExecutableTemplateId.LinuxRuntimeArenaDebug)
                (x64.CompilerX64ExecutableTemplateId.LinuxRuntimeArenaProfile)
                (x64.CompilerX64ExecutableTemplateId.LinuxRuntimeArenaProfileDebug)
                features.profile
                features.arena-debug))
            (when
              features.profile
              (compiler-x64-template-id-list-push!
                (&mut ids)
                (x64.CompilerX64ExecutableTemplateId.CommonProfile)))
            (when
              features.startup-profile
              (compiler-x64-template-id-list-push!
                (&mut ids)
                (x64.CompilerX64ExecutableTemplateId.CommonStartupProfile)))
            (when
              features.alloc
              (compiler-x64-template-id-list-push!
                (&mut ids)
                (compiler-x64-template-select-four
                  (x64.CompilerX64ExecutableTemplateId.LinuxRuntimeAlloc)
                  (x64.CompilerX64ExecutableTemplateId.LinuxRuntimeAllocDebug)
                  (x64.CompilerX64ExecutableTemplateId.LinuxRuntimeAllocProfile)
                  (x64.CompilerX64ExecutableTemplateId.LinuxRuntimeAllocProfileDebug)
                  features.profile
                  features.arena-debug)))
            (when
              features.region-mark
              (compiler-x64-template-id-list-push!
                (&mut ids)
                (x64.CompilerX64ExecutableTemplateId.LinuxRuntimeRegionMark)))
            (when
              features.region-reset
              (compiler-x64-template-id-list-push!
                (&mut ids)
                (compiler-x64-template-select-four
                  (x64.CompilerX64ExecutableTemplateId.LinuxRuntimeRegionReset)
                  (x64.CompilerX64ExecutableTemplateId.LinuxRuntimeRegionResetDebug)
                  (x64.CompilerX64ExecutableTemplateId.LinuxRuntimeRegionResetProfile)
                  (x64.CompilerX64ExecutableTemplateId.LinuxRuntimeRegionResetProfileDebug)
                  features.profile
                  features.arena-debug))))]
        [(x64.CompilerX64TemplateTarget.WindowsX64)
          (begin
            (compiler-x64-template-id-list-push!
              (&mut ids)
              (x64.CompilerX64ExecutableTemplateId.WindowsRuntimeMemcpy))
            (compiler-x64-template-id-list-push!
              (&mut ids)
              (x64.CompilerX64ExecutableTemplateId.WindowsRuntimeMemchr))
            (compiler-x64-template-id-list-push!
              (&mut ids)
              (x64.CompilerX64ExecutableTemplateId.WindowsRuntimeArrayZero))
            (compiler-x64-template-id-list-push!
              (&mut ids)
              (x64.CompilerX64ExecutableTemplateId.WindowsRuntimeMemFill8))
            (compiler-x64-template-id-list-push!
              (&mut ids)
              (x64.CompilerX64ExecutableTemplateId.WindowsRuntimeTlciImage))
            (when
              features.tlci-macro-entry
              (compiler-x64-template-id-list-push!
                (&mut ids)
                (x64.CompilerX64ExecutableTemplateId.WindowsRuntimeTlciMacro)))
            (compiler-x64-template-id-list-push!
              (&mut ids)
              (compiler-x64-template-select-four
                (x64.CompilerX64ExecutableTemplateId.WindowsRuntimeArena)
                (x64.CompilerX64ExecutableTemplateId.WindowsRuntimeArenaDebug)
                (x64.CompilerX64ExecutableTemplateId.WindowsRuntimeArenaProfile)
                (x64.CompilerX64ExecutableTemplateId.WindowsRuntimeArenaProfileDebug)
                features.profile
                features.arena-debug))
            (when
              features.profile
              (compiler-x64-template-id-list-push!
                (&mut ids)
                (x64.CompilerX64ExecutableTemplateId.CommonProfile)))
            (when
              features.startup-profile
              (compiler-x64-template-id-list-push!
                (&mut ids)
                (x64.CompilerX64ExecutableTemplateId.CommonStartupProfile)))
            (when
              features.alloc
              (compiler-x64-template-id-list-push!
                (&mut ids)
                (compiler-x64-template-select-four
                  (x64.CompilerX64ExecutableTemplateId.WindowsRuntimeAlloc)
                  (x64.CompilerX64ExecutableTemplateId.WindowsRuntimeAllocDebug)
                  (x64.CompilerX64ExecutableTemplateId.WindowsRuntimeAllocProfile)
                  (x64.CompilerX64ExecutableTemplateId.WindowsRuntimeAllocProfileDebug)
                  features.profile
                  features.arena-debug)))
            (when
              features.region-mark
              (compiler-x64-template-id-list-push!
                (&mut ids)
                (x64.CompilerX64ExecutableTemplateId.WindowsRuntimeRegionMark)))
            (when
              features.region-reset
              (compiler-x64-template-id-list-push!
                (&mut ids)
                (compiler-x64-template-select-four
                  (x64.CompilerX64ExecutableTemplateId.WindowsRuntimeRegionReset)
                  (x64.CompilerX64ExecutableTemplateId.WindowsRuntimeRegionResetDebug)
                  (x64.CompilerX64ExecutableTemplateId.WindowsRuntimeRegionResetProfile)
                  (x64.CompilerX64ExecutableTemplateId.WindowsRuntimeRegionResetProfileDebug)
                  features.profile
                  features.arena-debug)))
            (compiler-x64-template-id-list-push!
              (&mut ids)
              (x64.CompilerX64ExecutableTemplateId.WindowsRuntimeThread))
            (when
              features.backtrace
              (compiler-x64-template-id-list-push!
                (&mut ids)
                (x64.CompilerX64ExecutableTemplateId.WindowsRuntimeBacktrace)))
            (compiler-x64-template-id-list-push!
              (&mut ids)
              (if features.startup-profile
                (x64.CompilerX64ExecutableTemplateId.WindowsRuntimeLibcShimStartupProfile)
                (x64.CompilerX64ExecutableTemplateId.WindowsRuntimeLibcShim))))]
        [(x64.CompilerX64TemplateTarget.AnyX64) unit])
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