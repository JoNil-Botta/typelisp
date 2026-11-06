;# Strict bounded X.509 certificate decoding; no trust or signature decisions.
;#
;# Successful certificates own one exact DER copy. All binary fields are
;# copyable ranges into that owner, never lossy Strings. `view` borrows ranges.
;# Known extensions are decoded; every extension (including unknown critical
;# extensions) retains its OID, critical flag and exact value for path policy.
;# Algorithm identifiers must match byte-for-byte inside/outside the TBS.
;# Parsing recognizes RSA, RSA-PSS, P-256 ECDSA and Ed25519 encodings without
;# advertising cryptographic support. Unknown algorithms remain identifiable.
;# GeneralName supports rfc822Name, dNSName, URI, iPAddress, registeredID,
;# otherName, directoryName and ediPartyName. x400Address is unsupported and
;# fails the whole certificate with UnsupportedGeneralName(3), never a partial
;# SAN/constraint list. Invalid encodings retain malformed-DER/schema errors.
;#
;# `service-reference` constructs independent ASCII DNS/IP references;
;# `service-identity` matches only parsed leaf SANs under RFC 9525. It never
;# reads subject/Common Name or SNI and makes no trust/path/validity decision.
;# DNS matching accepts one root dot and complete left-most-label wildcards.
;# The caller can disallow wildcards; allowing them provides no PSL protection.
;# V1 rejects U-labels with InternationalizedNameUnsupported. ASCII xn-- labels
;# are compared case-insensitively; full IDNA2008 validation belongs to #7269.
;# All identity data is public. Comparison is variable-time; this module
;# processes no secret state and adds no secret stack-spill exposure.
;#
;# ```typelisp
;# (import stdlib.x509)
;# (import stdlib.byte_buf)
;# (define (main) : i64
;#   (let [empty : byte_buf.ByteBuf (byte_buf.new)]
;#     (match (x509.parse-der (byte_buf.as-bytes (& empty)) (x509.default-limits))
;#       [(x509.CertificateOk _) 1]
;#       [(x509.CertificateErr error) (if (= error.offset 0) 42 1)])))
;# ```
;#
;# ```typelisp
;# (import stdlib.x509)
;# (define (main) : i64
;#   (match (x509.service-reference "www.example.test.")
;#     [(x509.ServiceReferenceErr _) 1]
;#     [(x509.ServiceReferenceOk reference)
;#       (let [references : x509.ServiceReferences (x509.service-references-new)]
;#         (match (x509.service-reference-add! (&mut references) reference
;#           (x509.service-identity-default-limits))
;#           [(x509.ServiceReferenceAdded) 42]
;#           [(x509.ServiceReferenceAddErr _) 1]))]))
;# ```
(import stdlib.asn1_der as der)
(import stdlib.byte_buf)
(import stdlib.net.ip)
(import stdlib.pem)
(import stdlib.string)
(import stdlib.vector)
(import stdlib.x509_time as time)
(import (vector.vector pem.Block core) as pem_blocks)

;: Per-certificate DER, serial, extension and name budgets and PEM bundle caps.
(defstruct Limits
  (der der.Limits)
  (max-serial-bytes i64)
  (max-extensions i64)
  (max-names i64)
  (pem pem.Limits))

;: Serial policy is positive, nonzero, at most 20 encoded content octets.
(define (default-limits) : Limits
  (Limits (der.default-limits) 20 128 1024 (pem.default-limits)))

;: Validate all budgets before a DER or PEM entry point touches payload storage.
(define (limits-valid? [limits : Limits]) : bool
  (and
    (der.limits-valid? limits.der)
    (>= limits.max-serial-bytes 1)
    (<= limits.max-serial-bytes 20)
    (>= limits.max-extensions 0)
    (>= limits.max-names 0)
    (>= limits.pem.max-input-bytes 0)
    (>= limits.pem.max-certificate-bytes 0)
    (>= limits.pem.max-total-bytes 0)
    (>= limits.pem.max-certificates 0)))

;: Exact algorithm, OID contents and optional encoded parameters.
(defstruct Algorithm
  (encoded der.Range)
  (oid der.Range)
  (parameters der.Range))

;: One AttributeTypeAndValue, retaining RDN grouping, complete encoding and
;: the exact ANY value identifier/content; unknown attribute types stay opaque.
(defstruct Attribute
  (rdn i64)
  (oid der.Range)
  (encoded der.Range)
  (tag-class i64)
  (tag i64)
  (constructed bool)
  (value der.Range))

(import (vector.vector Attribute core) as attributes)
(import (vector.vector der.Range core) as ranges)

;: Encoded Name and its ordered RDN attributes; no string normalization occurs.
(defstruct Name
  (encoded der.Range)
  (attributes attributes.Vec))

;: Typed IP payload for GeneralName and IP constraint masks.
(defenum Address
  (NoAddress)
  (Address ip.IpAddr))

;: GeneralName CHOICE tag (0..8), exact encoded/value ranges and optional IP.
;: DNS, rfc822 and URI retain validated ASCII bytes; matching belongs elsewhere.
(defstruct GeneralName
  (kind i64)
  (encoded der.Range)
  (value der.Range)
  (address Address))

(import (vector.vector GeneralName core) as general_names)

;: One permitted/excluded subtree. IP masks use the shared typed address family.
(defstruct Constraint
  (excluded bool)
  (base GeneralName)
  (mask Address))

(import (vector.vector Constraint core) as constraints)

;: Exact extension metadata. `kind` is its 2.5.29 suffix, or -1 when unknown.
(defstruct Extension
  (oid der.Range)
  (critical bool)
  (encoded der.Range)
  (value der.Range)
  (kind i64))

(import (vector.vector Extension core) as extensions)

;: Decoded basic constraints; -1 means pathLenConstraint absent.
(defstruct BasicConstraints
  (present bool)
  (ca bool)
  (path-length i64))

;: Authority key identifier components. Empty ranges denote absent fields.
(defstruct AuthorityKeyIdentifier
  (key-id der.Range)
  (issuer general_names.Vec)
  (serial der.Range))

;: Owned certificate model; all ranges refer to `der`, including encapsulations.
;: key-usage=-1 denotes absent; otherwise bit 0 is digitalSignature, through
;: bit 8 decipherOnly. Empty EKU/SAN/constraint vectors denote absent extensions.
(defstruct Certificate
  (der byte_buf.ByteBuf)
  (version i64)
  (serial der.Range)
  (tbs der.Range)
  (tbs-signature-algorithm Algorithm)
  (signature-algorithm Algorithm)
  (issuer Name)
  (subject Name)
  (validity der.Range)
  (not-before time.Instant)
  (not-after time.Instant)
  (spki der.Range)
  (public-key-algorithm Algorithm)
  (public-key der.Range)
  (signature der.Range)
  (issuer-unique-id der.Range)
  (subject-unique-id der.Range)
  (extensions extensions.Vec)
  (basic-constraints BasicConstraints)
  (key-usage i64)
  (extended-key-usage ranges.Vec)
  (subject-key-id der.Range)
  (authority-key-id AuthorityKeyIdentifier)
  (subject-alt-names general_names.Vec)
  (name-constraints constraints.Vec))

;: One complete certificate or a DER byte offset, with no partial model.
(defenum CertificateResult
  (CertificateOk Certificate)
  (CertificateErr der.Error))

(import (vector.vector Certificate core) as certificates)

;: PEM error coordinates: -1 is framing/base64 (offset in PEM), otherwise
;: `certificate-index` identifies a block and offset is in that decoded DER.
;: `source` retains the original envelope range for diagnostics without bytes.
(defstruct LoadError
  (error der.Error)
  (certificate-index i64)
  (source der.Range))

;: Complete bundle or one failure, never a partial certificate sequence.
(defenum CertificatesResult
  (CertificatesOk certificates.Vec)
  (CertificatesErr LoadError))

;: Borrow an exact range from a successful owner; invalid caller ranges trap.
(define (view [certificate : (& certificate Certificate)] [range : der.Range]) : (&
    certificate
    bytes)
  (byte_buf.bytes-slice-view
    (byte_buf.as-bytes (& certificate.der))
    range.start
    range.length))

