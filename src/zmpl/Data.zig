/// Generic, JSON-compatible data type that can store a tree of values. The root value must be
/// `Object` or `Array`, which can contain any of:
/// `Object`, `Array`, 'NullType`, `String`, `Float`, `Integer`, `Boolean`.
///
/// Initialize a new `Data` instance and initialize its root object with the first call to
/// `array()` or `object()`.
///
/// Insert new values into the root object with either `append(value)` or `put(value)` depending
/// on the root value type. All inserted values must be of type `Data.Value`. Use the provided
/// member functions `object()`, `array()`, `string()`, `float()`, `integer()`, `boolean()` to
/// generate these values.
///
/// ```
/// var data = Data.init(allocator);
/// var root = try data.object(); // First call to `object()` or `array()` sets root value type.
/// try root.put("foo", data.string("a string"));
/// try root.put("bar", data.float(123.45));
/// try root.put("baz", data.integer(123));
/// try root.put("qux", data.boolean(true));
///
/// var object = data.object(); // Second call creates a new object without modifying root value.
/// var array = data.array(); // Since `data.object()` was called above, also creates a new array.
///
/// try object.put("nested_object", object);
/// try object.put("nested_array", array);
///
/// try array.append(data.string("value"));
/// try object.put("key", data.string("value"));
/// ```
///
/// `data.toJson()` returns a `[]const u8` with the full value tree converted to a JSON string.
/// `data.value` is a `Data.Value` generic which can be used with `switch` to walk through the
/// data tree (for Zmpl templates, use the `{.nested_object.key}` syntax to do this
/// automatically.
const std = @import("std");

const manifest = @import("zmpl.manifest").__Manifest;
const zmpl = @import("../zmpl.zig");
const util = zmpl.util;

const zmd = @import("zmd");

/// Output stream for writing values into a rendered template.
pub const Writer = std.ArrayList(u8).Writer;

const Data = @This();

pub const LayoutContent = struct {
    data: []const u8,

    pub fn format(self: LayoutContent, actual_fmt: []const u8, options: anytype, writer: anytype) !void {
        _ = options;
        _ = actual_fmt;
        try writer.writeAll(self.data);
    }
};

parent_allocator: std.mem.Allocator,
arena: ?std.heap.ArenaAllocator = null,
arena_allocator: std.mem.Allocator = undefined,
json_buf: std.ArrayList(u8),
output_buf: std.ArrayList(u8),
output_writer: ?std.ArrayList(u8).Writer = null,
value: ?*Value = null,
partial: bool = false,
content: LayoutContent = .{ .data = "" },
partial_data: ?*Object = null,
template_decls: std.StringHashMap(*Value),
slots: ?[]const String = null,

const indent = "  ";

/// Creates a new `Data` instance which can then be used to store any tree of `Value`.
pub fn init(parent_allocator: std.mem.Allocator) Data {
    const json_buf = std.ArrayList(u8).init(parent_allocator);
    const output_buf = std.ArrayList(u8).init(parent_allocator);

    return .{
        .parent_allocator = parent_allocator,
        .json_buf = json_buf,
        .output_buf = output_buf,
        .template_decls = std.StringHashMap(*Value).init(parent_allocator),
    };
}

/// Frees all resources used by this `Data` instance.
pub fn deinit(self: *Data) void {
    if (self.arena) |arena| arena.deinit();
    self.output_buf.deinit();
    self.json_buf.deinit();
}

/// Chomps output buffer. Used for partials to allow user to add an explicit blank line at the
/// end of a template if needed, otherwise `<div>{^partial_name}</div>` should not output a
/// newline.
pub fn chompOutputBuffer(self: *Data) void {
    if (std.mem.endsWith(u8, self.output_buf.items, "\r\n")) {
        _ = self.output_buf.pop();
        _ = self.output_buf.pop();
    } else if (std.mem.endsWith(u8, self.output_buf.items, "\n")) {
        _ = self.output_buf.pop();
    }
}

/// Convenience wrapper for `util.strip` to be used by compiled templates.
pub fn strip(self: *Data, input: []const u8) []const u8 {
    _ = self;
    return util.strip(input);
}

/// Convenience wrapper for `util.chomp` to be used by compiled templates.
pub fn chomp(self: *Data, input: []const u8) []const u8 {
    _ = self;
    return util.chomp(input);
}

const MarkdownFragmentType = enum { link };
const MarkdownNode = struct {
    content: ?[]const u8,
    href: ?[]const u8,
    title: ?[]const u8,
    meta: ?[]const u8,
};

