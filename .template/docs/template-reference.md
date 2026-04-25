# Template Reference

This template centers on `run_tasks.sh`, which executes tasks defined under `tasks/`. Tasks invoke code from `assets/`, optionally inside containers, and are executed by a workload manager (by default `.template/workload_managers/direct.sh` runs tasks sequentially in the current process).

## run_tasks.sh

Used to run tasks.

**Usage:**

```
./run_tasks.sh [OPTIONS] [KEY=VALUE ...] TASK [TASK ...]
```

**KEY=VALUE** pairs are environment overrides. They are **positional and accumulate**: each `KEY=VALUE` applies from that point onward to all subsequent task specs. For example, `FOO=1 task1 FOO=2 BAR=3 task2` gives `task1` the set `{FOO=1}` and `task2` the set `{FOO=2, BAR=3}` (later values win). Overrides are applied after each sourced file (`task_meta.sh`, `run_meta.sh`, `run_env.sh`, `run_deps.sh`) so every file in the chain sees them. If the same task and run are specified twice with different override context (e.g. `FOO=1 tasks/build/gcc FOO=2 tasks/build/gcc`), they run in consecutive stages and the second occurrence overwrites the first in the same run folder.

**TASK** can be:

- A task directory (path to a dir containing `run.sh`)
- A parent directory (recursively finds all descendant dirs with `run.sh`)
- A wildcard (e.g. `tasks/.../*`, `tasks/**`; use `"!(pattern)"` to exclude)

Optional suffix `:TASK_RUNS` overrides the task's `TASK_RUNS` (set in `task_meta.sh`). Examples: `:local`, `:run-{1:10}`, `:run*` (clean only, wildcard). Without suffix: uses the task's `TASK_RUNS`; cleans all runs with `--clean`. TASK_RUNS uses the same format for execute, clean, and dependency specs: comma-separated list of run spec items; each item is a literal with optional `{a,b,c}` (list) and `{start:end}` (range) patterns; multiple patterns expand to cartesian product (last varies fastest). Wildcards `*` and `?` outside `{...}` are supported for clean and dependency specs.

**Options:**


| Option              | Description                                                                                       |
| ------------------- | ------------------------------------------------------------------------------------------------- |
| `--dry-run`         | Create manifest without running; print manifest contents to stdout                                |
| `--clean`           | Remove output folders for specified tasks                                                         |
| `--skip-succeeded`  | Skip task runs that have already succeeded (`.run_success` exists).                               |
| `--skip-verify-def` | Skip verification that container image matches definition file                                    |
| `--include-disabled`    | Run runs even if `RUN_DISABLED` is set in `run_meta.sh`                                           |
| `--include-deps`    | Include missing dependency task runs in the invocation instead of failing                         |


**Examples:**

```bash
./run_tasks.sh tasks/build
./run_tasks.sh --dry-run tasks/experiment/MatMul
./run_tasks.sh tasks/experiment/MatMul/IS1/baseline:run-{1:5}
./run_tasks.sh RUN_WORKLOAD_MANAGER=.template/workload_managers/palmaII-skylake.sh tasks/experiment
./run_tasks.sh --clean tasks/experiment:run1
```

## Tasks

Tasks are defined as a tree under `tasks/`. A task is a directory containing at least `run.sh`; all other files (`task_meta.sh`, `run_meta.sh`, `run_env.sh`, `run_deps.sh`) are optional. Directories under `tasks/` form a hierarchy; any directory with `run.sh` is a task.

A **task** is an abstract definition of work. A **task run** is a concrete instance of that work. One task can have multiple task runs (e.g., repeated experiments).


|               | Task                                        | Task Run                                                                       |
| ------------- | ------------------------------------------- | ------------------------------------------------------------------------------ |
| Purpose       | Abstract definition of work                  | Concrete execution of that work                                                |
| Identified by | Directory containing `run.sh`               | A named run within a task (e.g., `assets`, `run1`)                              |
| Configuration | `task_meta.sh` (hierarchical, root-to-leaf) | `run_meta.sh` (with `$RUN_ID`), then `run_env.sh`                              |
| Execution     | --                                          | `run.sh` (leaf-only, invokes code from `assets/`)                               |
| Dependencies  | --                                          | `run_deps.sh` (hierarchical, writes `RUN_DEPENDENCIES`)                          |


