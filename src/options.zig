const std = @import("std");
const scanner = @import("scanner.zig");
const errors = @import("errors.zig");

/// Option-struct reflection, metadata lookup, value parsing, and field binding.
pub fn fieldValueMode(comptime T: type, comptime field_name: [:0]const u8) scanner.ValueMode {
    const F = @FieldType(T, field_name);
    if (F == bool) return .none;
    if (@typeInfo(F) == .optional and @typeInfo(F).optional.child == bool) return .none;

    if (@hasDecl(T, "meta") and @hasField(@TypeOf(T.meta), field_name)) {
        const field_meta = @field(T.meta, field_name);
        if (@hasField(@TypeOf(field_meta), "flag_value")) return .optional_inline;
    }

    return .required;
}

pub fn longOptionValueMode(
    comptime T: type,
    comptime fields: []const [:0]const u8,
    comptime has_meta: bool,
    name: []const u8,
) ?scanner.ValueMode {
    _ = has_meta;
    inline for (fields) |field_name| {
        if (std.mem.eql(u8, field_name, name)) return fieldValueMode(T, field_name);
    }
    return null;
}

pub fn shortOptionValueMode(
    comptime T: type,
    comptime fields: []const [:0]const u8,
    comptime has_meta: bool,
    short: u8,
) ?scanner.ValueMode {
    if (!has_meta) return null;

    inline for (fields) |field_name| {
        if (@hasField(@TypeOf(T.meta), field_name)) {
            const field_meta = @field(T.meta, field_name);
            if (@hasField(@TypeOf(field_meta), "short") and field_meta.short == short) {
                return fieldValueMode(T, field_name);
            }
        }
    }
    return null;
}

pub fn combineValueMode(a: ?scanner.ValueMode, b: ?scanner.ValueMode) ?scanner.ValueMode {
    if (a == .required or b == .required) return .required;
    if (a == .optional_inline or b == .optional_inline) return .optional_inline;
    if (a != null or b != null) return .none;
    return null;
}

pub fn OptionStructResolver(comptime T: type) type {
    return struct {
        const fields = @typeInfo(T).@"struct".field_names;
        const has_meta = @hasDecl(T, "meta");

        pub fn longValueMode(_: @This(), name: []const u8) ?scanner.ValueMode {
            return longOptionValueMode(T, fields, has_meta, name);
        }

        pub fn shortValueMode(_: @This(), short: u8) ?scanner.ValueMode {
            return shortOptionValueMode(T, fields, has_meta, short);
        }
    };
}

pub fn setField(
    comptime T: type,
    comptime fields: []const [:0]const u8,
    comptime has_meta: bool,
    opts: *T,
    name: []const u8,
    value: ?[]const u8,
) errors.ParseError!bool {
    inline for (fields) |field_name| {
        if (std.mem.eql(u8, field_name, name)) {
            try setValue(T, opts, field_name, has_meta, value);
            return true;
        }
    }
    return false;
}

pub fn setFieldNegated(
    comptime T: type,
    comptime fields: []const [:0]const u8,
    comptime has_meta: bool,
    opts: *T,
    name: []const u8,
) errors.ParseError!bool {
    inline for (fields) |field_name| {
        if (std.mem.eql(u8, field_name, name)) {
            try setNegatedValue(T, opts, field_name, has_meta);
            return true;
        }
    }
    return false;
}

fn setNegatedValue(
    comptime T: type,
    opts: *T,
    comptime field_name: [:0]const u8,
    comptime has_meta: bool,
) errors.ParseError!void {
    const F = @FieldType(T, field_name);

    // Check for no_value in meta first
    if (has_meta and @hasField(@TypeOf(T.meta), field_name)) {
        const field_meta = @field(T.meta, field_name);
        if (@hasField(@TypeOf(field_meta), "no_value")) {
            @field(opts, field_name) = field_meta.no_value;
            return;
        }
    }

    // Bool fields: --no-foo sets to false
    if (F == bool) {
        @field(opts, field_name) = false;
        return;
    }

    // Optional fields: --no-foo sets to null
    if (@typeInfo(F) == .optional) {
        @field(opts, field_name) = null;
        return;
    }

    // No no_value in meta and not bool/optional - error
    return errors.ParseError.InvalidValue;
}

pub fn setFieldByShort(
    comptime T: type,
    comptime fields: []const [:0]const u8,
    comptime has_meta: bool,
    opts: *T,
    short: u8,
    value: ?[]const u8,
) errors.ParseError!bool {
    if (!has_meta) return false;

    inline for (fields) |field_name| {
        if (@hasField(@TypeOf(T.meta), field_name)) {
            const field_meta = @field(T.meta, field_name);
            if (@hasField(@TypeOf(field_meta), "short")) {
                if (field_meta.short == short) {
                    try setValue(T, opts, field_name, has_meta, value);
                    return true;
                }
            }
        }
    }
    return false;
}