;: Read into a local position while retaining errors in one shared sticky state.
(define (take-any!
  [input : (& input bytes)]
  [state : (&mut state der.Cursor)]
  [position : (&mut position i64)]
  [end : i64]) : der.Tlv
  (when state.failed (return (der.empty-tlv)))
  (let
    [local : der.Cursor (der.cursor (deref position) end)]
    [value : der.Tlv (der.read! input (&mut local))]
    (set! (deref position) local.position)
    (when local.failed (der.fail! state local.error.kind local.error.offset))
    value))

;: Read a schema field with an exact identifier.
(define (take!
  [input : (& input bytes)]
  [state : (&mut state der.Cursor)]
  [position : (&mut position i64)]
  [end : i64]
  [tag-class : i64]
  [tag : i64]
  [constructed : bool]) : der.Tlv
  (let
    [value : der.Tlv (take-any! input state position end)]
    (when
      (and
        (not state.failed)
        (or
          (!= value.tag-class tag-class)
          (!= value.tag tag)
          (!= value.constructed constructed)))
      (der.fail! state (der.InvalidTag) value.start))
    value))

;: Enforce complete schema consumption.
(define (complete!
  [state : (&mut state der.Cursor)]
  [position : i64]
  [end : i64]) : unit
  (when (!= position end) (der.fail! state (der.TrailingData) position)))

;: Match encoded OID content to a lower-case hexadecimal constant, without copy.
(define (oid-is? [input : (& input bytes)] [oid : der.Range] [hex : String]) : bool
  (when (!= (* oid.length 2) (string-length hex)) (return false))
  (let
    [position : i64 0]
    (while (< position oid.length)
      (let
        [high : i64 (cast (string-ref hex (* position 2)) : i64)]
        [low : i64 (cast (string-ref hex (+ (* position 2) 1)) : i64)]
        (set!
          high
          (if (<= high 57)
            (- high 48)
            (- high 87)))
        (set!
          low
          (if (<= low 57)
            (- low 48)
            (- low 87)))
        (when
          (!=
            (cast (byte_buf.bytes-ref input (+ oid.start position)) : i64)
            (+ (* high 16) low))
          (return false)))
      (set! position (+ position 1)))
    true))

;: Require positive canonical serial contents, including an implicit AKI serial.
(define (serial!
  [input : (& input bytes)]
  [state : (&mut state der.Cursor)]
  [value : der.Tlv]
  [cap : i64]) : der.Range
  (der.integer! input state value)
  (when
    (not state.failed)
    (when
      (or
        (> (- value.end value.content) cap)
        (>= (cast (byte_buf.bytes-ref input value.content) : i64) 128)
        (and
          (= (- value.end value.content) 1)
          (= (byte_buf.bytes-ref input value.content) (cast 0 : u8))))
      (der.fail! state (der.InvalidValue) value.content)))
  (der.contents value))

;: Read a canonical nonnegative integer that fits i64.
(define (small-integer!
  [input : (& input bytes)]
  [state : (&mut state der.Cursor)]
  [value : der.Tlv]) : i64
  (der.integer! input state value)
  (when state.failed (return 0))
  (when
    (or
      (> (- value.end value.content) 8)
      (>= (cast (byte_buf.bytes-ref input value.content) : i64) 128))
    (der.fail! state (der.InvalidValue) value.content)
    (return 0))
  (let
    [position : i64 value.content]
    [out : i64 0]
    (while (< position value.end)
      (set!
        out
        (+ (* out 256) (cast (byte_buf.bytes-ref input position) : i64)))
      (set! position (+ position 1)))
    out))

;: Parse one AlgorithmIdentifier; known parameter profiles are checked below.
(define (algorithm!
  [input : (& input bytes)]
  [state : (&mut state der.Cursor)]
  [value : der.Tlv]) : Algorithm
  (let
    [position : i64 value.content]
    [oid : der.Tlv (take! input state (&mut position) value.end 0 6 false)]
    [parameters : der.Range (der.Range 0 0)]
    (when
      (and (not state.failed) (< position value.end))
      (set!
        parameters
        (der.encoded (take-any! input state (&mut position) value.end))))
    (complete! state position value.end)
    (Algorithm (der.encoded value) (der.contents oid) parameters)))

;: Read and parse an algorithm in sequence, keeping mutable borrows disjoint.
(define (next-algorithm!
  [input : (& input bytes)]
  [state : (&mut state der.Cursor)]
  [position : (&mut position i64)]
  [end : i64]) : Algorithm
  (let
    [value : der.Tlv (take! input state position end 0 16 true)]
    (algorithm! input state value)))

;: Read and decode one schema INTEGER.
(define (next-small!
  [input : (& input bytes)]
  [state : (&mut state der.Cursor)]
  [position : (&mut position i64)]
  [end : i64]) : i64
  (let
    [value : der.Tlv (take! input state position end 0 2 false)]
    (small-integer! input state value)))

;: Read and validate one positive INTEGER without narrowing it.
(define (next-serial!
  [input : (& input bytes)]
  [state : (&mut state der.Cursor)]
  [position : (&mut position i64)]
  [end : i64]
  [cap : i64]) : der.Range
  (let
    [value : der.Tlv (take! input state position end 0 2 false)]
    (serial! input state value cap)))

;: Read the one complete optional parameter value.
(define (parameter!
  [input : (& input bytes)]
  [state : (&mut state der.Cursor)]
  [algorithm : Algorithm]) : der.Tlv
  (let
    [position : i64 algorithm.parameters.start]
    (take-any!
      input
      state
      (&mut position)
      (+ position algorithm.parameters.length))))

;: Validate hash AlgorithmIdentifier parameters and return whether it is SHA-1.
(define (hash-algorithm!
  [input : (& input bytes)]
  [state : (&mut state der.Cursor)]
  [value : der.Tlv]) : bool
  (let
    [algorithm : Algorithm (algorithm! input state value)]
    (when
      (> algorithm.parameters.length 0)
      (let
        [parameter : der.Tlv (parameter! input state algorithm)]
        (when
          (or
            (!= parameter.tag-class 0)
            (!= parameter.tag 5)
            parameter.constructed
            (!= parameter.content parameter.end))
          (der.fail! state (der.InvalidValue) parameter.start))))
    (oid-is? input algorithm.oid "2b0e03021a")))

;: Validate PSS parameter ordering, DEFAULT omission and nested identifiers.
;: Omitted fields retain ASN.1 SHA-1/MGF1-SHA1/salt=20/trailer=1 defaults;
;: whether these algorithms are usable is a later signature-policy decision.
(define (pss!
  [input : (& input bytes)]
  [state : (&mut state der.Cursor)]
  [value : der.Tlv]) : unit
  (when
    (or (!= value.tag-class 0) (!= value.tag 16) (not value.constructed))
    (der.fail! state (der.InvalidTag) value.start)
    (return unit))
  (let
    [position : i64 value.content]
    [previous : i64 -1]
    (while (and (not state.failed) (< position value.end))
      (let
        [field : der.Tlv (take-any! input state (&mut position) value.end)]
        [inner : i64 field.content]
        (when
          (or
            (!= field.tag-class 2)
            (not field.constructed)
            (<= field.tag previous)
            (> field.tag 3))
          (der.fail! state (der.InvalidTag) field.start)
          (return unit))
        (set! previous field.tag)
        (cond
          [(= field.tag 0)
            (let
              [hash : der.Tlv
                (take! input state (&mut inner) field.end 0 16 true)]
              (when
                (hash-algorithm! input state hash)
                (der.fail! state (der.InvalidValue) field.start)))]
          [(= field.tag 1)
            (let
              [mgf : Algorithm
                (algorithm!
                  input
                  state
                  (take! input state (&mut inner) field.end 0 16 true))]
              (when
                (or
                  (not (oid-is? input mgf.oid "2a864886f70d010108"))
                  (= mgf.parameters.length 0))
                (der.fail! state (der.InvalidValue) field.start))
              (when
                (not state.failed)
                (let
                  [hash : der.Tlv (parameter! input state mgf)]
                  (when
                    (or
                      (!= hash.tag 16)
                      (!= hash.tag-class 0)
                      (not hash.constructed))
                    (der.fail! state (der.InvalidTag) hash.start))
                  (when
                    (and (not state.failed) (hash-algorithm! input state hash))
                    (der.fail! state (der.InvalidValue) field.start)))))]
          [else
            (let
              [number : i64
                (small-integer!
                  input
                  state
                  (take! input state (&mut inner) field.end 0 2 false))]
              (when
                (or (= field.tag 3) (= number 20))
                (der.fail! state (der.InvalidValue) field.start)))])
        (complete! state inner field.end)))))

