# MK750 — native macOS controller.
# Run `just` to list recipes.

set shell := ["bash", "-uc"]

# List the available recipes.
default:
    @just --list

# Build the package in debug configuration.
build:
    swift build

# Run the unit tests.
test:
    swift test

# Compile everything, including tests, and run the test suite.
check: build test

# Build the release app bundle at dist/MK750.app.
bundle:
    ./scripts/bundle.sh

# Bundle, then open the app. The app lives in the menu bar (no Dock icon).
run: bundle
    open dist/MK750.app

# Read the connected keyboard once and print its state as JSON.
# Read-only: sends no SET reports. Exits non-zero when the keyboard is absent.
diagnose:
    swift run MK750 --diagnose

# Remove only generated build outputs.
clean:
    rm -rf -- .build dist
