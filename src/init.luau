--!strict
--[=[
    @class OnBoot

    A simple module to load any Module or Service you might need.

    ```lua
    local services = OnBoot.LoadDescendants(ServerScriptService.Services, OnBoot.FindName("Service"))
    OnBoot.SpawnPhasesAsync(services, { "Init", "Start" })
    ```
]=]

local verbose = false
local warnTimeout = 5

--[=[
    @type PredicateFn (module: ModuleScript) -> boolean
    @within OnBoot

    Decides whether a ModuleScript should be loaded.
]=]
export type PredicateFn = (module: ModuleScript) -> boolean

--[=[
    @type ModuleFunction (...any) -> ...any
    @within OnBoot

    A module method, or a module that returns a function.
]=]
export type ModuleFunction = (...any) -> ...any

--[=[
    @type ModuleDict { [string]: any }
    @within OnBoot

    A module that returns a table. Methods named after a phase are called with the table as `self`, and an optional `Priority` number controls start order (higher first, default `0`).
]=]
export type ModuleDict = { [string]: any }

--[=[
    @type ModuleDef ModuleFunction | ModuleDict
    @within OnBoot

    Whatever a loaded ModuleScript returned.
]=]
export type ModuleDef = ModuleFunction | ModuleDict
type LoadedModulesState = { [string]: ModuleDef }
type Spawn = typeof(task.spawn)

const function mergeInto<T, V>(target: { [T]: V }, source: { [T]: V }): { [T]: V }
    for k, v in source do
        if target[k] ~= nil then
            warn(`[OnBoot] Duplicate module name "{k}" overwriting`)
        end
        target[k] = v
    end
    return target
end

const LoadedModules = {}

LoadedModules.__add = function(a: LoadedModulesState, b: LoadedModulesState): LoadedModulesState
    const out = setmetatable({}, LoadedModules)
    mergeInto(out, a)
    mergeInto(out, b)
    return out
end

--[=[
    @type LoadedModules { [string]: ModuleDef }
    @within OnBoot

    Loaded modules keyed by `Instance:GetFullName()`. Two sets can be merged with `a + b`, which returns a new table and warns about duplicate names.
]=]
export type LoadedModules = setmetatable<LoadedModulesState, typeof(LoadedModules)>

const function onError(err: any): string
    return debug.traceback(tostring(err), 2)
end

const function getModuleChildren(parent: Instance): { ModuleScript }
    const children = parent:GetChildren()
    const out = {}
    for _, child in children do
        if child:IsA("ModuleScript") then
            table.insert(out, child)
        end
    end
    return out
end

const function isInstance(value: any): boolean
    return typeof(value) == "Instance"
end

const function tryRequire(module: ModuleScript): (boolean, any)
    const success, loadedModule = xpcall(require, onError, module)
    if not success then
        warn(`[OnBoot] Failed to load {module:GetFullName()}:\n{loadedModule}`)
    end
    return success, loadedModule
end

const function resolveSingleRootStartup(
    root: Instance,
    predicate: PredicateFn?,
    queryDescendants: boolean
): LoadedModules
    assert(isInstance(root), `Root is not an Instance got type {typeof(root)}`)
    const modules: { ModuleScript } = if queryDescendants
        then root:QueryDescendants("ModuleScript")
        else getModuleChildren(root)
    const out: LoadedModules = setmetatable({}, LoadedModules)
    for _, module in modules do
        if predicate and not predicate(module) then
            continue
        end
        const success, loadedModule = tryRequire(module)
        if success then
            out[module:GetFullName()] = loadedModule
        end
    end
    return out
end

const function resolveMultiRootStartup(
    roots: { Instance },
    predicate: PredicateFn?,
    queryDescendants: boolean
): LoadedModules
    for _, root in roots do
        assert(isInstance(root), `Roots includes type other than Instance ({typeof(root)})`)
    end
    const out: LoadedModules = setmetatable({}, LoadedModules)
    for _, root in roots do
        const single = resolveSingleRootStartup(root, predicate, queryDescendants)
        mergeInto(out, single)
    end
    return out
end

const function load(root: Instance | { Instance }, predicate: PredicateFn?, queryDescendants: boolean): LoadedModules
    return if typeof(root) == "table"
        then resolveMultiRootStartup(root, predicate, queryDescendants)
        else resolveSingleRootStartup(root, predicate, queryDescendants)
