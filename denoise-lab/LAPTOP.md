# Benchmarking on your own machine

These steps build the Rust CPU denoiser and the GPU denoiser and time them. They are written so a
local Claude Code session (or you) can follow them on Windows, macOS or Linux.

## One-off setup

1. Install Rust from https://rustup.rs (on Windows this also needs the Visual Studio C++ build tools,
   which the installer offers).
2. Install Python 3.11 or newer.
3. Clone the repository and switch to the branch:

       git clone https://github.com/xycoord/obs-shaderfilter
       cd obs-shaderfilter
       git checkout claude/eloquent-franklin-pq7l0v
       cd denoise-lab

4. Make a Python environment and install the tools:

       python -m venv .venv
       .venv\Scripts\activate        (Windows)   or   . .venv/bin/activate   (macOS/Linux)
       pip install maturin numpy scipy

5. Build both crates into that environment:

       cd rust && maturin develop --release && cd ..
       cd gpu && maturin develop --release && cd ..

   The CPU crate is compiled for the machine it is built on (`rust/.cargo/config.toml`).

## Run

    python bench_laptop.py

It prints the GPU it found and the speed of each version at 1080p and 4K, in seconds per megapixel-frame
and frames per second. Copy the output back into the conversation.

If footage/ holds a camera clip it uses real frames; otherwise synthetic ones, which give much the same
timing.
