;# Bounded public SHA-256 transcripts for TLS 1.3.
;#
;# Absorb the exact complete Handshake encoding currently held by a
;# `tls_wire.TlsHandshakeReader`. Record headers and other record contents
;# never enter this API. No borrowed frame survives a call. Message ordering,
;# certificate policy, secrets, Finished MACs and transport belong to callers.
;#
;# `snapshot` copies only this public hash state by value and finalizes the
;# copy. Call it after ClientHello/ServerHello, before server CertificateVerify
;# or Finished, and after server/client Finished as required by the consumer.
;# It neither changes the live transcript nor shares mutable state with it.
;# `finalize!` ends the live transcript; `close!` discards it.
;#
;# Protocol consumers use `snapshot-boundary`, which checks the last message
;# kind and returns an opaque, read-only `TlsTranscriptHash` pointer. Its
;# constructor is inaccessible outside this module family. The pointer owns
;# one fixed-size public value in the active arena and must stay within that
;# arena's lifetime. The key schedule must accept only this opaque hash and
;# use `boundary-digest` with its expected tag. It must not accept an arbitrary
;# untagged digest. Local kind checks do not establish message order or roles;
;# the client engine still validates the complete protocol sequence.
;#
;# After the sole initial ClientHello, `hello-retry!` atomically replaces its
;# contribution with `fe 00 00 20 || SHA256(ClientHello1)` and absorbs the exact
;# held HRR. Absorb ClientHello2 normally. A repeated/late retry, an ordinary
;# absorption of HRR, or externally supplied message_hash is a typed error.
;# This tracks only retry eligibility, not general handshake ordering.
;#
;# Usage: `(import stdlib.net.tls_transcript)`
(import stdlib.byte_buf)
(import stdlib.crypto_sha256 as sha)
(import stdlib.net.tls_wire as wire)

;: Caller resource budgets. `max-input` includes every SHA input byte ever
;: processed, including ClientHello1 and its later 36-byte replacement.
(defstruct TlsTranscriptLimits
  (max-frame-body i64)
  (max-input u64))

;: Public lifecycle; no operation resumes a finalized or closed transcript.
(defenum TlsTranscriptLifecycle
  (TlsTranscriptLive)
  (TlsTranscriptFinalized)
  (TlsTranscriptClosed))

;: Only the first sole ClientHello permits the one HRR replacement.
(defenum TlsTranscriptRetryState
  (TlsTranscriptEmpty)
  (TlsTranscriptClientHello1)
  (TlsTranscriptLater)
  (TlsTranscriptRetried))

;: Protocol boundary labels. BeforeClientFinished permits the optional client
;: Certificate/CertificateVerify suffix, or the server Finished without it.
(defenum TlsTranscriptBoundary
  (ThroughClientHello)
  (ThroughServerHello)
  (BeforeCertificateVerify)
  (BeforeServerFinished)
  (ThroughServerFinished)
  (BeforeClientFinished)
  (ThroughClientFinished))

;: Immutable public hash with a validated local boundary tag. Only borrowed
;: pointers cross the module boundary; callers cannot construct or project it.
(defstruct TlsTranscriptHash
  (:opaque)
  (boundary TlsTranscriptBoundary)
  (digest sha.Sha256Digest))

;: Arena allocator used only for an opaque public boundary snapshot.
(unsafe
  (extern (transcript-runtime-alloc [size : i64]) : (MutPtr u8) (:symbol "tl_alloc")))

;: Public-data-only state. Construct with `new`. Fields are not a capability
;: for bypassing validation; do not alter a constructed state's bookkeeping.
(defstruct TlsTranscript
  (hash sha.Sha256State)
  (limits TlsTranscriptLimits)
  (input-length u64)
  (retry TlsTranscriptRetryState)
  (lifecycle TlsTranscriptLifecycle)
  (last-kind i64)
  (last-offset i64)
  (last-hello-retry bool))

