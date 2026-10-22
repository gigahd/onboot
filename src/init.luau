--!strict
--[[
    A simple module to load any Module or Service you might need.
]]

local verbose = false

local function mergeInto<T, V>(target: { [T]: V }, source: { [T]: V }): { [T]: V }
    for k, v in source do
        if target[k] ~= nil then
            warn(`[OnBoot] Duplicate module name "{k}" overwriting`)
        end
        target[k] = v
    end
    return target
end

type PredicateFn = (module: ModuleScript) -> boolean
type ModuleFunction = (...any) -> ()
type ModuleDict = { [string]: ModuleFunction }
type ModuleDef = ModuleFunction | ModuleDict
type LoadedModulesState = { [string]: ModuleDef }
type Spawn = typeof(task.spawn)

local LoadedModules = {
    __add = mergeInto,
}

export type LoadedModules = setmetatable<LoadedModulesState, typeof(LoadedModules)>

local function getModuleChildren(parent: Instance): { ModuleScript }
    local children = parent:GetChildren()
    local out = {}
    for _, child in children do
        if child:IsA("ModuleScript") then
            table.insert(out, child)
        end
    end
    return out
end

local function rootIsInstance(root: Instance): boolean
    return typeof(root) == "Instance"
end

local function resolveSingleRootStartup(
    root: Instance,
    predicate: PredicateFn?,
    queryDescendants: boolean
): LoadedModules
    assert(rootIsInstance(root), `Root is not an Instance got type {typeof(root)}`)
    local modules: { ModuleScript } = if queryDescendants
        then root:QueryDescendants("ModuleScript")
        else getModuleChildren(root)
    local out: LoadedModules = setmetatable({}, LoadedModules)
    for _, module in modules do
        if predicate and not predicate(module) then
            continue
        end
        local success, loadedModule = pcall(require, module)
        if success then
            out[module:GetFullName()] = loadedModule
        else
            warn(`Failed to load {module:GetFullName()} \nerror:{loadedModule}`)
        end
    end
    return out
end

local function resolveMultiRootStartup(
    roots: { Instance },
    predicate: PredicateFn?,
    queryDescendants: boolean
): LoadedModules
    for _, root in roots do
        assert(rootIsInstance(root), `Roots includes type other than Instance ({typeof(root)})`)
    end
    local out: LoadedModules = setmetatable({}, LoadedModules)
    for _, root in roots do
        local single = resolveSingleRootStartup(root, predicate, queryDescendants)
        mergeInto(out, single)
    end
    return out
end

local function load(root: Instance | { Instance }, predicate: PredicateFn?, queryDescendants: boolean): LoadedModules
    return if typeof(root) == "table"
        then resolveMultiRootStartup(root, predicate, queryDescendants)
        else resolveSingleRootStartup(root, predicate, queryDescendants)
end

local function loadDescendants(root: Instance | { Instance }, predicate: PredicateFn?): LoadedModules
    debug.profilebegin("Load Descendants")
    local result = load(root, predicate, true)
    debug.profileend()
    return result
end

local function loadChildren(parent: Instance | { Instance }, predicate: PredicateFn?): LoadedModules
    debug.profilebegin("Load Children")
    local result = load(parent, predicate, false)
    debug.profileend()
    return result
end

local function loadSingleModule(module: Instance)
    assert(rootIsInstance(module), `Module is not an Instance got type {typeof(module)}`)
    assert(module.ClassName == "ModuleScript", `Module is not a Module script, got {module.ClassName}`)
    local success, loadedModule = pcall(require, module)
    if success then
        return loadedModule
    else
        warn(`Failed to load {module:GetFullName()} \nerror:{loadedModule}`)
    end
    return nil
end

local function loadModule(module: Instance | { Instance }): LoadedModules
    debug.profilebegin("Load Module")
    local out = setmetatable({}, LoadedModules)
    if typeof(module) == "table" then
        for _, m in module do
            out[m:GetFullName()] = loadSingleModule(m)
        end
    else
        out[module:GetFullName()] = loadSingleModule(module)
    end
    debug.profileend()
    return out
end

const function spawn(name: string, method: ModuleFunction, methodName: string?, module: any)
    debug.setmemorycategory(name)
    const success, err: any = pcall(method, module)
    if not success then
        warn(`[OnBoot] {name}:{if methodName then `:{methodName}` else ""} failed:\n{err}`)
    elseif verbose then
        print(`[OnBoot] Called {name}:{if methodName then `:{methodName}` else ""}`)
    end