/// Evaluate equality of two Data trees, recursively comparing all values.
pub fn eql(self: *const Data, other: *const Data) bool {
    if (self.value != null and other.value != null) {
        return self.value.?.eql(other.value.?);
    } else if (self.value == null and other.value == null) {
        return true;
    } else return false;
}

/// Takes a string such as `.foo.bar.baz` and translates into a path into the data tree to return
/// a value that can be rendered in a template.
pub fn getValue(self: Data, key: []const u8) !?*Value {
    // Partial data always takes precedence over underlying template data.
    if (self.partial_data) |val| {
        if (val.get(key)) |partial_value| return partial_value;
    }

    if (self.value) |val| {
        var tokens = std.mem.splitSequence(u8, key, ".");
        var current_value = val;

        while (tokens.next()) |token| {
            switch (current_value.*) {
                .object => |*capture| {
                    var capt = capture.*;
                    current_value = capt.get(token) orelse return null;
                },
                .array => |*capture| {
                    var capt = capture.*;
                    const index = std.fmt.parseInt(usize, token, 10) catch |err| {
                        switch (err) {
                            error.InvalidCharacter => return null,
                            else => return err,
                        }
                    };
                    current_value = capt.get(index) orelse return null;
                },
                else => |*capture| {
                    return capture;
                },
            }
        }
        return current_value;
    } else return null;
}

/// Converts any `Value` in a root `Object` to a string. Returns an empty string if no match or
/// no compatible data type.
pub fn getValueString(self: Data, key: []const u8) ![]const u8 {
    if (try self.getValue(key)) |val| {
        switch (val.*) {
            .object, .array => return "", // No sense in trying to convert an object/array to a string
            else => |*capture| {
                var v = capture.*;
                return try v.toString();
            },
        }
    } else {
        std.debug.print("[zmpl] Unknown data reference: `{s}`\n", .{key});
        return error.ZmplUnknownDataReferenceError;
    }
}

const Item = struct {
    key: []const u8,
    value: *Value,
};

const IteratorSelector = enum { array, object };

pub fn items(self: *Data, comptime selector: IteratorSelector) []switch (selector) {
    .array => *Value,
    .object => Item,
} {
    const value = self.value orelse return &.{};
    return value.items(selector);
}

/// Attempt a given value to a string. If `.toString()` is implemented (i.e. likely a `Value`),
/// call that, otherwise try to use an appropriate formatter.
pub fn coerceString(self: *Data, value: anytype) ![]const u8 {
    const Formatter = enum {
        default,
        optional_default,
        string,
        optional_string,
        string_array,
        float,
        zmpl,
        zmpl_union,
        none,
    };

    const formatter: Formatter = switch (@typeInfo(@TypeOf(value))) {
        .Bool => .default,
        .Int => .default,
        .Float => .float,
        .Struct => switch (@TypeOf(value)) {
            Value, String, Integer, Float, Boolean, NullType => .zmpl,
            inline else => blk: {
                if (@hasDecl(@TypeOf(value), "format")) {
                    break :blk .default;
                } else {
                    std.debug.print("[zmpl] Error: Struct does not implement `format()`: {}\n", .{@TypeOf(value)});
                    return error.ZmplSyntaxError;
                }
            },
        },
        .ComptimeFloat => .float,
        .ComptimeInt => .default,
        .Null => .none,
        .Optional => if (@TypeOf(value) == ?[]const u8) .optional_string else .optional_default,
        .Union => |Union| blk: {
            break :blk switch (Union) {
                inline else => |capture| if (@hasField(@TypeOf(capture), "toString")) .zmpl_union else .default,
            };
        },
        .Pointer => |pointer| switch (pointer.child) {
            Value, String, Integer, Float, Boolean, NullType => .zmpl,
            []const u8 => |child| blk: {
                if (isStringCoercablePointer(pointer, child, []const u8)) {
                    break :blk .string_array;
                } else {
                    std.debug.print("[zmpl] Error: Unsupported type: {}\n", .{pointer});
                    return error.ZmplSyntaxError;
                }
            },
            u8 => |child| blk: {
                if (isStringCoercablePointer(pointer, child, u8)) {
                    break :blk .string;
                } else {
                    std.debug.print("[zmpl] Error: Unsupported type: {}\n", .{pointer});
                    return error.ZmplSyntaxError;
                }
            },
            []u8 => .string,
            type => blk: {
                if (@hasDecl(@TypeOf(value.*), "format")) {
                    break :blk .default;
                } else {
                    std.debug.print("[zmpl] Error: Struct does not implement `format()`: {}\n", .{@TypeOf(value.*)});
                    return error.ZmplSyntaxError;
                }
            },
            inline else => blk: {
                const child = @typeInfo(pointer.child);
                if (child == .Array) {
                    const arr = &child.Array;
                    if (arr.child == u8) break :blk .string;
                }
                std.debug.print("Unsupported type: {}\n", .{pointer});
                return error.ZmplSyntaxError;
            },
        },

        // This must be consistent with `std.builtin.Type` - we want to see an error if a new
        // field is added so we specifically do not want an `else` clause here:
        .Type,
        .Void,
        .NoReturn,
        .Array,
        .Undefined,
        .ErrorUnion,
        .ErrorSet,
        .Enum,
        .Fn,
        .Opaque,
        .Frame,
        .AnyFrame,
        .Vector,
        .EnumLiteral,
        => |Type| {
            std.debug.print("Unsupported type: {}\n", .{Type});
            return error.ZmplSyntaxError;
        },
    };

    const arena = self.allocator();

    return switch (formatter) {
        .default => try std.fmt.allocPrint(arena, "{}", .{value}),
        .optional_default => try std.fmt.allocPrint(arena, "{?}", .{value}),
        .string => try std.fmt.allocPrint(arena, "{s}", .{value}),
        .optional_string => try std.fmt.allocPrint(arena, "{?s}", .{value}),
        .string_array => try std.mem.join(arena, "\n", value),
        .float => try std.fmt.allocPrint(arena, "{d}", .{value}),
        .zmpl => try value.toString(),
        .zmpl_union => switch (value) {
            inline else => |capture| try capture.toString(),
        },
        .none => "",
    };
}