;: Enforce known signature/SPKI parameter syntax; unknown OIDs stay opaque.
(define (algorithm-profile!
  [input : (& input bytes)]
  [state : (&mut state der.Cursor)]
  [algorithm : Algorithm]
  [public-key? : bool]) : unit
  (cond
    [(or
        (oid-is? input algorithm.oid "2a864886f70d010101")
        (oid-is? input algorithm.oid "2a864886f70d01010b")
        (oid-is? input algorithm.oid "2a864886f70d010105"))
      (if (= algorithm.parameters.length 0)
        (der.fail! state (der.InvalidValue) algorithm.encoded.start)
        (let
          [parameter : der.Tlv (parameter! input state algorithm)]
          (when
            (or
              (!= parameter.tag-class 0)
              (!= parameter.tag 5)
              parameter.constructed
              (!= parameter.content parameter.end))
            (der.fail! state (der.InvalidValue) parameter.start))))]
    [(oid-is? input algorithm.oid "2a864886f70d01010a")
      (if (= algorithm.parameters.length 0)
        (when
          (not public-key?)
          (der.fail! state (der.InvalidValue) algorithm.encoded.start))
        (pss! input state (parameter! input state algorithm)))]
    [(oid-is? input algorithm.oid "2a8648ce3d0201")
      (if (= algorithm.parameters.length 0)
        (der.fail! state (der.InvalidValue) algorithm.encoded.start)
        (let
          [parameter : der.Tlv (parameter! input state algorithm)]
          (when
            (or
              (!= parameter.tag-class 0)
              (!= parameter.tag 6)
              parameter.constructed)
            (der.fail! state (der.InvalidValue) parameter.start))))]
    [(or
        (oid-is? input algorithm.oid "2a8648ce3d040302")
        (oid-is? input algorithm.oid "2b6570"))
      (when
        (> algorithm.parameters.length 0)
        (der.fail! state (der.InvalidValue) algorithm.parameters.start))]
    [else unit]))

;: Parse a Name's RDN SETs and AttributeTypeAndValue sequences.
(define (name!
  [input : (& input bytes)]
  [state : (&mut state der.Cursor)]
  [value : der.Tlv]
  [cap : i64]) : Name
  (let
    [position : i64 value.content]
    [rdn : i64 0]
    [out : attributes.Vec (attributes.with-capacity 0)]
    (while (and (not state.failed) (< position value.end))
      (let
        [set : der.Tlv (take! input state (&mut position) value.end 0 17 true)]
        [item : i64 set.content]
        (when (= item set.end) (der.fail! state (der.InvalidValue) item))
        (while (and (not state.failed) (< item set.end))
          (when
            (>= (attributes.len (& out)) cap)
            (der.fail! state (der.LimitExceeded) item)
            (return (Name (der.encoded value) out)))
          (let
            [pair : der.Tlv (take! input state (&mut item) set.end 0 16 true)]
            [field : i64 pair.content]
            [oid : der.Tlv (take! input state (&mut field) pair.end 0 6 false)]
            [text : der.Tlv (take-any! input state (&mut field) pair.end)]
            (complete! state field pair.end)
            (when
              (not state.failed)
              (attributes.push!
                out
                (Attribute
                  rdn
                  (der.contents oid)
                  (der.encoded pair)
                  text.tag-class
                  text.tag
                  text.constructed
                  (der.contents text)))))))
      (set! rdn (+ rdn 1)))
    (Name (der.encoded value) out)))

;: Decode a validated exact IP range through stdlib.net.ip's canonical type.
(define (address!
  [input : (& input bytes)]
  [state : (&mut state der.Cursor)]
  [range : der.Range]) : Address
  (match (ip.ip-from-bytes
    (byte_buf.bytes-slice-view input range.start range.length))
    [(ip.IpOk address) (Address address)]
    [(ip.IpErr _)
      (der.fail! state (der.InvalidValue) range.start)
      (NoAddress)]))

;: Validate a nonempty implicit IA5String, preserving exact bytes and case.
(define (ascii!
  [input : (& input bytes)]
  [state : (&mut state der.Cursor)]
  [value : der.Tlv]) : unit
  (when
    (= value.content value.end)
    (der.fail! state (der.InvalidValue) value.content))
  (let
    [position : i64 value.content]
    (while (< position value.end)
      (when
        (> (cast (byte_buf.bytes-ref input position) : i64) 127)
        (der.fail! state (der.InvalidValue) position))
      (set! position (+ position 1)))))

;: Validate GeneralName CHOICE contents. Constraint IPs contain address+mask.
(define (general-name!
  [input : (& input bytes)]
  [state : (&mut state der.Cursor)]
  [value : der.Tlv]
  [constraint? : bool]
  [cap : i64]) : GeneralName
  (let
    [address : Address (NoAddress)]
    (when
      (or
        (!= value.tag-class 2)
        (> value.tag 8)
        (!=
          value.constructed
          (or (= value.tag 0) (= value.tag 3) (= value.tag 4) (= value.tag 5))))
      (der.fail! state (der.InvalidTag) value.start))
    (when
      (not state.failed)
      (cond
        [(or (= value.tag 1) (= value.tag 2) (= value.tag 6))
          ; Empty IA5 bases are valid name constraints (including DNS
          ; namespace exclusions), while empty SAN entries are forbidden.
          (when
            (or (not constraint?) (< value.content value.end))
            (ascii! input state value))]
        [(= value.tag 7)
          (let
            [length : i64 (- value.end value.content)]
            (when
              (if constraint?
                (and (!= length 8) (!= length 32))
                (and (!= length 4) (!= length 16)))
              (der.fail! state (der.InvalidValue) value.content))
            (when
              (not state.failed)
              (set!
                address
                (address!
                  input
                  state
                  (der.Range
                    value.content
                    (if constraint?
                      (/ length 2)
                      length))))))]
        [(= value.tag 8) (der.oid! input state value)]
        [(= value.tag 4)
          (let
            [position : i64 value.content]
            [name : der.Tlv
              (take! input state (&mut position) value.end 0 16 true)]
            (name! input state name cap)
            (complete! state position value.end))]
        [(= value.tag 0)
          (let
            [position : i64 value.content]
            [oid : der.Tlv
              (take! input state (&mut position) value.end 0 6 false)]
            [wrapper : der.Tlv
              (take! input state (&mut position) value.end 2 0 true)]
            [inner : i64 wrapper.content]
            (der.oid! input state oid)
            (take-any! input state (&mut inner) wrapper.end)
            (complete! state inner wrapper.end)
            (complete! state position value.end))]
        [(= value.tag 5)
          (let
            [position : i64 value.content]
            [previous : i64 -1]
            (while (and (not state.failed) (< position value.end))
              (let
                [field : der.Tlv
                  (take-any! input state (&mut position) value.end)]
                (when
                  (or
                    (!= field.tag-class 2)
                    (<= field.tag previous)
                    (> field.tag 1)
                    (not field.constructed))
                  (der.fail! state (der.InvalidTag) field.start))
                (let
                  [inner : i64 field.content]
                  [text : der.Tlv
                    (take-any! input state (&mut inner) field.end)]
                  (when
                    (or
                      (!= text.tag-class 0)
                      text.constructed
                      (not
                        (or
                          (= text.tag 12)
                          (= text.tag 19)
                          (= text.tag 20)
                          (= text.tag 28)
                          (= text.tag 30)))
                      (= text.content text.end))
                    (der.fail! state (der.InvalidValue) text.start))
                  (complete! state inner field.end))
                (set! previous field.tag)))
            (when
              (!= previous 1)
              (der.fail! state (der.InvalidValue) value.content)))]
        [(= value.tag 3)
          ; ORAddress begins with BuiltInStandardAttributes SEQUENCE, then
          ; optional BuiltInDomainDefinedAttributes SEQUENCE and Extensions SET.
          ; Check the outer CHOICE shape before reporting the unsupported kind.
          (let
            [position : i64 value.content]
            (take! input state (&mut position) value.end 0 16 true)
            (when
              (and (not state.failed) (< position value.end))
              (let
                [field : der.Tlv
                  (take-any! input state (&mut position) value.end)]
                (when
                  (or
                    (!= field.tag-class 0)
                    (not field.constructed)
                    (and (!= field.tag 16) (!= field.tag 17)))
                  (der.fail! state (der.InvalidTag) field.start))
                (when
                  (and (= field.tag 16) (< position value.end))
                  (let
                    [_extension : der.Tlv
                      (take! input state (&mut position) value.end 0 17 true)]
                    unit))))
            (complete! state position value.end)
            (when
              (not state.failed)
              (der.fail! state (der.UnsupportedGeneralName 3) value.start)))]
        [else unit]))
    (GeneralName value.tag (der.encoded value) (der.contents value) address)))

