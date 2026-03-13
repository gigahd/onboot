--!strict
--[[
    A simple module to load any Module or Service you might need.
]]

local VERBOSE = true

type PredicateFn = (module: ModuleScript) -> boolean
type LoadedModules = { [string]: any }

local function mergeInto<T, V>(target: { [T]: V }, source: { [T]: V }): { [T]: V }
    for k, v in source do
        if target[k] ~= nil then
            warn(`[OnBoot] Duplicate module name "{k}" — overwriting`)
        end
        target[k] = v
    end
    return target
end

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
    local out: LoadedModules = {}
    for _, module in modules do
        if predicate and not predicate(module) then
            continue
        end
        local success, loadedModule = pcall(require, module)
        if success then
            out[module.Name] = loadedModule
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
    local out: LoadedModules = {}
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


local function spawnAllNoCallback(modules: LoadedModules, methodName: string)
    for name, mod in modules do
        local method: any = mod[methodName]
        if not (type(method) == "function") then
            continue
        end
        task.spawn(function()
            debug.setmemorycategory(name)
            local success, err = xpcall(method, function(e)
                return debug.traceback(tostring(e))
            end, mod)
            if not success then
                warn(`[OnBoot] {name}:{methodName} failed:\n{err}`)
            elseif VERBOSE then
                print(`[OnBoot] Called {name}:{methodName}`)
            end
        end)
    end
end

local function spawnAllCallback(modules: LoadedModules, methodName: string, callback: () -> ())
    local remaining = 0
    for _, mod in modules do
        if type(mod[methodName]) == "function" then
            remaining += 1
        end
    end
    if remaining == 0 then
        callback()
        return
    end
    for name, mod in modules do
        local method: any = mod[methodName]
        if type(method) ~= "function" then continue end
        task.spawn(function()
            debug.setmemorycategory(name)
            local success, err = xpcall(method, function(e)
                return debug.traceback(tostring(e))
            end, mod)
            if not success then
                warn(`[OnBoot] {name}:{methodName} failed:\n{err}`)
            elseif VERBOSE then
                print(`[OnBoot] Called {name}:{methodName}`)
            end
            remaining -= 1
            if remaining == 0 then
                callback()
            end
        end)
    end
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

local function spawnAll(modules: LoadedModules, methodName: string, callback: (() -> ())?)
    if callback then
        return spawnAllCallback(modules, methodName, callback)
    end
    spawnAllNoCallback(modules, methodName)
end

return table.freeze({
    FindName = findName,
    FindParentName = findParentName,
    MatchParentName = matchParentName,
    MatchName = matchName,
    LoadDescendants = loadDescendants,
    LoadChildren = loadChildren,
    SpawnAll = spawnAll,
})