;: Stable errors. Offsets name the reader's handshake stream, not record
;: headers. State-only operations use offset zero. SHA errors retain their
;: original typed payload, including both non-wrapping counter operands.
(defenum TlsTranscriptError
  (TlsTranscriptInvalidLimits)
  (TlsTranscriptNotLive TlsTranscriptLifecycle)
  (TlsTranscriptInvalidState)
  (TlsTranscriptNoFrame i64)
  (TlsTranscriptInvalidFrame i64)
  (TlsTranscriptFrameTooLarge i64 i64 i64)
  (TlsTranscriptInputTooLong i64 u64 u64 u64)
  (TlsTranscriptFrameKind i64 i64)
  (TlsTranscriptRetryUnavailable i64)
  (TlsTranscriptWireError wire.TlsWireError)
  (TlsTranscriptShaError i64 sha.Sha256Error)
  (TlsTranscriptBoundaryMismatch i64 i64 TlsTranscriptBoundary)
  (TlsTranscriptWrongBoundary TlsTranscriptBoundary TlsTranscriptBoundary)
  (TlsTranscriptInvalidHash))

;: A new transcript or a resource configuration error.
(defenum TlsTranscriptNewResult
  (TlsTranscriptNewOk TlsTranscript)
  (TlsTranscriptNewErr TlsTranscriptError))

;: An operation succeeds completely or leaves the state unchanged.
(defenum TlsTranscriptStatus
  (TlsTranscriptOk)
  (TlsTranscriptErr TlsTranscriptError))

;: An exact ordinary public digest or a checked failure.
(defenum TlsTranscriptDigestResult
  (TlsTranscriptDigestOk sha.Sha256Digest)
  (TlsTranscriptDigestErr TlsTranscriptError))

;: A fresh opaque arena-owned snapshot pointer, or a refusal before allocation.
(defenum TlsTranscriptHashResult
  (TlsTranscriptHashOk (Ptr TlsTranscriptHash))
  (TlsTranscriptHashErr TlsTranscriptError))

;: Default one-MiB frame and sixteen-MiB cumulative work budgets.
(define (default-limits) : TlsTranscriptLimits
  (TlsTranscriptLimits 1048576 (cast 16777216 : u64)))

;: Resource budgets fit both TLS's uint24 body domain and SHA's byte domain.
(define (limits-valid? [limits : (& limits TlsTranscriptLimits)]) : bool
  (and
    (>= limits.max-frame-body 0)
    (<= limits.max-frame-body wire.max-handshake-body)
    (<= limits.max-input (sha.max-byte-length))))

;: Construct one empty live transcript after checking its resource budgets.
(define (new [limits : TlsTranscriptLimits]) : TlsTranscriptNewResult
  (if (limits-valid? (& limits))
    (TlsTranscriptNewOk
      (TlsTranscript
        (sha.new)
        limits
        (cast 0 : u64)
        (TlsTranscriptEmpty)
        (TlsTranscriptLive)
        -1
        0
        false))
    (TlsTranscriptNewErr (TlsTranscriptInvalidLimits))))

;: Preflight lifecycle and public hash bookkeeping without changing anything.
(define (check-state [state : (& state TlsTranscript)]) : TlsTranscriptStatus
  (match state.lifecycle
    [(TlsTranscriptLive)
      (cond
        [(or
            (not (limits-valid? (& state.limits)))
            (> state.input-length state.limits.max-input)
            (< state.input-length state.hash.byte-length))
          (TlsTranscriptErr (TlsTranscriptInvalidState))]
        [state.hash.finalized
          (TlsTranscriptErr (TlsTranscriptShaError 0 (sha.Sha256Finalized)))]
        [(not (sha.state-valid? (& state.hash)))
          (TlsTranscriptErr (TlsTranscriptShaError 0 (sha.Sha256InvalidState)))]
        [else (TlsTranscriptOk)])]
    [(TlsTranscriptFinalized)
      (TlsTranscriptErr (TlsTranscriptNotLive (TlsTranscriptFinalized)))]
    [(TlsTranscriptClosed)
      (TlsTranscriptErr (TlsTranscriptNotLive (TlsTranscriptClosed)))]))

