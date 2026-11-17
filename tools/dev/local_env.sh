# This PC's own paths for the developer tools, from tools/dev/local.env (git-ignored; copy local.env.example to start).
# Sourced by env.sh and slot_guard.sh:   . tools/dev/local_env.sh || exit 1
# Sets and exports ML_TEST_ROOT, ML_SLOTS, ML_REPO in Windows form (the PowerShell tools and sigcheck read them too).
# A variable already set in the environment wins over the file. Where local.env is looked for, in this order:
#   $ML_LOCAL_ENV, this checkout's tools/dev/local.env, the main checkout's (a git worktree has none of its own).
ml_local_env() {
  local dev f="" common line k v miss=""
  dev="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [ -n "${ML_LOCAL_ENV:-}" ]; then f="$ML_LOCAL_ENV"
  elif [ -f "$dev/local.env" ]; then f="$dev/local.env"
  else
    common="$(cd "$dev" && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
    [ -n "$common" ] && f="$(cygpath -u "$(dirname "$common")")/tools/dev/local.env"
  fi
  if [ -n "$f" ] && [ -f "$f" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line%$'\r'}"
      case "$line" in ''|\#*) continue;; esac
      k="${line%%=*}"; v="${line#*=}"
      k="${k//[[:space:]]/}"
      v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
      v="${v#\"}"; v="${v%\"}"; v="${v#\'}"; v="${v%\'}"
      case "$k" in ML_TEST_ROOT|ML_SLOTS|ML_REPO) [ -n "${!k:-}" ] || printf -v "$k" '%s' "$v";; esac
    done < "$f"
  fi
  for k in ML_TEST_ROOT ML_SLOTS ML_REPO; do
    v="${!k:-}"
    case "$(cygpath -u "$v" 2>/dev/null)" in /*) ;; *) miss="$miss $k";; esac
  done
  # the slot helpers delete folders inside ML_SLOTS and loop over its paths word by word: only a folder named
  # *_ml_slots* with no space in its path is accepted (the same idea as the _ml_test guard of down)
  if [ -n "${ML_SLOTS:-}" ] && [ -z "$miss" ]; then
    v="$(cygpath -u "$ML_SLOTS")"
    case "$v" in *[[:space:]]*) miss="$miss ML_SLOTS(has a space)";; esac
    case "$(basename "${v%/}")" in *_ml_slots*) ;; *) miss="$miss ML_SLOTS(its folder name must contain _ml_slots)";; esac
  fi
  if [ -n "$miss" ]; then
    echo "local.env: not set, not an absolute path, or refused:$miss" >&2
    if [ -n "$f" ] && [ -f "$f" ]; then echo "  read: $f" >&2; else echo "  no local.env found${f:+ (looked for $f)}" >&2; fi
    echo "  Copy tools/dev/local.env.example to tools/dev/local.env and fill in this PC's paths (tools/dev/README.md, First-time setup)." >&2
    return 1
  fi
  ML_TEST_ROOT="$(cygpath -w "$ML_TEST_ROOT")"; ML_SLOTS="$(cygpath -w "$ML_SLOTS")"; ML_REPO="$(cygpath -w "$ML_REPO")"
  export ML_TEST_ROOT ML_SLOTS ML_REPO
}
ml_local_env