### Task: `task_meta.sh`

`task_meta.sh` files may appear along the path from `tasks/` to a task directory and are sourced in root-to-leaf order. They define the static configuration for a task (which runs exist).

**Available variables** (provided by the framework):


| Variable               | Description                                |
| ---------------------- | ------------------------------------------ |
| `$ASSETS`              | Path to the `assets/` directory             |
| `$TASKS`               | Path to the `tasks/` directory             |
| `$TEMPLATE`            | Path to the `.template/` directory          |
| `$WORKLOAD_MANAGERS`   | Path to the `.template/workload_managers/` directory  |
| `$CONTAINER_MANAGERS`  | Path to the `.template/container_managers/` directory |


**Writable variables** (read by the framework):


| Variable     | Description                                                                                                                              |
| ------------ | ---------------------------------------------------------------------------------------------------------------------------------------- |
| `TASK_RUNS`  | Default runs to execute for this task (e.g. `assets`, `run-{1:10}`). Comma-separated list; each item may use `{a,b,c}` and `{start:end}`.  |

**Priority** (highest to lowest): CLI override where applicable (e.g. `:TASK_RUNS` suffix) > `KEY=VALUE` env override on the command line > value from `task_meta.sh` chain (root-to-leaf) > built-in default (`assets`).


### Run: `run_meta.sh`

`run_meta.sh` files may appear along the path from `tasks/` to a task directory and are sourced in root-to-leaf order **with `RUN_ID` set** to the current run name. They define per-run configuration (container, workload manager, and whether the run is disabled).

**Available variables** (provided by the framework): same as `task_meta.sh`, plus `$RUN_ID` (the current run name).

**Writable variables** (read by the framework):


| Variable                | Description                                                                                                                       |
| ----------------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| `RUN_DISABLED`          | Set to `true` (or `1`, `yes`) to skip this run; skipped unless `--include-disabled` is used                                           |
| `RUN_CONTAINER`         | Container image for this run (e.g. a `.sif` path)                                                                                 |
| `RUN_CONTAINER_DEF`     | Definition file to validate the container against                                                                                  |
| `RUN_CONTAINER_GPU`     | Set to `ON` if the container uses a GPU                                                                                           |
| `RUN_CONTAINER_FLAGS`   | Extra flags passed to the container runtime                                                                                       |
| `RUN_CONTAINER_MANAGER` | Container manager script (default: `.template/container_managers/apptainer.sh`)                                                             |
| `RUN_WORKLOAD_MANAGER`  | Workload manager script for this run (default: `.template/workload_managers/direct.sh`)                                                     |
| `RUN_WORKLOAD_NAME`     | Workload name for the workload manager (e.g. SLURM job name; default: `run_tasks`)                                                 |

**Priority** (highest to lowest): `KEY=VALUE` env override on the command line > value from `run_meta.sh` chain (root-to-leaf) > built-in default.


### Task Run: `run_env.sh`, `run_deps.sh`, `run.sh`

**`run_env.sh`** -- Hierarchical (sourced root-to-leaf). Defines variables and helper functions for the run. Has task_meta.sh, run_meta.sh (with `RUN_ID`), and `RUN_ID` available. Available variables:

| Variable               | Description                                 |
| ---------------------- | ------------------------------------------- |
| `$ASSETS`              | Path to the `assets/` directory             |
| `$TASKS`               | Path to the `tasks/` directory              |
| `$TEMPLATE`            | Path to the `.template/` directory          |
| `$WORKLOAD_MANAGERS`   | Path to the `.template/workload_managers/` directory  |
| `$CONTAINER_MANAGERS`  | Path to the `.template/container_managers/` directory |
| `$RUN_ID`              | Identifier of the current task run          |


**`run_deps.sh`** -- Hierarchical (sourced root-to-leaf). Defines dependencies by writing `RUN_DEPENDENCIES` (array of dependency specs). Has the same data and variables available as `run_env.sh`. Each entry is a task path with an optional `:TASK_RUNS` suffix (same format as TASK_RUNS: comma-separated items, `{a,b,c}` and `{start:end}` patterns, wildcards `*`/`?` outside braces):

