#!/bin/bash
#
# Embeds the Boris engine binary into the app bundle's Resources directory.
#
# Supports:
#   - Universal Mach-O fat binaries (arm64 + x86_64) or automatic lipo merging
#     if discrete single-architecture binaries are available.
#   - Matching codesign identity and hardened runtime options for App Sandbox
#     execution compliance.
#
# Boris search order:
#   1. Explicit env overrides: SOLIPSIST_BORIS_BIN, or SOLIPSIST_BORIS_ARM64_BIN + SOLIPSIST_BORIS_X86_64_BIN
#   2. Prebuilt kits next to this repo (SUPPORT-NOT-FOR-GITHUB / sibling kit)
#   3. Existing zig-out in a boris checkout
#   4. Build from BORIS_REPO_DIR (default: ../boris)
#
# boris-editor + editor UI + oliver are bundled alongside boris so the
# release app ships a working Editor companion and compose preview with no
# env overrides. Missing pieces FAIL the build (same posture as the engine),
# except under SKIP_EMBED_BORIS=1.
#
# Env overrides (all optional, first match wins within each search):
#   BORIS_REPO_DIR, OLIVER_REPO_DIR — engine/editor/oliver source checkouts.
#     Required when SRCROOT is not a sibling of the checkouts (e.g. worktrees);
#     when unset, the boris repo is derived from SOLIPSIST_BORIS_BIN if it
#     points inside a checkout's zig-out/bin, then sibling fallbacks.
#   SOLIPSIST_BORIS_EDITOR_BIN — exact boris-editor binary.
#   SOLIPSIST_EDITOR_UI_DIR — exact compiled editor UI dir (index.html + assets/).
#   SOLIPSIST_OLIVER_BIN — exact oliver binary.
#
# The editor binary builds from source when the checkout has none
# (zig build --build-file editor/build.zig). The editor UI is NEVER npm-built
# here (needs node + network): a missing editor/ui/dist is a hard error with
# remediation instructions.
#
# Oliver (compose preview renderer) is embedded alongside boris so the
# release app renders previews without SOLIPSIST_OLIVER_BIN. Provenance:
# oliver is NOT shipped by the boris agent kit — source it from the oliver
# repo's own build (../oliver/zig-out/bin/oliver) or a kit that carries it.
# Search order: SOLIPSIST_OLIVER_BIN, kit bin dirs, oliver repo zig-out.
#
# Usage: embed-boris.sh SRCROOT DEST_DIR

set -euo pipefail

SRCROOT="${1:?usage: embed-boris.sh SRCROOT DEST_DIR}"
DEST_DIR="${2:?usage: embed-boris.sh SRCROOT DEST_DIR}"

find_prebuilt() {
  if [[ -n "${SOLIPSIST_BORIS_BIN:-}" && -x "${SOLIPSIST_BORIS_BIN}" ]]; then
    echo "${SOLIPSIST_BORIS_BIN}"
    return 0
  fi

  local candidates=(
    "$SRCROOT/SUPPORT-NOT-FOR-GITHUB/boris-agent-kit/boris-agent-kit/bin/boris"
    "$SRCROOT/../boris-agent-kit/bin/boris"
    "$SRCROOT/../boris/zig-out/bin/boris"
    "$SRCROOT/../../boris/zig-out/bin/boris"
    "$SRCROOT/../../../boris/zig-out/bin/boris"
  )
  local c
  for c in "${candidates[@]}"; do
    if [[ -x "$c" ]]; then
      echo "$c"
      return 0
    fi
  done
  return 1
}