end

const function getFunctionIfPossible(module: ModuleDict, methodName: string): ModuleFunction?
    return module[methodName] :: any
end

local function runAllNoCallback(loader: Spawn, modules: LoadedModules, methodName: string?)
    for name, mod in modules do
        local method = nil
        if type(mod) == "function" and not methodName then
            method = mod
        elseif type(mod) == "table" and methodName then
            const func = getFunctionIfPossible(mod, methodName)
            if not func then
                continue
            end
            method = func
        else
            continue
        end
        loader(spawn, name, method :: ModuleFunction, methodName, mod)
    end
end

local function runAllCallback(loader: Spawn, modules: LoadedModules, methodName: string?, callback: () -> ())
    local remaining = 0
    local callbackRan = false
    for name, mod in modules do
        local method = nil
        if type(mod) == "function" and not methodName then
            method = mod
        elseif type(mod) == "table" and methodName then
            const func = getFunctionIfPossible(mod, methodName)
            if not func then
                continue
            end
            method = func
        else
            continue
        end
        remaining += 1
        loader(function()
            spawn(name, method :: ModuleFunction, methodName, mod)
            remaining -= 1
            if remaining == 0 and not callbackRan then
                callbackRan = true
                callback()
            end
        end)
    end
    if remaining == 0 and not callbackRan then
        callbackRan = true
        callback()
        return
    end
end

local function spawnAllNoCallback(modules: LoadedModules, methodName: string?)
    runAllNoCallback(task.spawn, modules, methodName)
end

local function spawnAllCallback(modules: LoadedModules, methodName: string?, callback: () -> ())
    runAllCallback(task.spawn, modules, methodName, callback)
end

local function deferAllNoCallback(modules: LoadedModules, methodName: string?)
    runAllNoCallback(task.defer, modules, methodName)
end

local function deferAllCallback(modules: LoadedModules, methodName: string?, callback: () -> ())
    runAllCallback(task.defer, modules, methodName, callback)
end

local function findName(name: string): PredicateFn
    return function(module)
        return module.Name:find(name, 1, true) ~= nil
    end
end

local function findParentName(parentName: string): PredicateFn
    return function(module)
        return (module.Parent ~= nil and module.Parent.Name:find(parentName, 1, true) ~= nil)
    end
end

local function matchName(name: string): PredicateFn
    return function(module)
        return module.Name:match(name) ~= nil
    end
end

local function matchParentName(parentName: string): PredicateFn
    return function(module)
        return (module.Parent ~= nil and module.Parent.Name:match(parentName) ~= nil)
    end
end

local function spawnAll(modules: LoadedModules, methodName: string?, callback: (() -> ())?)
    if callback then
        return spawnAllCallback(modules, methodName, callback)
    end
    spawnAllNoCallback(modules, methodName)
end

local function deferAll(modules: LoadedModules, methodName: string?, callback: (() -> ())?)
    if callback then
        return deferAllCallback(modules, methodName, callback)
    end
    deferAllNoCallback(modules, methodName)
end

local function phasesRunner(loader: Spawn, modules: LoadedModules, phases: { string }, onComplete: (() -> ())?)
    local function runPhase(i: number)
        if i > #phases then
            if onComplete then
                onComplete()
            end
            return
        end
        runAllCallback(loader, modules, phases[i], function()
            runPhase(i + 1)
            if verbose then
                print(`Phase {phases[i]} Completed`)
            end
        end)
    end
    runPhase(1)
end

local function spawnPhases(modules: LoadedModules, phases: { string }, onComplete: (() -> ())?)
    phasesRunner(task.spawn, modules, phases, onComplete)
end

local function deferPhases(modules: LoadedModules, phases: { string }, onComplete: (() -> ())?)
    phasesRunner(task.defer, modules, phases, onComplete)
end

local function setDebugInfo(state: boolean)
    verbose = state
end

return table.freeze({
    SetDebugInfo = setDebugInfo,
    FindName = findName,
    FindParentName = findParentName,
    MatchParentName = matchParentName,
    MatchName = matchName,
    LoadDescendants = loadDescendants,
    LoadChildren = loadChildren,
    LoadModule = loadModule,
    SpawnAllAsync = spawnAll,
    DeferAllAsync = deferAll,
    SpawnPhasesAsync = spawnPhases,
    DeferPhasesAsync = deferPhases,
})