end

--[=[
    @function LoadDescendants
    @within OnBoot
    @param root Instance | { Instance }
    @param predicate PredicateFn?
    @return LoadedModules

    Requires every ModuleScript descendant of `root`. Modules that fail to load are warned about with a traceback and left out.
]=]
const function loadDescendants(root: Instance | { Instance }, predicate: PredicateFn?): LoadedModules
    debug.profilebegin("Load Descendants")
    const result = load(root, predicate, true)
    debug.profileend()
    return result
end

--[=[
    @function LoadChildren
    @within OnBoot
    @param parent Instance | { Instance }
    @param predicate PredicateFn?
    @return LoadedModules

    Requires the ModuleScripts that are direct children of `parent`. Modules that fail to load are warned about with a traceback and left out.
]=]
const function loadChildren(parent: Instance | { Instance }, predicate: PredicateFn?): LoadedModules
    debug.profilebegin("Load Children")
    const result = load(parent, predicate, false)
    debug.profileend()
    return result
end

const function loadSingleModule(module: Instance): any
    assert(isInstance(module), `Module is not an Instance got type {typeof(module)}`)
    assert(module:IsA("ModuleScript"), `Module is not a Module script, got {module.ClassName}`)
    const success, loadedModule = tryRequire(module)
    return if success then loadedModule else nil
end

--[=[
    @function LoadModule
    @within OnBoot
    @param module Instance | { Instance }
    @return LoadedModules

    Requires one ModuleScript, or an array of them. Errors if any entry is not a ModuleScript.
]=]
const function loadModule(module: Instance | { Instance }): LoadedModules
    debug.profilebegin("Load Module")
    const out: LoadedModules = setmetatable({}, LoadedModules)
    const modules: { Instance } = if typeof(module) == "table" then module else { module }
    for _, m in modules do
        const loadedModule = loadSingleModule(m)
        out[m:GetFullName()] = loadedModule
    end
    debug.profileend()
    return out
end

const function formatCall(name: string, methodName: string?): string
    return if methodName then `{name}:{methodName}` else name
end

const function safeCall(name: string, method: ModuleFunction, methodName: string?, self: ModuleDict?)
    debug.setmemorycategory(name:match("[^%.]+$") or name)
    const success, err: any = xpcall(method, onError, self)
    debug.resetmemorycategory()
    if not success then
        warn(`[OnBoot] {formatCall(name, methodName)} failed:\n{err}`)
    elseif verbose then
        print(`[OnBoot] Called {formatCall(name, methodName)}`)
    end
end

const function resolveMethod(name: string, mod: ModuleDef, methodName: string?): ModuleFunction?
    if methodName == nil then
        return if type(mod) == "function" then mod else nil
    end
    if type(mod) ~= "table" then
        return nil
    end
    const method = mod[methodName]
    if type(method) == "function" then
        return method
    end
    if method ~= nil and verbose then
        warn(`[OnBoot] Skipping {formatCall(name, methodName)}: expected a function, got {typeof(method)}`)
    end
    return nil
end

const function getPriority(mod: ModuleDef): number
    if type(mod) == "table" and type(mod.Priority) == "number" then
        return mod.Priority
    end
    return 0
end

const function orderedNames(modules: LoadedModules): { string }
    const names = {}
    for name in modules do
        table.insert(names, name)
    end
    table.sort(names, function(a, b)
        const priorityA, priorityB = getPriority(modules[a]), getPriority(modules[b])
        if priorityA ~= priorityB then
            return priorityA > priorityB
        end
        return a < b
    end)
    return names
end

const function warnIfPending(pending: { [string]: true }, methodName: string?)
    if warnTimeout <= 0 then
        return
    end
    const timeout = warnTimeout
    task.delay(timeout, function()
        if next(pending) == nil then
            return
        end
        const names = {}
        for name in pending do
            table.insert(names, formatCall(name, methodName))
        end
        table.sort(names)
        warn(`[OnBoot] Still waiting after {timeout}s on:\n{table.concat(names, "\n")}`)
    end)
end