find_arch_binaries() {
  local arm_cand=(
    "${SOLIPSIST_BORIS_ARM64_BIN:-}"
    "$SRCROOT/SUPPORT-NOT-FOR-GITHUB/boris-agent-kit/bin/aarch64-macos/boris"
    "$SRCROOT/SUPPORT-NOT-FOR-GITHUB/boris-agent-kit/bin/arm64/boris"
    "$SRCROOT/../boris/zig-out/bin/aarch64-macos/boris"
  )
  local x86_cand=(
    "${SOLIPSIST_BORIS_X86_64_BIN:-}"
    "$SRCROOT/SUPPORT-NOT-FOR-GITHUB/boris-agent-kit/bin/x86_64-macos/boris"
    "$SRCROOT/SUPPORT-NOT-FOR-GITHUB/boris-agent-kit/bin/x86_64/boris"
    "$SRCROOT/../boris/zig-out/bin/x86_64-macos/boris"
  )

  local arm_bin=""
  local x86_bin=""

  for c in "${arm_cand[@]}"; do
    if [[ -n "$c" && -x "$c" ]]; then
      arm_bin="$c"
      break
    fi
  done

  for c in "${x86_cand[@]}"; do
    if [[ -n "$c" && -x "$c" ]]; then
      x86_bin="$c"
      break
    fi
  done

  if [[ -n "$arm_bin" && -n "$x86_bin" ]]; then
    echo "$arm_bin|$x86_bin"
    return 0
  fi
  return 1
}

bundle_and_sign() {
  local target="$DEST_DIR/boris"
  chmod +x "$target"

  local arch_info
  arch_info="$(lipo -archs "$target" 2>/dev/null || echo "unknown")"
  local size_info
  size_info="$(du -h "$target" | cut -f1)"
  echo "embed-boris: bundled $target (arch: $arch_info, size: $size_info)"

  # Codesign matching host application identity & runtime options for App Sandbox execution
  local sign_identity="${EXPANDED_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:--}}"
  if [[ -n "$sign_identity" ]]; then
    echo "embed-boris: signing $target with identity '$sign_identity' (runtime hardened)"
    codesign --force --options runtime --sign "$sign_identity" "$target" 2>/dev/null || {
      echo "embed-boris: notice: ad-hoc signing fallback"
      codesign --force --options runtime --sign - "$target" 2>/dev/null || true
    }
  fi

  # Embed companion binaries (boris-editor, boris-package, boris-source-rag,
  # boris-content-audit) from kit bin dirs when available. A source-built
  # checkout (the documented reproduction path) produces some of them in
  # its zig-out — same trust level as the engine we already take there.
  local comp_candidates=(
    "$SRCROOT/SUPPORT-NOT-FOR-GITHUB/boris-agent-kit/boris-agent-kit/bin"
    "$SRCROOT/SUPPORT-NOT-FOR-GITHUB/boris-agent-kit/bin"
    "$SRCROOT/../boris-agent-kit/bin"
    "${BORIS_REPO_DIR:-$SRCROOT/../boris}/zig-out/bin"
  )
  # Worktree builds: the checkout is rarely $SRCROOT/../boris. Resolve it
  # the same way the editor/oliver lookups do.
  local _resolved_repo=""
  _resolved_repo="$(resolve_boris_repo)" || true
  if [[ -n "$_resolved_repo" ]]; then
    comp_candidates+=("$_resolved_repo/zig-out/bin" "$_resolved_repo/editor/zig-out/bin")
  fi
  local search_index_found=0
  for cdir in "${comp_candidates[@]}"; do
    if [[ -d "$cdir" ]]; then
      for comp in boris-editor boris-package boris-source-rag boris-content-audit; do
        if [[ -x "$cdir/$comp" && ! -f "$DEST_DIR/$comp" ]]; then
          cp "$cdir/$comp" "$DEST_DIR/$comp"
          chmod +x "$DEST_DIR/$comp"
          if [[ -n "$sign_identity" ]]; then
            codesign --force --options runtime --sign "$sign_identity" "$DEST_DIR/$comp" 2>/dev/null || \
            codesign --force --options runtime --sign - "$DEST_DIR/$comp" 2>/dev/null || true
          fi
          echo "embed-boris: bundled companion $comp"
        fi
      done
      # Notice-skip: boris-search-index exists in the kit but the app
      # does not locate or run it — do not embed it.
      if [[ -x "$cdir/boris-search-index" ]]; then
        search_index_found=1
      fi
    fi
  done
  if [[ "$search_index_found" -eq 1 ]]; then
    echo "embed-boris: notice: boris-search-index present in kit but not bundled (unused by app)"
  fi

  bundle_oliver "$sign_identity"
  bundle_editor "$sign_identity"
  bundle_editor_ui
}

