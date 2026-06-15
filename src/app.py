"""
Flask app that serves clang.js as a static-page library.

Routes:
- GET  /              -> the demo HTML page
- GET  /api/run       -> placeholder for any future server-side endpoint
- GET  /static/...    -> static assets (clang.js lib, wasm, sysroot.tar)

The clang.js library itself runs entirely in the browser via WebAssembly.
This Flask app just serves the static files; no Node.js/npm build step is
required to use clang.js — the dist files from the npm package are copied
verbatim into static/clang/.
"""

import os
import logging

from flask import Flask, render_template, jsonify

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("clang-flask")

app = Flask(__name__, static_folder="static", static_url_path="/static")


@app.route("/")
def index():
    """Serve the demo HTML page that uses clang.js."""
    return render_template("index.html")


@app.route("/nim")
def nim_page():
    """Serve the wasm-nim demo page (Nim 2.2.4 compiler compiled to wasm)."""
    return render_template("nim.html")


@app.route("/nim-build")
def nim_build_page():
    """Serve the Nim Build/Run IDE page (text input + Build/Run buttons)."""
    return render_template("nim-build.html")


@app.route("/healthz")
def healthz():
    """Simple health check endpoint."""
    return jsonify(status="ok", service="clang-flask")


@app.route("/api/info")
def info():
    """Report which dist files are present (handy for debugging)."""
    files = {}
    for sub, names in (
        ("clang", ("clang.js", "clang.wasm", "lld.wasm", "memfs.wasm", "sysroot.tar")),
        ("nim", ("nim.js", "nim.wasm")),
    ):
        d = os.path.join(app.static_folder, sub)
        for name in names:
            path = os.path.join(d, name)
            if os.path.exists(path):
                files[f"{sub}/{name}"] = os.path.getsize(path)
            else:
                files[f"{sub}/{name}"] = None
    return jsonify(dist=files)


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "5000"))
    debug = os.environ.get("FLASK_DEBUG", "0") == "1"
    log.info("Starting clang-flask on port %d (debug=%s)", port, debug)
    app.run(host="0.0.0.0", port=port, debug=debug, threaded=True)