;: Decode a nonempty GeneralNames content range, including implicit AKI names.
(define (general-names!
  [input : (& input bytes)]
  [state : (&mut state der.Cursor)]
  [value : der.Tlv]
  [cap : i64]) : general_names.Vec
  (let
    [position : i64 value.content]
    [out : general_names.Vec (general_names.with-capacity 0)]
    (when (= position value.end) (der.fail! state (der.InvalidValue) position))
    (while (and (not state.failed) (< position value.end))
      (when
        (>= (general_names.len (& out)) cap)
        (der.fail! state (der.LimitExceeded) position)
        (return out))
      (let
        [name : GeneralName
          (general-name!
            input
            state
            (take-any! input state (&mut position) value.end)
            false
            cap)]
        (when (not state.failed) (general_names.push! out name))))
    out))

;: Validate one exact encapsulated DER value and translate offsets to its owner.
(define (encapsulated!
  [input : (& input bytes)]
  [state : (&mut state der.Cursor)]
  [range : der.Range]
  [limits : der.Limits]
  [depth-offset : i64]) : der.Tlv
  (when state.failed (return (der.empty-tlv)))
  (der.validate! input range limits depth-offset state)
  (let
    [position : i64 range.start]
    (take-any! input state (&mut position) (+ range.start range.length))))

;: Require a universal primitive/constructed tag on an already read value.
(define (tag!
  [state : (&mut state der.Cursor)]
  [value : der.Tlv]
  [tag : i64]
  [constructed : bool]) : unit
  (when
    (or
      (!= value.tag-class 0)
      (!= value.tag tag)
      (!= value.constructed constructed))
    (der.fail! state (der.InvalidTag) value.start)))

;: Parse BasicConstraints with DER DEFAULT omission and checked path length.
(define (basic!
  [input : (& input bytes)]
  [state : (&mut state der.Cursor)]
  [value : der.Tlv]) : BasicConstraints
  (tag! state value 16 true)
  (let
    [position : i64 value.content]
    [ca : bool false]
    [path : i64 -1]
    (when
      (and (not state.failed) (< position value.end))
      (let
        [field : der.Tlv (take-any! input state (&mut position) value.end)]
        (if (and (= field.tag-class 0) (= field.tag 1) (not field.constructed))
          (begin
            (when
              (or
                (!= (- field.end field.content) 1)
                (!=
                  (byte_buf.bytes-get input field.content (cast 0 : u8))
                  (cast 255 : u8)))
              (der.fail! state (der.InvalidValue) field.content))
            (set! ca true)
            (when
              (< position value.end)
              (set!
                path
                (small-integer!
                  input
                  state
                  (take! input state (&mut position) value.end 0 2 false)))))
          (der.fail! state (der.InvalidValue) field.start))))
    (complete! state position value.end)
    (BasicConstraints true ca path)))

;: Parse canonical named KeyUsage bits (1..9 significant bits, no trailing zero).
(define (key-usage!
  [input : (& input bytes)]
  [state : (&mut state der.Cursor)]
  [value : der.Tlv]) : i64
  (tag! state value 3 false)
  (when state.failed (return 0))
  (der.bits! input state value)
  (let
    [length : i64 (- value.end value.content)]
    [out : i64 0]
    (when
      (or (< length 2) (> length 3))
      (der.fail! state (der.InvalidValue) value.content)
      (return 0))
    (let
      [unused : i64 (cast (byte_buf.bytes-ref input value.content) : i64)]
      [bits : i64 (- (* (- length 1) 8) unused)]
      [index : i64 0]
      (when
        (or
          (> bits 9)
          (<= bits 0)
          (=
            (bit-and
              (cast (byte_buf.bytes-ref input (- value.end 1)) : i64)
              (shl 1 unused))
            0))
        (der.fail! state (der.InvalidValue) (- value.end 1)))
      (while (< index bits)
        (when
          (!=
            (bit-and
              (cast
                (byte_buf.bytes-ref input (+ value.content (+ 1 (/ index 8))))
                : i64)
              (shl 1 (- 7 (% index 8))))
            0)
          (set! out (bit-or out (shl 1 index))))
        (set! index (+ index 1))))
    out))

;: Parse EKU OIDs, rejecting an empty sequence or duplicate purpose.
(define (eku!
  [input : (& input bytes)]
  [state : (&mut state der.Cursor)]
  [value : der.Tlv]
  [cap : i64]) : ranges.Vec
  (tag! state value 16 true)
  (let
    [position : i64 value.content]
    [out : ranges.Vec (ranges.with-capacity 0)]
    (when (= position value.end) (der.fail! state (der.InvalidValue) position))
    (while (and (not state.failed) (< position value.end))
      (when
        (>= (ranges.len (& out)) cap)
        (der.fail! state (der.LimitExceeded) position)
        (return out))
      (let
        [oid : der.Tlv (take! input state (&mut position) value.end 0 6 false)]
        [index : i64 0]
        (while (< index (ranges.len (& out)))
          (when
            (=
              (der.compare-ranges
                input
                (der.contents oid)
                (ranges.get (& out) index (der.Range 0 0)))
              0)
            (der.fail! state (der.Duplicate) oid.start))
          (set! index (+ index 1)))
        (when (not state.failed) (ranges.push! out (der.contents oid)))))
    out))

;: Parse the implicit fields of AuthorityKeyIdentifier, with paired issuer/serial.
(define (aki!
  [input : (& input bytes)]
  [state : (&mut state der.Cursor)]
  [value : der.Tlv]
  [limits : Limits]) : AuthorityKeyIdentifier
  (tag! state value 16 true)
  (let
    [position : i64 value.content]
    [previous : i64 -1]
    [key-id : der.Range (der.Range 0 0)]
    [serial : der.Range (der.Range 0 0)]
    [issuer : general_names.Vec (general_names.with-capacity 0)]
    (while (and (not state.failed) (< position value.end))
      (let
        [field : der.Tlv (take-any! input state (&mut position) value.end)]
        (when
          (or
            (!= field.tag-class 2)
            (<= field.tag previous)
            (> field.tag 2)
            (!= field.constructed (= field.tag 1)))
          (der.fail! state (der.InvalidTag) field.start))
        (set! previous field.tag)
        (cond
          [(= field.tag 0)
            (set! key-id (der.contents field))
            (when
              (= key-id.length 0)
              (der.fail! state (der.InvalidValue) field.content))]
          [(= field.tag 1)
            (set! issuer (general-names! input state field limits.max-names))]
          [(= field.tag 2)
            (set! serial (serial! input state field limits.max-serial-bytes))]
          [else unit])))
    (when
      (or
        (= previous -1)
        (!= (> (general_names.len (& issuer)) 0) (> serial.length 0)))
      (der.fail! state (der.InvalidValue) value.content))
    (AuthorityKeyIdentifier key-id issuer serial)))

