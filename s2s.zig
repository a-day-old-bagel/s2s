const std = @import("std");
const testing = std.testing;
const options = @import("s2s_options");

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// Public API:

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
pub fn serialize(
    stream: anytype,
    comptime T: type,
    value: T,
    comptime opt: Options,
) (@TypeOf(stream).Error || error{ MapTooLarge })!void {
    comptime validateTopLevelType(T);

    if (!options.skip_runtime_type_validation) {
        const type_hash = comptime computeTypeHash(T);
        try stream.writeAll(type_hash[0..]);
    }

    try serializeRecursive(stream, T, value, opt);
}

/// Deserializes a value of type `T` from the `stream`.
/// - `stream` is a instance of `std.io.Reader`
/// - `T` is the type to deserialize
/// - 'opt' contains optional features
pub fn deserialize(
    stream: anytype,
    comptime T: type,
    comptime opt: Options,
) (@TypeOf(stream).Error || error{ UnexpectedData, EndOfStream })!T {
    comptime validateTopLevelType(T);
    if (comptime requiresAllocationForDeserialize(T, opt))
        @compileError(@typeName(T) ++ " requires allocation to be deserialized. Use deserializeAlloc instead of deserialize!");
    return deserializeInternal(stream, T, null, opt) catch |err| switch (err) {
        error.OutOfMemory => unreachable,
        else => |e| return e,
    };
}

/// Deserializes a value of type `T` from the `stream`.
/// - `stream` is a instance of `std.io.Reader`
/// - `T` is the type to deserialize
/// - `allocator` is an allocator require to allocate slices and pointers.
/// Result must be freed by using `free()`.
/// Custom override functions not yet supported for this case.
pub fn deserializeAlloc(
    stream: anytype,
    comptime T: type,
    allocator: std.mem.Allocator,
) (@TypeOf(stream).Error || error{ UnexpectedData, OutOfMemory, EndOfStream })!T {
    comptime validateTopLevelType(T);
    return try deserializeInternal(stream, T, allocator, .{});
}