# Resolves the boris source checkout: BORIS_REPO_DIR first, then derived
# from SOLIPSIST_BORIS_BIN when it points inside a checkout's zig-out/bin
# (worktree builds), then SRCROOT-relative siblings.
resolve_boris_repo() {
  if [[ -n "${BORIS_REPO_DIR:-}" && -d "${BORIS_REPO_DIR}" ]]; then
    echo "${BORIS_REPO_DIR}"
    return 0
  fi

  if [[ -n "${SOLIPSIST_BORIS_BIN:-}" ]]; then
    local bindir
    bindir="$(dirname "${SOLIPSIST_BORIS_BIN}")"
    if [[ "$(basename "$bindir")" == "bin" && "$(basename "$(dirname "$bindir")")" == "zig-out" ]]; then
      local repo
      repo="$(dirname "$(dirname "$bindir")")"
      if [[ -f "$repo/build.zig" && -d "$repo/editor" ]]; then
        echo "$repo"
        return 0
      fi
    fi
  fi

  local candidates=(
    "$SRCROOT/../boris"
    "$SRCROOT/../../boris"
    "$SRCROOT/../../../boris"
  )
  local c
  for c in "${candidates[@]}"; do
    if [[ -f "$c/build.zig" && -d "$c/editor" ]]; then
      echo "$c"
      return 0
    fi
  done
  return 1
}

# Resolves the oliver source checkout: OLIVER_REPO_DIR first, then a sibling
# of the resolved boris checkout, then SRCROOT-relative siblings.
resolve_oliver_repo() {
  if [[ -n "${OLIVER_REPO_DIR:-}" && -d "${OLIVER_REPO_DIR}" ]]; then
    echo "${OLIVER_REPO_DIR}"
    return 0
  fi

  local boris_repo=""
  boris_repo="$(resolve_boris_repo)" || true
  local candidates=()
  if [[ -n "$boris_repo" ]]; then
    candidates+=("$boris_repo/../oliver")
  fi
  candidates+=(
    "$SRCROOT/../oliver"
    "$SRCROOT/../../oliver"
    "$SRCROOT/../../../oliver"
  )
  local c
  for c in "${candidates[@]}"; do
    if [[ -f "$c/build.zig" ]]; then
      echo "$c"
      return 0
    fi
  done
  return 1
}

find_editor_binary() {
  if [[ -n "${SOLIPSIST_BORIS_EDITOR_BIN:-}" && -x "${SOLIPSIST_BORIS_EDITOR_BIN}" ]]; then
    echo "${SOLIPSIST_BORIS_EDITOR_BIN}"
    return 0
  fi

  local cdir
  for cdir in \
    "$SRCROOT/SUPPORT-NOT-FOR-GITHUB/boris-agent-kit/boris-agent-kit/bin" \
    "$SRCROOT/SUPPORT-NOT-FOR-GITHUB/boris-agent-kit/bin" \
    "$SRCROOT/../boris-agent-kit/bin" \
  ; do
    if [[ -x "$cdir/boris-editor" ]]; then
      echo "$cdir/boris-editor"
      return 0
    fi
  done

  local repo=""
  repo="$(resolve_boris_repo)" || true
  if [[ -n "$repo" ]]; then
    local bin="$repo/editor/zig-out/bin/boris-editor"
    if [[ ! -x "$bin" ]]; then
      echo "embed-boris: building boris-editor (first run takes a few minutes)…"
      (cd "$repo" && zig build --build-file editor/build.zig) || {
        echo "embed-boris: FAILED to build boris-editor from $repo" >&2
        return 1
      }
    fi
    if [[ -x "$bin" ]]; then
      echo "$bin"
      return 0
    fi
  fi
  return 1
}