;: Parse bounded NameConstraints. Profile minimum=0/default and maximum absent.
(define (constraints!
  [input : (& input bytes)]
  [state : (&mut state der.Cursor)]
  [value : der.Tlv]
  [cap : i64]) : constraints.Vec
  (tag! state value 16 true)
  (let
    [position : i64 value.content]
    [previous : i64 -1]
    [out : constraints.Vec (constraints.with-capacity 0)]
    (while (and (not state.failed) (< position value.end))
      (let
        [group : der.Tlv (take-any! input state (&mut position) value.end)]
        [item : i64 group.content]
        (when
          (or
            (!= group.tag-class 2)
            (not group.constructed)
            (<= group.tag previous)
            (> group.tag 1)
            (= item group.end))
          (der.fail! state (der.InvalidTag) group.start))
        (set! previous group.tag)
        (while (and (not state.failed) (< item group.end))
          (when
            (>= (constraints.len (& out)) cap)
            (der.fail! state (der.LimitExceeded) item)
            (return out))
          (let
            [subtree : der.Tlv
              (take! input state (&mut item) group.end 0 16 true)]
            [inner : i64 subtree.content]
            [base : GeneralName
              (general-name!
                input
                state
                (take-any! input state (&mut inner) subtree.end)
                true
                cap)]
            [mask : Address (NoAddress)]
            (complete! state inner subtree.end)
            (when
              (and (not state.failed) (= base.kind 7))
              (let
                [half : i64 (/ base.value.length 2)]
                (set!
                  mask
                  (address!
                    input
                    state
                    (der.Range (+ base.value.start half) half)))))
            (when
              (not state.failed)
              (constraints.push! out (Constraint (= group.tag 1) base mask)))))))
    (when (= previous -1) (der.fail! state (der.InvalidValue) value.content))
    out))

;: Identify a standard extension without converting its OID to text.
(define (extension-kind [input : (& input bytes)] [oid : der.Range]) : i64
  (if (and
    (= oid.length 3)
    (= (byte_buf.bytes-ref input oid.start) (cast 85 : u8))
    (= (byte_buf.bytes-ref input (+ oid.start 1)) (cast 29 : u8)))
    (cast (byte_buf.bytes-ref input (+ oid.start 2)) : i64)
    -1))

;: Empty model used only internally until every field has validated.
(define (empty-certificate) : Certificate
  (let
    [range : der.Range (der.Range 0 0)]
    [algorithm : Algorithm (Algorithm range range range)]
    [instant : time.Instant (time.Instant 1970 1 1 0 0 0 0)]
    (Certificate
      (byte_buf.new)
      0
      range
      range
      algorithm
      algorithm
      (Name range (attributes.with-capacity 0))
      (Name range (attributes.with-capacity 0))
      range
      instant
      instant
      range
      algorithm
      range
      range
      range
      range
      (extensions.with-capacity 0)
      (BasicConstraints false false -1)
      -1
      (ranges.with-capacity 0)
      range
      (AuthorityKeyIdentifier range (general_names.with-capacity 0) range)
      (general_names.with-capacity 0)
      (constraints.with-capacity 0))))

;: Parse the v3 Extensions wrapper and populate the model's known extensions.
(define (extensions!
  [input : (& input bytes)]
  [state : (&mut state der.Cursor)]
  [wrapper : der.Tlv]
  [limits : Limits]
  [out : (&mut out Certificate)]) : unit
  (let
    [outer : i64 wrapper.content]
    [sequence : der.Tlv (take! input state (&mut outer) wrapper.end 0 16 true)]
    [position : i64 sequence.content]
    (complete! state outer wrapper.end)
    (when
      (= position sequence.end)
      (der.fail! state (der.InvalidValue) position))
    (while (and (not state.failed) (< position sequence.end))
      (when
        (>= (extensions.len (& out.extensions)) limits.max-extensions)
        (der.fail! state (der.LimitExceeded) position)
        (return unit))
      (let
        [extension : der.Tlv
          (take! input state (&mut position) sequence.end 0 16 true)]
        [field : i64 extension.content]
        [oid : der.Tlv (take! input state (&mut field) extension.end 0 6 false)]
        [value : der.Tlv (take-any! input state (&mut field) extension.end)]
        [critical : bool false]
        [index : i64 0]
        [kind : i64 (extension-kind input (der.contents oid))]
        (when
          (and (= value.tag-class 0) (= value.tag 1) (not value.constructed))
          (when
            (or
              (!= (- value.end value.content) 1)
              (!=
                (byte_buf.bytes-get input value.content (cast 0 : u8))
                (cast 255 : u8)))
            (der.fail! state (der.InvalidValue) value.content))
          (set! critical true)
          (set! value (take-any! input state (&mut field) extension.end)))
        (tag! state value 4 false)
        (complete! state field extension.end)
        (while (and
          (not state.failed)
          (< index (extensions.len (& out.extensions))))
          (let
            [prior : Extension
              (extensions.get
                (& out.extensions)
                index
                (Extension
                  (der.Range 0 0)
                  false
                  (der.Range 0 0)
                  (der.Range 0 0)
                  -1))]
            (when
              (= (der.compare-ranges input (der.contents oid) prior.oid) 0)
              (der.fail! state (der.Duplicate) oid.start)))
          (set! index (+ index 1)))
        (let
          [inner : der.Tlv
            (encapsulated! input state (der.contents value) limits.der 6)]
          (when state.failed (return unit))
          (cond
            [(= kind 19)
              (set! out.basic-constraints (basic! input state inner))]
            [(= kind 15) (set! out.key-usage (key-usage! input state inner))]
            [(= kind 37)
              (set!
                out.extended-key-usage
                (eku! input state inner limits.max-names))]
            [(= kind 14)
              (tag! state inner 4 false)
              (when
                (= inner.content inner.end)
                (der.fail! state (der.InvalidValue) inner.content))
              (set! out.subject-key-id (der.contents inner))]
            [(= kind 35)
              (set! out.authority-key-id (aki! input state inner limits))]
            [(= kind 17)
              (tag! state inner 16 true)
              (set!
                out.subject-alt-names
                (general-names! input state inner limits.max-names))]
            [(= kind 30)
              (set!
                out.name-constraints
                (constraints! input state inner limits.max-names))]
            [else unit]))
        (when
          (not state.failed)
          (extensions.push!
            out.extensions
            (Extension
              (der.contents oid)
              critical
              (der.encoded extension)
              (der.contents value)
              kind)))))))

;: Validate encoded public-key material for recognized SPKI algorithms.
(define (public-key!
  [input : (& input bytes)]
  [state : (&mut state der.Cursor)]
  [algorithm : Algorithm]
  [key : der.Range]
  [limits : Limits]) : unit
  (cond
    [(or
        (oid-is? input algorithm.oid "2a864886f70d010101")
        (oid-is? input algorithm.oid "2a864886f70d01010a"))
      (let
        [rsa : der.Tlv (encapsulated! input state key limits.der 4)]
        [position : i64 rsa.content]
        (tag! state rsa 16 true)
        (serial!
          input
          state
          (take! input state (&mut position) rsa.end 0 2 false)
          limits.der.max-bytes)
        (serial!
          input
          state
          (take! input state (&mut position) rsa.end 0 2 false)
          limits.der.max-bytes)
        (complete! state position rsa.end))]
    [(oid-is? input algorithm.oid "2b6570")
      (when (!= key.length 32) (der.fail! state (der.InvalidValue) key.start))]
    [(oid-is? input algorithm.oid "2a8648ce3d0201")
      (let
        [curve : der.Tlv (parameter! input state algorithm)]
        (when
          (and
            (not state.failed)
            (oid-is? input (der.contents curve) "2a8648ce3d030107"))
          (let
            [first : u8 (byte_buf.bytes-get input key.start (cast 0 : u8))]
            (when
              (not
                (or
                  (and (= key.length 65) (= first (cast 4 : u8)))
                  (and
                    (= key.length 33)
                    (or (= first (cast 2 : u8)) (= first (cast 3 : u8))))))
              (der.fail! state (der.InvalidValue) key.start)))))]
    [else unit]))

;: Decode exact certificate time contents with original DER error coordinates.
(define (time!
  [input : (& input bytes)]
  [state : (&mut state der.Cursor)]
  [value : der.Tlv]) : time.Instant
  (when
    (or (!= value.tag-class 0) value.constructed)
    (der.fail! state (der.InvalidTag) value.start))
  (match (time.parse
    (byte_buf.bytes-slice-view input value.content (- value.end value.content))
    value.tag
    value.content)
    [(time.TimeOk instant) instant]
    [(time.TimeErr error)
      (der.fail! state (der.InvalidTime) error.offset)
      (time.Instant 1970 1 1 0 0 0 0)]))

;: Read and parse a distinguished name.
(define (next-name!
  [input : (& input bytes)]
  [state : (&mut state der.Cursor)]
  [position : (&mut position i64)]
  [end : i64]
  [cap : i64]) : Name
  (let
    [value : der.Tlv (take! input state position end 0 16 true)]
    (name! input state value cap)))