- `tasks/task1` -- depends on all runs of task1: every run must have `.run_success`, and at least one run must exist
- `tasks/task1:local` -- depends on the `local` run of task1
- `tasks/task1:run-{1:10}` -- depends on runs `run-1` through `run-10` of task1
- `"tasks/task1:run*"` -- depends on all runs matching `run*` (quote to prevent shell glob expansion)

A dependency is resolved if it is in the current invocation or already has a `.run_success` file on disk. If neither holds, the runner fails with an error listing the unresolved dependencies. Between stages, the runner verifies that all dependency runs have `.run_success` files before proceeding.

**`run.sh`** -- Leaf-only (one per task, required). The entry point for execution; invokes code from `assets/`. Has task_meta.sh, run_meta.sh, and run_env.sh chains available (and `RUN_ID`).

Run folders are identified by framework marker files (`.run_script.sh`, `.run_begin`, `.run_success`, `.run_failed`, `.run_metadata`). These distinguish run output directories from task definition directories when resolving tasks.

## Assets

Assets hold the actual implementation of experiments. Structure is flexible; there is no predefined layout. Write outputs to the current working directory (which is `$RUN_FOLDER`) so the task framework manages data placement.

## Containers

Containers provide a fixed environment for running tasks and document how to build experiments. They are runtime-only: all task output is stored on the host. The framework is agnostic to the container runtime: a **container manager** script (default `.template/container_managers/apptainer.sh`) provides verification and the exec snippet. Set `RUN_CONTAINER`, `RUN_CONTAINER_DEF`, `RUN_CONTAINER_MANAGER`, etc. in `run_meta.sh` per run; the framework exports them as `CONTAINER`, `CONTAINER_DEF`, etc. for the container manager.

## Workload Managers

Execution always goes through a workload manager. `run_tasks.sh` creates a single manifest and invokes workload manager scripts per stage. The default is `.template/workload_managers/direct.sh`, which runs tasks sequentially in the current process (no cluster). For cluster execution, set `RUN_WORKLOAD_MANAGER` and `RUN_WORKLOAD_NAME` in `run_meta.sh` or via `KEY=VALUE` overrides (e.g. `RUN_WORKLOAD_MANAGER=.template/workload_managers/palmaII-gpu4090.sh tasks/...`). Cluster scripts submit jobs to the scheduler (e.g. SLURM). You cannot mix `direct.sh` with other workload managers in the same invocation; the framework errors at manifest creation if both appear.

Several cluster workload manager scripts are provided in the `.template/workload_managers/` directory, categorized by CPU or GPU architecture and expected runtime. Scripts with suffixes like `l`, `xl`, or `xxl` are for longer runtimes; the `compact` script is suited for sequential or low-resource tasks such as compilation. Walltime is hardcoded per script (e.g. `SBATCH_TIME` in each script).

**Interface:** A workload manager script is invoked once per stage:

```bash
./wm_script "$MANIFEST" "$LOG_DIR" "$STAGE"
```

- **$1** = manifest path  
- **$2** = log directory (also contains `wm_job_ids` in cluster mode)  
- **$3** = stage number to process (0, 1, …)

The script parses the manifest, filters to JOB blocks where `STAGE` matches `$3` and `WORKLOAD_MANAGER` matches itself, then for each matching JOB: resolves `DEPENDS` via `wm_job_ids`, submits or runs the job, and appends the mapping to `wm_job_ids`.

**wm_job_ids:** A file `wm_job_ids` in the same directory as the manifest maps manifest JOB ids to workload-manager-specific job ids (e.g. SLURM job ids). Format: one line per submitted job, tab-separated, append-only: `<manifest_job_id>\t<wm_job_id>`. Before submitting, the WM reads this file to resolve `DEPENDS` to concrete job ids (e.g. `#SBATCH --dependency=afterok:...`). After submitting, it appends a new line. `direct.sh` does not use `wm_job_ids`.

**Contract:** The script must (1) fully parse and validate the manifest before submitting any jobs; (2) submit/run only jobs in the given stage whose `WORKLOAD_MANAGER` matches the script; (3) each task run must execute:

```bash
"$TEMPLATE/run_tasks.sh" --array-manifest="$MANIFEST_PATH" --array-job-id=<JOB> --array-task-id=<INDEX>
```

