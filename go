#!/usr/bin/env bash
set -euo pipefail
set -x

rm -rf out
mkdir out


#cat > out/staticexample.zig <<EOF
#const std = @import("std");
#pub fn main() !void {
#    try std.io.getStdOut().writer().writeAll("hello\n");
#}
#EOF
#(cd out && zig build-exe staticexample.zig)
#
#zig build -Dexe=out/staticexample
#result=$(./zig-out/bin/staticexample)
#
#if [ ! "$result" = "hello" ]; then
#    echo unexpected output from staticexample: $result
#    exit 1
#fi

zig build -Dexe=$(which ls)
result=$(./zig-out/bin/ls)

if [ ! "$result" = "hello" ]; then
    echo unexpected output from pie-hello: $result
    exit 1
fi



cat > out/pie-hello.zig <<EOF
const std = @import("std");
pub fn main() !void {
    try std.io.getStdOut().writer().writeAll("hello\n");
}
EOF
(cd out && zig build-exe -fPIC -fPIE pie-hello.zig)

zig build -Dexe=out/pie-hello
result=$(./zig-out/bin/pie-hello)

if [ ! "$result" = "hello" ]; then
    echo unexpected output from pie-hello: $result
    exit 1
fi



mkdir out/foolib
cat > out/foolib/foo.zig <<EOF
export fn foofunc() u32 { return 42; }
EOF
(cd out/foolib && zig build-lib -dynamic foo.zig)

cat > out/dynamicexample.zig <<EOF
const std = @import("std");
extern fn foofunc() u32;
const c = @cImport({ @cInclude("stdio.h"); });
pub fn main() !void {
    _ = c.fputs("hello\n", c.stdout);
    _ = foofunc();
    //const stdout = std.io.getStdOut().writer();
    //try stdout.print("feof(stdout)={}\n", .{c.feof(c.stdout)});
}
EOF
(cd out && zig build-exe out/dynamicexample.zig -Lfoolib -lc -lfoo)

zig build -Dexe=out/dynamicexample
result=$(./zig-out/bin/libdynamicexample.so)

if [ ! "$result" = "hello" ]; then
    echo unexpected output from dynamicexample: $result
    exit 1
fi


ls=$(which ls)
zig build -Dexe=$ls

echo Success