;: Check the wire reader's held complete-frame boundary before taking a view.
;: This validates the supplied representation, never reassembles a frame.
(define (check-frame
  [state : (& state TlsTranscript)]
  [reader : (& reader wire.TlsHandshakeReader)]) : TlsTranscriptStatus
  (match (check-state state)
    [(TlsTranscriptErr error) (return (TlsTranscriptErr error))]
    [(TlsTranscriptOk) unit])
  (when
    reader.failed
    (return
      (TlsTranscriptErr
        (TlsTranscriptWireError (wire.copy-error (& reader.error))))))
  (when
    (or
      (< reader.base 0)
      (< reader.start 0)
      (> reader.start (- 9223372036854775807 reader.base))
      (> reader.start (byte_buf.len (& reader.pending))))
    (return (TlsTranscriptErr (TlsTranscriptInvalidFrame 0))))
  (let
    [offset : i64 (wire.handshake-reader-message-offset reader)]
    (when
      (= reader.held 0)
      (return (TlsTranscriptErr (TlsTranscriptNoFrame offset))))
    (when
      (or
        (< reader.held wire.handshake-header-length)
        (> reader.held (- (byte_buf.len (& reader.pending)) reader.start)))
      (return (TlsTranscriptErr (TlsTranscriptInvalidFrame offset))))
    (let
      [frame : (& reader bytes) (wire.handshake-reader-message reader)]
      [body : i64 (wire.read-be frame 1 3)]
      (when
        (!= reader.held (+ wire.handshake-header-length body))
        (return (TlsTranscriptErr (TlsTranscriptInvalidFrame (+ offset 1)))))
      (when
        (> body state.limits.max-frame-body)
        (return
          (TlsTranscriptErr
            (TlsTranscriptFrameTooLarge
              (+ offset 1)
              body
              state.limits.max-frame-body))))
      (TlsTranscriptOk))))

;: Recognize HRR from the raw ServerHello random using the wire codec helper.
;: Typed ServerHello structure/policy validation remains the caller's job.
(define (retry-frame? [frame : (& frame bytes)]) : bool
  (and
    (>= (byte_buf.bytes-length frame) 38)
    (= (wire.read-be frame 0 1) wire.handshake-server-hello)
    (wire.hello-retry-request-random? (byte_buf.bytes-slice-view frame 6 32))))

;: Bound cumulative work and the actual SHA stream before any mutation.
(define (check-length
  [state : (& state TlsTranscript)]
  [hash-length : u64]
  [additional : u64]
  [offset : i64]) : TlsTranscriptStatus
  (match (sha.length-add hash-length additional)
    [(Sha256LengthErr error)
      (return (TlsTranscriptErr (TlsTranscriptShaError offset error)))]
    [(Sha256LengthOk _) unit])
  (if (> additional (- state.limits.max-input state.input-length))
    (TlsTranscriptErr
      (TlsTranscriptInputTooLong
        offset
        state.input-length
        additional
        state.limits.max-input))
    (TlsTranscriptOk)))

;: Absorb only the held complete exact frame, including its four-byte header.
;: No ordering policy is imposed apart from HRR/message_hash handling.
(define (absorb!
  [state : (&mut state TlsTranscript)]
  [reader : (& reader wire.TlsHandshakeReader)]) : TlsTranscriptStatus
  (match (check-frame state reader)
    [(TlsTranscriptErr error) (return (TlsTranscriptErr error))]
    [(TlsTranscriptOk) unit])
  (let
    [frame : (& reader bytes) (wire.handshake-reader-message reader)]
    [offset : i64 (wire.handshake-reader-message-offset reader)]
    [kind : i64 (wire.read-be frame 0 1)]
    [count : u64 (cast (byte_buf.bytes-length frame) : u64)]
    (when
      (or (= kind wire.handshake-message-hash) (retry-frame? frame))
      (return (TlsTranscriptErr (TlsTranscriptFrameKind offset kind))))
    (match (check-length state state.hash.byte-length count offset)
      [(TlsTranscriptErr error) (return (TlsTranscriptErr error))]
      [(TlsTranscriptOk) unit])
    (match (sha.update! (&mut state.hash) frame)
      [(Sha256UpdateErr error)
        (TlsTranscriptErr (TlsTranscriptShaError offset error))]
      [(Sha256UpdateOk)
        (set! state.input-length (+ state.input-length count))
        (set! state.last-kind kind)
        (set! state.last-offset offset)
        (set! state.last-hello-retry false)
        (set!
          state.retry
          (match state.retry
            [(TlsTranscriptEmpty)
              (if (= kind wire.handshake-client-hello)
                (TlsTranscriptClientHello1)
                (TlsTranscriptLater))]
            [(TlsTranscriptRetried) (TlsTranscriptRetried)]
            [_ (TlsTranscriptLater)]))
        (TlsTranscriptOk)])))

