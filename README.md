# onboot
A simple way to initiate any module or service you need.

## Installation
Add it to your `wally.toml`:

```toml
[dependencies]
OnBoot = "gigahd/onboot@0.7.0"
```

## Quick start

```luau
local OnBoot = require(ReplicatedStorage.Packages.OnBoot)

local services = OnBoot.LoadDescendants(ServerScriptService.Services, OnBoot.FindName("Service"))

OnBoot.SpawnPhasesAsync(services, { "Init", "Start" })
print("Everything is running")
```

A service is any ModuleScript that returns a table with methods named after your phases:

```luau
local DataService = {}
DataService.Priority = 10

function DataService:Init() end
function DataService:Start() end

return DataService
```

### [Documentation](https://gigahd.github.io/onboot/)

## Loading

Every loader returns a `LoadedModules` table that maps each module's full name (`Instance:GetFullName()`) to whatever it returned. A module that fails to `require` logs a warning with a traceback and is left out.

| Function | Description |
| --- | --- |
| `LoadChildren(parent, predicate?)` | Loads the ModuleScripts that are direct children of `parent`. |
| `LoadDescendants(root, predicate?)` | Loads every ModuleScript descendant of `root`. |
| `LoadModule(module)` | Loads one ModuleScript, or an array of them. |

`parent`/`root` can be an Instance or an array of Instances. Two loaded sets can be merged with `a + b`. This returns a new table, warns about duplicate names and leaves `a` and `b` unchanged.

### Predicates

| Function | Matches when |
| --- | --- |
| `FindName(text)` | the module's name contains `text` |
| `FindParentName(text)` | the parent's name contains `text` |
| `MatchName(pattern)` | the module's name matches the Luau string pattern |
| `MatchParentName(pattern)` | the parent's name matches the Luau string pattern |

A predicate is any `(module: ModuleScript) -> boolean`, so you can write your own.

## Running

| Function | Yields | Description |
| --- | --- | --- |
| `SpawnAll(modules, methodName?, callback?)` | No | Calls `methodName` on every module with `task.spawn`. `callback` runs once all of them have finished. |
| `DeferAll(modules, methodName?, callback?)` | No | Same, but with `task.defer`. |
| `SpawnPhases(modules, phases, onComplete?)` | No | Runs each phase in order. A phase starts only after every method in the previous phase has finished. |
| `DeferPhases(modules, phases, onComplete?)` | No | Same, but with `task.defer`. |
| `SpawnAllAsync` / `DeferAllAsync` / `SpawnPhasesAsync` / `DeferPhasesAsync` | Yes | Same arguments as above, but they yield the calling thread until everything has finished. |

How a module gets called:

- **Table modules**: `methodName` is called as a method (`module:Init()`). Modules without that method are skipped. So are modules whose field isn't a function; with verbose on, those log a warning.
- **Function modules**: these are called directly when no `methodName` is given.
- **Order**: modules start in descending `Priority` (a number field on the module, default `0`), then alphabetically by full name. Each method runs in its own thread, so a yielding method doesn't hold up the others.
- **Errors**: a method that errors logs a warning with a full traceback and still counts as finished, so callbacks and later phases still run.
- **Hangs**: if methods are still running after the warn timeout (5 seconds by default), a warning lists them.

## Settings

| Function | Description |
| --- | --- |
| `SetVerbose(state)` | Logs each call and each completed phase. `SetDebugInfo` is an alias. |
| `SetWarnTimeout(seconds)` | Sets how long to wait before warning about methods that haven't finished. `0` turns the warning off. |

## Development

```sh
rokit install
lune run tests/run.luau
stylua --check src tests
selene src
```