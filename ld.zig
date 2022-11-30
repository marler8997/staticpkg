const builtin = @import("builtin");
const std = @import("std");
const build_options = @import("build_options");
const assert = std.debug.assert;
const os = std.os;
const elf = std.elf;
const native_endian = @import("builtin").target.cpu.arch.endian();
const native_arch = builtin.cpu.arch;
const native_os = builtin.os.tag;

const exe = @embedFile(build_options.exe_filename);
comptime {
    if (!std.mem.eql(u8, exe[0..4], elf.MAGIC))
        @compileError("exe has bad magic");
    if (exe[elf.EI_VERSION] != 1)
        @compileError("exe has invalid elf version");
    {
        const ElfClass = enum { _32, _64 };
        const exe_class: ElfClass = switch (exe[elf.EI_CLASS]) {
            elf.ELFCLASS32 => ._32,
            elf.ELFCLASS64 => ._64,
            else => @compileError("exe has invalid format class"),
        };
        const this_class: ElfClass = switch (@sizeOf(usize)) {
            4 => ._32,
            8 => ._64,
            else => @compileError("expected pointer size of 32 or 64"),
        };
        if (exe_class != this_class)
            @compileError("elf class (32 or 64 bits) mismatch");
    }
}

const exe_needs_swap = switch (exe[elf.EI_DATA]) {
    elf.ELFDATA2LSB => (native_endian == .Big),
    elf.ELFDATA2MSB => (native_endian == .Little),
    else => @compileError("exe has invalid endianness"),
};
pub fn exeEhdr() *align(1)const elf.Ehdr {
    return @ptrCast(*align(1)const elf.Ehdr, exe);
}
pub fn readIntExe(comptime T: type, bytes: *const [@divExact(@typeInfo(T).Int.bits, 8)]u8) T {
    return if (exe_needs_swap) std.mem.readIntForeign(T, bytes) else std.mem.readIntNative(T, bytes);
}
pub fn swapExeInt(comptime T: type, val: T) T {
    return if (exe_needs_swap) @byteSwap(val) else val;
}

pub fn swapExeInt2(val: anytype) @TypeOf(val) {
    return if (exe_needs_swap) @byteSwap(val) else val;
}


// TODO: not sure we want to support exec?
//       wouldn't that kind of file not need staticpkg because it's already static?
const exe_info: struct {
    phdrs: []const align(1) elf.Phdr,
    shdrs: []const align(1) elf.Shdr,
} = blk: {
    const elf_type = readIntExe(u16, exe[16..18]);
    switch (elf_type) {
        @enumToInt(elf.ET.DYN) => {},
        else => @compileError("exe is not a dynamic executable"),
    }
    const phdrs_ptr = @ptrCast([*]align(1)const elf.Phdr, @ptrCast([*]const u8, exe) + exeEhdr().e_phoff);
    std.debug.assert(exeEhdr().e_phentsize == @sizeOf(elf.Phdr));
    const phdrs_len = swapExeInt(u16, exeEhdr().e_phnum);

    const shdrs_ptr = @ptrCast([*]align(1)const elf.Shdr, @ptrCast([*]const u8, exe) + exeEhdr().e_shoff);
    std.debug.assert(exeEhdr().e_shentsize == @sizeOf(elf.Shdr));
    const shdrs_len = swapExeInt(u16, exeEhdr().e_shnum);

    break :blk .{
        .phdrs = phdrs_ptr[0 .. phdrs_len],
        .shdrs = shdrs_ptr[0 .. shdrs_len],
    };
};

pub fn main() !u8 {
    const exe_base = mapElf(exe, exe_info.phdrs);

    std.log.warn("TODO: need to setup the GOT!!!", .{});
    doElfRelocations(exe, exe_info.shdrs, exe_base);

    const entry_addr = exe_base + exeEhdr().e_entry;
    if (std.os.linux.elf_aux_maybe) |auxv| {
        var i: usize = 0;
        while (auxv[i].a_type != elf.AT_NULL) : (i += 1) {
            switch (auxv[i].a_type) {
                elf.AT_PHDR => auxv[i].a_un.a_val = exe_base + exeEhdr().e_phoff,
                elf.AT_PHNUM => auxv[i].a_un.a_val = exeEhdr().e_phnum,
                elf.AT_PHENT => auxv[i].a_un.a_val = exeEhdr().e_phentsize,
                elf.AT_ENTRY => auxv[i].a_un.a_val = entry_addr,
                //elf.AT_EXECFN =>
                // not sure if we should set this or not?
                //elf.AT_BASE =>
                else => {},
            }
        }
    }

    // need to restore the original stack pointer (rsp)
    // according to zig's std/star.zig, we should be able to get the original stack
    // pointer from 'std.os.argv' is set to minus 1 usize for argc
    //
    const original_rsp = @ptrToInt(std.os.argv.ptr) - @sizeOf(usize);
    std.log.info("will restore rsp to 0x{x}", .{original_rsp});
    //std.log.info("jumping to 0x{x}", .{entry_addr});
    asm volatile(
        // TODO: restore the stack pointer
        \\jmp *%[entry_addr]
        :
        : [original_rsp] "{rsp}" (original_rsp),
          [entry_addr] "{rdi}" (entry_addr)

    );
    unreachable;
}