const function runAll(loader: Spawn, modules: LoadedModules, methodName: string?, callback: (() -> ())?)
    const pending: { [string]: true } = {}
    local remaining = 1
    const function finishOne()
        remaining -= 1
        if remaining == 0 and callback then
            callback()
        end
    end
    for _, name in orderedNames(modules) do
        const mod = modules[name]
        const method = resolveMethod(name, mod, methodName)
        if not method then
            continue
        end
        const fn: ModuleFunction = method
        const self: ModuleDict? = if type(mod) == "table" then mod else nil
        remaining += 1
        pending[name] = true
        loader(function()
            safeCall(name, fn, methodName, self)
            pending[name] = nil
            finishOne()
        end)
    end
    if next(pending) ~= nil then
        warnIfPending(pending, methodName)
    end
    finishOne()
end

const function phasesRunner(loader: Spawn, modules: LoadedModules, phases: { string }, onComplete: (() -> ())?)
    const function runPhase(i: number)
        if i > #phases then
            if onComplete then
                onComplete()
            end
            return
        end
        runAll(loader, modules, phases[i], function()
            if verbose then
                print(`[OnBoot] Phase {phases[i]} completed`)
            end
            runPhase(i + 1)
        end)
    end
    runPhase(1)
end

const function awaitCompletion(start: (done: () -> ()) -> (), callback: (() -> ())?)
    const thread = coroutine.running()
    local finished = false
    local yielded = false
    start(function()
        finished = true
        if callback then
            callback()
        end
        if yielded then
            task.spawn(thread)
        end
    end)
    if not finished then
        yielded = true
        coroutine.yield()
    end
end

--[=[
    @function SpawnAll
    @within OnBoot
    @param modules LoadedModules
    @param methodName string? -- Method to call on table modules; omit to call function modules instead
    @param callback (() -> ())? -- Called once every method has finished

    Calls `methodName` on every module, each in its own thread via `task.spawn`. Modules start in descending `Priority`, then by name. Errors are warned about with a traceback and still count as finished.
]=]
const function spawnAll(modules: LoadedModules, methodName: string?, callback: (() -> ())?)
    runAll(task.spawn, modules, methodName, callback)
end

--[=[
    @function DeferAll
    @within OnBoot
    @param modules LoadedModules
    @param methodName string? -- Method to call on table modules; omit to call function modules instead
    @param callback (() -> ())? -- Called once every method has finished

    Same as [OnBoot.SpawnAll], but starts each method with `task.defer`.
]=]
const function deferAll(modules: LoadedModules, methodName: string?, callback: (() -> ())?)
    runAll(task.defer, modules, methodName, callback)
end

--[=[
    @function SpawnPhases
    @within OnBoot
    @param modules LoadedModules
    @param phases { string } -- Method names to run in order, e.g. `{ "Init", "Start" }`
    @param onComplete (() -> ())? -- Called once the last phase has finished

    Runs each phase with [OnBoot.SpawnAll]. A phase starts only after every method in the previous phase has finished.
]=]
const function spawnPhases(modules: LoadedModules, phases: { string }, onComplete: (() -> ())?)
    phasesRunner(task.spawn, modules, phases, onComplete)
end

--[=[
    @function DeferPhases
    @within OnBoot
    @param modules LoadedModules
    @param phases { string } -- Method names to run in order, e.g. `{ "Init", "Start" }`
    @param onComplete (() -> ())? -- Called once the last phase has finished

    Same as [OnBoot.SpawnPhases], but starts each method with `task.defer`.
]=]
const function deferPhases(modules: LoadedModules, phases: { string }, onComplete: (() -> ())?)
    phasesRunner(task.defer, modules, phases, onComplete)
end

--[=[
    @function SpawnAllAsync
    @within OnBoot
    @yields
    @param modules LoadedModules
    @param methodName string? -- Method to call on table modules; omit to call function modules instead
    @param callback (() -> ())? -- Called once every method has finished, before this returns

    Same as [OnBoot.SpawnAll], but yields until every method has finished.
]=]
const function spawnAllAsync(modules: LoadedModules, methodName: string?, callback: (() -> ())?)
    awaitCompletion(function(done)
        spawnAll(modules, methodName, done)
    end, callback)
end

