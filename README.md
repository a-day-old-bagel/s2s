# struct to stream | stream to struct

A Zig binary serialization format and library.

![Project logo](design/logo.png)

## Features

- Convert (nearly) any Zig runtime datatype to binary data and back.
- Computes a stream signature that prevents deserialization of invalid data.
- No support for graph like structures. Everything is considered to be tree data.

**Unsupported types**:

- All `comptime` only types
- Unbound pointers (c pointers, pointer to many)
- `volatile` pointers
- Untagged or `external` unions
- Opaque types
- Function pointers
- Frames

## Madeorsk's fork

This is a fork from [`ziglibs/s2s`](https://github.com/ziglibs/s2s) which provides more features for real-world usage.

- Usable with zig's dependency manager.
- Support `[]u8` with sentinels.
- Support hash maps.

## API

The library itself provides only some APIs, as most of the serialization process is not configurable.

```zig
/// Serializes the given `value: T` into the `stream`.
/// - `stream` is a instance of `std.io.Writer`
/// - `T` is the type to serialize
/// - `value` is the instance to serialize.
fn serialize(stream: anytype, comptime T: type, value: T) StreamError!void;

/// Deserializes a value of type `T` from the `stream`.
/// - `stream` is a instance of `std.io.Reader`
/// - `T` is the type to deserialize
fn deserialize(stream: anytype, comptime T: type) (StreamError || error{UnexpectedData,EndOfStream})!T;

/// Deserializes a value of type `T` from the `stream`.
/// - `stream` is a instance of `std.io.Reader`
/// - `T` is the type to deserialize
/// - `allocator` is an allocator require to allocate slices and pointers.
/// Result must be freed by using `free()`.
fn deserializeAlloc(stream: anytype, comptime T: type, allocator: std.mem.Allocator) (StreamError || error{ UnexpectedData, OutOfMemory,EndOfStream })!T;

/// Releases all memory allocated by `deserializeAlloc`.
/// - `allocator` is the allocator passed to `deserializeAlloc`.
/// - `T` is the type that was passed to `deserializeAlloc`.
/// - `value` is the value that was returned by `deserializeAlloc`.
fn free(allocator: std.mem.Allocator, comptime T: type, value: T) void;
```

## Usage and Development

### Adding the library

The current latest version is 0.3.0 for zig 0.13.0.

```sh-session
[user@host s2s]$ zig fetch --save git+https://github.com/madeorsk/s2s#v0.3.0
```

In `build.zig`.

```zig
// Add s2s dependency.
const s2s = b.dependency("s2s", .{
	.target = target,
	.optimize = optimize,
});
exe.root_module.addImport("s2s", s2s.module("s2s"));
```

## Project Status

Most of the serialization/deserialization is implemented for the _trivial_ case.

Pointers/slices with non-standard alignment aren't properly supported yet.