fn setValue(
    comptime T: type,
    opts: *T,
    comptime field_name: [:0]const u8,
    comptime has_meta: bool,
    value: ?[]const u8,
) errors.ParseError!void {
    const F = @FieldType(T, field_name);

    // Bool fields are flags (no value needed)
    if (F == bool) {
        @field(opts, field_name) = true;
        return;
    }

    if (@typeInfo(F) == .optional and @typeInfo(F).optional.child == bool and value == null) {
        @field(opts, field_name) = true;
        return;
    }

    // No value provided - check for flag_value in meta
    if (value == null) {
        if (has_meta and @hasField(@TypeOf(T.meta), field_name)) {
            const field_meta = @field(T.meta, field_name);
            if (@hasField(@TypeOf(field_meta), "flag_value")) {
                @field(opts, field_name) = field_meta.flag_value;
                return;
            }
        }
        return errors.ParseError.MissingValue;
    }

    // Check for custom parse function in meta
    if (has_meta and @hasField(@TypeOf(T.meta), field_name)) {
        const field_meta = @field(T.meta, field_name);
        if (@hasField(@TypeOf(field_meta), "parse")) {
            const result = field_meta.parse(value.?);
            if (@typeInfo(@TypeOf(result)) == .error_union) {
                @field(opts, field_name) = result catch return errors.ParseError.InvalidValue;
            } else if (@typeInfo(@TypeOf(result)) == .optional) {
                @field(opts, field_name) = result orelse return errors.ParseError.InvalidValue;
            } else {
                @field(opts, field_name) = result;
            }
            return;
        }
    }

    // Repeatable options: append when the field is a list-like type.
    if (listElemType(F)) |Elem| {
        const parsed = try parseScalar(Elem, value.?);
        var list_ptr = &@field(opts, field_name);
        list_ptr.append(parsed) catch |e| {
            const name = @errorName(e);
            if (std.mem.eql(u8, name, "OutOfMemory")) return errors.ParseError.OutOfMemory;
            if (std.mem.eql(u8, name, "Overflow")) return errors.ParseError.TooManyValues;
            return errors.ParseError.InvalidValue;
        };
        return;
    }

    @field(opts, field_name) = try parseScalar(F, value.?);
}

fn parseScalar(comptime T: type, value: []const u8) errors.ParseError!T {
    if (T == []const u8) return value;

    switch (@typeInfo(T)) {
        .optional => {
            const Child = @typeInfo(T).optional.child;
            const parsed = try parseScalar(Child, value);
            return @as(T, parsed);
        },
        .int => return std.fmt.parseInt(T, value, 0) catch return errors.ParseError.InvalidValue,
        .@"enum" => return std.meta.stringToEnum(T, value) orelse return errors.ParseError.InvalidValue,
        else => return errors.ParseError.InvalidValue,
    }
}

/// Fixed-capacity list for repeatable options (no allocator required).
///
///   const Opts = struct {
///       exclude: opt.Multi([]const u8, 32) = .{},
///       pub const meta = .{ .exclude = .{ .short = 'x' } };
///   };
pub fn Multi(comptime Elem: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();

        buffer: [capacity]Elem = undefined,
        len: usize = 0,

        pub fn append(self: *Self, item: Elem) error{Overflow}!void {
            if (self.len >= capacity) return error.Overflow;
            self.buffer[self.len] = item;
            self.len += 1;
        }

        pub fn slice(self: *Self) []Elem {
            return self.buffer[0..self.len];
        }

        pub fn constSlice(self: *const Self) []const Elem {
            return self.buffer[0..self.len];
        }
    };
}

pub fn listElemType(comptime ListT: type) ?type {
    if (@typeInfo(ListT) != .@"struct") return null;

    if (!@hasDecl(ListT, "append")) return null;
    const append_info = @typeInfo(@TypeOf(ListT.append));
    if (append_info != .@"fn") return null;
    const params = append_info.@"fn".param_types;
    if (params.len != 2) return null;

    const fields = @typeInfo(ListT).@"struct".field_names;
    var elem: ?type = null;
    inline for (fields) |field_name| {
        if (std.mem.eql(u8, field_name, "items")) {
            const info = @typeInfo(@FieldType(ListT, field_name));
            if (info == .pointer and info.pointer.size == .slice) elem = info.pointer.child;
        }
        if (std.mem.eql(u8, field_name, "buffer")) {
            const info = @typeInfo(@FieldType(ListT, field_name));
            if (info == .array) elem = info.array.child;
        }
    }

    const found = elem orelse return null;
    const item_param = params[1] orelse return null;
    if (item_param != found) return null;

    return found;
}

pub fn optionShort(comptime T: type, comptime field_name: [:0]const u8) ?u8 {
    if (!@hasDecl(T, "meta")) return null;
    if (!@hasField(@TypeOf(T.meta), field_name)) return null;

    const field_meta = @field(T.meta, field_name);
    if (!@hasField(@TypeOf(field_meta), "short")) return null;
    return field_meta.short;
}

pub fn validateOptionStruct(comptime T: type) void {
    const info = @typeInfo(T);
    if (info != .@"struct") @compileError("options must be a struct: " ++ @typeName(T));

    const fields = info.@"struct".field_names;

    if (@hasDecl(T, "meta")) {
        inline for (@typeInfo(@TypeOf(T.meta)).@"struct".field_names) |meta_field| {
            if (!@hasField(T, meta_field)) {
                @compileError("meta entry has no matching option field: " ++ @typeName(T) ++ "." ++ meta_field);
            }
        }
    }

    inline for (fields, 0..) |left, left_idx| {
        if (optionShort(T, left)) |left_short| {
            inline for (fields[left_idx + 1 ..]) |right| {
                if (optionShort(T, right)) |right_short| {
                    if (left_short == right_short) {
                        @compileError("duplicate short option in " ++ @typeName(T));
                    }
                }
            }
        }
    }
}