/// Add a const value. Must be called for **all** constants defined at build time before
/// rendering a template.
pub fn addConst(self: *Data, name: []const u8, value: *Value) !void {
    try self.template_decls.put(name, value);
}

/// Retrieves a typed value from template decls. Errors if value is not found, i.e. all expected
/// values **must** be assigned before rendering a template.
pub fn getConst(self: *Data, T: type, name: []const u8) !T {
    if (self.template_decls.get(name)) |value| {
        return switch (T) {
            i128 => value.integer.value,
            f128 => value.float.value,
            []const u8 => value.string.value,
            bool => value.boolean.value,
            else => @compileError("Unsupported constant type: " ++ @typeName(T)),
        };
    } else {
        std.debug.print("[zmpl] Undefined constant: `{s}` - must call `Data.addConst(...)` before rendering.\n", .{name});
        return error.ZmplMissingConstant;
    }
}

/// Coerce a data reference to the given type.
/// If a partial argument is a data reference (as opposed to a local constant/literal/etc.),
/// attempt to coerce it to the expected argument type.
pub fn getCoerce(self: Data, T: type, name: []const u8) !T {
    return switch (T) {
        []const u8 => self.getT(.string, name) orelse error.ZmplUnknownDataReferenceError,
        u1,
        u2,
        u4,
        u8,
        u16,
        u32,
        u64,
        u128,
        i1,
        i2,
        i4,
        i8,
        i16,
        i32,
        i64,
        i128,
        => if (self.getT(.integer, name)) |value|
            @as(T, @intCast(value))
        else
            error.ZmplUnknownDataReferenceError,
        f16, f32, f64, f128 => if (self.getT(.float, name)) |value|
            @as(T, @floatCast(value))
        else
            error.ZmplUnknownDataReferenceError,
        bool => self.getT(.boolean, name) orelse error.ZmplUnknownDataReferenceError,
        *Value => try self._get(name),
        else => @compileError("Unsupported type for data lookup in partial args: " ++ @typeName(T)),
    };
}

/// Resets the current `Data` object, allowing it to be re-initialized with a new root value.
pub fn reset(self: *Data) void {
    if (self.value) |*ptr| {
        ptr.*.deinit();
    }
    self.output_buf.clearAndFree();
    self.json_buf.clearAndFree();
    self.value = null;
}

/// No-op function. Used by templates to prevent unused local constant errors for values that
/// might not be used by the template (e.g. allocator, `addConst()` values).
pub fn noop(self: Data, T: type, value: T) void {
    _ = self;
    _ = value;
}

/// Set or retrieve the root value. Must be `array` or `object`. Raise an error if root value
/// already present and not matching requested value type.
pub fn root(self: *Data, root_type: enum { object, array }) !*Value {
    if (self.value) |value| {
        switch (value.*) {
            .object => if (root_type != .object) return error.ZmplIncompatibleRootObject,
            .array => if (root_type != .array) return error.ZmplIncompatibleRootObject,
            else => unreachable,
        }

        return value;
    } else {
        self.value = switch (root_type) {
            .object => try self.createObject(),
            .array => try self.createArray(),
        };
        return self.value.?;
    }
}