# The compiled Svelte shell (index.html + assets/) the host serves for
# GET / and /assets/*. Never npm-built here — see header.
find_editor_ui() {
  if [[ -n "${SOLIPSIST_EDITOR_UI_DIR:-}" && -f "${SOLIPSIST_EDITOR_UI_DIR}/index.html" ]]; then
    echo "${SOLIPSIST_EDITOR_UI_DIR}"
    return 0
  fi

  local repo=""
  repo="$(resolve_boris_repo)" || true
  if [[ -n "$repo" ]]; then
    if [[ -f "$repo/editor/ui/dist/index.html" ]]; then
      echo "$repo/editor/ui/dist"
      return 0
    fi
    echo "embed-boris: FAILED: editor UI not built in $repo" >&2
    echo "embed-boris: build it once with:" >&2
    echo "embed-boris:   cd $repo/editor/ui && npm ci && npm run build" >&2
    return 1
  fi
  return 1
}

# Bundles the boris-editor host with the same codesign identity/path as boris.
bundle_editor() {
  local sign_identity="${1:--}"
  if [[ -f "$DEST_DIR/boris-editor" ]]; then
    return 0
  fi
  local editor
  if ! editor="$(find_editor_binary)"; then
    echo "embed-boris: FAILED: no boris-editor binary found" >&2
    echo "embed-boris: set SOLIPSIST_BORIS_EDITOR_BIN or BORIS_REPO_DIR" >&2
    return 1
  fi
  cp "$editor" "$DEST_DIR/boris-editor"
  chmod +x "$DEST_DIR/boris-editor"
  if [[ -n "$sign_identity" ]]; then
    codesign --force --options runtime --sign "$sign_identity" "$DEST_DIR/boris-editor" 2>/dev/null || \
    codesign --force --options runtime --sign - "$DEST_DIR/boris-editor" 2>/dev/null || true
  fi
  echo "embed-boris: bundled boris-editor (provenance: $editor)"
}

# Bundles the compiled editor UI as Resources/editor-ui/.
bundle_editor_ui() {
  if [[ -f "$DEST_DIR/editor-ui/index.html" ]]; then
    return 0
  fi
  local ui
  if ! ui="$(find_editor_ui)"; then
    echo "embed-boris: FAILED: no compiled editor UI found" >&2
    echo "embed-boris: set SOLIPSIST_EDITOR_UI_DIR or BORIS_REPO_DIR" >&2
    return 1
  fi
  mkdir -p "$DEST_DIR/editor-ui"
  cp -R "$ui/." "$DEST_DIR/editor-ui/"
  echo "embed-boris: bundled editor-ui (provenance: $ui)"
}

find_oliver() {
  if [[ -n "${SOLIPSIST_OLIVER_BIN:-}" && -x "${SOLIPSIST_OLIVER_BIN}" ]]; then
    echo "${SOLIPSIST_OLIVER_BIN}"
    return 0
  fi

  # Kit bin dirs (a kit that ships oliver) first, then the oliver repo build.
  # Depth mirrors the boris candidates so both the main checkout and nested
  # worktrees resolve the sibling oliver checkout.
  local candidates=(
    "$SRCROOT/SUPPORT-NOT-FOR-GITHUB/boris-agent-kit/boris-agent-kit/bin/oliver"
    "$SRCROOT/SUPPORT-NOT-FOR-GITHUB/boris-agent-kit/bin/oliver"
    "$SRCROOT/../boris-agent-kit/bin/oliver"
    "$SRCROOT/../oliver/zig-out/bin/oliver"
    "$SRCROOT/../../oliver/zig-out/bin/oliver"
    "$SRCROOT/../../../oliver/zig-out/bin/oliver"
  )
  local c
  for c in "${candidates[@]}"; do
    if [[ -x "$c" ]]; then
      echo "$c"
      return 0
    fi
  done

  local repo=""
  repo="$(resolve_oliver_repo)" || true
  if [[ -n "$repo" ]]; then
    local bin="$repo/zig-out/bin/oliver"
    if [[ ! -x "$bin" ]]; then
      echo "embed-boris: building oliver (first run takes a few minutes)…"
      (cd "$repo" && zig build) || {
        echo "embed-boris: FAILED to build oliver from $repo" >&2
        return 1
      }
    fi
    if [[ -x "$bin" ]]; then
      echo "$bin"
      return 0
    fi
  fi
  return 1
}

