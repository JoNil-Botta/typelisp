;; compiler_x64_executable_template.tl - Closed x86-64 template gate types.
;; SPEC 3.5.1 makes a nullary enum its 0-based 8-byte tag. Registry code uses
;; this representation helper only for closed, bounds-checked enum tables.
(defmacro (compiler-x64-template-enum-tag [value : Expr]) : Expr
  `(let
    [compiler-x64-template-enum-tag-value ,value]
    (unsafe
      (ptr-read
        (ptr-cast
          (ptr-addr-of compiler-x64-template-enum-tag-value)
          : (Ptr i64))))))

(defenum CompilerX64ExecutableTemplateId
  (CommonProfile)
  (CommonStartupProfile)
  (LinuxRuntimeMemcpy)
  (LinuxRuntimeMemchr)
  (LinuxRuntimeMemFill8)
  (LinuxRuntimeArrayZero)
  (LinuxRuntimeTlciImage)
  (LinuxRuntimeTlciMacro)
  (LinuxRuntimeBacktrace)
  (LinuxRuntimeArena)
  (LinuxRuntimeArenaDebug)
  (LinuxRuntimeArenaProfile)
  (LinuxRuntimeArenaProfileDebug)
  (LinuxRuntimeAlloc)
  (LinuxRuntimeAllocDebug)
  (LinuxRuntimeAllocProfile)
  (LinuxRuntimeAllocProfileDebug)
  (LinuxRuntimeRegionMark)
  (LinuxRuntimeRegionReset)
  (LinuxRuntimeRegionResetDebug)
  (LinuxRuntimeRegionResetProfile)
  (LinuxRuntimeRegionResetProfileDebug)
  (WindowsRuntimeMemcpy)
  (WindowsRuntimeMemchr)
  (WindowsRuntimeMemFill8)
  (WindowsRuntimeArrayZero)
  (WindowsRuntimeTlciImage)
  (WindowsRuntimeTlciMacro)
  (WindowsRuntimeBacktrace)
  (WindowsRuntimeArena)
  (WindowsRuntimeArenaDebug)
  (WindowsRuntimeArenaProfile)
  (WindowsRuntimeArenaProfileDebug)
  (WindowsRuntimeAlloc)
  (WindowsRuntimeAllocDebug)
  (WindowsRuntimeAllocProfile)
  (WindowsRuntimeAllocProfileDebug)
  (WindowsRuntimeRegionMark)
  (WindowsRuntimeRegionReset)
  (WindowsRuntimeRegionResetDebug)
  (WindowsRuntimeRegionResetProfile)
  (WindowsRuntimeRegionResetProfileDebug)
  (WindowsRuntimeThread)
  (WindowsRuntimeLibcShim)
  (WindowsRuntimeLibcShimStartupProfile)
  (LinuxStartupPrefix)
  (LinuxStartupPrefixStartupProfile)
  (LinuxStartupTail)
  (LinuxStartupTailBacktrace)
  (LinuxObjectTlciImageBytes)
  (LinuxObjectTlciMacroBytes)
  (LinuxObjectExitBytes)
  (WindowsObjectChkstkBytes)
  (WindowsObjectSetupPreGetcmdBytes)
  (WindowsObjectSetupAfterGetcmdBytes)
  (WindowsObjectSetupAfterBoot1Bytes)
  (WindowsObjectSetupAfterBoot2Bytes)
  (WindowsObjectSetupEpilogueBytes)
  (WindowsObjectAddRdxRaxBytes)
  (WindowsObjectRetBytes)
  (WindowsObjectTlciImageBytes)
  (WindowsObjectTlciMacroBytes)
  (WindowsObjectEntryGsClearBytes)
  (WindowsObjectConvertFiberArgsBytes)
  (WindowsObjectCreateFiberArgsBytes)
  (WindowsObjectCreateFiberTailBytes)
  (WindowsObjectStackGuaranteeArgsBytes)
  (WindowsObjectStderrHandleArgsBytes)
  (WindowsObjectWriteFailureTailBytes)
  (WindowsObjectWriteOverflowTailBytes)
  (WindowsObjectExit134ArgsBytes)
  (WindowsObjectOverflowFilterTestBytes)
  (WindowsObjectOverflowFilterReturnBytes)
  (LinuxObjectTlciImageContribution)
  (LinuxObjectTlciMacroContribution)
  (LinuxObjectStartContribution)
  (WindowsObjectTlciImageContribution)
  (WindowsObjectTlciMacroContribution)
  (WindowsObjectRuntimeSupportContribution)
  (WindowsObjectStartContribution)
  (WindowsObjectMainFiberContribution)
  (WindowsObjectOverflowFilterContribution))

(defenum CompilerX64TemplateTarget
  (AnyX64)
  (LinuxX64)
  (WindowsX64))

(defenum CompilerX64TemplateRenderKind
  (Assembly)
  (OpaqueBytes)
  (StructuredObject))

(define (compiler-x64-template-target-matches?
  [expected : CompilerX64TemplateTarget]
  [actual : CompilerX64TemplateTarget]) : bool
  (let
    [expected-tag : i64 (compiler-x64-template-enum-tag expected)]
    (or
      (= expected-tag 0)
      (= expected-tag (compiler-x64-template-enum-tag actual)))))