/// Creates a new `Object`. The first call to `array()` or `object()` sets the root value.
/// Subsequent calls create a new `Object` without setting the root value. e.g.:
///
/// var data = Data.init(allocator);
/// var object = try data.object(); // <-- the root value is now an object.
/// try nested_object = try data.object(); // <-- creates a new, detached object.
/// try object.put("nested", nested_object); // <-- adds a nested object to the root object.
pub fn object(self: *Data) !*Value {
    if (self.value) |_| {
        return try self.createObject();
    } else {
        self.value = try self.createObject();
        return self.value.?;
    }
}

pub fn createObject(self: *Data) !*Value {
    const obj = Object.init(self.allocator());
    const ptr = try self.allocator().create(Value);
    ptr.* = Value{ .object = obj };
    return ptr;
}

/// Creates a new `Array`. The first call to `array()` or `object()` sets the root value.
/// Subsequent calls create a new `Array` without setting the root value. e.g.:
///
/// var data = Data.init(allocator);
/// var array = try data.array(); // <-- the root value is now an array.
/// try nested_array = try data.array(); // <-- creates a new, detached array.
/// try array.append(nested_array); // <-- adds a nested array to the root array.
pub fn array(self: *Data) !*Value {
    if (self.value) |_| {
        return try self.createArray();
    } else {
        self.value = try self.createArray();
        return self.value.?;
    }
}

/// Creates a new `Array`. For most use cases, use `array()` instead.
pub fn createArray(self: *Data) !*Value {
    const arr = Array.init(self.allocator());
    const ptr = try self.allocator().create(Value);
    ptr.* = Value{ .array = arr };
    return ptr;
}

/// Creates a new `Value` representing a string (e.g. `"foobar"`).
pub fn string(self: *Data, value: []const u8) *Value {
    const arena = self.allocator();
    const duped = arena.dupe(u8, value) catch @panic("Out of memory");
    const val = arena.create(Value) catch @panic("Out of memory");
    val.* = .{ .string = .{ .value = duped, .allocator = arena } };
    return val;
}

/// Creates a new `Value` representing an integer (e.g. `1234`).
pub fn integer(self: *Data, value: i128) *Value {
    const arena = self.allocator();
    const val = arena.create(Value) catch @panic("Out of memory");
    val.* = .{ .integer = .{ .value = value, .allocator = arena } };
    return val;
}

/// Creates a new `Value` representing a float (e.g. `1.234`).
pub fn float(self: *Data, value: f128) *Value {
    const arena = self.allocator();
    const val = arena.create(Value) catch @panic("Out of memory");
    val.* = .{ .float = .{ .value = value, .allocator = arena } };
    return val;
}

/// Creates a new `Value` representing a boolean (true/false).
pub fn boolean(self: *Data, value: bool) *Value {
    const arena = self.allocator();
    const val = arena.create(Value) catch @panic("Out of memory");
    val.* = .{ .boolean = .{ .value = value, .allocator = arena } };
    return val;
}

/// Create a new `Value` representing a `null` value. Public, but for internal use only.
pub fn _null(arena: std.mem.Allocator) *Value {
    const val = arena.create(Value) catch @panic("Out of memory");
    val.* = .{ .Null = NullType{ .allocator = arena } };
    return val;
}

/// Write a given string to the output buffer. Creates a new output buffer if not already
/// present. Used by compiled Zmpl templates.
pub fn write(self: *Data, slice: []const u8) !void {
    if (self.output_writer) |writer| {
        try writer.writeAll(slice);
    } else {
        self.output_writer = self.output_buf.writer();
        try (self.output_writer.?).writeAll(util.chomp(slice));
    }
}

/// Get a value from the data tree using an exact key. Returns `null` if key not found or if
/// root object is not `Object`.
pub fn get(self: Data, key: []const u8) ?*Value {
    if (self.value == null) return null;

    return switch (self.value.?.*) {
        .object => |value| value.get(key),
        else => null,
    };
}

/// Get a typed value from the data tree using an exact key. Returns `null` if key not found or
/// if root object is not `Object`. Use this function to resolve the underlying value in a Value.
/// (e.g. `.string` returns `[]const u8`).
pub fn getT(self: *const Data, comptime T: ValueType, key: []const u8) ?switch (T) {
    .object => *Object,
    .array => []*const Value,
    .string => []const u8,
    .float => f128,
    .integer => i128,
    .boolean => bool,
    .Null => null,
} {
    if (self.value == null) return null;

    return switch (self.value.?.*) {
        .object => |value| value.getT(T, key),
        else => null,
    };
}