fn elfToMemProtectFlags(elf_p_flags: u32) usize {
    return (if (elf_p_flags & elf.PF_R != 0) os.PROT.READ else @as(usize, 0)) |
        (if (elf_p_flags & elf.PF_W != 0) os.PROT.WRITE else @as(usize, 0)) |
        (if (elf_p_flags & elf.PF_X != 0) os.PROT.EXEC else @as(usize, 0));
}

fn mapElf(bin: []const u8, phdrs: []const align(1) elf.Phdr) usize {
    var min_vaddr: usize = std.math.maxInt(usize);
    var max_vaddr: usize = 0;
    for (phdrs) |*phdr| {
        //std.log.info("phdr type={}", .{phdr.p_type});
        switch (phdr.p_type) {
            elf.PT_LOAD => {
                if (phdr.p_memsz == 0) {
                    // maybe we can skip this section if this ever actually happens?
                    std.log.err("got a PT_LOAD section of size 0?", .{});
                    std.os.exit(0x7f);
                }
                const end = phdr.p_vaddr + phdr.p_memsz;
                std.log.info("load section 0x{x} - 0x{x}", .{phdr.p_vaddr, end});
                min_vaddr = std.math.min(min_vaddr, phdr.p_vaddr);
                max_vaddr = std.math.max(max_vaddr, end);
            },
            else => {},
        }
    }

    // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    // TODO: get the actual page size from the auxilary vector from linux
    // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    const page_size = std.mem.page_size;

    const min_vaddr_aligned = std.mem.alignBackward(min_vaddr, page_size);
    const max_vaddr_aligned = std.mem.alignForward(max_vaddr, page_size);
    const total_len_aligned = max_vaddr_aligned - min_vaddr_aligned;

    std.log.info("mapElf range 0x{x}-0x{x} (page-aligned 0x{x}-0x{x}) len={}", .{
        min_vaddr, max_vaddr, min_vaddr_aligned, max_vaddr_aligned, total_len_aligned});

    const base = os.linux.mmap(null, total_len_aligned, os.PROT.WRITE, os.MAP.PRIVATE | os.MAP.ANONYMOUS, -1, 0);
    switch (os.errno(base)) {
        .SUCCESS => {},
        else => |errno| {
            std.log.err("mmap {} bytes for {s} exe failed, errno={}", .{total_len_aligned, build_options.exe_filename, errno});
            std.os.exit(0x7f);
        },
    }
    std.log.info("base 0x{x}", .{base});
    // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    // TODO: unmap unused portions

    for (phdrs) |*phdr| {
        switch (phdr.p_type) {
            elf.PT_LOAD => {
                const start_unaligned = base + phdr.p_vaddr;

                const ptr = @intToPtr([*]u8, start_unaligned);
                @memcpy(ptr, bin.ptr + phdr.p_offset, phdr.p_memsz);

                const limit_unaligned = start_unaligned + phdr.p_memsz;
                const start_aligned = std.mem.alignBackward(start_unaligned, page_size);
                const limit_aligned = std.mem.alignForward(limit_unaligned, page_size);
                const len_aligned = limit_aligned - start_aligned;
                switch (os.errno(std.os.linux.mprotect(@intToPtr([*]u8, start_aligned), len_aligned, elfToMemProtectFlags(phdr.p_flags)))) {
                    .SUCCESS => {},
                    else => |errno| {
                        std.log.err("mprotect to {} failed, errno={}", .{phdr.p_flags, errno});
                        std.os.exit(0x7f);
                    },
                }
            },
            else => {},
        }
    }
    return base;
}

