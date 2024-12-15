const std = @import("std");
const builtin = @import("builtin");

const util = @import("util.zig");

allocator: std.mem.Allocator,
template_paths: []const TemplatePath,
templates_paths: []const TemplatePath,

const Manifest = @This();

pub const TemplatePath = struct {
    prefix: []const u8,
    path: []const u8,
};

const TemplateDef = struct {
    key: []const u8,
    name: []const u8,
    prefix: []const u8,
    content: []const u8,
    partial: bool,
};

pub fn init(
    allocator: std.mem.Allocator,
    templates_paths: []const TemplatePath,
    template_paths: []const TemplatePath,
) Manifest {
    return .{
        .allocator = allocator,
        .templates_paths = templates_paths,
        .template_paths = template_paths,
    };
}

pub fn compile(
    self: *Manifest,
    comptime TemplateType: type,
    comptime options: type,
) ![]const u8 {
    var template_defs = std.ArrayList(TemplateDef).init(self.allocator);

    var templates_paths_map = std.StringHashMap([]const u8).init(self.allocator);
    for (self.templates_paths) |templates_path| {
        try templates_paths_map.put(templates_path.prefix, templates_path.path);
    }

    var template_map = std.StringHashMap(TemplateType.TemplateMap).init(self.allocator);

    // First pass - generate names for all templates and store in prefix->name nested hashmap.
    for (self.template_paths) |template_path| {
        const result = try template_map.getOrPut(template_path.prefix);
        var map = if (result.found_existing)
            result.value_ptr
        else blk: {
            result.value_ptr.* = TemplateType.TemplateMap.init(self.allocator);
            break :blk result.value_ptr;
        };

        const generated_name = try util.generateVariableNameAlloc(self.allocator);
        const key = try util.templatePathStore(
            self.allocator,
            templates_paths_map.get(template_path.prefix).?,
            template_path.path,
        );
        if (map.get(key)) |_| {
            std.debug.print("[zmpl] Found duplicate template: {s}\n", .{template_path.path});
            std.debug.print("[zmpl] Template names must be uniquely identifiable. Exiting.\n", .{});
            std.process.exit(1);
        }

        try map.putNoClobber(key, generated_name);
    }

    // Second pass - compile all templates, some of which may reference templates in other prefix scopes
    for (self.templates_paths) |templates_path| {
        try self.compileTemplates(
            &template_defs,
            templates_path,
            templates_paths_map,
            TemplateType,
            &template_map,
            options,
        );
    }
    std.debug.print("[zmpl] Compiled {} template(s)\n", .{self.template_paths.len});

    var buf = std.ArrayList(u8).init(self.allocator);
    const writer = buf.writer();
    defer buf.deinit();

    try writer.writeAll(
        \\// Zmpl template manifest.
        \\// This file is automatically generated at build time and should not be manually modified.
        \\
        \\const std = @import("std");
        \\const __zmpl = @import("zmpl");
        \\
    );

    if (@hasDecl(options, "manifest_header")) {
        const manifest_header = options.manifest_header;
        const decodedHeader: []u8 = try self.allocator.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(manifest_header));
        defer self.allocator.free(decodedHeader);
        try std.base64.standard.Decoder.decode(decodedHeader, manifest_header);

        try writer.writeAll(decodedHeader);
    }

    for (template_defs.items) |template_def| {
        try writer.writeAll(try std.fmt.allocPrint(self.allocator,
            \\
            \\{s}
            \\
        , .{template_def.content}));
    }

    try writer.writeAll(
        \\
        \\pub const ZmplValue = __zmpl.Data.Value;
        \\pub const __Manifest = struct {
        \\    const TemplateType = enum { zmpl, markdown };
        \\    pub const Template = __zmpl.Template;
        \\
        \\    /// Find any template matching a given name. Uses all template paths in order.
        \\    pub fn find(name: []const u8) ?Template {
        \\        for (templates) |template| {
        \\            if (!std.mem.eql(u8, template.key, name)) continue;
        \\
        \\            return template;
        \\        }
        \\
        \\        return null;
        \\    }
        \\
        \\    /// Find a template in a given prefix, i.e. a template located within a specific
        \\    /// template path.
        \\    pub fn findPrefixed(prefix: []const u8, name: []const u8) ?Template {
        \\        for (templates) |template| {
        \\            if (!std.mem.eql(u8, template.prefix, prefix)) continue;
        \\            if (!std.mem.eql(u8, template.key, name)) continue;
        \\
        \\            return template;
        \\        }
        \\
        \\        return null;
        \\    }
        \\
    );

    for (template_defs.items) |template_def| {
        if (template_def.partial) continue;

        try writer.writeAll(try std.fmt.allocPrint(self.allocator,
            \\const {0s} = __Manifest.Template{{
            \\  .key = "{2s}",
            \\  .name = "{0s}",
            \\  .prefix = "{1s}",
            \\}};
            \\
        , .{ template_def.name, template_def.prefix, template_def.key }));
    }

    try writer.writeAll(
        \\    pub const templates = [_]Template{
        \\
    );

    for (template_defs.items) |template_def| {
        if (template_def.partial) continue;

        try writer.print(
            \\{s},
            \\
        ,
            .{template_def.name},
        );
    }

    try writer.writeAll(
        \\    };
        \\};
    );
    return self.allocator.dupe(u8, buf.items);
}

fn compileTemplates(
    self: *Manifest,
    array: *std.ArrayList(TemplateDef),
    templates_path: TemplatePath,
    templates_paths_map: std.StringHashMap([]const u8),
    comptime TemplateType: type,
    template_map: *std.StringHashMap(TemplateType.TemplateMap),
    comptime options: type,
) !void {
    for (self.template_paths) |template_path| {
        if (!std.mem.eql(u8, template_path.prefix, templates_path.prefix)) continue;

        const key = try util.templatePathStore(self.allocator, templates_paths_map.get(template_path.prefix).?, template_path.path);
        const generated_name = template_map.get(template_path.prefix).?.get(key).?;

        var file = try std.fs.openFileAbsolute(template_path.path, .{});
        const size = (try file.stat()).size;
        const content = try file.readToEndAlloc(self.allocator, @intCast(size));
        var template = TemplateType.init(
            self.allocator,
            generated_name,
            templates_path.path,
            templates_path.prefix,
            template_path.path,
            templates_paths_map,
            content,
            template_map.*,
        );
        const partial = template.partial;
        const output = try template.compile(options);

        const template_def: TemplateDef = .{
            .key = key,
            .name = generated_name,
            .prefix = templates_path.prefix,
            .content = output,
            .partial = partial,
        };

        try array.append(template_def);
    }
}
