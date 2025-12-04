#!/usr/bin/env python
"""
Verify that models match migrations.
Fails CI if there are pending model changes not captured in migrations.
"""

import os
import subprocess
import sys
from pathlib import Path


def main() -> int:
    """Check if migrations are in sync with models."""
    print("Checking if migrations are in sync with models...")

    # Generate migration to see if anything is pending
    result = subprocess.run(
        [
            "alembic",
            "revision",
            "--autogenerate",
            "-m",
            "ci_check",
        ],
        capture_output=True,
        text=True,
        check=False,
        env={"PYTHONPATH": "src", **os.environ},
    )

    # Check if any changes detected
    output = result.stdout + result.stderr

    # If the migration was created, there are pending changes
    if "Generating" in output and "ci_check" in output:
        print("❌ Pending model changes not captured in migrations:")
        print(output)

        # Clean up the generated migration file
        for f in Path("alembic/versions").glob("*ci_check*.py"):
            f.unlink()
            print(f"Cleaned up: {f}")

        return 1

    if result.returncode != 0:
        print(f"❌ Alembic command failed: {output}")
        return 1

    print("✅ Models and migrations are in sync")
    return 0


if __name__ == "__main__":
    sys.exit(main())