;: Read and parse one certificate time.
(define (next-time!
  [input : (& input bytes)]
  [state : (&mut state der.Cursor)]
  [position : (&mut position i64)]
  [end : i64]) : time.Instant
  (let
    [value : der.Tlv (take-any! input state position end)]
    (time! input state value)))

;: Parse one borrowed DER certificate and allocate its owner only after success.
(define (parse-der [input : (& input bytes)] [limits : Limits]) : CertificateResult
  (when
    (not (limits-valid? limits))
    (return (CertificateErr (der.Error (der.InvalidLimit) 0))))
  (let
    [state : der.Cursor (der.cursor 0 (byte_buf.bytes-length input))]
    (der.validate!
      input
      (der.Range 0 (byte_buf.bytes-length input))
      limits.der
      0
      (&mut state))
    (when state.failed (return (CertificateErr state.error)))
    (parse-validated input limits state)))

;: Decode schema fields after canonical validation, preserving its work budget.
(define (parse-validated
  [input : (& input bytes)]
  [limits : Limits]
  [initial : der.Cursor]) : CertificateResult
  (let
    [state : der.Cursor initial]
    [position : i64 0]
    [out : Certificate (empty-certificate)]
    [certificate : der.Tlv
      (take! input (&mut state) (&mut position) state.end 0 16 true)]
    [outer : i64 certificate.content]
    [tbs : der.Tlv
      (take! input (&mut state) (&mut outer) certificate.end 0 16 true)]
    [signature-algorithm : Algorithm
      (next-algorithm! input (&mut state) (&mut outer) certificate.end)]
    [signature : der.Tlv
      (take! input (&mut state) (&mut outer) certificate.end 0 3 false)]
    [field : i64 tbs.content]
    [version : i64 0]
    [serial : der.Tlv (take-any! input (&mut state) (&mut field) tbs.end)]
    (complete! (&mut state) outer certificate.end)
    (when
      (and (= serial.tag-class 2) (= serial.tag 0) serial.constructed)
      (let
        [inner : i64 serial.content]
        (set! version (next-small! input (&mut state) (&mut inner) serial.end))
        (when
          (or (< version 1) (> version 2))
          (der.fail! (&mut state) (der.InvalidValue) serial.content))
        (complete! (&mut state) inner serial.end))
      (set! serial (take-any! input (&mut state) (&mut field) tbs.end)))
    (tag! (&mut state) serial 2 false)
    (set! out.version (+ version 1))
    (set!
      out.serial
      (serial! input (&mut state) serial limits.max-serial-bytes))
    (set! out.tbs (der.encoded tbs))
    (set! out.signature-algorithm signature-algorithm)
    (let
      [inner-algorithm : Algorithm
        (next-algorithm! input (&mut state) (&mut field) tbs.end)]
      (set! out.tbs-signature-algorithm inner-algorithm)
      (when
        (and
          (not state.failed)
          (!=
            (der.compare-ranges
              input
              inner-algorithm.encoded
              signature-algorithm.encoded)
            0))
        (der.fail!
          (&mut state)
          (der.AlgorithmMismatch)
          signature-algorithm.encoded.start)))
    (algorithm-profile! input (&mut state) signature-algorithm false)
    (set!
      out.issuer
      (next-name! input (&mut state) (&mut field) tbs.end limits.max-names))
    (when
      (= (attributes.len (& out.issuer.attributes)) 0)
      (der.fail! (&mut state) (der.InvalidValue) out.issuer.encoded.start))
    (let
      [validity : der.Tlv
        (take! input (&mut state) (&mut field) tbs.end 0 16 true)]
      [inner : i64 validity.content]
      (set! out.validity (der.encoded validity))
      (set!
        out.not-before
        (next-time! input (&mut state) (&mut inner) validity.end))
      (set!
        out.not-after
        (next-time! input (&mut state) (&mut inner) validity.end))
      (complete! (&mut state) inner validity.end))
    (set!
      out.subject
      (next-name! input (&mut state) (&mut field) tbs.end limits.max-names))
    (let
      [spki : der.Tlv (take! input (&mut state) (&mut field) tbs.end 0 16 true)]
      [inner : i64 spki.content]
      [algorithm : Algorithm
        (next-algorithm! input (&mut state) (&mut inner) spki.end)]
      [key : der.Tlv (take! input (&mut state) (&mut inner) spki.end 0 3 false)]
      (complete! (&mut state) inner spki.end)
      (algorithm-profile! input (&mut state) algorithm true)
      (when
        (and
          (not state.failed)
          (or
            (< (- key.end key.content) 2)
            (!= (byte_buf.bytes-ref input key.content) (cast 0 : u8))))
        (der.fail! (&mut state) (der.InvalidValue) key.content))
      (when
        (not state.failed)
        (set! out.spki (der.encoded spki))
        (set! out.public-key-algorithm algorithm)
        (set!
          out.public-key
          (der.Range (+ key.content 1) (- key.end (+ key.content 1))))
        (public-key! input (&mut state) algorithm out.public-key limits)))
    (let
      [previous : i64 0]
      (while (and (not state.failed) (< field tbs.end))
        (let
          [optional : der.Tlv
            (take-any! input (&mut state) (&mut field) tbs.end)]
          (when
            (or
              (!= optional.tag-class 2)
              (<= optional.tag previous)
              (> optional.tag 3)
              (< version 1)
              (and (= optional.tag 3) (!= version 2))
              (!= optional.constructed (= optional.tag 3)))
            (der.fail! (&mut state) (der.InvalidTag) optional.start))
          (set! previous optional.tag)
          (if (= optional.tag 3)
            (extensions! input (&mut state) optional limits (&mut out))
            (begin
              (der.bits! input (&mut state) optional)
              (if (= optional.tag 1)
                (set! out.issuer-unique-id (der.contents optional))
                (set! out.subject-unique-id (der.contents optional))))))))
    (when
      (and (not state.failed) (= (attributes.len (& out.subject.attributes)) 0))
      (let
        [index : i64 0]
        [critical-san : bool false]
        (while (< index (extensions.len (& out.extensions)))
          (let
            [extension : Extension
              (extensions.get
                (& out.extensions)
                index
                (Extension
                  (der.Range 0 0)
                  false
                  (der.Range 0 0)
                  (der.Range 0 0)
                  -1))]
            (when
              (and (= extension.kind 17) extension.critical)
              (set! critical-san true)))
          (set! index (+ index 1)))
        (when
          (not critical-san)
          (der.fail! (&mut state) (der.InvalidValue) out.subject.encoded.start))))
    (when
      (and
        (not state.failed)
        (or
          (< (- signature.end signature.content) 2)
          (!= (byte_buf.bytes-ref input signature.content) (cast 0 : u8))))
      (der.fail! (&mut state) (der.InvalidValue) signature.content))
    (when
      (not state.failed)
      (set!
        out.signature
        (der.Range
          (+ signature.content 1)
          (- signature.end (+ signature.content 1))))
      (cond
        [(oid-is? input signature-algorithm.oid "2b6570")
          (when
            (!= out.signature.length 64)
            (der.fail! (&mut state) (der.InvalidValue) out.signature.start))]
        [(oid-is? input signature-algorithm.oid "2a8648ce3d040302")
          (let
            [ecdsa : der.Tlv
              (encapsulated! input (&mut state) out.signature limits.der 2)]
            [inner : i64 ecdsa.content]
            (tag! (&mut state) ecdsa 16 true)
            (next-serial!
              input
              (&mut state)
              (&mut inner)
              ecdsa.end
              limits.der.max-bytes)
            (next-serial!
              input
              (&mut state)
              (&mut inner)
              ecdsa.end
              limits.der.max-bytes)
            (complete! (&mut state) inner ecdsa.end))]
        [else unit]))
    (if state.failed
      (CertificateErr state.error)
      (begin
        (set! out.der (byte_buf.from-bytes input))
        (CertificateOk out)))))

;: Load one/many certificate PEM blocks atomically using the shared PEM/base64.
(define (parse-pem [input : (& input bytes)] [limits : Limits]) : CertificatesResult
  (when
    (not (limits-valid? limits))
    (return
      (CertificatesErr
        (LoadError (der.Error (der.InvalidLimit) 0) -1 (der.Range 0 0)))))
  (let
    [pem-limits : pem.Limits limits.pem]
    (when
      (< limits.der.max-bytes pem-limits.max-certificate-bytes)
      (set! pem-limits.max-certificate-bytes limits.der.max-bytes))
    (parse-pem-bounded input limits pem-limits)))

