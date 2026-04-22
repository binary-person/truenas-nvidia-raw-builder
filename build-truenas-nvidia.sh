#!/usr/bin/env bash
set -euo pipefail

cd "${SCALE_BUILD_DIR:-/opt/scale-build}"

if [[ -z "${NVIDIA_DRIVER_RUN_URL:-}" ]]; then
  echo "ERROR: NVIDIA_DRIVER_RUN_URL must be set" >&2
  exit 1
fi

case "${NVIDIA_KERNEL_MODULE_TYPE:-}" in
  "" ) ;;
  open|proprietary ) ;;
  * )
    echo "ERROR: NVIDIA_KERNEL_MODULE_TYPE must be one of: open, proprietary" >&2
    exit 1
    ;;
esac

echo "==> Environment"
echo "TRUENAS_VERSION=${TRUENAS_VERSION:-}"
echo "TRUENAS_TRAIN=${TRUENAS_TRAIN:-}"
echo "NVIDIA_DRIVER_RUN_URL=${NVIDIA_DRIVER_RUN_URL}"
echo "NVIDIA_KERNEL_MODULE_TYPE=${NVIDIA_KERNEL_MODULE_TYPE:-}"

echo "==> Patching scale_build/extensions.py for direct .run URL"
python3 - <<'PY'
import re
from pathlib import Path

p = Path("scale_build/extensions.py")
s = p.read_text()

download_pattern = re.compile(
    r"(?ms)^    def download_nvidia_driver\(self\):\n.*?(?=^    def install_nvidia_driver\(self, kernel_version\):)"
)

download_replacement = """    def download_nvidia_driver(self):
        from urllib.parse import urlparse, unquote

        driver_url = os.environ.get("NVIDIA_DRIVER_RUN_URL")
        if not driver_url:
            raise RuntimeError("NVIDIA_DRIVER_RUN_URL must be set")

        parsed = urlparse(driver_url)
        filename = os.path.basename(unquote(parsed.path))

        if not filename:
            raise RuntimeError(
                f"Could not extract filename from NVIDIA_DRIVER_RUN_URL: {driver_url}"
            )

        if not filename.endswith(".run"):
            raise RuntimeError(
                f"Driver filename must end with .run, got: {filename}"
            )

        result = f"{self.chroot}/{filename}"
        self.run(["wget", "-c", "-O", f"/{filename}", driver_url])

        os.chmod(result, 0o755)

        return result

"""

install_pattern = re.compile(
    r"(?ms)^    def install_nvidia_driver\(self, kernel_version\):\n.*?(?=^\S|\Z)"
)

install_replacement = """    def install_nvidia_driver(self, kernel_version):
        driver = self.download_nvidia_driver()

        module_type = os.environ.get("NVIDIA_KERNEL_MODULE_TYPE")
        if module_type and module_type not in {"open", "proprietary"}:
            raise RuntimeError(
                "NVIDIA_KERNEL_MODULE_TYPE must be one of: open, proprietary"
            )

        installer_args = [
            f"/{os.path.basename(driver)}",
            "--skip-module-load",
            "--silent",
            f"--kernel-name={kernel_version}",
            "--allow-installation-with-running-driver",
            "--no-rebuild-initramfs",
        ]

        if module_type:
            installer_args.append(f"--kernel-module-type={module_type}")

        self.run(installer_args)

        os.unlink(driver)

"""

s2, n1 = download_pattern.subn(download_replacement, s, count=1)
if n1 != 1:
    raise SystemExit("Could not patch download_nvidia_driver")

s3, n2 = install_pattern.subn(install_replacement, s2, count=1)
if n2 != 1:
    raise SystemExit("Could not patch install_nvidia_driver")

p.write_text(s3)
print("Patched scale_build/extensions.py")
PY

echo "==> Starting build"
make update

echo "==> Extracting nvidia.raw"
rm -rf /tmp/truenas-rootfs
mkdir -p /tmp/truenas-rootfs /out
rm -f /out/nvidia.raw /out/rootfs.squashfs /out/nvidia.raw.sha256

unsquashfs -dest /tmp/truenas-rootfs ./tmp/update/rootfs.squashfs

cp /tmp/truenas-rootfs/usr/share/truenas/sysext-extensions/nvidia.raw /out/nvidia.raw
cp ./tmp/update/rootfs.squashfs /out/rootfs.squashfs

sha256sum /out/nvidia.raw | tee /out/nvidia.raw.sha256

echo "==> Done"
ls -lh /out
