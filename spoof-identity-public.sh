#!/usr/bin/env bash
#
# tools/spoof-identity-public.sh
#
# Rewrites the identifying strings in this repository's checked-out source so a built APK's
# applicationId, AGP namespace, and locally-built native library names no longer match a fixed,
# blockable package identity. Confined to the source/build inputs a built APK is actually
# assembled from; touches no other repository.
#
# Deliberately leaves the app label and every user-visible "BakaSU"/"KernelSU" brand string
# untouched. Detection and blocklisting key on the package identifier (and the signing
# certificate, which this script never touches), not on the label shown in Settings or the
# launcher, so a general-purpose build gains nothing from also disguising the brand, and loses
# something real: the app stops reading as what it is to someone who installed it on purpose.
#
# Covers:
#   - applicationId / AGP namespace / Kotlin+Java+AIDL package tree (dot, slash, and underscore
#     forms: source files, baseline-profile class descriptors, and the one JNI exported symbol
#     derived from the package name)
#   - the two locally-built native libraries (CMake target names + the Kotlin lookup of them)
#   - the versionName "-spoofed" suffix a spoofed-build path may add (dropped outright, along
#     with the now-dead flag that guards it)
#
# Does not cover: the app label/display name, any "BakaSU"/"KernelSU" brand string, launcher
# icon artwork, the ksu:// URI scheme, the SELinux domain name, or anything inside ksud (a
# prebuilt binary, not source kept in this repository). See the issue thread this script was
# written against for why those are left alone.
#
# Written to run once against a pristine checkout, immediately before a build. Running it a
# second time against an already-converted tree is harmless for the text substitutions (the
# second pass simply finds nothing left to replace) but the directory-move step fails loudly,
# which is the intended signal that there is nothing left to do.
#
# Usage:
#   tools/spoof-identity-public.sh <new.package.name> [--dry-run] [--force]
#
#   <new.package.name>  lowercase dotted identifier, at least two segments (e.g.
#                        calm.tidal.drift).
#   --dry-run            list the files that would be edited; write nothing, move nothing.
#   --force              proceed even if the working tree has uncommitted changes.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

DRY_RUN=0
FORCE=0
NEW_NS=""

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --force) FORCE=1 ;;
        *)
            if [[ -z "$NEW_NS" ]]; then
                NEW_NS="$arg"
            else
                echo "unexpected extra argument: $arg" >&2
                exit 1
            fi
            ;;
    esac
done

if [[ -z "$NEW_NS" ]]; then
    echo "usage: $0 <new.package.name> [--dry-run] [--force]" >&2
    exit 1
fi

if ! [[ "$NEW_NS" =~ ^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$ ]]; then
    echo "error: '$NEW_NS' is not a lowercase, dot-separated identifier with at least two segments" >&2
    exit 1
fi

if [[ $FORCE -eq 0 ]] && [[ -n "$(git status --porcelain)" ]]; then
    echo "error: working tree is not clean; commit/stash first or pass --force" >&2
    exit 1
fi

# --- derived names -----------------------------------------------------------------------

OLD_DOT="org.bakasu.bakasu"
OLD_SLASH="org/bakasu/bakasu"
OLD_US="org_bakasu_bakasu"

OLD_RS_DOT="org.bakasu.rootService"
OLD_RS_SLASH="org/bakasu/rootService"

NEW_DOT="$NEW_NS"
NEW_SLASH="${NEW_NS//./\/}"
NEW_US="${NEW_NS//./_}"

NEW_RS_DOT="${NEW_NS}.rootService"
NEW_RS_SLASH="${NEW_SLASH}/rootService"

# Deterministic, non-descriptive names for the two native libraries this repo builds. Prefixed
# with the first character of the new package's leading segment so the result is a valid
# identifier either way; never prefixed with "lib" here -- CMake's add_library() and
# System.loadLibrary() already add that prefix themselves, so doing it twice would look for
# "liblibXXXX.so" and fail to load.
PKG_FIRST_SEG="${NEW_NS%%.*}"
LIB_PREFIX_CHAR="${PKG_FIRST_SEG:0:1}"
NATIVE_LIB_MAIN="${LIB_PREFIX_CHAR}$(echo -n "${NEW_NS}:main" | sha256sum | cut -c1-10)"
NATIVE_LIB_AUX="${LIB_PREFIX_CHAR}$(echo -n "${NEW_NS}:aux" | sha256sum | cut -c1-10)"

echo "package     : $OLD_DOT -> $NEW_DOT"
echo "rootService : $OLD_RS_DOT -> $NEW_RS_DOT"
echo "native libs : kernelsu -> $NATIVE_LIB_MAIN, adbroot -> $NATIVE_LIB_AUX"
echo "label       : unchanged (brand strings are left alone in this variant)"
echo

# --- file set -----------------------------------------------------------------------------
# Confined to the source/build inputs a built APK is actually assembled from. Deliberately
# excludes upstream/ (tracked byte-for-byte against the kernel-side fork, see UPSTREAM.md),
# .github/, and prose docs (README.md, AGENTS.md, UPSTREAM.md) -- none of those ship in the APK.

INCLUDE_TOP_FILES=(
    build.gradle.kts
    settings.gradle.kts
    gradle.properties
    manager-config.json
    manager-config.example.json
    sign.example.properties
)
INCLUDE_DIRS=(app baselineprofile lint-rules)
EXTS=(kt java xml json cc c h hpp pro properties txt kts aidl)