const RelaSection = enum {
    dyn,
    plt,
    pub fn name(self: RelaSection) []const u8 {
        return switch (self) {
            .dyn => ".rela.dyn",
            .plt => ".rela.plt",
        };
    }
    pub fn expectedFlags(self: RelaSection) usize {
        return switch (self) {
            .dyn => elf.SHF_ALLOC,
            .plt => elf.SHF_ALLOC | elf.SHF_INFO_LINK,
        };
    }
};

fn doElfRelocations(bin: []const u8, shdrs: []const align(1) elf.Shdr, base: usize) void {
    for (shdrs) |*shdr| {

        // NOTE: elf.Sym will be relevant here!
        //     Elf64_Word st_name;  /* (4 bytes) Symbol name(index in .strtab, or 0 for no name)  */
        //     unsigned char st_info;  /* (1 byte) Symbol type and binding */
        //     unsigned char st_other; /* (1 byte) Symbol visibility */
        //     Elf64_Section st_shndx; /* (2 bytes) Section index */
        //     Elf64_Addr st_value; /* (8 bytes) Symbol value */
        //     Elf64_Xword st_size; /*  (8 bytes) Symbol size */
        //
        //std.log.info("section header {}", .{shdr.*});
//    sh_name: Elf32_Word,
//    sh_type: Elf32_Word,
//    sh_flags: Elf32_Word,
//    sh_addr: Elf32_Addr,
//    sh_offset: Elf32_Off,
//    sh_size: Elf32_Word,
//    sh_link: Elf32_Word,
//    sh_info: Elf32_Word,
//    sh_addralign: Elf32_Word,
        //    sh_entsize: Elf32_Word,
        switch (shdr.sh_type) {
            // should be the same as SH_RELA except entries don't have an addend
            elf.SHT_REL => @panic("SH_REL section not implemented"),
            elf.SHT_RELA => {
                const rela_dyn = 125;
                const rela_plt = 135;
                const opt_rela_section: ?RelaSection = switch (shdr.sh_name) {
                    rela_dyn => .dyn,
                    rela_plt => .plt,
                    else => null,
                };
                const s = opt_rela_section orelse {
                    std.log.err("encountered a SHT_RELA section with an unknown name {}", .{shdr.sh_name});
                    os.exit(0xff);
                    continue;
                };
                {
                    const expected_flags = s.expectedFlags();
                    if (shdr.sh_flags != expected_flags) {
                        std.log.err("expected section {s} to have flags 0x{x} but has 0x{x}", .{s.name(), expected_flags, shdr.sh_flags});
                        os.exit(0xff);
                    }
                }

                const relocs_addr = @ptrToInt(bin.ptr) + shdr.sh_offset;
                const relocs_limit = relocs_addr + shdr.sh_size;
                var reloc_ptr = @intToPtr([*]align(1)const elf.Rela, relocs_addr);
                while (@ptrToInt(reloc_ptr) + @sizeOf(elf.Rela) <= relocs_limit) : (reloc_ptr += 1) {
                    const r_offset = swapExeInt2(reloc_ptr[0].r_offset);
                    const r_info = swapExeInt2(reloc_ptr[0].r_info);
                    //const r_addend = swapExeInt2(reloc_ptr[0].r_addend);
                    //std.log.info("reloc 0x{x} info=0x{x} addend=0x{x}", .{r_offset, r_info, r_addend,});
                    const rel_type = r_info & 0x3f; // TODO: not sure how many bits to mask here
                    // TODO: swap fields
                    switch (rel_type) {
                        elf.R_X86_64_COPY => {
                            std.log.warn("TODO: implement R_X86_64_COPY", .{});
                        },
                        elf.R_X86_64_GLOB_DAT => {
                            // todo: popolate GOT entry
                            const got_entry_addr = base + r_offset;
                            std.log.info("TODO: write GOT entry at addr 0x{x}", .{got_entry_addr});
                            @intToPtr(*usize, got_entry_addr).* = 0x123;
                        },
                        elf.R_X86_64_JUMP_SLOT => {
                            std.log.warn("TODO: implement R_X86_64_JUMP_SLOT", .{});
                        },
                        elf.R_X86_64_RELATIVE => {
                            std.log.warn("TODO: implement R_X86_64_RELATIVE", .{});
                        },
                        else => {
                            std.log.err("x86_64 relocation type {} not implemented", .{rel_type});
                            os.exit(0xff);
                        },
                    }
                    //const is_x86_64_relative = r.r_info & elf.R_X6_64_RELATIVE;

                }
            },
            else => {},
        }
    }
}