/// Receives an array of keys and recursively gets each key from nested objects, returning `null`
/// if a key is not found, or `*Value` if all keys are found.
pub fn chain(self: *Data, keys: []const []const u8) ?*Value {
    if (self.value == null) return null;

    return self.value.?.chain(keys);
}

/// Gets a value from the data tree using reference lookup syntax (e.g. `.foo.bar.baz`).
/// Used internally by templates.
pub fn _get(self: Data, key: []const u8) !*Value {
    return if (try self.getValue(key)) |value|
        value
    else
        error.ZmplUnknownDataReferenceError;
}

/// Returns the entire `Data` tree as a JSON string.
pub fn toJson(self: *Data) ![]const u8 {
    if (self.value) |_| {} else return "";

    const writer = self.json_buf.writer();
    self.json_buf.clearAndFree();
    try self.value.?._toJson(writer, false, 0);
    return self.allocator().dupe(u8, self.json_buf.items[0..self.json_buf.items.len]);
}

/// Returns the entire `Data` tree as a pretty-printed JSON string.
pub fn toPrettyJson(self: *Data) ![]const u8 {
    if (self.value) |_| {} else return "";

    const writer = self.json_buf.writer();
    self.json_buf.clearAndFree();
    try self.value.?._toJson(writer, true, 0);
    try writer.writeByte('\n');
    return self.allocator().dupe(u8, self.json_buf.items[0..self.json_buf.items.len]);
}

/// Parses a JSON string and updates the current `Data` object with the parsed data. Inverse of
/// `toJson`.
pub fn fromJson(self: *Data, json: []const u8) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator(), json, .{});
    self.value = try self.parseJsonValue(parsed.value);
}

fn parseJsonValue(self: *Data, value: std.json.Value) !*Value {
    return switch (value) {
        .object => |*val| blk: {
            var it = val.iterator();
            const obj = try self.createObject();
            while (it.next()) |item| {
                try obj.put(item.key_ptr.*, try self.parseJsonValue(item.value_ptr.*));
            }
            break :blk obj;
        },
        .array => |*val| blk: {
            var arr = try self.array();
            for (val.items) |item| try arr.append(try self.parseJsonValue(item));
            break :blk arr;
        },
        .string => |val| self.string(val),
        .number_string => |val| if (std.mem.containsAtLeast(u8, val, 1, "."))
            self.float(try std.fmt.parseFloat(f128, val))
        else
            self.integer(try std.fmt.parseInt(i128, val, 10)),
        .integer => |val| self.integer(val),
        .float => |val| self.float(val),
        .bool => |val| self.boolean(val),
        .null => _null(self.allocator()),
    };
}

pub const ValueType = enum {
    object,
    array,
    float,
    integer,
    boolean,
    string,
    Null,
};