where `<JOB>` is the manifest JOB id and `<INDEX>` is the 0-based run index within that job.

**Manifest format:** Header: `SKIP_VERIFY_DEF` (true/false), then `---`. Then JOB blocks ordered by stage, separated by `---`. Each block:

- `JOB\t<id>` — unique job id
- `STAGE\t<N>` — stage number
- `WORKLOAD_NAME\t<name>` — workload name for the WM (e.g. `#SBATCH --job-name`)
- `WORKLOAD_MANAGER\t<script path>` — script that owns this job
- `DEPENDS\t<comma-separated manifest job ids or empty>`
- Run lines: `<idx>\t<run_name>\t<task_path>[\tKEY=VALUE...]`. PATH is relative to REPOSITORY_ROOT. Per-run overrides appear as extra tab-separated fields.

## Test runner

The declarative test runner in `./.template/run_tests.sh` runs `./run_tasks.sh` against each `.test` file and validates:
- exit code (`EXIT:`)
- stdout/stderr (`STDOUT:` / `STDERR:` or `STDOUT_FILE:` / `STDERR_FILE:`)
- file effects inside the per-test workdir (`FILE_EXISTS:`, `FILE_CONTENT:`, etc.)

Run it from the repository root.

**Usage:**

```bash
./.template/run_tests.sh [GLOB ...]
```

- **No arguments:** discover tests under `tests/` recursively (any `.test` file).
- **With arguments:** run only the tests matched by the provided globs (paths are resolved relative to the current working directory unless absolute).


### Per-test workdir behavior

For each `.test` file, the runner creates a per-test workdir next to the test file:

`<test_directory>/<name>.workdir/`

It is initialized before running directives to provide a clean testing environment:
- a symlink to the template at `.template/` inside the workdir
- a symlink to the repo `assets/` directory at `assets/` inside the workdir
- a copy of the repo `tasks/` directory at `tasks/` inside the workdir

After the test:
- on PASS: the workdir is removed
- on FAIL: the workdir is kept for inspection, and the runner writes a failure log next to the `.test` file

### Failure artifacts

On FAIL, the runner writes `<name>.failed` next to the `.test` file.

For `STDOUT_FILE:` / `STDERR_FILE:` / `FILES_MATCH:` mismatches, the runner also writes an `.actual.*` file beside the expected reference file and points to it from `<name>.failed`.

### `.test` DSL

Directive parsing rules:
- comment lines: lines whose first non-whitespace character is `#`
- blank lines are ignored
- directives are processed in order

Commands:
- `RUN: <args>` starts a command block (invokes `run_tasks.sh` with shell word-splitting of `<args>`)
- `EXIT: <code>` is required after each `RUN:` and asserts the last command’s exit code

Optional expectations (checked after the matching `EXIT:`):
- `STDOUT: ... END_STDOUT` exact stdout block
- `STDOUT_FILE: <path>` compare stdout to a reference file
- `STDERR: ... END_STDERR` exact stderr block
- `STDERR_FILE: <path>` compare stderr to a reference file
- `FILE_EXISTS: <path>` assert a regular file exists under the workdir repo root
- `FILE_NOT_EXISTS: <path>` assert nothing exists under the workdir repo root
- `FILE_CONTENT: <path>` ... `END_FILE_CONTENT` exact file content under the workdir repo root
- `FILES_MATCH: <repo_path> <test_path>` compare a file under the workdir repo root (`repo_path`) to a reference file (`test_path`)

### Path token support

Paths inside directive values may contain the following tokens:
- `$TASKS` (expanded to the workdir `tasks/` directory)
- `$ASSETS` (expanded to the workdir `assets/` directory)
- `$TEST_WORKDIR` (expanded to the absolute path of the current test's workdir)
- `$TEST_NAME` (expanded to `<name>` for the current test)

After token expansion:
- if the resulting path is absolute, it is used as-is
- otherwise the path is resolved relative to the directory containing the `.test` file

For `FILE_*` directives and the `repo_path` side of `FILES_MATCH:`, resolution is the same: after token expansion, non-absolute paths are resolved relative to the directory containing the `.test` file. Use `$TASKS` / `$ASSETS` to refer into the per-test workdir.