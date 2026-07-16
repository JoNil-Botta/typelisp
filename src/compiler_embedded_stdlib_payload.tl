;; Handwritten lookup over build-time embedded stdlib payload shards.
(import compiler_embedded_stdlib_payload_a as a)
(import compiler_embedded_stdlib_payload_b as b)
(import compiler_embedded_stdlib_payload_c as c)
(import compiler_embedded_stdlib_payload_d as d)
(import compiler_embedded_stdlib_payload_e as e)
(import compiler_embedded_stdlib_payload_f as f)
(import stdlib.string)

(defenum CompilerEmbeddedStdlibPayload
  (CompilerEmbeddedStdlibPayloadNone)
  (CompilerEmbeddedStdlibPayloadSome (Array u8)))

(define (compiler-embedded-stdlib-payload-lookup [suffix : String]) : CompilerEmbeddedStdlibPayload
  (cond
    [(string.eq suffix "arena.tl")
      (CompilerEmbeddedStdlibPayloadSome a.payload-arena)]
    [(string.eq suffix "atomic.tl")
      (CompilerEmbeddedStdlibPayloadSome a.payload-atomic)]
    [(string.eq suffix "args.tl")
      (CompilerEmbeddedStdlibPayloadSome a.payload-args)]
    [(string.eq suffix "array.tl")
      (CompilerEmbeddedStdlibPayloadSome a.payload-array)]
    [(string.eq suffix "byte_buf.tl")
      (CompilerEmbeddedStdlibPayloadSome a.payload-byte-buf)]
    [(string.eq suffix "byte_buf_core.tl")
      (CompilerEmbeddedStdlibPayloadSome a.payload-byte-buf-core)]
    [(string.eq suffix "clone.tl")
      (CompilerEmbeddedStdlibPayloadSome a.payload-clone)]
    [(string.eq suffix "cpu.tl")
      (CompilerEmbeddedStdlibPayloadSome b.payload-cpu)]
    [(string.eq suffix "comptime.tl")
      (CompilerEmbeddedStdlibPayloadSome b.payload-comptime)]
    [(string.eq suffix "core_macros.tl")
      (CompilerEmbeddedStdlibPayloadSome b.payload-core-macros)]
    [(string.eq suffix "env.tl")
      (CompilerEmbeddedStdlibPayloadSome b.payload-env)]
    [(string.eq suffix "eq.tl")
      (CompilerEmbeddedStdlibPayloadSome b.payload-eq)]
    [(string.eq suffix "ffi.tl")
      (CompilerEmbeddedStdlibPayloadSome b.payload-ffi)]
    [(string.eq suffix "fs.tl")
      (CompilerEmbeddedStdlibPayloadSome b.payload-fs)]
    [(string.eq suffix "format.tl")
      (CompilerEmbeddedStdlibPayloadSome c.payload-format)]
    [(string.eq suffix "hash.tl")
      (CompilerEmbeddedStdlibPayloadSome c.payload-hash)]
    [(string.eq suffix "hashmap.tl")
      (CompilerEmbeddedStdlibPayloadSome c.payload-hashmap)]
    [(string.eq suffix "io_core.tl")
      (CompilerEmbeddedStdlibPayloadSome c.payload-io-core)]
    [(string.eq suffix "io.tl")
      (CompilerEmbeddedStdlibPayloadSome c.payload-io)]
    [(string.eq suffix "iterator.tl")
      (CompilerEmbeddedStdlibPayloadSome c.payload-iterator)]
    [(string.eq suffix "json.tl")
      (CompilerEmbeddedStdlibPayloadSome c.payload-json)]
    [(string.eq suffix "math.tl")
      (CompilerEmbeddedStdlibPayloadSome d.payload-math)]
    [(string.eq suffix "msvc.tl")
      (CompilerEmbeddedStdlibPayloadSome d.payload-msvc)]
    [(string.eq suffix "process.tl")
      (CompilerEmbeddedStdlibPayloadSome d.payload-process)]
    [(string.eq suffix "process_borrowed.tl")
      (CompilerEmbeddedStdlibPayloadSome d.payload-process-borrowed)]
    [(string.eq suffix "profile.tl")
      (CompilerEmbeddedStdlibPayloadSome d.payload-profile)]
    [(string.eq suffix "queue.tl")
      (CompilerEmbeddedStdlibPayloadSome d.payload-queue)]
    [(string.eq suffix "random.tl")
      (CompilerEmbeddedStdlibPayloadSome d.payload-random)]
    [(string.eq suffix "result.tl")
      (CompilerEmbeddedStdlibPayloadSome e.payload-result)]
    [(string.eq suffix "runtime.tl")
      (CompilerEmbeddedStdlibPayloadSome e.payload-runtime)]
    [(string.eq suffix "serialize.tl")
      (CompilerEmbeddedStdlibPayloadSome e.payload-serialize)]
    [(string.eq suffix "sort.tl")
      (CompilerEmbeddedStdlibPayloadSome e.payload-sort)]
    [(string.eq suffix "sync.tl")
      (CompilerEmbeddedStdlibPayloadSome e.payload-sync)]
    [(string.eq suffix "string.tl")
      (CompilerEmbeddedStdlibPayloadSome e.payload-string)]
    [(string.eq suffix "test.tl")
      (CompilerEmbeddedStdlibPayloadSome e.payload-test)]
    [(string.eq suffix "thread.tl")
      (CompilerEmbeddedStdlibPayloadSome f.payload-thread)]
    [(string.eq suffix "time.tl")
      (CompilerEmbeddedStdlibPayloadSome f.payload-time)]
    [(string.eq suffix "text_buf.tl")
      (CompilerEmbeddedStdlibPayloadSome f.payload-text-buf)]
    [(string.eq suffix "text_buf_borrowed.tl")
      (CompilerEmbeddedStdlibPayloadSome f.payload-text-buf-borrowed)]
    [(string.eq suffix "text_buf_family.tl")
      (CompilerEmbeddedStdlibPayloadSome f.payload-text-buf-family)]
    [(string.eq suffix "vector.tl")
      (CompilerEmbeddedStdlibPayloadSome f.payload-vector)]
    [(string.eq suffix "vector_slice.tl")
      (CompilerEmbeddedStdlibPayloadSome f.payload-vector-slice)]
    [else (CompilerEmbeddedStdlibPayloadNone)]))