;: Return a checked independent public digest without altering the live state.
(define (snapshot [state : (& state TlsTranscript)]) : TlsTranscriptDigestResult
  (match (check-state state)
    [(TlsTranscriptErr error) (TlsTranscriptDigestErr error)]
    [(TlsTranscriptOk)
      (let
        [copy : sha.Sha256State
          (sha.Sha256State
            state.hash.words
            state.hash.block
            state.hash.block-length
            state.hash.byte-length
            state.hash.finalized)]
        (match (sha.finalize! (&mut copy))
          [(Sha256FinalizeOk digest) (TlsTranscriptDigestOk digest)]
          [(Sha256FinalizeErr error)
            (TlsTranscriptDigestErr (TlsTranscriptShaError 0 error))]))]))

;: Replace the sole ClientHello1 and absorb the held exact HRR atomically.
;: Scratch state is published only after all checks and SHA operations pass.
(define (hello-retry!
  [state : (&mut state TlsTranscript)]
  [reader : (& reader wire.TlsHandshakeReader)]) : TlsTranscriptStatus
  (match (check-frame state reader)
    [(TlsTranscriptErr error) (return (TlsTranscriptErr error))]
    [(TlsTranscriptOk) unit])
  (let
    [offset : i64 (wire.handshake-reader-message-offset reader)]
    [frame : (& reader bytes) (wire.handshake-reader-message reader)]
    [count : u64 (+ (cast 36 : u64) (cast (byte_buf.bytes-length frame) : u64))]
    (match state.retry
      [(TlsTranscriptClientHello1) unit]
      [_ (return (TlsTranscriptErr (TlsTranscriptRetryUnavailable offset)))])
    (when
      (not (retry-frame? frame))
      (return
        (TlsTranscriptErr
          (TlsTranscriptFrameKind offset (wire.read-be frame 0 1)))))
    (match (check-length state (cast 0 : u64) count offset)
      [(TlsTranscriptErr error) (return (TlsTranscriptErr error))]
      [(TlsTranscriptOk) unit])
    (let
      [digest : sha.Sha256Digest
        (match (snapshot state)
          [(TlsTranscriptDigestOk value) value]
          [(TlsTranscriptDigestErr error) (return (TlsTranscriptErr error))])]
      [octets : byte_buf.ByteBuf (byte_buf.with-capacity 32)]
      [_filled : unit
        (let
          [index : i64 0]
          (while (< index 32)
            (set!
              octets
              (byte_buf.push octets (sha.digest-byte (& digest) index)))
            (set! index (+ index 1))))]
      [synthetic : byte_buf.ByteBuf
        (wire.message-hash-frame (byte_buf.as-bytes (& octets)))]
      [replacement : sha.Sha256State (sha.new)]
      (match (sha.update! (&mut replacement) (byte_buf.as-bytes (& synthetic)))
        [(Sha256UpdateErr error)
          (return (TlsTranscriptErr (TlsTranscriptShaError offset error)))]
        [(Sha256UpdateOk) unit])
      (match (sha.update! (&mut replacement) frame)
        [(Sha256UpdateErr error)
          (TlsTranscriptErr (TlsTranscriptShaError offset error))]
        [(Sha256UpdateOk)
          (set! state.hash replacement)
          (set! state.input-length (+ state.input-length count))
          (set! state.retry (TlsTranscriptRetried))
          (set! state.last-kind wire.handshake-server-hello)
          (set! state.last-offset offset)
          (set! state.last-hello-retry true)
          (TlsTranscriptOk)]))))

