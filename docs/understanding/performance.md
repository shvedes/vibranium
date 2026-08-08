# Performance

Vibranium is designed around fast interactive usage.
The main objective is to minimize unnecessary work in frequently executed components, especially menus, launchers, and background helpers.

## Avoiding unnecessary processes

Creating external processes has overhead. Every command requires process creation and program loading.  
Because Vibranium relies heavily on Bash, many operations use shell built-ins instead of spawning additional utilities.

Example:

```bash
# Avoid:
var=$(echo "$value" | tr 'a-z' 'A-Z')

# Prefer:
var="${value^^}"
```

Common optimizations include:

- Bash parameter expansion instead of `sed` or `awk` for simple transformations.
- Built-in pattern matching instead of additional filtering commands.
- Bash arithmetic instead of external calculators.

External tools are still used when they provide functionality that Bash cannot reasonably replace.

## Avoiding repeated work

Expensive operations are cached or reused whenever possible.
Examples:

- Configuration data is loaded once per process instead of repeatedly reading files.
- Generated data is cached when recalculation is unnecessary.
- Internal libraries avoid repeated filesystem operations.

## Batching external operations

When external commands are required, Vibranium attempts to reduce the number of calls.
Examples:

- Hyprland state is queried in batches instead of through many individual `hyprctl` calls.
- Theme generation handles multiple files in a single operation.
- Long-running operations use background services and signals instead of blocking interactive components.

## Integer-based calculations

Bash has no native floating-point arithmetic.  
For simple calculations, Vibranium uses fixed-point integer values instead of spawning tools such as `bc`.
Example:

```bash
# Represent 5% as 500 hundredths
step=$((5 * 100))

# Perform integer calculation
new=$((current + step))
```

This avoids additional processes while keeping deterministic results.

## Practical impact

These optimizations affect the parts of Vibranium used most often:

- Menus open quickly because generation has minimal overhead.
- Theme changes avoid unnecessary regeneration.
- Background tasks do not block interactive components.
- Status modules remain responsive by avoiding excessive polling.

## Trade-offs

Performance-focused shell code has costs:

- Some implementations are more complex than their naive alternatives.
- Modern Bash features are required.
- Optimized code requires stricter maintenance.

Vibranium prioritizes predictable and consistent performance over the simplest possible implementation.

## Debugging and profiling

Most Vibranium tools provide verbose output and logging.

Useful locations:

```text
~/.cache/vibranium/
```

When optimizing or debugging, measure the actual bottleneck rather than optimizing assumptions.  
The goal is simple: common desktop actions should complete without noticeable delay.