/// Releases all memory allocated by `deserializeAlloc`.
/// - `allocator` is the allocator passed to `deserializeAlloc`.
/// - `T` is the type that was passed to `deserializeAlloc`.
/// - `value` is the value that was returned by `deserializeAlloc`.
pub fn free(allocator: std.mem.Allocator, comptime T: type, value: *T) void {
    recursiveFree(allocator, T, value);
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// Implementation:

/// Try to get the entry type of the unmanaged hash map, if it is one.
/// Return NULL if it's not an unmanaged hash map.
fn findHashMapEntryType(comptime T: type) ?type {
    return if (
        @hasDecl(T, "Entry") and
        @hasField(T.Entry, "key_ptr") and
        @hasField(T.Entry, "value_ptr")
    ) T.Entry else null;
}

/// Serialize an unmanaged hash map.
fn serializeMap(
    stream: anytype,
    comptime T: type,
    value: T,
    comptime opt: Options,
) (@TypeOf(stream).Error || error{ MapTooLarge })!void {
    // Serialize the map size.
    if (@hasField(T, "size")) {
        try serializeRecursive(stream, u32, value.size, opt);
    } else if (@hasDecl(T, "count")) {
        if (value.count() > std.math.maxInt(u32)) return error.MapTooLarge;
        try serializeRecursive(stream, u32, @as(u32, @intCast(value.count())), opt);
    } else @compileError("unsupported map type");

    // Serialize each entry.
    var iterator = value.iterator();
    while (iterator.next()) |entry| {
        try serializeRecursive(stream, T.Entry, entry, opt);
    }
}

fn serializeRecursive(
    stream: anytype,
    comptime T: type,
    value: T,
    comptime opt: Options,
) (@TypeOf(stream).Error || error{ MapTooLarge })!void {
    switch (@typeInfo(T)) {
        // Primitive types:
        .void => {}, // no data
        .bool => try stream.writeByte(@intFromBool(value)),
        .float => switch (T) {
            f16 => try stream.writeInt(u16, @bitCast(value), .little),
            f32 => try stream.writeInt(u32, @bitCast(value), .little),
            f64 => try stream.writeInt(u64, @bitCast(value), .little),
            f80 => try stream.writeInt(u80, @bitCast(value), .little),
            f128 => try stream.writeInt(u128, @bitCast(value), .little),
            else => unreachable,
        },

        .int => {
            if (T == usize) {
                try stream.writeInt(u64, value, .little);
            } else {
                try stream.writeInt(AlignedInt(T), value, .little);
            }
        },
        .pointer => |ptr| {
            switch (ptr.size) {
                .one => try serializeRecursive(stream, ptr.child, value.*, opt),
                .slice => {
                    try stream.writeInt(u64, value.len, .little);
                    if (ptr.child == u8) {
                        try stream.writeAll(value);
                    } else {
                        for (value) |item| {
                            try serializeRecursive(stream, ptr.child, item, opt);
                        }
                    }
                },
                .c => unreachable,
                .many => unreachable,
            }
        },
        .array => |arr| {
            if (arr.child == u8) {
                try stream.writeAll(&value);
            } else {
                for (value) |item| {
                    try serializeRecursive(stream, arr.child, item, opt);
                }
            }
        },
        .@"struct" => |str| {
            if (opt.override_fn.len > 0 and (@hasDecl(T, opt.override_fn))) {
                try @field(T, opt.override_fn)(value, stream);
                return;
            }

            // Try to detect a structure like std.HashMapUnmanaged(T).
            if (std.meta.fieldIndex(T, "unmanaged")) |unmanagedField| {
                // Try to serialize an unmanaged hash map type from the unmanaged field.
                if (comptime findHashMapEntryType(std.meta.fields(T)[unmanagedField].type) != null) {
                    try serializeMap(stream, std.meta.fields(T)[unmanagedField].type, value.unmanaged, opt);
                    // Serialized the map type, nothing more to do.
                    return;
                }
            } else {
                // Try to serialize the provided type as an unmanaged hash map type.
                if (comptime findHashMapEntryType(T) != null) {
                    try serializeMap(stream, T, value.unmanaged, opt);
                    // Serialized the map type, nothing more to do.
                    return;
                }
            }

            // we can safely ignore the struct layout here as we will serialize the data by field order,
            // instead of memory representation

            inline for (str.fields) |fld| {
                try serializeRecursive(stream, fld.type, @field(value, fld.name), opt);
            }
        },
        .optional => |optional| {
            if (value) |item| {
                try stream.writeInt(u8, 1, .little);
                try serializeRecursive(stream, optional.child, item, opt);
            } else {
                try stream.writeInt(u8, 0, .little);
            }
        },
        .error_union => |eu| {
            if (value) |item| {
                try stream.writeInt(u8, 1, .little);
                try serializeRecursive(stream, eu.payload, item, opt);
            } else |item| {
                try stream.writeInt(u8, 0, .little);
                try serializeRecursive(stream, eu.error_set, item, opt);
            }
        },
        .error_set => {
            // Error unions are serialized by "index of sorted name", so we
            // hash all names in the right order
            const names = comptime getSortedErrorNames(T);

            const index = for (names, 0..) |name, i| {
                if (std.mem.eql(u8, name, @errorName(value)))
                    break @as(u16, @intCast(i));
            } else unreachable;

            try stream.writeInt(u16, index, .little);
        },
        .@"enum" => |list| {
            const Tag = if (list.tag_type == usize) u64 else list.tag_type;
            try stream.writeInt(AlignedInt(Tag), @intFromEnum(value), .little);
        },
        .@"union" => |un| {
            const Tag = un.tag_type orelse @compileError("Untagged unions are not supported!");

            const active_tag = std.meta.activeTag(value);

            try serializeRecursive(stream, Tag, active_tag, opt);

            inline for (std.meta.fields(T)) |fld| {
                if (@field(Tag, fld.name) == active_tag) {
                    try serializeRecursive(stream, fld.type, @field(value, fld.name), opt);
                }
            }
        },
        .vector => |vec| {
            const array: [vec.len]vec.child = value;
            try serializeRecursive(stream, @TypeOf(array), array, opt);
        },

        // Unsupported types:
        .noreturn,
        .type,
        .comptime_float,
        .comptime_int,
        .undefined,
        .null,
        .@"fn",
        .@"opaque",
        .frame,
        .@"anyframe",
        .enum_literal,
        => unreachable,
    }
}

fn deserializeInternal(
    stream: anytype,
    comptime T: type,
    allocator: ?std.mem.Allocator,
    comptime opt: Options,
) (@TypeOf(stream).Error || error{ UnexpectedData, OutOfMemory, EndOfStream })!T {

    if (!options.skip_runtime_type_validation) {
        const type_hash = comptime computeTypeHash(T);
        var ref_hash: [type_hash.len]u8 = undefined;
        try stream.readNoEof(&ref_hash);
        if (!std.mem.eql(u8, type_hash[0..], ref_hash[0..]))
            return error.UnexpectedData;
    }

    var result: T = undefined;
    try recursiveDeserialize(stream, T, allocator, &result, opt);
    return result;
}

///Determines the size of the next byte aligned integer type that can accommodate the same range of values as `T`
fn AlignedInt(comptime T: type) type {
    return std.math.ByteAlignedInt(T);
}

fn deserializeMap(
    stream: anytype,
    comptime T: type,
    comptime EntryType: type,
    allocator: ?std.mem.Allocator,
    target: *T,
    comptime opt: Options,
) (@TypeOf(stream).Error || error{ UnexpectedData, OutOfMemory, EndOfStream })!void {
    // Initialize the map.
    target.* = T.init(allocator.?);

    // Read the size of the map.
    const size = try stream.readInt(u32, .little);

    // Ensure total capacity of the map, managed or not.
    if (@hasField(T, "unmanaged")) {
        try target.ensureTotalCapacity(size);
    } else {
        try target.ensureTotalCapacity(allocator.?, size);
    }

    for (0..size) |_| {
        // Deserialize each entry and put it in the map.
        var entry: EntryType = undefined;
        try recursiveDeserialize(stream, EntryType, allocator, &entry, opt);
        defer {
            allocator.?.destroy(entry.key_ptr);
            allocator.?.destroy(entry.value_ptr);
        }
        try target.put(entry.key_ptr.*, entry.value_ptr.*);
    }
}

fn recursiveDeserialize(
    stream: anytype,
    comptime T: type,
    allocator: ?std.mem.Allocator,
    target: *T,
    comptime opt: Options,
) (@TypeOf(stream).Error || error{ UnexpectedData, OutOfMemory, EndOfStream })!void {
    switch (@typeInfo(T)) {
        // Primitive types:
        .void => target.* = {},
        .bool => target.* = (try stream.readByte()) != 0,
        .float => target.* = @bitCast(switch (T) {
            f16 => try stream.readInt(u16, .little),
            f32 => try stream.readInt(u32, .little),
            f64 => try stream.readInt(u64, .little),
            f80 => try stream.readInt(u80, .little),
            f128 => try stream.readInt(u128, .little),
            else => unreachable,
        }),

        .int => target.* = if (T == usize)
            std.math.cast(usize, try stream.readInt(u64, .little)) orelse return error.UnexpectedData
        else
            @truncate(try stream.readInt(AlignedInt(T), .little)),

        .pointer => |ptr| {
            switch (ptr.size) {
                .one => {
                    const pointer = try allocator.?.create(ptr.child);
                    errdefer allocator.?.destroy(pointer);

                    try recursiveDeserialize(stream, ptr.child, allocator, pointer, opt);

                    target.* = pointer;
                },
                .slice => {
                    const length = std.math.cast(usize, try stream.readInt(u64, .little)) orelse return error.UnexpectedData;

                    const slice = blk: {
                        if (ptr.sentinel) |_sentinel| {
                            // There is a sentinel, append it.
                            const typedSentinel: *const u8 = @ptrCast(@alignCast(_sentinel));
                            break :blk try allocator.?.allocSentinel(ptr.child, length, typedSentinel.*);
                        } else {
                            break :blk try allocator.?.alloc(ptr.child, length);
                        }
                    };
                    errdefer allocator.?.free(slice);

                    if (ptr.child == u8) {
                        try stream.readNoEof(slice);
                    } else {
                        for (slice) |*item| {
                            try recursiveDeserialize(stream, ptr.child, allocator, item, opt);
                        }
                    }

                    target.* = slice;
                },
                .c => unreachable,
                .many => unreachable,
            }
        },
        .array => |arr| {
            if (arr.child == u8) {
                try stream.readNoEof(target);
            } else {
                for (&target.*) |*item| {
                    try recursiveDeserialize(stream, arr.child, allocator, item, opt);
                }
            }
        },
        .@"struct" => |str| {
            if (opt.override_fn.len > 0 and (@hasDecl(T, opt.override_fn))) {
                target.* = try @field(T, opt.override_fn)(stream);
                return;
            }

            // Try to detect a structure like std.HashMapUnmanaged(T).
            if (std.meta.fieldIndex(T, "unmanaged")) |unmanagedField| {
                // Try to deserialize an unmanaged hash map type from the unmanaged field.
                if (comptime findHashMapEntryType(std.meta.fields(T)[unmanagedField].type)) |EntryType| {
                    try deserializeMap(stream, T, EntryType, allocator, target, opt);
                    // Deserialized the map type, nothing more to do.
                    return;
                }
            } else {
                // Try to deserialize the provided type as an unmanaged hash map type.
                if (comptime findHashMapEntryType(T)) |EntryType| {
                    try deserializeMap(stream, T, EntryType, allocator, target, opt);
                    // Deserialized the map type, nothing more to do.
                    return;
                }
            }

            // we can safely ignore the struct layout here as we will serialize the data by field order,
            // instead of memory representation

            inline for (str.fields) |fld| {
                try recursiveDeserialize(stream, fld.type, allocator, &@field(target.*, fld.name), opt);
            }
        },
        .optional => |optional| {
            const is_set = try stream.readInt(u8, .little);

            if (is_set != 0) {
                target.* = @as(optional.child, undefined);
                try recursiveDeserialize(stream, optional.child, allocator, &target.*.?, opt);
            } else {
                target.* = null;
            }
        },
        .error_union => |eu| {
            const is_value = try stream.readInt(u8, .little);
            if (is_value != 0) {
                var value: eu.payload = undefined;
                try recursiveDeserialize(stream, eu.payload, allocator, &value, opt);
                target.* = value;
            } else {
                var err: eu.error_set = undefined;
                try recursiveDeserialize(stream, eu.error_set, allocator, &err, opt);
                target.* = err;
            }
        },
        .error_set => {
            // Error unions are serialized by "index of sorted name", so we
            // hash all names in the right order
            const names = comptime getSortedErrorNames(T);
            const index = try stream.readInt(u16, .little);

            switch (index) {
                inline 0...names.len - 1 => |idx| target.* = @field(T, names[idx]),
                else => return error.UnexpectedData,
            }
        },
        .@"enum" => |list| {
            const Tag = if (list.tag_type == usize) u64 else list.tag_type;
            const tag_value: Tag = @truncate(try stream.readInt(AlignedInt(Tag), .little));
            if (list.is_exhaustive) {
                target.* = std.meta.intToEnum(T, tag_value) catch return error.UnexpectedData;
            } else {
                target.* = @enumFromInt(tag_value);
            }
        },
        .@"union" => |un| {
            const Tag = un.tag_type orelse @compileError("Untagged unions are not supported!");

            var active_tag: Tag = undefined;
            try recursiveDeserialize(stream, Tag, allocator, &active_tag, opt);

            inline for (std.meta.fields(T)) |fld| {
                if (@field(Tag, fld.name) == active_tag) {
                    var union_value: fld.type = undefined;
                    try recursiveDeserialize(stream, fld.type, allocator, &union_value, opt);
                    target.* = @unionInit(T, fld.name, union_value);
                    return;
                }
            }

            return error.UnexpectedData;
        },
        .vector => |vec| {
            var array: [vec.len]vec.child = undefined;
            try recursiveDeserialize(stream, @TypeOf(array), allocator, &array, opt);
            target.* = array;
        },

        // Unsupported types:
        .noreturn,
        .type,
        .comptime_float,
        .comptime_int,
        .undefined,
        .null,
        .@"fn",
        .@"opaque",
        .frame,
        .@"anyframe",
        .enum_literal,
        => unreachable,
    }
}

fn makeMutableSlice(comptime T: type, slice: []const T, comptime withSentinel: bool) []T {
    if (slice.len == 0) {
        var buf: [if (withSentinel) 1 else 0]T = if (withSentinel) .{undefined} else .{};
        return &buf;
    } else {
        return @as([*]T, @constCast(slice.ptr))[0..slice.len + (if (withSentinel) 1 else 0)];
    }
}

fn recursiveFree(allocator: std.mem.Allocator, comptime T: type, value: *T) void {
    switch (@typeInfo(T)) {
        // Non-allocating primitives:
        .void, .bool, .float, .int, .error_set, .@"enum" => {},

        // Composite types:
        .pointer => |ptr| {
            switch (ptr.size) {
                .one => {
                    const mut_ptr = @constCast(value.*);
                    recursiveFree(allocator, ptr.child, mut_ptr);
                    allocator.destroy(mut_ptr);
                },
                .slice => {
                    const mut_slice = makeMutableSlice(ptr.child, value.*, ptr.sentinel != null);
                    for (mut_slice) |*item| {
                        recursiveFree(allocator, ptr.child, item);
                    }
                    allocator.free(mut_slice);
                },
                .c => unreachable,
                .many => unreachable,
            }
        },
        .array => |arr| {
            for (&value.*) |*item| {
                recursiveFree(allocator, arr.child, item);
            }
        },
        .@"struct" => |str| {
            // Try to detect a structure like std.HashMapUnmanaged(T).
            if (std.meta.fieldIndex(T, "unmanaged")) |unmanagedField| {
                // Try to deinitialize an unmanaged hash map type from the unmanaged field.
                if (comptime findHashMapEntryType(std.meta.fields(T)[unmanagedField].type) != null) {
                    // Free keys / values.
                    var iterator = value.iterator();
                    while (iterator.next()) |entry| {
                        recursiveFree(allocator, @typeInfo(@TypeOf(entry.key_ptr)).pointer.child, entry.key_ptr);
                        recursiveFree(allocator, @typeInfo(@TypeOf(entry.value_ptr)).pointer.child, entry.value_ptr);
                    }
                    value.deinit();
                    // Deinitialized the map type, nothing more to do.
                    return;
                }
            } else {
                // Try to deinitialize the provided type as an unmanaged hash map type.
                if (comptime findHashMapEntryType(T) != null) {
                    // Free keys / values.
                    var iterator = value.iterator();
                    while (iterator.next()) |entry| {
                        recursiveFree(allocator, @typeInfo(@TypeOf(entry.key_ptr)).pointer.child, entry.key_ptr);
                        recursiveFree(allocator, @typeInfo(@TypeOf(entry.value_ptr)).pointer.child, entry.value_ptr);
                    }
                    value.deinit();
                    // Deinitialized the map type, nothing more to do.
                    return;
                }
            }

            // we can safely ignore the struct layout here as we will serialize the data by field order,
            // instead of memory representation

            inline for (str.fields) |fld| {
                recursiveFree(allocator, fld.type, &@field(value.*, fld.name));
            }
        },
        .optional => |opt| {
            if (value.*) |*item| {
                recursiveFree(allocator, opt.child, item);
            }
        },
        .error_union => |eu| {
            if (value.*) |*item| {
                recursiveFree(allocator, eu.payload, item);
            } else |_| {
                // errors aren't meant to be freed
            }
        },
        .@"union" => |un| {
            const Tag = un.tag_type orelse @compileError("Untagged unions are not supported!");

            const active_tag: Tag = value.*;

            inline for (std.meta.fields(T)) |fld| {
                if (@field(Tag, fld.name) == active_tag) {
                    recursiveFree(allocator, fld.type, &@field(value.*, fld.name));
                    return;
                }
            }
        },
        .vector => |vec| {
            var array: [vec.len]vec.child = value.*;
            for (&array) |*item| {
                recursiveFree(allocator, vec.child, item);
            }
        },

        // Unsupported types:
        .noreturn,
        .type,
        .comptime_float,
        .comptime_int,
        .undefined,
        .null,
        .@"fn",
        .@"opaque",
        .frame,
        .@"anyframe",
        .enum_literal,
        => unreachable,
    }
}

/// Returns `true` if `T` requires allocation to be deserialized.
fn requiresAllocationForDeserialize(comptime T: type, comptime opt: Options) bool {
    if (@typeInfo(T) == .@"struct" and opt.override_fn.len > 0 and (@hasDecl(T, opt.override_fn))) return false;
    switch (@typeInfo(T)) {
        .pointer => return true,
        .@"struct", .@"union" => {
            inline for (comptime std.meta.fields(T)) |fld| {
                if (requiresAllocationForDeserialize(fld.type, opt)) {
                    return true;
                }
            }
            return false;
        },
        .error_union => |eu| return requiresAllocationForDeserialize(eu.payload, opt),
        else => return false,
    }
}

const TypeHashFn = std.hash.Fnv1a_64;

fn intToLittleEndianBytes(val: anytype) [@sizeOf(@TypeOf(val))]u8 {
    const T = @TypeOf(val);
    var res: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(AlignedInt(T), &res, val, .little);
    return res;
}

/// Computes a unique type hash from `T` to identify deserializing invalid data.
/// Incorporates field order and field type, but not field names, so only checks
/// for structural equivalence. Compile errors on unsupported or comptime types.
fn computeTypeHash(comptime T: type) [8]u8 {
    var hasher = TypeHashFn.init();

    computeTypeHashInternal(&hasher, T);

    return intToLittleEndianBytes(hasher.final());
}

fn getSortedErrorNames(comptime T: type) []const []const u8 {
    comptime {
        const error_set = @typeInfo(T).error_set orelse @compileError("Cannot serialize anyerror");

        var sorted_names: [error_set.len][]const u8 = undefined;
        for (error_set, 0..) |err, i| {
            sorted_names[i] = err.name;
        }

        std.mem.sortUnstable([]const u8, &sorted_names, {}, struct {
            fn order(ctx: void, lhs: []const u8, rhs: []const u8) bool {
                _ = ctx;
                return (std.mem.order(u8, lhs, rhs) == .lt);
            }
        }.order);
        return &sorted_names;
    }
}

fn getSortedEnumNames(comptime T: type) []const []const u8 {
    comptime {
        const type_info = @typeInfo(T).@"enum";

        var sorted_names: [type_info.fields.len][]const u8 = undefined;
        for (type_info.fields, 0..) |err, i| {
            sorted_names[i] = err.name;
        }

        std.mem.sortUnstable([]const u8, &sorted_names, {}, struct {
            fn order(ctx: void, lhs: []const u8, rhs: []const u8) bool {
                _ = ctx;
                return (std.mem.order(u8, lhs, rhs) == .lt);
            }
        }.order);
        return &sorted_names;
    }
}

/// Try to compute a map type hash.
/// Return false if the detected type is not a map.
fn computeMapTypeHash(hasher: *TypeHashFn, comptime T: type) bool {
    if (@hasDecl(T, "KV") and
        @hasField(T.KV, "key") and
        @hasField(T.KV, "value")) {
        // We can read the key-value type declaration.
        hasher.update("map");
        hasher.update(@typeName(std.meta.fields(T.KV)[std.meta.fieldIndex(T.KV, "key").?].type));
        hasher.update(@typeName(std.meta.fields(T.KV)[std.meta.fieldIndex(T.KV, "value").?].type));
        return true;
    } else {
        // No key-value type declaration, probably not a map.
        return false;
    }
}

fn computeTypeHashInternal(hasher: *TypeHashFn, comptime T: type) void {
    @setEvalBranchQuota(10_000);
    switch (@typeInfo(T)) {
        // Primitive types:
        .void,
        .bool,
        .float,
        => hasher.update(@typeName(T)),

        .int => {
            if (T == usize) {
                // special case: usize can differ between platforms, this
                // format uses u64 internally.
                hasher.update(@typeName(u64));
            } else {
                hasher.update(@typeName(T));
            }
        },
        .pointer => |ptr| {
            if (ptr.is_volatile) @compileError("Serializing volatile pointers is most likely a mistake.");
            if (ptr.sentinel != null and ptr.child != u8) @compileError("Sentinels other than u8 are not supported yet!");
            switch (ptr.size) {
                .one => {
                    hasher.update("pointer");
                    computeTypeHashInternal(hasher, ptr.child);
                },
                .slice => {
                    hasher.update("slice");
                    if (ptr.sentinel) |_sentinel| {
                        const sentinelHash: *const u8 = @ptrCast(@alignCast(_sentinel));
                        hasher.update(&[_]u8{sentinelHash.*});
                    }
                    computeTypeHashInternal(hasher, ptr.child);
                },
                .c => @compileError("C-pointers are not supported"),
                .many => @compileError("Many-pointers are not supported"),
            }
        },
        .array => |arr| {
            hasher.update(&intToLittleEndianBytes(@as(u64, arr.len)));
            if (arr.sentinel) |_sentinel| {
                const sentinelHash: *const u8 = @ptrCast(@alignCast(_sentinel));
                hasher.update(&[_]u8{sentinelHash.*});
            }
            computeTypeHashInternal(hasher, arr.child);
        },
        .@"struct" => |str| {
            // Try to detect a structure like std.HashMapUnmanaged(T).
            if (std.meta.fieldIndex(T, "unmanaged")) |unmanagedField| {
                // Try to read an unmanaged hash map type from the unmanaged field.
                if (computeMapTypeHash(hasher, std.meta.fields(T)[unmanagedField].type)) {
                    // Parsed the map type, nothing more to do.
                    return;
                }
            } else {
                // Try to read the provided type as an unmanaged hash map type.
                if (computeMapTypeHash(hasher, T)) {
                    // Parsed the map type, nothing more to do.
                    return;
                }
            }

            // we can safely ignore the struct layout here as we will serialize the data by field order,
            // instead of memory representation

            // add some generic marker to the hash so emtpy structs get
            // added as information
            hasher.update("struct");

            for (str.fields) |fld| {
                if (fld.is_comptime) @compileError("comptime fields are not supported.");
                computeTypeHashInternal(hasher, fld.type);
            }
        },
        .optional => |opt| {
            hasher.update("optional");
            computeTypeHashInternal(hasher, opt.child);
        },
        .error_union => |eu| {
            hasher.update("error union");
            computeTypeHashInternal(hasher, eu.error_set);
            computeTypeHashInternal(hasher, eu.payload);
        },
        .error_set => {
            // Error unions are serialized by "index of sorted name", so we
            // hash all names in the right order

            hasher.update("error set");
            const names = comptime getSortedErrorNames(T);
            for (names) |name| {
                hasher.update(name);
            }
        },
        .@"enum" => |list| {
            const Tag = if (list.tag_type == usize)
                u64
            else if (list.tag_type == isize)
                i64
            else
                list.tag_type;
            if (list.is_exhaustive) {
                // Exhaustive enums only allow certain values, so we
                // tag them via the value type
                hasher.update("enum.exhaustive");
                computeTypeHashInternal(hasher, Tag);
                const names = getSortedEnumNames(T);
                inline for (names) |name| {
                    hasher.update(name);
                    hasher.update(&intToLittleEndianBytes(@as(Tag, @intFromEnum(@field(T, name)))));
                }
            } else {
                // Non-exhaustive enums are basically integers. Treat them as such.
                hasher.update("enum.non-exhaustive");
                computeTypeHashInternal(hasher, Tag);
            }
        },
        .@"union" => |un| {
            const tag = un.tag_type orelse @compileError("Untagged unions are not supported!");
            hasher.update("union");
            computeTypeHashInternal(hasher, tag);
            for (un.fields) |fld| {
                computeTypeHashInternal(hasher, fld.type);
            }
        },
        .vector => |vec| {
            hasher.update("vector");
            hasher.update(&intToLittleEndianBytes(@as(u64, vec.len)));
            computeTypeHashInternal(hasher, vec.child);
        },

        // Unsupported types:
        .noreturn,
        .type,
        .comptime_float,
        .comptime_int,
        .undefined,
        .null,
        .@"fn",
        .@"opaque",
        .frame,
        .@"anyframe",
        .enum_literal,
        => @compileError("Unsupported type " ++ @typeName(T)),
    }
}

fn validateTopLevelType(comptime T: type) void {
    switch (@typeInfo(T)) {

        // Unsupported top level types:
        .error_set,
        .error_union,
        => @compileError("Unsupported top level type " ++ @typeName(T) ++ ". Wrap into struct to serialize these."),

        else => {},
    }
}

fn testSameHash(comptime T1: type, comptime T2: type) void {
    const hash_1 = comptime computeTypeHash(T1);
    const hash_2 = comptime computeTypeHash(T2);
    if (comptime !std.mem.eql(u8, hash_1[0..], hash_2[0..]))
        @compileError("The computed hash for " ++ @typeName(T1) ++ " and " ++ @typeName(T2) ++ " does not match.");
}

test "type hasher basics" {
    testSameHash(void, void);
    testSameHash(bool, bool);
    testSameHash(u1, u1);
    testSameHash(u32, u32);
    testSameHash(f32, f32);
    testSameHash(f64, f64);
    testSameHash(@Vector(4, u32), @Vector(4, u32));
    testSameHash(usize, u64);
    testSameHash([]const u8, []const u8);
    testSameHash([]const u8, []u8);
    testSameHash([]const u8, []u8);
    testSameHash([:0]const u8, [:0]u8);
    testSameHash(?*struct { a: f32, b: u16 }, ?*const struct { hello: f32, lol: u16 });
    testSameHash(enum { a, b, c }, enum { a, b, c });
    testSameHash(enum(u8) { a, b, c, _ }, enum(u8) { c, b, a, _ });

    testSameHash(enum(u8) { a, b, c }, enum(u8) { a, b, c });
    testSameHash(enum(u8) { a = 1, b = 6, c = 9 }, enum(u8) { a = 1, b = 6, c = 9 });

    testSameHash(enum(usize) { a, b, c }, enum(u64) { a, b, c });
    testSameHash(enum(isize) { a, b, c }, enum(i64) { a, b, c });
    testSameHash([5]@Vector(4, u32), [5]@Vector(4, u32));

    testSameHash(union(enum) { a: u32, b: f32 }, union(enum) { a: u32, b: f32 });

    testSameHash(error{ Foo, Bar }, error{ Foo, Bar });
    testSameHash(error{ Foo, Bar }, error{ Bar, Foo });
    testSameHash(error{ Foo, Bar }!void, error{ Bar, Foo }!void);
}

fn testSerialize(comptime T: type, value: T) !void {
    var data = std.ArrayList(u8).init(std.testing.allocator);
    defer data.deinit();

    try serialize(data.writer(), T, value, .{});
}

const enable_failing_test = false;

test "serialize basics" {
    try testSerialize(void, {});
    try testSerialize(bool, false);
    try testSerialize(bool, true);
    try testSerialize(u1, 0);
    try testSerialize(u1, 1);
    try testSerialize(u8, 0xFF);
    try testSerialize(u32, 0xDEADBEEF);
    try testSerialize(usize, 0xDEADBEEF);

    try testSerialize(f16, std.math.pi);
    try testSerialize(f32, std.math.pi);
    try testSerialize(f64, std.math.pi);
    try testSerialize(f80, std.math.pi);
    try testSerialize(f128, std.math.pi);

    try testSerialize([3]u8, "hi!".*);
    try testSerialize([]const u8, "Hello, World!");
    try testSerialize(*const [3]u8, "foo");

    try testSerialize([3:0]u8, "hi!".*);
    try testSerialize([:0]const u8, "Hello, World!");
    try testSerialize(*const [3:0]u8, "foo");

    try testSerialize(enum { a, b, c }, .a);
    try testSerialize(enum { a, b, c }, .b);
    try testSerialize(enum { a, b, c }, .c);

    try testSerialize(enum(u8) { a, b, c }, .a);
    try testSerialize(enum(u8) { a, b, c }, .b);
    try testSerialize(enum(u8) { a, b, c }, .c);

    try testSerialize(enum(isize) { a, b, c }, .a);
    try testSerialize(enum(isize) { a, b, c }, .b);
    try testSerialize(enum(isize) { a, b, c }, .c);

    try testSerialize(enum(usize) { a, b, c }, .a);
    try testSerialize(enum(usize) { a, b, c }, .b);
    try testSerialize(enum(usize) { a, b, c }, .c);

    const TestEnum = enum(u8) { a, b, c, _ };
    try testSerialize(TestEnum, .a);
    try testSerialize(TestEnum, .b);
    try testSerialize(TestEnum, .c);
    try testSerialize(TestEnum, @as(TestEnum, @enumFromInt(0xB1)));

    if (enable_failing_test) {
        try testSerialize(struct { val: error{ Foo, Bar } }, .{ .val = error.Foo });
        try testSerialize(struct { val: error{ Bar, Foo } }, .{ .val = error.Bar });
        try testSerialize(struct { val: error{ Bar, Foo }!u32 }, .{ .val = error.Bar });
        try testSerialize(struct { val: error{ Bar, Foo }!u32 }, .{ .val = 0xFF });
    }
    try testSerialize(union(enum) { a: f32, b: u32 }, .{ .a = 1.5 });
    try testSerialize(union(enum) { a: f32, b: u32 }, .{ .b = 2.0 });

    try testSerialize(?u32, null);
    try testSerialize(?u32, 143);

    // Make a string hash map and try to serialize it.
    var strMap = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer strMap.deinit();
    try strMap.put("mykey", "any value");
    try strMap.put("another key", "foo bar baz");
    try testSerialize(std.StringHashMap([]const u8), strMap);
}

fn serDesAlloc(comptime T: type, value: T) !T {
    var data = std.ArrayList(u8).init(std.testing.allocator);
    defer data.deinit();

    try serialize(data.writer(), T, value, .{});

    var stream = std.io.fixedBufferStream(data.items);

    return try deserializeAlloc(stream.reader(), T, std.testing.allocator);
}

fn testSerDesAlloc(comptime T: type, value: T) !void {
    var data: std.ArrayList(u8) = .init(std.testing.allocator);
    defer data.deinit();

    try serialize(data.writer(), T, value, .{});

    var stream = std.io.fixedBufferStream(data.items);

    var deserialized = try deserializeAlloc(stream.reader(), T, std.testing.allocator);
    defer free(std.testing.allocator, T, &deserialized);

    try std.testing.expectEqual(value, deserialized);
}

fn testSerDesPtrContentEquality(comptime T: type, value: T) !void {
    var data = std.ArrayList(u8).init(std.testing.allocator);
    defer data.deinit();

    try serialize(data.writer(), T, value, .{});

    var stream = std.io.fixedBufferStream(data.items);

    var deserialized = try deserializeAlloc(stream.reader(), T, std.testing.allocator);
    defer free(std.testing.allocator, T, &deserialized);

    try std.testing.expectEqual(value.*, deserialized.*);
}

fn testSerDesSliceContentEquality(comptime T: type, value: T) !void {
    var data = std.ArrayList(u8).init(std.testing.allocator);
    defer data.deinit();

    try serialize(data.writer(), T, value, .{});

    var stream = std.io.fixedBufferStream(data.items);

    var deserialized = try deserializeAlloc(stream.reader(), T, std.testing.allocator);
    defer free(std.testing.allocator, T, &deserialized);

    try std.testing.expectEqualSlices(std.meta.Child(T), value, deserialized);
}

test "ser/des" {
    try testSerDesAlloc(void, {});
    try testSerDesAlloc(bool, false);
    try testSerDesAlloc(bool, true);
    try testSerDesAlloc(u1, 0);
    try testSerDesAlloc(u1, 1);
    try testSerDesAlloc(u8, 0xFF);
    try testSerDesAlloc(u32, 0xDEADBEEF);
    try testSerDesAlloc(usize, 0xDEADBEEF);

    try testSerDesAlloc(f16, std.math.pi);
    try testSerDesAlloc(f32, std.math.pi);
    try testSerDesAlloc(f64, std.math.pi);
    try testSerDesAlloc(f80, std.math.pi);
    try testSerDesAlloc(f128, std.math.pi);

    try testSerDesAlloc([3]u8, "hi!".*);
    try testSerDesSliceContentEquality([]const u8, "Hello, World!");
    try testSerDesPtrContentEquality(*const [3]u8, "foo");

    try testSerDesAlloc([3:0]u8, "hi!".*);
    try testSerDesSliceContentEquality([:0]const u8, "Hello, World!");
    try testSerDesPtrContentEquality(*const [3:0]u8, "foo");

    try testSerDesAlloc(enum { a, b, c }, .a);
    try testSerDesAlloc(enum { a, b, c }, .b);
    try testSerDesAlloc(enum { a, b, c }, .c);

    try testSerDesAlloc(enum(u8) { a, b, c }, .a);
    try testSerDesAlloc(enum(u8) { a, b, c }, .b);
    try testSerDesAlloc(enum(u8) { a, b, c }, .c);

    try testSerDesAlloc(enum(usize) { a, b, c }, .a);
    try testSerDesAlloc(enum(usize) { a, b, c }, .b);
    try testSerDesAlloc(enum(usize) { a, b, c }, .c);

    try testSerDesAlloc(enum(isize) { a, b, c }, .a);
    try testSerDesAlloc(enum(isize) { a, b, c }, .b);
    try testSerDesAlloc(enum(isize) { a, b, c }, .c);

    const TestEnum = enum(u8) { a, b, c, _ };
    try testSerDesAlloc(TestEnum, .a);
    try testSerDesAlloc(TestEnum, .b);
    try testSerDesAlloc(TestEnum, .c);
    try testSerDesAlloc(TestEnum, @as(TestEnum, @enumFromInt(0xB1)));

    if (enable_failing_test) {
        try testSerDesAlloc(struct { val: error{ Foo, Bar } }, .{ .val = error.Foo });
        try testSerDesAlloc(struct { val: error{ Bar, Foo } }, .{ .val = error.Bar });
        try testSerDesAlloc(struct { val: error{ Bar, Foo }!u32 }, .{ .val = error.Bar });
        try testSerDesAlloc(struct { val: error{ Bar, Foo }!u32 }, .{ .val = 0xFF });
    }

    try testSerDesAlloc(union(enum) { a: f32, b: u32 }, .{ .a = 1.5 });
    try testSerDesAlloc(union(enum) { a: f32, b: u32 }, .{ .b = 2.0 });

    try testSerDesAlloc(?u32, null);
    try testSerDesAlloc(?u32, 143);


    // Make a string hash map and try to serialize and deserialize it.
    var strMap = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer strMap.deinit();
    try strMap.put("mykey", "any value");
    try strMap.put("another key", "foo bar baz");
    
    // Get the deserialized string hash map.
    var deserializedStrMap = try serDesAlloc(std.StringHashMap([]const u8), strMap);
    defer free(std.testing.allocator, std.StringHashMap([]const u8), &deserializedStrMap);

    // Checking that the string hash map has been deserialized successfully.
    try std.testing.expectEqualStrings("any value", deserializedStrMap.get("mykey").?);
    try std.testing.expectEqualStrings("foo bar baz", deserializedStrMap.get("another key").?);
}
