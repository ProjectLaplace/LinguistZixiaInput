#!/bin/sh
set -eu

# Serialize commands that share the same Xcode DerivedData directory.
#
# Xcode keeps a build database under DerivedData. Two concurrent xcodebuild
# processes pointed at the same -derivedDataPath can race on that database and
# fail with "database is locked". This wrapper keeps the shared build cache, but
# makes every participating xcodebuild enter it one at a time.
#
# The lock is an atomically-created directory, not a regular file. On local
# filesystems, mkdir succeeds for exactly one process and fails for all others
# while the directory exists, which is enough for this Makefile-level mutex.
if [ "$#" -lt 2 ]; then
    echo "Usage: $0 <lock-dir> <command> [args...]" >&2
    exit 2
fi

lock_dir=$1
shift

mkdir -p "$(dirname "$lock_dir")"

reported_wait=0
while ! mkdir "$lock_dir" 2>/dev/null; do
    if [ -f "$lock_dir/pid" ]; then
        pid=$(cat "$lock_dir/pid" 2>/dev/null || true)
        # If the owner process no longer exists, the previous command likely
        # crashed or was killed before trap cleanup ran. Remove that stale lock
        # so future builds do not wait forever.
        if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
            echo "XCODEBUILD LOCK: removing stale lock from pid $pid" >&2
            rm -f "$lock_dir/pid"
            rmdir "$lock_dir" 2>/dev/null || true
            continue
        fi
    fi
    if [ "$reported_wait" -eq 0 ]; then
        echo "XCODEBUILD LOCK: waiting for $lock_dir" >&2
        reported_wait=1
    fi
    sleep 1
done

# Write the wrapper PID, not the child xcodebuild PID. The wrapper stays alive
# for the whole command, so this is sufficient for stale-lock detection.
echo "$$" >"$lock_dir/pid"

cleanup() {
    rm -f "$lock_dir/pid"
    rmdir "$lock_dir" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# Important boundary: this only protects commands that use the same lock path.
# A raw xcodebuild invocation that bypasses this wrapper can still collide with
# the shared DerivedData database.
"$@"
