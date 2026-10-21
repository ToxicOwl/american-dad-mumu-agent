from __future__ import annotations

from pathlib import Path
import subprocess


class AdbError(RuntimeError):
    """Raised when ADB does not complete successfully."""


class AdbClient:
    def __init__(self, adb_path: Path, device: str) -> None:
        self.adb_path = adb_path
        self.device = device

    def _run(self, *args: str, timeout: int = 30) -> str:
        if not self.adb_path.is_file():
            raise AdbError(f"ADB was not found: {self.adb_path}")
        try:
            process = subprocess.run(
                [str(self.adb_path), "-s", self.device, *args],
                check=False,
                capture_output=True,
                text=True,
                timeout=timeout,
            )
        except OSError as exc:
            raise AdbError(f"Cannot run ADB: {exc}") from exc
        except subprocess.TimeoutExpired as exc:
            raise AdbError(f"ADB did not finish within {timeout} seconds.") from exc

        output = "\n".join(part for part in (process.stdout.strip(), process.stderr.strip()) if part).strip()
        if process.returncode != 0:
            raise AdbError(output or f"ADB failed with exit code {process.returncode}.")
        return output

    def connect(self) -> str:
        # ADB needs no device selector for connection setup.
        try:
            process = subprocess.run(
                [str(self.adb_path), "connect", self.device],
                check=False,
                capture_output=True,
                text=True,
                timeout=30,
            )
        except OSError as exc:
            raise AdbError(f"Cannot run ADB: {exc}") from exc
        output = "\n".join(part for part in (process.stdout.strip(), process.stderr.strip()) if part).strip()
        if process.returncode != 0:
            raise AdbError(output or f"Could not connect to {self.device}.")
        return output

    def state(self) -> str:
        return self._run("get-state")

    def android_version(self) -> str:
        return self._run("shell", "getprop", "ro.build.version.release")

    def model(self) -> str:
        return self._run("shell", "getprop", "ro.product.model")

    def tap(self, x: int, y: int) -> str:
        """Tap one explicitly supplied screen coordinate on the configured device."""
        if x < 0 or y < 0:
            raise AdbError("Tap coordinates cannot be negative.")
        return self._run("shell", "input", "tap", str(x), str(y), timeout=15)

    def screenshot(self, destination: Path) -> Path:
        """Save a PNG screenshot directly to the local computer using ADB exec-out."""
        if not self.adb_path.is_file():
            raise AdbError(f"ADB was not found: {self.adb_path}")
        destination.parent.mkdir(parents=True, exist_ok=True)
        try:
            process = subprocess.run(
                [str(self.adb_path), "-s", self.device, "exec-out", "screencap", "-p"],
                check=False,
                capture_output=True,
                timeout=30,
            )
        except OSError as exc:
            raise AdbError(f"Cannot run ADB: {exc}") from exc
        except subprocess.TimeoutExpired as exc:
            raise AdbError("Screenshot request did not finish within 30 seconds.") from exc
        if process.returncode != 0:
            message = process.stderr.decode("utf-8", errors="replace").strip()
            raise AdbError(message or "ADB could not capture the emulator screen.")
        if not process.stdout.startswith(b"\x89PNG\r\n\x1a\n"):
            raise AdbError("ADB did not return a PNG screenshot. Is MuMu running?")
        destination.write_bytes(process.stdout)
        return destination
