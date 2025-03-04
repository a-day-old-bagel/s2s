# struct to stream | stream to struct

A Zig binary serialization format and library.

![Project logo](design/logo.png)

## Features

- Convert (nearly) any Zig runtime datatype to binary data and back.
- Optionally computes a stream signature that prevents deserialization of invalid data.
- User can provide custom (de)serialization overrides for their structs if desired.
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

## adayoldbagel's fork

This fork merges Madeorsk's feature additions with the original repo's latest updates.
A few extra features are also in the works, according to what I find useful for my own projects:
- Adds the ability to override the recursive (de)serialization behavior for structs with appropriate override functions implemented.
- Adds a build option to skip runtime type hashing and validation, which shrinks the serialized stream.
- Some more involved compression techniques are tentatively planned as well.
- Incompatibilities in streams between build options and versions may later be solved with some sort of stream metadata header.
- Handling of more diverse map data types is being attempted, extending Madeorsk's work.

All additions to this branch are highly experimental, not at all robust, and likely not fit for public consumption at this time.

## API

The library itself provides only some APIs, as most of the serialization process is not configurable.

```zig
/// Options given to (de)serialize functions
/// - 'override_fn' is a function name. If any struct has a function named this, (de)serialization will call it instead.
pub const Options = struct {
    override_fn: []const u8 = "",
};

/// Serializes the given `value: T` into the `stream`.
/// - `stream` is a instance of `std.io.Writer`
/// - `T` is the type to serialize
/// - `value` is the instance to serialize.
/// - 'opt' contains optional features
fn serialize(stream: anytype, comptime T: type, value: T, comptime opt: Options) (StreamError || error{ MapTooLarge })!void;

/// Deserializes a value of type `T` from the `stream`.
/// - `stream` is a instance of `std.io.Reader`
/// - `T` is the type to deserialize
/// - 'opt' contains optional features
fn deserialize(stream: anytype, comptime T: type, comptime opt: Options) (StreamError || error{ UnexpectedData,EndOfStream })!T;

/// Deserializes a value of type `T` from the `stream`.
/// - `stream` is a instance of `std.io.Reader`
/// - `T` is the type to deserialize
/// - `allocator` is an allocator require to allocate slices and pointers.
/// Result must be freed by using `free()`.
/// Custom override functions not yet supported for this case.
fn deserializeAlloc(stream: anytype, comptime T: type, allocator: std.mem.Allocator) (StreamError || error{ UnexpectedData, OutOfMemory, EndOfStream })!T;

/// Releases all memory allocated by `deserializeAlloc`.
/// - `allocator` is the allocator passed to `deserializeAlloc`.
/// - `T` is the type that was passed to `deserializeAlloc`.
/// - `value` is the value that was returned by `deserializeAlloc`.
fn free(allocator: std.mem.Allocator, comptime T: type, value: T) void;
```

If you wish to add custom override (de)serialization functions to a struct, you might consider the following example.

> **_NOTE:_**  This example is only meant to demonstrate syntax and the potential signatures of override functions.
It does not represent a typical use case where override functions would be useful.

```zig
pub const MyStruct = struct {
    foo: u32,

    pub fn mySerialize(self: MyStruct, stream: anytype) !void {
        try stream.writeInt(u32, self.foo, .little);
    }
    
    pub fn myDeserialize(stream: anytype) !MyStruct {
        return .{ .foo = try stream.readInt(u32, .little) };
    }
};

pub fn main() !void {
    
    // have some std.io.stream "stream"
    
    const original: MyStruct = .{};
    try s2s.serialize(stream, MyStruct, original, .{ .override_fn = "mySerialize" });
    
    const copy = try s2s.deserialize(stream, MyStruct, .{ .override_fn = "myDeserialize" });
    assert(original.foo == copy.foo);
}
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
