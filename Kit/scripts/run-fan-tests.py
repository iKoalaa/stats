#!/usr/bin/env python3
"""Run fan tests without launching Stats or connecting to the real SMC helper.

Requires a previously built Kit.framework with ENABLE_TESTABILITY=YES.
Build artifacts are retained in --build-dir for inspection.
"""
import argparse
import os
from pathlib import Path
import re
import subprocess


ROOT = Path(__file__).resolve().parents[2]


def run():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--products", required=True, type=Path)
    parser.add_argument("--build-dir", required=True, type=Path)
    args = parser.parse_args()
    products = args.products.resolve()
    build = args.build_dir.resolve()
    if not (products / "Kit.framework").is_dir():
        parser.error("--products must contain a built Kit.framework")
    build.mkdir(parents=True, exist_ok=True)
    platform = Path(subprocess.check_output(
        ["xcrun", "--sdk", "macosx", "--show-sdk-platform-path"], text=True).strip())
    frameworks = platform / "Developer/Library/Frameworks"
    libraries = platform / "Developer/usr/lib"
    common = ["xcrun", "swiftc", "-swift-version", "5", "-g",
              "-module-cache-path", str(build / "cache"),
              "-F", str(products), "-F", str(frameworks),
              "-I", str(ROOT / "Kit/lldb"), "-I", str(ROOT / "Kit/lldb/include"),
              "-I", str(libraries), "-L", str(libraries),
              "-Xlinker", "-rpath", "-Xlinker", str(products),
              "-Xlinker", "-rpath", "-Xlinker", str(frameworks),
              "-Xlinker", "-rpath", "-Xlinker", str(libraries)]
    main = build / "main.swift"
    core = [ROOT / "Tests/FanCurve.swift", ROOT / "Tests/FanCurveController.swift", ROOT / "Tests/FanCurveCommandGate.swift"]
    expected = sum(len(re.findall(r"^    func test\w+\(", path.read_text(), re.MULTILINE)) for path in core)
    main.write_text(
        'import XCTest\nimport Darwin\n'
        'let suite = XCTestSuite(name: "Fan curves")\n'
        'suite.addTest(FanCurveTests.defaultTestSuite)\n'
        'suite.addTest(FanCurveControllerTests.defaultTestSuite)\n'
        'suite.addTest(FanCurveCommandGateTests.defaultTestSuite)\n'
        'suite.run()\n'
        'exit(suite.testRun?.hasSucceeded == true && '
        f'suite.testRun?.executionCount == {expected} ? 0 : 1)\n', encoding="utf-8")
    suites = [
        ("curves", [], core + [main]),
        ("editor", ["-parse-as-library", "-D", "FAN_CURVE_UI_TESTS"],
         [ROOT / "Stats/Views/Fans.swift", ROOT / "Tests/FanCurveEditor.swift"]),
        ("helper", ["-D", "FAN_HELPER_TESTS"],
         [ROOT / "SMC/Helper/main.swift", ROOT / "SMC/Helper/protocol.swift", ROOT / "Tests/FanHelper.swift"]),
    ]
    # Compile the real algorithms against fake OS boundaries, never the live driver.
    boundaries = ("IOServiceMatching", "IOServiceGetMatchingServices", "IOIteratorNext",
                  "IOObjectRelease", "IOServiceOpen", "IOServiceClose", "IOConnectCallStructMethod", "usleep")
    source = (ROOT / "SMC/smc.swift").read_text()
    for name in boundaries:
        source, count = re.subn(r"\b" + name + r"(?=\()", "mock" + name, source)
        if not count:
            raise RuntimeError(f"Missing expected OS boundary: {name}")
    if re.search(r"\b(?:" + "|".join(boundaries) + r")\s*\(", source):
        raise RuntimeError("An unmocked OS call remains")
    mocked = build / "SMCUnderTest.swift"
    mocked.write_text(source.replace("#if arch(arm64)", "#if TEST_ARM64"), encoding="utf-8")
    for branch in ("intel", "arm64"):
        flags = ["-parse-as-library", "-D", "SMC_STANDALONE_TESTS"]
        if branch == "arm64":
            flags += ["-D", "TEST_ARM64"]
        else:
            flags += ["-D", "TEST_INTEL"]
        suites.append((f"smc-{branch}", flags, [mocked, ROOT / "Tests/SMC.swift"]))
    env = dict(os.environ)
    env["DYLD_FRAMEWORK_PATH"] = str(products)
    for name, flags, sources in suites:
        executable = build / name
        print(f"Building and running {name} tests (no real fan commands)...", flush=True)
        subprocess.run(common + flags + [str(path) for path in sources] + ["-o", str(executable)],
                       check=True, timeout=180)
        result = subprocess.run([str(executable)], env=env, timeout=120,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        (build / f"{name}.log").write_text(result.stdout, encoding="utf-8")
        if result.returncode:
            print(result.stdout, flush=True)
            result.check_returncode()
        for line in result.stdout.splitlines():
            if "Executed " in line:
                print(line.strip(), flush=True)


if __name__ == "__main__":
    run()