collect_files() {
    local -a files=()
    for f in "${INCLUDE_TOP_FILES[@]}"; do
        [[ -f "$f" ]] && files+=("$f")
    done
    local -a find_expr=()
    for ext in "${EXTS[@]}"; do
        find_expr+=(-o -name "*.${ext}")
    done
    find_expr=("${find_expr[@]:1}") # drop the leading -o
    for d in "${INCLUDE_DIRS[@]}"; do
        [[ -d "$d" ]] || continue
        while IFS= read -r -d '' f; do
            files+=("$f")
        done < <(find "$d" -type f \( "${find_expr[@]}" \) -not -path '*/build/*' -print0)
    done
    printf '%s\n' "${files[@]}"
}

mapfile -t TARGET_FILES < <(collect_files)
echo "scanning ${#TARGET_FILES[@]} files"

# run_sed <literal-pattern> <literal-replacement>
# Exact substring replacement (never a regex) across every file in TARGET_FILES. Reports
# instead of writing when DRY_RUN=1.
run_sed() {
    local pattern="$1" replacement="$2"
    DRY_RUN="$DRY_RUN" python3 - "$pattern" "$replacement" "${TARGET_FILES[@]}" <<'PY'
import os, sys
pattern, replacement, *files = sys.argv[1:]
dry = os.environ.get("DRY_RUN") == "1"
for path in files:
    with open(path, encoding="utf-8", errors="ignore") as fh:
        text = fh.read()
    if pattern not in text:
        continue
    if dry:
        print(f"  would edit: {path}")
        continue
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text.replace(pattern, replacement))
PY
}

# 1. package tree, most specific form first so a shorter prefix never eats a longer one.
run_sed "$OLD_RS_DOT" "$NEW_RS_DOT"
run_sed "$OLD_RS_SLASH" "$NEW_RS_SLASH"
run_sed "$OLD_DOT" "$NEW_DOT"
run_sed "$OLD_SLASH" "$NEW_SLASH"
run_sed "$OLD_US" "$NEW_US"

# 2. upstream applicationId default, independent of the namespace above.
run_sed "com.resukisu.resukisu" "$NEW_DOT"

# 3. the two native libraries built from app/src/main/cpp in this repo (CMakeLists.txt target
#    names, the Kotlin System.loadLibrary() call, and the Kotlin lookup used to hand ksud a
#    path for --libadbroot). Case-sensitive, lowercase-only, so this never touches "KernelSU".
run_sed "kernelsu" "$NATIVE_LIB_MAIN"
run_sed "adbroot" "$NATIVE_LIB_AUX"

if [[ $DRY_RUN -eq 1 ]]; then
    echo
    echo "dry run only; no files were written, no directories were moved"
    exit 0
fi

# 4. move the package directories to match the new namespace.
move_tree() {
    local old="$1" new="$2"
    [[ -d "$old" ]] || return 0
    mkdir -p "$(dirname "$new")"
    git mv "$old" "$new"
}

move_tree "app/src/main/java/${OLD_SLASH}" "app/src/main/java/${NEW_SLASH}"
move_tree "app/src/main/aidl/${OLD_RS_SLASH}" "app/src/main/aidl/${NEW_RS_SLASH}"

# clean up now-empty parent directories git mv leaves behind on disk
find app/src/main/java app/src/main/aidl -depth -type d -empty -delete 2>/dev/null || true

# the "adbroot" rename above already rewrote CMakeLists.txt's add_library() source-file
# reference from adbroot.cc to "$NATIVE_LIB_AUX.cc" (the pattern is a substring of the
# filename too); move the actual file to match, or the native build can't find it.
if [[ -f "app/src/main/cpp/adbroot.cc" ]]; then
    git mv "app/src/main/cpp/adbroot.cc" "app/src/main/cpp/${NATIVE_LIB_AUX}.cc"
fi

# 5. the spoofed-build versionName leak: drop the "-spoofed" suffix and the now-dead flag.
#    Matched against the exact text known to exist at the time this script was written; it
#    fails loudly instead of silently leaving the leak in place if that text has since moved.
python3 - "$REPO_ROOT/build.gradle.kts" <<'PY'
import sys

path = sys.argv[1]
src = open(path, encoding="utf-8").read()

needle_decl = '\nval isSpoofedBuild = project.findProperty("IS_SPOOFED_BUILD")?.toString()?.toBoolean() ?: false\n'
needle_fn = '''
fun getGitDescribe(): String {
    val desc = providers.exec {
        commandLine("git", "describe", "--tags", "--always", "--abbrev=0")
    }.standardOutput.asText.get().trim()
    if (isSpoofedBuild) {
        return "$desc-spoofed"
    }
    return desc
}
'''
replacement_fn = '''
fun getGitDescribe(): String = providers.exec {
    commandLine("git", "describe", "--tags", "--always", "--abbrev=0")
}.standardOutput.asText.get().trim()
'''

if needle_decl not in src or needle_fn not in src:
    sys.stderr.write(
        "error: build.gradle.kts no longer matches the expected isSpoofedBuild/getGitDescribe "
        "text; leaving it untouched. Update this script's needle text to match and re-run.\n"
    )
    sys.exit(1)

src = src.replace(needle_decl, "\n")
src = src.replace(needle_fn, replacement_fn)
open(path, "w", encoding="utf-8").write(src)
PY

echo
echo "done. Review with 'git status' / 'git diff --stat' before handing off to the build+sign step."
