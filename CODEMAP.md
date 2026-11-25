# Code map

| Path | Responsibility |
| --- | --- |
| `src/main.sh` | Selects install, debug or check. Each mode opens its own transcript. |
| `src/lib/common.sh` | Defines the installation layout, interactive input, private directories, service-user execution, environment file operations and HTTPS requests. |
| `src/modes/install.sh` | Collects settings, inspects existing workers, downloads the verified archive, backs up foreign installations, provisions sealed credentials and manages the worker unit. |
| `src/modes/debug.sh` | Enables verbose logging, follows the journal, and schedules restoration through systemd for temporary sessions. |
| `src/modes/check.sh` | Inspects the worker layout and connectivity. An explicitly enabled Delinea test authenticates against an operator-supplied HTTPS endpoint. |
| `tools/build.sh` | Assembles the shared library, alphabetically ordered modes and dispatcher, validates the embedded copies and emits the checksum manifest. |
| `tools/templates/` | Source templates for the bootstrap, paste payload and generated README. |
| `tests/build/`, `tests/check/`, `tests/debug/`, `tests/install/` | Container and systemd tests. The check fixture serves a local test vault over TLS. |

The README lists the current entry points, environment variables and verification procedure. Edit the source and templates, then run `tools/build.sh` to regenerate the artifacts.

## Shared contracts

| Interface | Use |
| --- | --- |
| `kit_main` | Resolves the mode from the first argument, `KIT_MODE`, or the interactive menu. Its call is the last line of the assembled script. |
| `kit_ask`, `kit_ask_secret`, `kit_pick` | Read prompts from `/dev/tty`. Use the hidden prompt for credentials. Automation supplies named variables. |
| `kit_confirm_typed` | Gates replacement of a foreign installation. In automation the operator sets `KIT_REPLACE=yes`. |
| `ok`, `warn`, `fail`, `kit_summary` | Record counters, print the summary and return the mode's result. `kit_die` exits immediately with an explanation. |
| `kit_on_exit`, `kit_secret_register` | Register cleanup and secret variables. The shared exit trap runs handlers in reverse order. Quote path arguments when registering shell commands. |
| `kit_as_worker` | Runs service-owned commands with the worker's identity and a minimal environment. Pass credentials on stdin. |
| `kit_envfile_update`, `kit_envfile_set`, `kit_envfile_unset` | Replace complete assignments atomically and preserve unrelated multiline records. Privileged callers select a protected directory and validate the destination. |
| `kit_http` | Returns the body in `HB`, HTTP status in `HC`, and curl exit code in `HE`. Check both status values before using a response. |

## Extending a mode

Private install, debug and check functions use the `inst_`, `dbg_` and `chk_` prefixes. Keep mode dispatch in `src/main.sh` and shared functions in `src/lib/common.sh`. Document operator inputs with `# @env NAME  description` in the mode file. The build generates the environment table in the README.

Keep runtime shell features compatible with Bash 4.2 and systemd 219 on the oldest supported hosts. The build checks the generated scripts for Bash syntax, tab characters, carriage returns and paste line length.

## Test harness

`tests/run.sh` discovers `tests/<group>/<name>.sh`. The tests run in individual disposable Linux containers with the repository mounted read-only at `/kit`. Filter with `-i IMAGE` and `-t PATTERN`. Tests return 0 for a pass and 77 for a skip. The runner stores output under `tests/.work/logs/`.

Check-mode fixtures provide a worker, a vault and its loopback TLS endpoint. Installer tests check archive handling and decrypt backups with a temporary recipient key. `tests/run-systemd.sh` runs each service lifecycle suite in a fresh systemd container, including restoration after interruption.