--[=[
    @function DeferAllAsync
    @within OnBoot
    @yields
    @param modules LoadedModules
    @param methodName string? -- Method to call on table modules; omit to call function modules instead
    @param callback (() -> ())? -- Called once every method has finished, before this returns

    Same as [OnBoot.DeferAll], but yields until every method has finished.
]=]
const function deferAllAsync(modules: LoadedModules, methodName: string?, callback: (() -> ())?)
    awaitCompletion(function(done)
        deferAll(modules, methodName, done)
    end, callback)
end

--[=[
    @function SpawnPhasesAsync
    @within OnBoot
    @yields
    @param modules LoadedModules
    @param phases { string } -- Method names to run in order, e.g. `{ "Init", "Start" }`
    @param onComplete (() -> ())? -- Called once the last phase has finished, before this returns

    Same as [OnBoot.SpawnPhases], but yields until the last phase has finished.
]=]
const function spawnPhasesAsync(modules: LoadedModules, phases: { string }, onComplete: (() -> ())?)
    awaitCompletion(function(done)
        spawnPhases(modules, phases, done)
    end, onComplete)
end

--[=[
    @function DeferPhasesAsync
    @within OnBoot
    @yields
    @param modules LoadedModules
    @param phases { string } -- Method names to run in order, e.g. `{ "Init", "Start" }`
    @param onComplete (() -> ())? -- Called once the last phase has finished, before this returns

    Same as [OnBoot.DeferPhases], but yields until the last phase has finished.
]=]
const function deferPhasesAsync(modules: LoadedModules, phases: { string }, onComplete: (() -> ())?)
    awaitCompletion(function(done)
        deferPhases(modules, phases, done)
    end, onComplete)
end

--[=[
    @function FindName
    @within OnBoot
    @param name string
    @return PredicateFn

    Matches modules whose name contains `name` (plain text, no patterns).
]=]
const function findName(name: string): PredicateFn
    return function(module)
        return module.Name:find(name, 1, true) ~= nil
    end
end

--[=[
    @function FindParentName
    @within OnBoot
    @param parentName string
    @return PredicateFn

    Matches modules whose parent's name contains `parentName` (plain text, no patterns).
]=]
const function findParentName(parentName: string): PredicateFn
    return function(module)
        return (module.Parent ~= nil and module.Parent.Name:find(parentName, 1, true) ~= nil)
    end
end

--[=[
    @function MatchName
    @within OnBoot
    @param name string -- A Luau string pattern
    @return PredicateFn

    Matches modules whose name matches the pattern `name`.
]=]
const function matchName(name: string): PredicateFn
    return function(module)
        return module.Name:match(name) ~= nil
    end
end

--[=[
    @function MatchParentName
    @within OnBoot
    @param parentName string -- A Luau string pattern
    @return PredicateFn

    Matches modules whose parent's name matches the pattern `parentName`.
]=]
const function matchParentName(parentName: string): PredicateFn
    return function(module)
        return (module.Parent ~= nil and module.Parent.Name:match(parentName) ~= nil)
    end
end

--[=[
    @function SetVerbose
    @within OnBoot
    @param state boolean

    Logs every call, every completed phase, and every phase field that is not a function.
]=]
const function setVerbose(state: boolean)
    verbose = state
end

--[=[
    @function SetDebugInfo
    @within OnBoot
    @deprecated 0.7.0 -- Use [OnBoot.SetVerbose] instead.
    @param state boolean
]=]

--[=[
    @function SetWarnTimeout
    @within OnBoot
    @param seconds number -- `0` disables the warning

    Sets how long to wait before warning about methods that are still running. Defaults to `5`.
]=]
const function setWarnTimeout(seconds: number)
    warnTimeout = seconds
end

return table.freeze({
    SetVerbose = setVerbose,
    SetDebugInfo = setVerbose,
    SetWarnTimeout = setWarnTimeout,
    FindName = findName,
    FindParentName = findParentName,
    MatchParentName = matchParentName,
    MatchName = matchName,
    LoadDescendants = loadDescendants,
    LoadChildren = loadChildren,
    LoadModule = loadModule,
    SpawnAll = spawnAll,
    DeferAll = deferAll,
    SpawnPhases = spawnPhases,
    DeferPhases = deferPhases,
    SpawnAllAsync = spawnAllAsync,
    DeferAllAsync = deferAllAsync,
    SpawnPhasesAsync = spawnPhasesAsync,
    DeferPhasesAsync = deferPhasesAsync,
})