/// A generic type representing any supported type. All types are JSON-compatible and can be
/// serialized and deserialized losslessly.
pub const Value = union(ValueType) {
    object: Object,
    array: Array,
    float: Float,
    integer: Integer,
    boolean: Boolean,
    string: String,
    Null: NullType,

    /// Compares one `Value` to another `Value` recursively. Order of `Object` keys is ignored.
    pub fn eql(self: *const Value, other: *const Value) bool {
        switch (self.*) {
            .object => |*capture| switch (other.*) {
                .object => |*other_capture| return capture.eql(other_capture),
                inline else => return false,
            },
            .array => |*capture| switch (other.*) {
                .array => |*other_capture| return capture.eql(other_capture),
                inline else => return false,
            },
            .string => |*capture| switch (other.*) {
                .string => |*other_capture| return capture.eql(other_capture),
                inline else => return false,
            },
            .integer => |*capture| switch (other.*) {
                .integer => |*other_capture| return capture.eql(other_capture),
                inline else => return false,
            },
            .float => |*capture| switch (other.*) {
                .float => |*other_capture| return capture.eql(other_capture),
                inline else => return false,
            },
            .boolean => |*capture| switch (other.*) {
                .boolean => |*other_capture| return capture.eql(other_capture),
                inline else => return false,
            },
            .Null => |*capture| switch (other.*) {
                .Null => |*other_capture| return capture.eql(other_capture),
                inline else => return false,
            },
        }
    }

    /// Gets a `Value` from an `Object`.
    pub fn get(self: *const Value, key: []const u8) ?*Value {
        switch (self.*) {
            .object => |*capture| return capture.get(key),
            inline else => unreachable,
        }
    }

    /// Get a typed value from the data tree using an exact key. Returns `null` if key not found or
    /// if root object is not `Object`. Use this function to resolve the underlying value in a Value.
    /// (e.g. `.string` returns `[]const u8`).
    pub fn getT(self: *const Value, comptime T: ValueType, key: []const u8) ?switch (T) {
        .object => *Object,
        .array => *Array,
        .string => []const u8,
        .float => f128,
        .integer => i128,
        .boolean => bool,
        .Null => null,
    } {
        return switch (self.*) {
            .object => |value| value.getT(T, key),
            else => null,
        };
    }

    /// Receives an array of keys and recursively gets each key from nested objects, returning `null`
    /// if a key is not found, or `*Value` if all keys are found.
    pub fn chain(self: *const Value, keys: []const []const u8) ?*Value {
        return switch (self.*) {
            .object => |*capture| capture.chain(keys),
            else => null,
        };
    }

    /// Puts a `Value` into an `Object`.
    pub fn put(self: *Value, key: []const u8, value: ?*Value) !void {
        switch (self.*) {
            .object => |*capture| try capture.put(key, value orelse _null(capture.allocator)),
            inline else => unreachable,
        }
    }

    /// Appends a `Value` to an `Array`.
    pub fn append(self: *Value, value: ?*Value) !void {
        switch (self.*) {
            .array => |*capture| try capture.append(value orelse _null(capture.allocator)),
            inline else => unreachable,
        }
    }

    pub fn toJson(self: *const Value) ![]const u8 {
        const arena = switch (self.*) {
            inline else => |capture| capture.allocator,
        };
        var buf = std.ArrayList(u8).init(arena);
        const writer = buf.writer();
        try self._toJson(writer, false, 0);
        return try buf.toOwnedSlice();
    }

    /// Generates a JSON string representing the complete data tree.
    pub fn _toJson(self: *const Value, writer: Writer, pretty: bool, level: usize) !void {
        return switch (self.*) {
            .array => |*capture| try capture.toJson(writer, pretty, level),
            .object => |*capture| try capture.toJson(writer, pretty, level),
            inline else => |*capture| try capture.toJson(writer),
        };
    }

    pub fn clone(self: *const Value, gpa: std.mem.Allocator) !*Value {
        const json = try self.toJson();
        const arena = switch (self.*) {
            inline else => |capture| capture.allocator,
        };
        defer arena.free(json);
        var data = Data.init(gpa);
        try data.fromJson(json);
        return data.value.?;
    }

    pub fn format(self: *Value, actual_fmt: []const u8, options: anytype, writer: anytype) !void {
        _ = options;
        _ = actual_fmt;
        try writer.writeAll(try self.toString());
    }

    /// Converts a primitive type (string, integer, float) to a string representation.
    pub fn toString(self: *Value) ![]const u8 {
        return switch (self.*) {
            .object, .array => unreachable,
            inline else => |*capture| try capture.toString(),
        };
    }

    /// Return the number of items in an array or an object.
    pub fn count(self: *Value) usize {
        switch (self.*) {
            .array => |capture| return capture.count(),
            .object => |capture| return capture.count(),
            else => unreachable,
        }
    }

    pub fn iterator(self: *Value) *Iterator {
        switch (self.*) {
            .array => |*capture| return capture.*.iterator(),
            .object => unreachable, // TODO
            else => unreachable,
        }
    }

    pub fn items(self: *Value, comptime selector: IteratorSelector) []switch (selector) {
        .array => *Value,
        .object => Item,
    } {
        return switch (selector) {
            .array => blk: {
                switch (self.*) {
                    .array => |capture| break :blk capture.array.items,
                    else => return &.{},
                }
            },
            .object => blk: {
                switch (self.*) {
                    .object => |capture| {
                        var it = capture.hashmap.iterator();
                        var items_array = std.ArrayList(Item).init(capture.allocator);
                        while (it.next()) |item| {
                            items_array.append(
                                .{ .key = item.key_ptr.*, .value = item.value_ptr.* },
                            ) catch @panic("OOM");
                        }
                        break :blk items_array.items;
                    },
                    else => return &.{},
                }
            },
        };
    }

    pub fn deinit(self: *Value) void {
        switch (self.*) {
            .array => |*ptr| ptr.deinit(),
            .object => |*ptr| ptr.deinit(),
            else => {},
        }
    }
};

