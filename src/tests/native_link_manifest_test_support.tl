;; Pure fixtures shared by the semantic and codec tests.
(import native_link_manifest_types as n)
(import native_link_manifest_profiles as profiles)
(import native_link_manifest_builder as builder)
(import native_link_manifest_codec as codec)
(import native_link_manifest_core as core)
(import stdlib.iterator)
(import stdlib.string)

(define (sample [windows : bool]) : n.NativeLinkSemanticInput
  (let
    [profile : n.NativeToolchainProfile
      (profiles.freestanding-profile
        (if windows
          (n.WindowsX86_64)
          (n.LinuxX86_64)))]
    [output : n.NativeOutputKind (n.FreestandingStaticExecutable)]
    [events : builder.NativeEventBuilder (builder.event-builder 32)]
    [limits : core.NativeLinkLimits (core.default-limits)]
    (builder.append-profile-controls! (&mut events) (& profile) (& output))
    (match (builder.finish
      events
      (& profile)
      output
      "example.app"
      (__tl_make-array n.LogicalRoot 0)
      (n.HermeticInputs)
      (& limits))
      [(builder.BuiltManifest manifest)
        (n.NativeLinkSemanticInput manifest profile)]
      [_ (stdlib.string.tl_oob_abort)])))

(define (rebind-profile! [input : (&mut i n.NativeLinkSemanticInput)]) : unit
  (let
    [limits : core.NativeLinkLimits (core.default-limits)]
    (match (codec.profile-identity (& input.profile) (& limits.wire))
      [(codec.NativeDigest identity)
        (set! input.manifest.profile.content identity)]
      [_ (stdlib.string.tl_oob_abort)])))

(define (rejects? [input : (& i n.NativeLinkSemanticInput)]) : bool
  (let
    [limits : core.NativeLinkLimits (core.default-limits)]
    [result : core.NativeLinkValidation (core.validate input (& limits))]
    (not result.ok)))

(define (has-reason?
  [result : (& r core.NativeLinkValidation)]
  [reason : core.NativeLinkReason]) : bool
  (for [i (iterator.range 0 result.count)]
    (when (= (array-ref result.diagnostics i).reason reason) (return true)))
  false)

;; Attested identities exercise the sealed-profile schema only. No test reads
;; a toolchain file or claims that the dummy hashes were observed on disk.
(define (sealed-sample) : n.NativeLinkSemanticInput
  (let
    [profile : n.NativeToolchainProfile
      (profiles.freestanding-profile (n.WindowsX86_64))]
    [limits : core.NativeLinkLimits (core.default-limits)]
    [events : builder.NativeEventBuilder (builder.event-builder 16)]
    [output : n.NativeOutputKind (n.StaticExecutable)]
    [digest : (Array u8 32) (make-array u8 32)]
    [roots : (__tl_dyn-array n.LogicalRoot) (__tl_make-array n.LogicalRoot 2)]
    (for [i (iterator.range 0 32)]
      (set! (array-ref digest i) (cast 0 : u8)))
    (set! profile.id "test.sealed-msvc.v1")
    (set! profile.runtime (n.MsvcRuntime))
    (set!
      profile.runtime-floor
      (n.RuntimeVersion (cast 14 : u32) (cast 0 : u32) (cast 0 : u32)))
    (set! profile.entry (n.RuntimeEntry "mainCRTStartup"))
    (set! profile.startup (n.CrtStartup "crt0"))
    (set! (array-ref profile.runtime-identities 0) "typelisp.msvc-runtime.v1")
    (set! (array-ref profile.outputs 2) (n.StaticExecutable))
    (for [i (iterator.range 0 (array-length profile.capabilities))]
      (match (array-ref profile.capabilities i).kind
        [(n.OutputFreestandingStatic)
          (set!
            (array-ref profile.capabilities i).support
            (n.Unsupported (n.CompilerFreestandingOnly)))
          (set! (array-ref profile.capabilities i).helper-id "")]
        [(n.OutputStatic)
          (set!
            (array-ref profile.capabilities i).support
            (n.Supported (n.Implemented)))
          (set!
            (array-ref profile.capabilities i).helper-id
            "typelisp.runtime.v1")]
        [_ unit]))
    (set! profile.roots (__tl_make-array n.LogicalRoot 2))
    (set! profile.files (__tl_make-array n.ProfileFile 2))
    (set! profile.inputs (__tl_make-array n.ProfileInput 2))
    (for [i (iterator.range 0 2)]
      (let
        [root : String
          (if (= i 0)
            "sdk-a"
            "sdk-b")]
        [file : String
          (if (= i 0)
            "crt0"
            "crtend")]
        (set!
          (array-ref roots i)
          (n.LogicalRoot
            (if (= i 0)
              "input-a"
              "input-b")
            (n.UnspecifiedContent)))
        (set!
          (array-ref profile.roots i)
          (n.LogicalRoot (clone root) (n.UnspecifiedContent)))
        (set!
          (array-ref profile.files i)
          (n.ProfileFile
            (clone file)
            (n.NativePathRef
              root
              (if (= i 0)
                "crt0.obj"
                "crtend.obj")
              (n.ObjectFile)
              (n.ExactContent (n.ContentIdentity (cast 1 : u32) (clone digest))))))
        (set!
          (array-ref profile.inputs i)
          (n.ProfileInput
            (if (= i 0)
              (n.StartupInput)
              (n.EndInput))
            file
            (n.ProfileRowOrigin (clone profile.id) "crt" (cast i : u64))))))
    (builder.append-profile-controls! (&mut events) (& profile) (& output))
    (match (builder.finish
      events
      (& profile)
      output
      "test.app"
      roots
      (n.HermeticInputs)
      (& limits))
      [(builder.BuiltManifest value) (n.NativeLinkSemanticInput value profile)]
      [_ (stdlib.string.tl_oob_abort)])))