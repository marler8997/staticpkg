const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

//    
//    {
//        const build_options = b.addOptions();
//
//        const local_ld_filename = b.pathJoin(&.{ b.build_root, "ld"});
//        const copy_ld_step = CopyFileStep.create(b, ld_filename, local_ld_filename);
//        const local_exe_filename = b.pathJoin(&.{ b.build_root, "exe"});
//        const copy_exe_step = CopyFileStep.create(b, exe_filename, local_exe_filename);
    //

    if (b.option([]const u8, "exe", "The executable file to wrap in a static executable")) |dyn_exe_src| {
        const name = std.fs.path.basename(dyn_exe_src);
        const exe_embed = b.pathJoin(&.{ b.build_root, b.fmt("{s}-embed", .{name}) });
        const copy_exe = CopyFileStep.create(b, dyn_exe_src, exe_embed);

        const build_options = b.addOptions();
        build_options.addOptionFileSource("exe_filename", .{ .path = exe_embed });
        
        //const exe = b.addSharedLibrary(name, "ld.zig", .unversioned);
        const exe = b.addExecutable(name, "ld.zig");

        //exe.override_dest_dir = .bin;
        
        exe.step.dependOn(&copy_exe.step);
        exe.addOptions("build_options", build_options);
        
        exe.single_threaded = true;
        //exe.force_pic = true;
        //exe.pie = true;
        exe.setTarget(target);
        exe.setBuildMode(mode);
        exe.install();
        //exe.out_filename = name;
        //exe.entry_symbol_name = "ld_start";
        //exe.strip = true;
        b.step("ld", "build/install ld").dependOn(&exe.install_step.?.step);
    }
    {
        const exe = b.addExecutable("make-staticpkg", "make-staticpkg.zig");
        exe.single_threaded = true;
        exe.setTarget(target);
        exe.setBuildMode(mode);
        exe.install();
    }
}
const CopyFileStep = struct {
    step: std.build.Step,
    src: []const u8,
    // TODO: would be nice if we could put this in the cache
    dst: []const u8,
    pub fn create(b: *std.build.Builder, src: []const u8, dst: []const u8) *CopyFileStep {
        const step = b.allocator.create(CopyFileStep) catch unreachable;
        step.* = .{
            .step = std.build.Step.init(.custom, "copyfile", b.allocator, make),
            .src = src,
            .dst = dst,
        };
        return step;
    }
    fn make(step: *std.build.Step) !void {
        const self = @fieldParentPtr(CopyFileStep, "step", step);
        //std.log.info("cp '{s}' to '{s}'", .{self.src, self.dst});
        try std.fs.cwd().copyFile(self.src, std.fs.cwd(), self.dst, .{});
    }
    
};
