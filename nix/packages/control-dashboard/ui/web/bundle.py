"""Bundles the dashboard for a browser, as dear-imgui-rs' xtask web-demo does.

usage: bundle.py DASHBOARD_WASM PROVIDER_DIR OUT_DIR

DASHBOARD_WASM is the cargo build for wasm32-unknown-unknown, PROVIDER_DIR
has imgui-sys-v1{.js,.wasm,-wrapper.js} (xtask build-cimgui-provider). Needs
wasm-bindgen and wasm-tools on PATH.
"""

import shutil, subprocess, sys
from pathlib import Path

wasm, provider, out = map(Path, sys.argv[1:])
out.mkdir(parents=True, exist_ok=True)
name = "control-dashboard"
subprocess.run(["wasm-bindgen", "--target", "web", "--no-typescript", "--out-name", name, "--out-dir", out, wasm], check=True)

# Both modules share one memory: the dashboard imports it, as the provider does.
bg = out / f"{name}_bg.wasm"
wat = subprocess.run(["wasm-tools", "print", bg], check=True, capture_output=True, text=True).stdout
lines = [l for l in wat.splitlines() if l.strip() != '(export "memory" (memory 0))']
mem = next(i for i, l in enumerate(lines) if l.lstrip().startswith("(memory"))
del lines[mem]
module = next(i for i, l in enumerate(lines) if l.lstrip().startswith("(module"))
lines[module + 1:module + 1] = ['  (import "env" "memory" (memory (;0;) 256 4096))', '  (export "memory" (memory 0))']
subprocess.run(["wasm-tools", "parse", "-", "-o", bg], input="\n".join(lines), check=True, text=True)

js = out / f"{name}.js"
code = js.read_text()
# Beside the entry for its own glue, in the imports it returns.
at = code.index(f'"./{name}_bg.js": import0,')
code = code[:at] + "env: { memory: globalThis.__imgui_shared_memory },\n        " + code[at:]
js.write_text(code)

for f in ["imgui-sys-v1.js", "imgui-sys-v1.wasm", "imgui-sys-v1-wrapper.js"]:
    shutil.copy(provider / f, out / f)
shutil.copy(Path(__file__).parent / "index.html", out / "index.html")