pub const NullType = struct {
    allocator: std.mem.Allocator,

    pub fn toJson(self: NullType, writer: Writer) !void {
        _ = self;
        try writer.writeAll("null");
    }

    pub fn eql(self: *const NullType, other: *const NullType) bool {
        _ = other;
        _ = self;
        return true;
    }

    pub fn toString(self: NullType) ![]const u8 {
        _ = self;
        return "";
    }
};

pub const Float = struct {
    value: f128,
    allocator: std.mem.Allocator,

    pub fn eql(self: *const Float, other: *const Float) bool {
        return self.value == other.value;
    }

    pub fn toJson(self: Float, writer: Writer) !void {
        try writer.print("{d}", .{self.value});
    }

    pub fn toString(self: Float) ![]const u8 {
        return std.fmt.allocPrint(self.allocator, "{d}", .{self.value});
    }
};

pub const Integer = struct {
    value: i128,
    allocator: std.mem.Allocator,

    pub fn eql(self: *const Integer, other: *const Integer) bool {
        return self.value == other.value;
    }

    pub fn toJson(self: Integer, writer: Writer) !void {
        try writer.print("{}", .{self.value});
    }

    pub fn toString(self: Integer) ![]const u8 {
        return std.fmt.allocPrint(self.allocator, "{}", .{self.value});
    }
};

pub const Boolean = struct {
    value: bool,
    allocator: std.mem.Allocator,

    pub fn eql(self: *const Boolean, other: *const Boolean) bool {
        return self.value == other.value;
    }

    pub fn toJson(self: Boolean, writer: Writer) !void {
        try writer.writeAll(if (self.value) "true" else "false");
    }

    pub fn toString(self: Boolean) ![]const u8 {
        return std.fmt.allocPrint(self.allocator, "{}", .{self.value});
    }
};

pub const String = struct {
    value: []const u8,
    allocator: std.mem.Allocator,

    pub fn eql(self: *const String, other: *const String) bool {
        return std.mem.eql(u8, self.value, other.value);
    }

    pub fn toJson(self: String, writer: Writer) !void {
        try std.json.encodeJsonString(self.value, .{}, writer);
    }

    pub fn toString(self: String) ![]const u8 {
        return self.value;
    }
};

pub const Object = struct {
    hashmap: std.StringHashMap(*Value),
    allocator: std.mem.Allocator,

    pub fn init(arena: std.mem.Allocator) Object {
        return .{ .hashmap = std.StringHashMap(*Value).init(arena), .allocator = arena };
    }

    pub fn deinit(self: *Object) void {
        var it = self.hashmap.iterator();
        while (it.next()) |entry| {
            self.allocator.destroy(entry.key_ptr);
            self.allocator.destroy(entry.value_ptr);
        }
        self.hashmap.clearAndFree();
    }

    /// Recursively compares equality of keypairs with another `Object`.
    pub fn eql(self: *const Object, other: *const Object) bool {
        if (self.count() != other.count()) return false;
        var it = self.hashmap.iterator();
        while (it.next()) |item| {
            const other_value = other.get(item.key_ptr.*);
            if (other_value) |capture| {
                if (!item.value_ptr.*.eql(capture)) return false;
            }
        }

        return true;
    }

    pub fn put(self: *Object, key: []const u8, value: ?*Value) !void {
        const key_dupe = try self.allocator.dupe(u8, key);
        if (value) |capture| {
            switch (capture.*) {
                inline else => try self.hashmap.put(key_dupe, capture),
            }
        } else {
            try self.hashmap.put(key_dupe, _null(self.allocator));
        }
    }

    pub fn get(self: Object, key: []const u8) ?*Value {
        if (self.hashmap.getEntry(key)) |entry| {
            return entry.value_ptr.*;
        } else return null;
    }

    pub fn getT(self: Object, comptime T: ValueType, key: []const u8) ?switch (T) {
        .object => *Object,
        .array => []*Value,
        .string => []const u8,
        .float => f128,
        .integer => i128,
        .boolean => bool,
        .Null => null,
    } {
        if (self.hashmap.getEntry(key)) |entry| {
            const value = entry.value_ptr.*.*;
            return switch (T) {
                .object => switch (value) {
                    .object => entry.value_ptr.*,
                    else => null,
                },
                .array => switch (value) {
                    .array => |capture| capture.array.items,
                    else => null,
                },
                .string => switch (value) {
                    .string => |capture| capture.value,
                    else => null,
                },
                .float => switch (value) {
                    .float => |capture| capture.value,
                    else => null,
                },
                .integer => switch (value) {
                    .integer => |capture| capture.value,
                    else => null,
                },
                .boolean => switch (value) {
                    .boolean => |capture| capture.value,
                    else => null,
                },
                .Null => null,
            };
        } else return null;
    }

    pub fn chain(self: Object, keys: []const []const u8) ?*Value {
        var current_object = self;

        for (keys, 1..) |key, depth| {
            if (current_object.get(key)) |capture| {
                switch (capture.*) {
                    .object => |obj| current_object = obj,
                    else => |*val| return if (depth == keys.len) return val else null,
                }
            } else return null;
        }

        return null;
    }

    pub fn contains(self: Object, key: []const u8) bool {
        return self.hashmap.contains(key);
    }

    pub fn count(self: Object) u32 {
        return self.hashmap.count();
    }

    pub fn toJson(self: *const Object, writer: Writer, pretty: bool, level: usize) anyerror!void {
        try writer.writeByte('{');
        if (pretty) try writer.writeByte('\n');
        var it = self.hashmap.keyIterator();
        var index: usize = 0;
        const size = self.hashmap.count();
        while (it.next()) |key| {
            if (pretty) try writer.writeBytesNTimes(indent, level + 1);
            try std.json.encodeJsonString(key.*, .{}, writer);
            try writer.writeAll(":");
            if (pretty) try writer.writeByte(' ');
            var value = self.hashmap.get(key.*).?;
            try value._toJson(writer, pretty, level + 1);
            index += 1;
            if (index < size) try writer.writeAll(",");
            if (pretty) try writer.writeByte('\n');
        }
        if (pretty) try writer.writeBytesNTimes(indent, level);
        try writer.writeByte('}');
    }
};