;: Decode a validated PEM budget after applying the stricter DER byte cap.
(define (parse-pem-bounded
  [input : (& input bytes)]
  [limits : Limits]
  [pem-limits : pem.Limits]) : CertificatesResult
  (match (pem.decode-certificates input pem-limits)
    [(pem.PemErr error)
      (CertificatesErr (LoadError error -1 (der.Range error.offset 0)))]
    [(pem.PemOk blocks)
      (let
        [index : i64 0]
        [out : certificates.Vec (certificates.with-capacity 0)]
        (while (< index (pem_blocks.len (& blocks)))
          (let
            [block : pem.Block
              (pem_blocks.get
                (& blocks)
                index
                (pem.Block (byte_buf.new) (der.Range 0 0)))]
            (match (parse-der (byte_buf.as-bytes (& block.der)) limits)
              [(CertificateErr error)
                (return (CertificatesErr (LoadError error index block.source)))]
              [(CertificateOk certificate) (certificates.push! out certificate)]))
          (set! index (+ index 1)))
        (CertificatesOk out))]))

;: Canonical ASCII service name, excluding its optional terminal root dot.
;: Only immutable pointers cross the module boundary. Constructors validate
;: before allocating this fixed-size value in the active arena.
(defstruct ServiceDnsName
  (:opaque)
  (octets (Array u8 253))
  (length i64))

;: Independently supplied reference identity. DNS pointers must come from
;: service-reference and remain within their allocation arena's lifetime.
(defenum ServiceReference
  (Dns (Ptr ServiceDnsName))
  (Ip ip.IpAddr))

;: Stable public failure categories; no input or certificate bytes are retained.
(defenum ServiceIdentityErrorKind
  (InternationalizedNameUnsupported)
  (InvalidDnsName)
  (DnsNameTooLong)
  (InvalidIdentityLimits)
  (ReferenceLimit)
  (EmptyReferences)
  (InvalidReference)
  (PresentedLimit)
  (NoSupportedPresentedIdentifier)
  (IdentityMismatch))

;: Byte offset for input errors, reference index for InvalidReference, otherwise
;: zero. Diagnostics never echo certificate bodies or unrelated SAN values.
(defstruct ServiceIdentityError
  (kind ServiceIdentityErrorKind)
  (offset i64))

;: A validated DNS/IP reference or an input failure without partial identity.
(defenum ServiceReferenceResult
  (ServiceReferenceOk ServiceReference)
  (ServiceReferenceErr ServiceIdentityError))

;: Complete append or refusal without changing the caller's reference list.
(defenum ServiceReferenceStatus
  (ServiceReferenceAdded)
  (ServiceReferenceAddErr ServiceIdentityError))

;: Caller-owned bounded list. Use service-references-new and service-reference-add!.
;: Matching rechecks the configured bound even if callers alter this collection.
(defstruct ServiceReferences
  (values (Array ServiceReference 64))
  (length i64))

;: Explicit wildcard policy; allowing wildcards does not enforce a public suffix
;: policy. No PSL, label-count heuristic, SNI or subject fallback is consulted.
(defenum ServiceWildcardPolicy
  (AllowWildcards)
  (DisallowWildcards))

;: Checked per-call limits; maxima are 64 references and 4096 parsed SANs.
;: DNS values are independently bounded to 253 non-root text octets.
(defstruct ServiceIdentityLimits
  (max-references i64)
  (max-presented i64)
  (wildcards ServiceWildcardPolicy))

;: First SAN in parser order, then first reference in caller order. The indices
;: identify the actual reference as required by RFC 9525 section 6.6. Success
;: proves identity only: trust, validity, signatures and path policy are separate.
(defenum ServiceIdentityResult
  (ServiceIdentityMatch i64 i64)
  (ServiceIdentityErr ServiceIdentityError))

;: Internal validated presented-name shape; length omits the terminal root dot.
(defenum ServiceDnsShape
  (ServiceDnsValid i64 bool)
  (ServiceDnsInvalid ServiceIdentityError))

;: Arena allocation for a fixed-size, public, immutable validated DNS value.
(unsafe
  (extern (service-identity-alloc [size : i64]) : (MutPtr u8) (:symbol "tl_alloc")))

;: Default reference/SAN bounds and RFC wildcard matching.
(define (service-identity-default-limits) : ServiceIdentityLimits
  (ServiceIdentityLimits 16 1024 (AllowWildcards)))

;: Validate limits before traversal, growth or copying.
(define (service-identity-limits-valid? [limits : ServiceIdentityLimits]) : bool
  (and
    (>= limits.max-references 0)
    (<= limits.max-references 64)
    (>= limits.max-presented 0)
    (<= limits.max-presented 4096)))

;: Return an empty fixed-capacity list without arena allocation.
(define (service-references-new) : ServiceReferences
  (ServiceReferences (make-array ServiceReference 64) 0))

;: ASCII case folding for public DNS bytes, independent of locale.
(define (service-ascii-lower [value : u8]) : u8
  (if (and (>= value 65) (<= value 90))
    (+ value 32)
    value))

;: Validate ASCII LDH labels once, including NR-LDH/reserved-prefix syntax.
;: V1 treats xn-- suffixes as ASCII; Unicode/Punycode symmetry validation and
;: U-label conversion belong to #7269. Presented errors are ignored by matching.
(define (service-dns-shape [input : (& input bytes)] [presented : bool]) : ServiceDnsShape
  (let
    [length : i64 (byte_buf.bytes-length input)]
    [end : i64 length]
    [start : i64 0]
    [cursor : i64 0]
    [wildcard : bool false]
    (when
      (> length 254)
      (return (ServiceDnsInvalid (ServiceIdentityError (DnsNameTooLong) 254))))
    (when
      (and (> end 0) (= (byte_buf.bytes-ref input (- end 1)) 46))
      (set! end (- end 1)))
    (when
      (> end 253)
      (return (ServiceDnsInvalid (ServiceIdentityError (DnsNameTooLong) 253))))
    (while (<= cursor end)
      (if (or (= cursor end) (= (byte_buf.bytes-ref input cursor) 46))
        (let
          [width : i64 (- cursor start)]
          (when
            (or (= width 0) (> width 63))
            (return
              (ServiceDnsInvalid (ServiceIdentityError (InvalidDnsName) start))))
          (if (and
            presented
            (= start 0)
            (= width 1)
            (= (byte_buf.bytes-ref input 0) 42))
            (set! wildcard true)
            (begin
              (when
                (= (byte_buf.bytes-ref input start) 42)
                (return
                  (ServiceDnsInvalid
                    (ServiceIdentityError (InvalidDnsName) start))))
              (when
                (or
                  (= (byte_buf.bytes-ref input start) 45)
                  (= (byte_buf.bytes-ref input (- cursor 1)) 45))
                (return
                  (ServiceDnsInvalid
                    (ServiceIdentityError (InvalidDnsName) start))))
              (when
                (and
                  (>= width 4)
                  (= (byte_buf.bytes-ref input (+ start 2)) 45)
                  (= (byte_buf.bytes-ref input (+ start 3)) 45)
                  (not
                    (and
                      (=
                        (service-ascii-lower (byte_buf.bytes-ref input start))
                        120)
                      (=
                        (service-ascii-lower
                          (byte_buf.bytes-ref input (+ start 1)))
                        110)
                      (> width 4))))
                (return
                  (ServiceDnsInvalid
                    (ServiceIdentityError (InvalidDnsName) start))))))
          (set! start (+ cursor 1)))
        (let
          [value : u8 (byte_buf.bytes-ref input cursor)]
          [lower : u8 (service-ascii-lower value)]
          (when
            (>= value 128)
            (return
              (ServiceDnsInvalid
                (ServiceIdentityError (InternationalizedNameUnsupported) cursor))))
          (when
            (not
              (or
                (and (>= lower 97) (<= lower 122))
                (and (>= value 48) (<= value 57))
                (= value 45)
                (and presented (= cursor 0) (= value 42))))
            (return
              (ServiceDnsInvalid (ServiceIdentityError (InvalidDnsName) cursor))))))
      (set! cursor (+ cursor 1)))
    (when
      (and wildcard (= end 1))
      (return (ServiceDnsInvalid (ServiceIdentityError (InvalidDnsName) 0))))
    (ServiceDnsValid end wildcard)))

