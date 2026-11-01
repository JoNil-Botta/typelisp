;# Linux resolver snapshot loading. Reads two fixed paths through bounded file
;# handles, then delegates all policy and normalization to resolver_config.
;# The injectable byte source is also the hermetic adapter test boundary.
(import stdlib.byte_buf)
(import stdlib.io)
(import stdlib.net.resolver_config as config)

;: Bounded byte-source result. Errors carry logical source identity, not input.
(defenum ConfigBytesResult
  (ConfigBytesOk byte_buf.ByteBuf)
  (ConfigBytesErr config.ConfigError))

;: Map a host error to a bounded numeric detail without copying its path.
(define (host-error-code [error : (& error io.IoError)]) : i64
  (match error
    [(IoNotFound _) 2]
    [(IoPermissionDenied _) 13]
    [(IoInvalidPath _) 22]
    [(IoInterrupted _) 4]
    [(IoSystemCode code _) code]
    [(IoUnsupported _) 38]
    [(IoUnknown _) 5]))

;: Construct a structured unavailable-source error.
(define (unavailable [source : config.ConfigSource] [code : i64]) : config.ConfigError
  (config.ConfigError source 0 0 (ConfigUnavailable) code))

;: Only scalar progress/error facts leave a temporary read arena.
(defenum ConfigReadStep
  (ConfigReadProgress i64 bool)
  (ConfigReadFailure i64))

;: Read one bounded chunk in a scratch arena, copy its live bytes into the
;: preallocated outer buffer, and reclaim all temporary I/O allocations.
;: Mutating only byte/scalar places cannot retain scratch-owned storage.
(define (read-step!
  [out : (&mut out byte_buf.ByteBuf)]
  [handle : io.FileHandle]
  [read : (-> io.FileHandle i64 io.ResultIoRead)]) : ConfigReadStep
  (let
    [remaining : i64 (- 1048577 (byte_buf.len out))]
    [requested : i64
      (if (< remaining 8192)
        remaining
        8192)]
    (with-arena
      scratch
      (match (read handle requested)
        [(ErrIoRead error) (ConfigReadFailure (host-error-code (& error)))]
        [(OkIoRead chunk)
          (let
            [count : i64 (byte_buf.len (& chunk.bytes))]
            (if (or (< count 0) (> count requested))
              (ConfigReadFailure 5)
              (let
                [index : i64 0]
                [old-length : i64 (byte_buf.len out)]
                (while (< index count)
                  (set!
                    (array-ref out.slots (+ old-length index))
                    (byte_buf.ref (& chunk.bytes) index))
                  (set! index (+ index 1)))
                (set! out.len (+ old-length count))
                (ConfigReadProgress count chunk.eof))))]))))

;: Read an already-open source through injected file operations. This owns
;: exactly one close, including every failure path.
(define (read-open-source
  [source : config.ConfigSource]
  [handle : io.FileHandle]
  [read : (-> io.FileHandle i64 io.ResultIoRead)]
  [close : (-> io.FileHandle io.ResultIoUnit)]) : ConfigBytesResult
  (let
    [out : byte_buf.ByteBuf (byte_buf.with-capacity 1048577)]
    [done : bool false]
    [failed : bool false]
    [failure : config.ConfigError (unavailable source 0)]
    (while (not done)
      (match (read-step! (&mut out) handle read)
        [(ConfigReadFailure code)
          (set! failure (unavailable source code))
          (set! failed true)
          (set! done true)]
        [(ConfigReadProgress count eof)
          (cond
            [(> (byte_buf.len (& out)) 1048576)
              (set!
                failure
                (config.error-at source 0 1048576 (ConfigFileTooLarge)))
              (set! failed true)
              (set! done true)]
            [(and (= count 0) (not eof))
              (set! failure (unavailable source 5))
              (set! failed true)
              (set! done true)]
            [else (set! done eof)])]))
    (match (close handle)
      [(ErrIoUnit error)
        (when
          (not failed)
          (set! failure (unavailable source (host-error-code (& error))))
          (set! failed true))]
      [(OkIoUnit) unit])
    (if failed
      (ConfigBytesErr failure)
      (ConfigBytesOk out))))

;: Read at most 1 MiB plus one overflow-detection byte. A bounded number of
;: short reads is guaranteed because every non-EOF success consumes >=1 byte.
;: Each <=8192-byte temporary read is reclaimed before the next read.
;: Opened handles close exactly once on every success and failure path.
;: The path argument is for injected filesystem fixtures; errors identify the
;: logical source path returned by config.source-path.
(define (read-source-path [source : config.ConfigSource] [path : (& path str)]) : ConfigBytesResult
  (match (io.file-open path (OpenRead))
    [(ErrIoFile error)
      (ConfigBytesErr (unavailable source (host-error-code (& error))))]
    [(OkIoFile handle)
      (read-open-source source handle io.file-read-chunk io.file-close)]))

;: System byte source with fixed path selection, no environment/libc resolver.
(cfg
  (not windows)
  (define (system-source [source : config.ConfigSource]) : ConfigBytesResult
    (let
      [path : String (config.source-path source)]
      (read-source-path source (& path)))))

;: Build a complete replacement through an injected bounded source.
;: The core rechecks byte bounds even when an injected source violates its cap.
(define (load-with-source [read : (-> config.ConfigSource ConfigBytesResult)]) : config.ResolverConfigResult
  (match (read (ConfigHosts))
    [(ConfigBytesErr error) (ResolverConfigErr error)]
    [(ConfigBytesOk hosts)
      (match (config.validate-source
        (byte_buf.as-bytes (& hosts))
        (ConfigHosts))
        [(ConfigInvalid error) (return (ResolverConfigErr error))]
        [(ConfigValid) unit])
      (match (read (ConfigResolv))
        [(ConfigBytesErr error) (ResolverConfigErr error)]
        [(ConfigBytesOk resolv)
          (config.parse-linux
            (byte_buf.as-bytes (& hosts))
            (byte_buf.as-bytes (& resolv)))])]))

;: Linux convenience factory. No background watcher and no caller-state mutation.
(cfg
  (not windows)
  (define (load-system) : config.ResolverConfigResult
    (load-with-source system-source)))