# Bundles the oliver renderer with the same codesign identity/path as boris.
# Missing oliver FAILS the build (compose preview depends on it).
bundle_oliver() {
  local sign_identity="${1:--}"
  if [[ -f "$DEST_DIR/oliver" ]]; then
    return 0
  fi
  local oliver
  if ! oliver="$(find_oliver)"; then
    echo "embed-boris: FAILED: no oliver binary found" >&2
    echo "embed-boris: set SOLIPSIST_OLIVER_BIN or OLIVER_REPO_DIR" >&2
    return 1
  fi
  cp "$oliver" "$DEST_DIR/oliver"
  chmod +x "$DEST_DIR/oliver"
  if [[ -n "$sign_identity" ]]; then
    codesign --force --options runtime --sign "$sign_identity" "$DEST_DIR/oliver" 2>/dev/null || \
    codesign --force --options runtime --sign - "$DEST_DIR/oliver" 2>/dev/null || true
  fi
  echo "embed-boris: bundled oliver (provenance: $oliver)"
}

mkdir -p "$DEST_DIR"

# 1. Check if discrete arm64 and x86_64 binaries are available for lipo
if ARCH_PAIR="$(find_arch_binaries)"; then
  ARM_BIN="${ARCH_PAIR%%|*}"
  X86_BIN="${ARCH_PAIR##*|}"
  echo "embed-boris: creating universal fat binary from $ARM_BIN and $X86_BIN"
  lipo -create -output "$DEST_DIR/boris" "$ARM_BIN" "$X86_BIN"
  bundle_and_sign
  exit 0
fi

# 2. Check for prebuilt single or universal binary
if BIN="$(find_prebuilt)"; then
  cp "$BIN" "$DEST_DIR/boris"
  bundle_and_sign
  exit 0
fi

# Explicit opt-out only (ci.yml sets SKIP_EMBED_BORIS=1 for the PR/app
# compile job, which cannot vendor an engine). Release CI now provides
# discrete arm64/x86_64 binaries via SOLIPSIST_BORIS_*_BIN, so it must NOT
# be skipped on GITHUB_ACTIONS: a release without an embedded engine is a
# silent failure.
if [[ "${SKIP_EMBED_BORIS:-}" == "1" ]]; then
  echo "embed-boris: SKIP_EMBED_BORIS=1 — compiling without a bundle"
  exit 0
fi

BORIS_REPO="${BORIS_REPO_DIR:-$SRCROOT/../boris}"
BIN="$BORIS_REPO/zig-out/bin/boris"

if [[ ! -x "$BIN" ]]; then
  echo "embed-boris: building Boris engine (first run takes a few minutes)…"
  (cd "$BORIS_REPO" && zig build) || {
    echo "embed-boris: FAILED to find or build a boris binary" >&2
    echo "embed-boris: set SOLIPSIST_BORIS_BIN or place the agent kit under SUPPORT-NOT-FOR-GITHUB/" >&2
    exit 1
  }
fi

cp "$BIN" "$DEST_DIR/boris"
bundle_and_sign
