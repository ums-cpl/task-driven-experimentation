# Tips and Tricks

Short practical advice for using this template effectively.

---

## Before running tasks, do a dry run

Before running tasks (especially large or long-running workflows), it is advisable to do a dry run.
Use the `--dry-run` option so that the runner builds the execution manifest and prints what would be run, without actually submitting or executing anything.
This helps you verify task selection, dependency order, and paths before committing to a full run.

**Example:**

```bash
./run_tasks.sh --dry-run tasks/experiment/
```

See [Template Reference](template-reference.md) for more on `--dry-run`.

---

## Preview then confirm

When you want to inspect the execution manifest and then optionally run it in one step, use `--preview`.
It creates the same on-disk manifest as a normal run, prints it, then asks whether to proceed.
The default answer is no; reply `y` or `yes` to invoke workload managers.
If you abort, the temporary invocation directory under `workload_logs/` is removed.

**Example:**

```bash
./run_tasks.sh --preview tasks/experiment/
```

`--preview` cannot be combined with `--dry-run` or `--clean`.
For non-interactive use, prefer `--dry-run`, or pipe a reply to stdin (for example `printf 'y\n' | ./run_tasks.sh --preview ...`).