;: Validate only the immediate predecessor/last message, not the whole order.
;: HRR has ServerHello's wire kind but cannot label a ThroughServerHello hash.
(define (boundary-matches?
  [state : (& state TlsTranscript)]
  [boundary : TlsTranscriptBoundary]) : bool
  (match boundary
    [(ThroughClientHello) (= state.last-kind wire.handshake-client-hello)]
    [(ThroughServerHello)
      (and
        (= state.last-kind wire.handshake-server-hello)
        (not state.last-hello-retry))]
    [(BeforeCertificateVerify) (= state.last-kind wire.handshake-certificate)]
    [(BeforeServerFinished)
      (= state.last-kind wire.handshake-certificate-verify)]
    [(ThroughServerFinished) (= state.last-kind wire.handshake-finished)]
    [(BeforeClientFinished)
      (or
        (= state.last-kind wire.handshake-finished)
        (= state.last-kind wire.handshake-certificate)
        (= state.last-kind wire.handshake-certificate-verify))]
    [(ThroughClientFinished) (= state.last-kind wire.handshake-finished)]))

;: Snapshot into one immutable opaque hash after checking liveness and last
;: kind. The allocation belongs to the active arena; retain it only while that
;: arena lives. No input digest or constructor is exposed to safe callers.
(define (snapshot-boundary
  [state : (& state TlsTranscript)]
  [boundary : TlsTranscriptBoundary]) : TlsTranscriptHashResult
  (match (check-state state)
    [(TlsTranscriptErr error) (return (TlsTranscriptHashErr error))]
    [(TlsTranscriptOk) unit])
  (when
    (not (boundary-matches? state boundary))
    (return
      (TlsTranscriptHashErr
        (TlsTranscriptBoundaryMismatch
          state.last-offset
          state.last-kind
          boundary))))
  (match (snapshot state)
    [(TlsTranscriptDigestErr error) (TlsTranscriptHashErr error)]
    [(TlsTranscriptDigestOk digest)
      (let
        [storage : (MutPtr TlsTranscriptHash)
          (unsafe
            (ptr-cast
              (transcript-runtime-alloc
                (comptime (size-of (type TlsTranscriptHash))))
              : (MutPtr TlsTranscriptHash)))]
        (unsafe
          (ptr-write! storage (TlsTranscriptHash boundary digest)))
        (TlsTranscriptHashOk
          (unsafe
            (ptr-cast storage : (Ptr TlsTranscriptHash)))))]))

;: Check a protocol consumer's expected tag and return a by-value public
;: digest only on an exact match. Null is a typed refusal. Non-null pointers
;: must originate from snapshot-boundary and remain within their arena lifetime.
(define (boundary-digest
  [value : (Ptr TlsTranscriptHash)]
  [expected : TlsTranscriptBoundary]) : TlsTranscriptDigestResult
  (if (ptr-null? value)
    (TlsTranscriptDigestErr (TlsTranscriptInvalidHash))
    (let
      [hash : TlsTranscriptHash
        (unsafe
          (ptr-read value))]
      (if (= hash.boundary expected)
        (TlsTranscriptDigestOk hash.digest)
        (TlsTranscriptDigestErr
          (TlsTranscriptWrongBoundary hash.boundary expected))))))

;: Finalize exactly once; failure leaves the live transcript unchanged.
(define (finalize! [state : (&mut state TlsTranscript)]) : TlsTranscriptDigestResult
  (match (snapshot state)
    [(TlsTranscriptDigestErr error) (TlsTranscriptDigestErr error)]
    [(TlsTranscriptDigestOk digest)
      (sha.wipe-state! (&mut state.hash))
      (set! state.lifecycle (TlsTranscriptFinalized))
      (TlsTranscriptDigestOk digest)]))

;: Discard public transcript storage. Repeated closure is harmless.
(define (close! [state : (&mut state TlsTranscript)]) : unit
  (sha.wipe-state! (&mut state.hash))
  (set! state.lifecycle (TlsTranscriptClosed)))