#!/usr/bin/env python3
"""Export the audited source revisions and run the focused RFC #793 probes."""
import argparse
from pathlib import Path
import subprocess
import tempfile

ENGINE = "46677c9ac2b45eaedbbdab13903a037d64c0fc84"
CORE = "5425b7c4d04920da4da25af221c139e928a1b918"


def export(repo, revision, output):
    output.mkdir()
    archive = subprocess.run(
        ["git", "-C", str(repo), "archive", revision],
        check=True, stdout=subprocess.PIPE,
    )
    subprocess.run(["tar", "-x", "-C", str(output)], input=archive.stdout, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--engine-repo", required=True, type=Path)
    parser.add_argument("--core-repo", required=True, type=Path)
    parser.add_argument("--zig", default="zig")
    args = parser.parse_args()
    if subprocess.check_output([args.zig, "version"], text=True).strip() != "0.16.0":
        parser.error("the audited toolchain is Zig 0.16.0")
    with tempfile.TemporaryDirectory(prefix="rfc-793-") as temporary:
        root = Path(temporary)
        engine = root / "labelle-engine"
        export(args.engine_repo.resolve(), ENGINE, engine)
        export(args.core_repo.resolve(), CORE, root / "labelle-core")
        evidence = Path(__file__).resolve().parent
        (engine / "test/rfc793_probe.zig").write_bytes((evidence / "probes.zig").read_bytes())
        build = engine / "build.zig"
        original = build.read_text()
        # Keep the audited module wiring, then select only the relevant tests.
        prefix, separator, _ = original.partition('    const test_step = b.step("test",')
        if not separator:
            raise RuntimeError("audited build layout did not match")
        build.write_text(prefix + '''    const step = b.step("test", "RFC investigation");
    const files = [_][]const u8{
        "test/rfc793_probe.zig", "test/engine_sprite_anim_test.zig",
        "test/animation_events_test.zig", "test/sprite_animation_events_test.zig",
        "test/engine_events_test.zig",
    };
    for (files) |file| {
        const mod = b.createModule(.{ .root_source_file = b.path(file), .target = target, .optimize = optimize });
        mod.addImport("engine", engine_module);
        mod.addImport("labelle-core", core_module);
        const tests = b.addTest(.{ .root_module = mod });
        step.dependOn(&b.addRunArtifact(tests).step);
    }
}
''')
        subprocess.run([args.zig, "build", "test", "--summary", "all"], cwd=engine, check=True)


if __name__ == "__main__":
    main()
