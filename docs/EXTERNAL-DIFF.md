# Fastra as an external file comparison tool

Fastra 1.119.0 and later include an executable helper inside the app bundle:

```sh
/Applications/Fastra.app/Contents/Helpers/fastra-diff \
  --read-only --focus-diff \
  --left-label "Original" --right-label "Modified" -- \
  "/path/to/left file.txt" "/path/to/right file.txt"
```

When integrating from another program, launch this executable directly and pass
an argument array. No shell is necessary. Development bundles provide the same
relative path, `Contents/Helpers/fastra-diff`.

## Protocol 1

Exactly two file paths must follow the mandatory `--` separator. Relative paths
are relative to the caller's working directory. Spaces, Unicode and leading
hyphens are ordinary filename characters after the separator. Symbolic links to
readable regular files are accepted; directories and special files are rejected.

| Option | Meaning |
| --- | --- |
| `--left-label TEXT` | Visible name of the left side; defaults to its filename. |
| `--right-label TEXT` | Visible name of the right side; defaults to its filename. |
| `--read-only` | Guarantees that comparison actions cannot write either input. |
| `--focus-diff` | Makes the new comparison window key, activates Fastra and focuses the comparison. |

Each option may occur once. Labels consume the following argument as text,
including text starting with `--`. Unknown options fail visibly. No implicit
positional options, merge mode, output file or wait-until-closed mode exists.
Requests, including JSON encoding overhead, may occupy at most 64 KiB.

Every invocation opens a separate comparison window using Fastra's existing
file-diff renderer. External comparisons in protocol 1 are read-only even when
`--read-only` is omitted. Both inputs remain comparison sources, never editable
document tabs. Save and Save As are disabled while this window is active; no
merge or apply action exists. The window explicitly says “Read-only comparison”.

External comparison windows have no project sidebar. They do not write the
normal sidebar preference or change other open windows. With `--focus-diff`,
the comparison receives focus; without it, the window is shown without asking
macOS to activate Fastra. These transient comparisons are not session-restored.
Closing a comparison does not terminate Fastra by default.

The ordinary text-diff limits still apply: binary files, very large files,
unsupported encodings and excessive differences display an explanation in the
window. Acceptance does not promise that every readable file can be rendered as
a text diff. It also does not freeze files against changes by other programs;
Fastra reads the inputs asynchronously after acceptance.

## Acceptance and errors

The helper communicates through a named local Mach port in the current user
session. It opens no network port. The endpoint is scoped to the app's bundle
identifier and user ID. If no endpoint exists, the helper uses macOS
LaunchServices to open its containing app bundle and waits for readiness.
The endpoint becomes ready after session restoration, so restored windows cannot
take focus back from an accepted comparison. A restoration exceeding the handoff
deadline therefore produces code 6.
Concurrent launches use LaunchServices' normal existing-instance behavior.

A request carries a UUID and an absolute deadline. Retries within one helper
invocation reuse both. Fastra serializes acceptance and opens one window per
request ID. A repeated ID with different content is rejected. Confirmed IDs are
remembered through the deadline plus 60 seconds; a later expired request cannot
create another window. A new helper invocation is a new request, even for the
same two files. The private IPC envelope is not a public integration API; call
the bundled helper.

The overall handoff deadline is **10 seconds**. Exit 0 confirms that Fastra
accepted the request and created its comparison window; calculating and drawing
the diff may still be in progress. It does not wait for the window to close.
The normal successful invocation writes nothing to stdout or stderr.

| Exit | Meaning | stderr diagnostic (after `fastra-diff: `) |
| --- | --- | --- |
| 0 | Accepted, or successful capability query | None |
| 2 | Invalid arguments or oversized request | `Expected options followed by -- and exactly two file paths.` |
| 3 | Missing, unreadable or non-regular input | `An input is missing, unreadable, or not a regular file.` |
| 4 | Unsupported option or protocol version | `Unsupported protocol option or version.` |
| 5 | Invalid containing app or failed macOS launch | `Fastra could not be started.` |
| 6 | Rejected, unavailable or timed-out IPC handoff | `Fastra rejected the request or did not confirm it before the deadline.` |

Every failed normal invocation writes exactly one diagnostic line to stderr and
nothing to stdout. If the app starts but never provides its endpoint, the result
is code 6. If confirmation is lost after acceptance, an error cannot prove that
no window was opened; retries inside the helper are idempotent, but a fresh helper
invocation intentionally represents another comparison.

## Capability detection

```sh
/Applications/Fastra.app/Contents/Helpers/fastra-diff --capabilities --json
```

This exact invocation works without starting Fastra or opening a window. It
writes one JSON object followed by a newline:

```json
{"protocol":1,"fileDiff":true,"readOnly":true,"focusDiff":true,"labels":true,"existingInstanceIpc":true}
```

`protocol` versions the invocation contract, independently of Fastra's product
version. Consumers should check the protocol and the capabilities they require.

## Build and verification

`app/build.sh` compiles the native helper and copies it into `Contents/Helpers`.
`app/sign-bundle.sh` signs it before signing the outer app. The portability gate
checks executability and runs capability detection. No machine-specific build
path is needed to locate the containing app.

After building:

```sh
cd app
./test.sh
./selftest.sh externaldiff
./external-diff-test.sh
```

The self-test exercises the real helper against the running app, concurrent and
repeated Mach messages, rendered differences, labels, command targeting and
unchanged input bytes and normal windows. The Python runner uses an isolated
bundle copy under `.build`, separate bundle IDs and preferences. It tests real
LaunchServices cold starts (one and four simultaneous callers), silent acceptance,
capabilities without a startable app, codes 2–6 and a missing-endpoint timeout.
The runner briefly opens test windows; run it in an available desktop session.
It never installs a test bundle into `/Applications`.