;: Classify strict IPv4/IPv6 before DNS; never consume URI brackets, zones,
;: prefixes, ports, SNI or certificate data. Only this checked constructor
;: publishes a DNS pointer. One optional final DNS root dot is discarded.
(define (service-reference [input : (& input str)]) : ServiceReferenceResult
  (match (ip.parse-ip input)
    [(ip.IpOk address) (return (ServiceReferenceOk (Ip address)))]
    [(ip.IpErr _) unit])
  (let
    [bytes : (& input bytes) (byte_buf.str-as-bytes input)]
    (match (service-dns-shape bytes false)
      [(ServiceDnsInvalid error) (ServiceReferenceErr error)]
      [(ServiceDnsValid length _)
        (let
          [canonical : (Array u8 253) (make-array u8 253)]
          [index : i64 0]
          (while (< index length)
            (set!
              (array-ref canonical index)
              (service-ascii-lower (byte_buf.bytes-ref bytes index)))
            (set! index (+ index 1)))
          ; A terminal dot must not permit numeric IPv4 to become a DNS-ID.
          (match (ip.parse-ipv4 (string.substring-view input 0 length))
            [(ip.Ipv4Ok address)
              (return (ServiceReferenceOk (Ip (ip.V4 address))))]
            [(ip.Ipv4Err _) unit])
          (let
            [storage : (MutPtr ServiceDnsName)
              (unsafe
                (ptr-cast
                  (service-identity-alloc
                    (comptime (size-of (type ServiceDnsName))))
                  : (MutPtr ServiceDnsName)))]
            (unsafe
              (ptr-write! storage (ServiceDnsName canonical length)))
            (ServiceReferenceOk
              (Dns
                (unsafe
                  (ptr-cast storage : (Ptr ServiceDnsName)))))))])))

;: Append only within a valid configured cap. Failure leaves the list unchanged.
(define (service-reference-add!
  [references : (&mut references ServiceReferences)]
  [reference : ServiceReference]
  [limits : ServiceIdentityLimits]) : ServiceReferenceStatus
  (when
    (not (service-identity-limits-valid? limits))
    (return
      (ServiceReferenceAddErr (ServiceIdentityError (InvalidIdentityLimits) 0))))
  (let
    [length : i64 references.length]
    (when
      (or (< length 0) (>= length limits.max-references))
      (return
        (ServiceReferenceAddErr (ServiceIdentityError (ReferenceLimit) 0))))
    (match reference
      [(Dns name)
        (when
          (ptr-null? name)
          (return
            (ServiceReferenceAddErr
              (ServiceIdentityError (InvalidReference) length))))]
      [(Ip _) unit])
    (set! (array-ref references.values length) reference)
    (set! references.length (+ length 1))
    (ServiceReferenceAdded)))

;: Compare one validated presented DNS shape with one checked reference.
;: No allocation, lowercase copy or unbounded substring construction occurs.
(define (service-dns-matches?
  [name : (Ptr ServiceDnsName)]
  [presented : (& presented bytes)]
  [length : i64]
  [wildcard : bool]) : bool
  (when (ptr-null? name) (return false))
  (let
    [reference : ServiceDnsName
      (unsafe
        (ptr-read name))]
    [cursor : i64 0]
    [offset : i64 0]
    (when
      wildcard
      (while (and
        (< offset reference.length)
        (!= (array-ref reference.octets offset) 46))
        (set! offset (+ offset 1)))
      (when (= offset reference.length) (return false))
      (set! cursor 1))
    (when (!= (- reference.length offset) (- length cursor)) (return false))
    (while (< cursor length)
      (when
        (!=
          (array-ref reference.octets offset)
          (service-ascii-lower (byte_buf.bytes-ref presented cursor)))
        (return false))
      (set! cursor (+ cursor 1))
      (set! offset (+ offset 1)))
    true))

;: SAN-only RFC 9525 DNS/IP matching. Invalid DNS/wildcard SANs are ignored;
;: malformed SAN DER and IP widths have already failed parse-der. Bounds are
;: checked before traversal, including SANs after an otherwise matching entry.
;: Public addresses/names use variable-time comparisons and no secret state.
(define (service-identity
  [certificate : (& certificate Certificate)]
  [references : (& references ServiceReferences)]
  [limits : ServiceIdentityLimits]) : ServiceIdentityResult
  (when
    (not (service-identity-limits-valid? limits))
    (return
      (ServiceIdentityErr (ServiceIdentityError (InvalidIdentityLimits) 0))))
  (let
    [count : i64 references.length]
    [presented-count : i64
      (general_names.len (& certificate.subject-alt-names))]
    [index : i64 0]
    [supported : bool false]
    (when
      (or (< count 0) (> count limits.max-references))
      (return (ServiceIdentityErr (ServiceIdentityError (ReferenceLimit) 0))))
    (when
      (= count 0)
      (return (ServiceIdentityErr (ServiceIdentityError (EmptyReferences) 0))))
    (when
      (> presented-count limits.max-presented)
      (return (ServiceIdentityErr (ServiceIdentityError (PresentedLimit) 0))))
    (while (< index count)
      (match (array-ref references.values index)
        [(Dns name)
          (when
            (ptr-null? name)
            (return
              (ServiceIdentityErr
                (ServiceIdentityError (InvalidReference) index))))]
        [(Ip _) unit])
      (set! index (+ index 1)))
    (set! index 0)
    (while (< index presented-count)
      (let
        [san : GeneralName
          (general_names.get
            (& certificate.subject-alt-names)
            index
            (GeneralName -1 (der.Range 0 0) (der.Range 0 0) (NoAddress)))]
        [reference-index : i64 0]
        [dns-length : i64 0]
        [wildcard : bool false]
        [valid : bool false]
        (when
          (= san.kind 2)
          ; Public certificate fields can be modified; guard ranges before view.
          (when
            (and
              (>= san.value.start 0)
              (>= san.value.length 0)
              (<= san.value.start (byte_buf.len (& certificate.der)))
              (<=
                san.value.length
                (- (byte_buf.len (& certificate.der)) san.value.start)))
            (match (service-dns-shape (view certificate san.value) true)
              [(ServiceDnsInvalid _) unit]
              [(ServiceDnsValid length has-wildcard)
                (set! dns-length length)
                (set! wildcard has-wildcard)
                (set!
                  valid
                  (or (not wildcard) (= limits.wildcards (AllowWildcards))))])))
        (when
          (= san.kind 7)
          (match san.address
            [(Address _) (set! valid true)]
            [(NoAddress) unit]))
        (when
          valid
          (set! supported true)
          (while (< reference-index count)
            (match (array-ref references.values reference-index)
              [(Dns name)
                (when
                  (and
                    (= san.kind 2)
                    (service-dns-matches?
                      name
                      (view certificate san.value)
                      dns-length
                      wildcard))
                  (return (ServiceIdentityMatch reference-index index)))]
              [(Ip address)
                (when
                  (= san.kind 7)
                  (match san.address
                    [(Address presented)
                      (when
                        (ip.ip-eq? (& address) (& presented))
                        (return (ServiceIdentityMatch reference-index index)))]
                    [(NoAddress) unit]))])
            (set! reference-index (+ reference-index 1)))))
      (set! index (+ index 1)))
    (ServiceIdentityErr
      (ServiceIdentityError
        (if supported
          (IdentityMismatch)
          (NoSupportedPresentedIdentifier))
        0))))

;: Stable non-secret rendering, independent of SAN/input text and addresses.
(define (service-identity-error-message [error : ServiceIdentityError]) : String
  (match error.kind
    [(InternationalizedNameUnsupported)
      "internationalized service name unsupported"]
    [(InvalidDnsName) "invalid ASCII service name"]
    [(DnsNameTooLong) "service name too long"]
    [(InvalidIdentityLimits) "invalid service identity limits"]
    [(ReferenceLimit) "service reference limit exceeded"]
    [(EmptyReferences) "empty service reference list"]
    [(InvalidReference) "invalid service reference"]
    [(PresentedLimit) "presented identity limit exceeded"]
    [(NoSupportedPresentedIdentifier)
      "no supported presented service identifier"]
    [(IdentityMismatch) "service identity mismatch"]))