pub const Array = struct {
    allocator: std.mem.Allocator,
    array: std.ArrayList(*Value),
    it: Iterator = undefined,

    pub fn init(arena: std.mem.Allocator) Array {
        return .{ .array = std.ArrayList(*Value).init(arena), .allocator = arena };
    }

    pub fn deinit(self: *Array) void {
        self.array.clearAndFree();
    }

    // Compares equality of all items in an array. Order must be identical.
    pub fn eql(self: *const Array, other: *const Array) bool {
        if (self.count() != other.count()) return false;
        for (self.array.items, other.array.items) |lhs, rhs| {
            if (!lhs.eql(rhs)) return false;
        }
        return true;
    }

    pub fn get(self: *const Array, index: usize) ?*Value {
        return if (self.array.items.len > index) self.array.items[index] else null;
    }

    pub fn append(self: *Array, value: ?*Value) !void {
        try self.array.append(value orelse _null(self.allocator));
    }

    pub fn toJson(self: *const Array, writer: Writer, pretty: bool, level: usize) anyerror!void {
        try writer.writeAll("[");
        if (pretty) try writer.writeByte('\n');
        for (self.array.items, 0..) |*item, index| {
            if (pretty) try writer.writeBytesNTimes(indent, level + 1);
            try item.*._toJson(writer, pretty, level + 1);
            if (index < self.array.items.len - 1) try writer.writeAll(",");
            if (pretty) try writer.writeByte('\n');
        }
        if (pretty) try writer.writeBytesNTimes(indent, level);
        try writer.writeAll("]");
    }

    pub fn count(self: Array) usize {
        return self.array.items.len;
    }

    pub fn iterator(self: *Array) *Iterator {
        self.it = .{ .array = self.array };
        return &self.it;
    }
};

pub const Iterator = struct {
    array: std.ArrayList(*Value),
    index: usize = 0,

    pub fn next(self: *Iterator) ?*Value {
        self.index += 1;
        if (self.index > self.array.items.len) return null;
        return self.array.items[self.index - 1];
    }
};

pub fn allocator(self: *Data) std.mem.Allocator {
    if (self.arena) |_| {
        return self.arena_allocator;
    } else {
        self.arena = std.heap.ArenaAllocator.init(self.parent_allocator);
        self.arena_allocator = self.arena.?.allocator();
        return self.arena_allocator;
    }
}

fn isStringCoercablePointer(pointer: std.builtin.Type.Pointer, child: type, array_child: type) bool {
    // Logic borrowed from old implementation of std.meta.isZigString
    if (!pointer.is_volatile and
        !pointer.is_allowzero and
        pointer.size == .Slice) return true;
    if (!pointer.is_volatile and
        !pointer.is_allowzero and pointer.size == .One and
        child == .Array and
        &child.Array.child == array_child) return true;
    return false;
}
