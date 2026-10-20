(import native_link_manifest_types as n)
(import native_link_manifest_profiles as profiles)
(import native_link_manifest_builder as builder)
(import native_link_manifest_core as core)
(import native_link_manifest_codec as codec)
(import native_link_manifest as manifest)
(import stdlib.iterator)
(import stdlib.string)
(import stdlib.byte_buf_core as buf)

(define (argument-bytes) : String
  (let
    [bytes : buf.ByteBufBuilder (buf.byte-buf-builder-with-capacity 300)]
    (buf.byte-buf-builder-append-string
      (&mut bytes)
      " @literal ; $HOME -Wl,a,b ")
    (for [byte (iterator.range 1 256)]
      (buf.byte-buf-builder-push (&mut bytes) (cast byte : u8)))
    (buf.byte-buf-builder-to-string (& bytes))))

(define (main) : i64
  (let
    [limits : core.NativeLinkLimits (core.default-limits)]
    [argument : String (argument-bytes)]
    (for [target (iterator.range 0 2)]
      (let
        [profile : n.NativeToolchainProfile
          (profiles.freestanding-profile
            (if (= target 0)
              (n.LinuxX86_64)
              (n.WindowsX86_64)))]
        (for [mode (iterator.range 0 3)]
          (let
            [output : n.NativeOutputKind
              (clone (array-ref profile.outputs mode))]
            [events : builder.NativeEventBuilder (builder.event-builder 17)]
            (builder.append-profile-controls!
              (&mut events)
              (& profile)
              (& output))
            (builder.append!
              (&mut events)
              (n.CommandLineOrigin (cast 4 : u64))
              (n.ExternalArgument (n.ExternalCompatibilityArg (clone argument))))
            (match (builder.finish
              events
              (& profile)
              output
              "native.example"
              (__tl_make-array n.LogicalRoot 0)
              (n.ExplicitExternalCompatibility)
              (& limits))
              [(builder.BuiltManifest value)
                (let
                  [input : n.NativeLinkSemanticInput
                    (n.NativeLinkSemanticInput value (clone profile))]
                  [options : n.PresentationOptions
                    (n.PresentationOptions false)]
                  [decision : core.NativeCapabilityDecision
                    (core.classify (& input) (core.ExternalBackend) (& limits))]
                  (when (not decision.validation.ok) (return 1))
                  (when (not decision.opaque-external-closure) (return 2))
                  (match (manifest.encode (& input) (& limits))
                    [(manifest.NativeCanonicalBytes bytes)
                      (match (manifest.decode (& bytes) (& limits))
                        [(manifest.NativeSemanticInput decoded)
                          (when
                            (not
                              (match (array-ref decoded.manifest.events 16).payload
                                [(n.ExternalArgument arg)
                                  (string.eq (& arg.argv-element) (& argument))]
                                [_ false]))
                            (return 3))
                          (match (manifest.encode (& decoded) (& limits))
                            [(manifest.NativeCanonicalBytes again)
                              (when
                                (not (codec.bytes-equal? (& bytes) (& again)))
                                (return 4))]
                            [_ (return 5)])]
                        [_ (return 6)])]
                    [_ (return 7)])
                  (when
                    (not
                      (match (manifest.fingerprint (& input) (& limits))
                        [(manifest.NativeFingerprint _) true]
                        [_ false]))
                    (return 8))
                  (when
                    (not
                      (match (manifest.render-human
                        (& input)
                        (& options)
                        1048576
                        (& limits))
                        [(manifest.NativeRendered _) true]
                        [_ false]))
                    (return 9)))]
              [_ (return 10)])))))
    42))