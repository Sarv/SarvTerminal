# Linux Development & Testing (from macOS)

How to build, run, and test the Linux (GTK) app while working on a Mac.

## 1. Compile check (Docker — fastest loop)

Requires Docker Desktop running. First run builds the dev image automatically.

```sh
./scripts/linux/build.sh                      # full GTK app build
./scripts/linux/build.sh -Dtest-filter=hosts  # targeted zig tests, etc.
```

Zig caches persist in named Docker volumes, so incremental builds are fast.
This proves the code compiles and unit tests pass — it does not show the UI.

## 2. See the UI: UTM virtual machine (recommended)

1. Install [UTM](https://mac.getutm.app) (free). Easiest: use UTM's built-in
   **Gallery** Ubuntu desktop image (Create VM → Download from gallery).
   Alternatively download the [Ubuntu Server ARM64 ISO](https://ubuntu.com/download/server/arm)
   — it has no GUI, so after installing run
   `sudo apt install -y ubuntu-desktop^ && sudo reboot` to get GNOME.
2. Create a VM (**Virtualize**, not Emulate; 4+ CPU, 8 GB RAM, 40 GB disk),
   install Ubuntu, then remove the ISO from the VM drive before rebooting.
3. Inside the VM:

```sh
sudo apt update && sudo apt install -y \
  libgtk-4-dev libadwaita-1-dev blueprint-compiler gettext \
  libx11-dev libwayland-dev wayland-protocols pkg-config gcc g++ git curl xz-utils \
  libxml2-utils libgtk4-layer-shell-dev

# Zig (match minimum_zig_version in build.zig.zon)
curl -fsSL https://ziglang.org/download/0.15.2/zig-aarch64-linux-0.15.2.tar.xz | \
  sudo tar -xJ -C /opt && sudo ln -s /opt/zig-*/zig /usr/local/bin/zig

git clone https://github.com/Sarv/SarvTerminal.git && cd SarvTerminal
git checkout feat/linux-ui
zig build run
```

4. To test new commits: `git pull && zig build run`.

> **VM OpenGL note:** the terminal surface renders with OpenGL, and most VMs
> (incl. UTM without 3D accel) can't provide a GL context — you'll see an
> "Unable to acquire an OpenGL context" screen. Force Mesa's software renderer:
> ```sh
> sudo apt install -y libgl1-mesa-dri mesa-utils
> LIBGL_ALWAYS_SOFTWARE=1 zig build run
> ```
> or enable "Hardware OpenGL Acceleration" in UTM → Display. The Sarv dialogs
> (Hosts, Keys, Snippets, Sync…) are plain GTK and render even without GL — open
> them from the ☰ menu.

> Ubuntu 24.04's blueprint-compiler may be older than the required 0.16;
> if the build complains, use Ubuntu 25.04+ or install blueprint-compiler
> from source (`pip install blueprint-compiler` is NOT it — use the
> gitlab.gnome.org/jwestman/blueprint-compiler repo, meson build).

## 3. Quick functional checks: your own Linux server + XQuartz

```sh
brew install --cask xquartz     # once, then log out/in
ssh -X user@your-linux-box
# on the server: install deps as above, clone, then:
zig build run
```

The app window renders on your Mac via X11 forwarding. Slow, but zero VM setup.

## 4. Continuous: GitHub Actions

`.github/workflows/linux.yml` builds every push on Fedora, Ubuntu and Arch,
runs the Zig tests, launches the app under Xvfb and uploads a **screenshot
artifact per distro** — download them from the workflow run page to eyeball
the UI without any local setup.
