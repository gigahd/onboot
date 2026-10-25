const fs = require("@lune/fs")
const luau = require("@lune/luau")
const process = require("@lune/process")
const task = require("@lune/task")

const source = fs.readFile("src/init.luau")

type Fake = {
    Name: string,
    ClassName: string,
    Parent: Fake?,
    children: { Fake },
    [string]: any,
}

const function newWorld()
    const instances: { [any]: boolean } = {}
    const definitions: { [any]: { value: any?, err: string? } } = {}
    const warnings: { string } = {}
    const prints: { string } = {}

    const function newInstance(className: string, name: string, parent: Fake?): Fake
        const inst: Fake = { Name = name, ClassName = className, Parent = parent, children = {} }
        function inst:IsA(class: string)
            return self.ClassName == class
        end
        function inst:GetFullName()
            if self.Parent then
                return `{self.Parent:GetFullName()}.{self.Name}`
            end
            return self.Name
        end
        function inst:GetChildren()
            return table.clone(self.children)
        end
        function inst:QueryDescendants(class: string)
            const out = {}
            const function walk(node)
                for _, child in node.children do
                    if child.ClassName == class then
                        table.insert(out, child)
                    end
                    walk(child)
                end
            end
            walk(self)
            return out
        end
        if parent then
            table.insert(parent.children, inst)
        end
        instances[inst] = true
        return inst
    end

    const function newModule(name: string, parent: Fake?, value: any, err: string?): Fake
        const inst = newInstance("ModuleScript", name, parent)
        definitions[inst] = { value = value, err = err }
        return inst
    end

    const fakeDebug = table.clone(debug) :: any
    fakeDebug.profilebegin = function() end
    fakeDebug.profileend = function() end
    fakeDebug.setmemorycategory = function() end
    fakeDebug.resetmemorycategory = function() end

    const env = {
        typeof = function(value)
            if instances[value] then
                return "Instance"
            end
            return typeof(value)
        end,
        require = function(module)
            const def = definitions[module]
            if def.err then
                error(def.err)
            end
            return def.value
        end,
        warn = function(...)
            table.insert(warnings, table.concat({ ... }, " "))
        end,
        print = function(...)
            table.insert(prints, table.concat({ ... }, " "))
        end,
        debug = fakeDebug,
        task = task,
    }

    const OnBoot = luau.load(source, { debugName = "OnBoot", environment = env })()

    return {
        OnBoot = OnBoot,
        newInstance = newInstance,
        newModule = newModule,
        warnings = warnings,
        prints = prints,
    }
end

const function hasWarning(world, pattern: string): boolean
    for _, message in world.warnings do
        if message:find(pattern, 1, true) then
            return true
        end
    end
    return false
end

const function expect(condition: any, message: string)
    if not condition then
        error(message, 2)
    end
end

const function expectEqual(actual: any, expected: any, label: string)
    if actual ~= expected then
        error(`{label}: expected {tostring(expected)}, got {tostring(actual)}`, 2)
    end
end

const tests: { { name: string, fn: () -> () } } = {}
const function test(name: string, fn: () -> ())
    table.insert(tests, { name = name, fn = fn })
end

test("LoadChildren only loads direct ModuleScript children keyed by full name", function()
    const w = newWorld()
    const root = w.newInstance("Folder", "Root")
    w.newModule("A", root, { tag = "a" })
    w.newInstance("Script", "NotAModule", root)
    const sub = w.newInstance("Folder", "Sub", root)
    w.newModule("B", sub, { tag = "b" })

    const loaded = w.OnBoot.LoadChildren(root)
    expectEqual(loaded["Root.A"].tag, "a", "Root.A")
    expectEqual(loaded["Root.Sub.B"], nil, "Root.Sub.B")
end)

test("LoadDescendants recurses and applies predicates", function()
    const w = newWorld()
    const root = w.newInstance("Folder", "Root")
    const services = w.newInstance("Folder", "Services", root)
    w.newModule("DataService", services, {})
    w.newModule("Util", root, {})

    const all = w.OnBoot.LoadDescendants(root)
    expect(all["Root.Services.DataService"] ~= nil, "descendant missing")
    expect(all["Root.Util"] ~= nil, "child missing")

    const filtered = w.OnBoot.LoadDescendants(root, w.OnBoot.FindName("Service"))
    expect(filtered["Root.Services.DataService"] ~= nil, "FindName missed match")
    expectEqual(filtered["Root.Util"], nil, "FindName non-match")

    const byParent = w.OnBoot.LoadDescendants(root, w.OnBoot.MatchParentName("^Serv"))
    expect(byParent["Root.Services.DataService"] ~= nil, "MatchParentName missed match")
    expectEqual(byParent["Root.Util"], nil, "MatchParentName non-match")
end)

test("failed require warns with prefix and is skipped", function()
    const w = newWorld()
    const root = w.newInstance("Folder", "Root")
    w.newModule("Broken", root, nil, "boom")
    w.newModule("Fine", root, {})

    const loaded = w.OnBoot.LoadChildren(root)
    expectEqual(loaded["Root.Broken"], nil, "broken module")
    expect(loaded["Root.Fine"] ~= nil, "fine module missing")
    expect(hasWarning(w, "[OnBoot] Failed to load Root.Broken"), "missing load warning")
    expect(hasWarning(w, "boom"), "missing error message")
end)

test("LoadModule validates input before using it", function()
    const w = newWorld()
    const ok, err = pcall(w.OnBoot.LoadModule, { "not an instance" } :: any)
    expect(not ok, "expected an error")
    expect(tostring(err):find("Module is not an Instance", 1, true), `unhelpful error: {err}`)
end)

test("multi-root load warns on duplicates", function()
    const w = newWorld()
    const root = w.newInstance("Folder", "Root")
    const sub = w.newInstance("Folder", "Sub", root)
    w.newModule("A", sub, {})

    w.OnBoot.LoadDescendants({ root, sub })
    expect(hasWarning(w, `Duplicate module name "Root.Sub.A"`), "missing duplicate warning")
end)

test("__add returns a new table without mutating operands", function()
    const w = newWorld()
    const aFolder = w.newInstance("Folder", "A")
    w.newModule("X", aFolder, {})
    const a = w.OnBoot.LoadChildren(aFolder)
    const bFolder = w.newInstance("Folder", "B")
    w.newModule("Y", bFolder, {})
    const b = w.OnBoot.LoadChildren(bFolder)

    const merged = a + b
    expect(merged ~= a and merged ~= b, "merge returned an operand")
    expect(merged["A.X"] ~= nil and merged["B.Y"] ~= nil, "merged missing entries")
    expectEqual(a["B.Y"], nil, "left operand mutated")
    expect(getmetatable(merged) == getmetatable(a), "merged lost metatable")
end)

test("SpawnAll calls methods with self, skips non-functions, and orders by priority then name", function()
    const w = newWorld()
    const order = {}
    const selfSeen = {}
    const root = w.newInstance("Folder", "Root")
    const function makeService(name: string, priority: number?)
        const service = { Priority = priority }
        function service.Init(self)
            table.insert(order, name)
            selfSeen[name] = self == service
        end
        w.newModule(name, root, service)
    end
    makeService("C")
    makeService("A")
    makeService("B", 10)
    w.newModule("Flag", root, { Init = true })

    local done = 0
    w.OnBoot.SpawnAll(w.OnBoot.LoadChildren(root), "Init", function()
        done += 1
    end)

    expectEqual(table.concat(order, ","), "B,A,C", "call order")
    expect(selfSeen.A and selfSeen.B and selfSeen.C, "self not passed")
    expectEqual(done, 1, "callback count")
    expect(not hasWarning(w, "attempt to call"), "non-function field was called")
end)

test("function modules run without receiving themselves", function()
    const w = newWorld()
    const root = w.newInstance("Folder", "Root")
    local received = "unset"
    const function fn(arg)
        received = if arg == fn then "self" else tostring(arg)
    end
    w.newModule("Fn", root, fn)

    w.OnBoot.SpawnAll(w.OnBoot.LoadChildren(root))
    expectEqual(received, "nil", "function module argument")
end)

test("errors are reported with a traceback and don't block the callback", function()
    const w = newWorld()
    const root = w.newInstance("Folder", "Root")
    w.newModule("Bad", root, {
        Init = function()
            error("init exploded")
        end,
    })
    w.newModule("Good", root, { Init = function() end })

    local done = false
    w.OnBoot.SpawnAll(w.OnBoot.LoadChildren(root), "Init", function()
        done = true
    end)

    expect(done, "callback did not fire")
    expect(hasWarning(w, "[OnBoot] Root.Bad:Init failed:"), "bad log format")
    expect(hasWarning(w, "init exploded"), "missing error message")
    expect(hasWarning(w, "function Init"), "missing traceback")
    expect(not hasWarning(w, "::"), "double colon in log")
end)

test("DeferAll callback waits for yielding methods and fires once", function()
    const w = newWorld()
    const root = w.newInstance("Folder", "Root")
    const finished = {}
    w.newModule("Slow", root, {
        Init = function()
            task.wait(0.05)
            finished.Slow = true
        end,
    })
    w.newModule("Fast", root, {
        Init = function()
            finished.Fast = true
        end,
    })

    local calls = 0
    local sawBoth = false
    w.OnBoot.DeferAll(w.OnBoot.LoadChildren(root), "Init", function()
        calls += 1
        sawBoth = finished.Slow == true and finished.Fast == true
    end)
    task.wait(0.2)
    expectEqual(calls, 1, "callback count")
    expect(sawBoth, "callback fired before all methods finished")
end)

test("SpawnAllAsync yields until every method finishes", function()
    const w = newWorld()
    const root = w.newInstance("Folder", "Root")
    local finished = false
    w.newModule("Slow", root, {
        Start = function()
            task.wait(0.05)
            finished = true
        end,
    })

    local callbackFired = false
    w.OnBoot.SpawnAllAsync(w.OnBoot.LoadChildren(root), "Start", function()
        callbackFired = true
    end)
    expect(finished, "returned before method finished")
    expect(callbackFired, "callback not fired")
end)

test("SpawnAllAsync returns immediately when nothing yields", function()
    const w = newWorld()
    const root = w.newInstance("Folder", "Root")
    w.newModule("Sync", root, { Start = function() end })
    w.OnBoot.SpawnAllAsync(w.OnBoot.LoadChildren(root), "Start")
    w.OnBoot.SpawnAllAsync(w.OnBoot.LoadChildren(w.newInstance("Folder", "Empty")), "Start")
end)

test("phases run strictly in order and the Async variant yields", function()
    const w = newWorld()
    const root = w.newInstance("Folder", "Root")
    const log = {}
    for _, name in { "A", "B" } do
        w.newModule(name, root, {
            Init = function()
                task.wait(if name == "A" then 0.05 else 0)
                table.insert(log, `{name}.Init`)
            end,
            Start = function()
                table.insert(log, `{name}.Start`)
            end,
        })
    end

    w.OnBoot.SetVerbose(true)
    w.OnBoot.DeferPhasesAsync(w.OnBoot.LoadChildren(root), { "Init", "Start" })
    expectEqual(#log, 4, "phase call count")
    expect(log[3]:find("Start") and log[4]:find("Start"), `Start ran before Init finished: {table.concat(log, ",")}`)

    local phaseLogged = false
    for _, message in w.prints do
        if message:find("[OnBoot] Phase Init completed", 1, true) then
            phaseLogged = true
        end
    end
    expect(phaseLogged, "missing phase log")
end)

test("warns about methods that are still pending after the timeout", function()
    const w = newWorld()
    const root = w.newInstance("Folder", "Root")
    w.newModule("Hang", root, {
        Init = function()
            task.wait(0.3)
        end,
    })

    w.OnBoot.SetWarnTimeout(0.05)
    w.OnBoot.SpawnAll(w.OnBoot.LoadChildren(root), "Init")
    task.wait(0.15)
    expect(hasWarning(w, "Still waiting after 0.05s on:"), "missing hang warning")
    expect(hasWarning(w, "Root.Hang:Init"), "hang warning missing module")
end)

test("no hang warning when everything finishes in time", function()
    const w = newWorld()
    const root = w.newInstance("Folder", "Root")
    w.newModule("Quick", root, {
        Init = function()
            task.wait(0.01)
        end,
    })

    w.OnBoot.SetWarnTimeout(0.1)
    w.OnBoot.SpawnAll(w.OnBoot.LoadChildren(root), "Init")
    task.wait(0.2)
    expect(not hasWarning(w, "Still waiting"), "unexpected hang warning")
end)

local failures = 0
for _, case in tests do
    const ok, err = pcall(case.fn)
    if ok then
        print(`PASS  {case.name}`)
    else
        failures += 1
        print(`FAIL  {case.name}\n      {err}`)
    end
end

print(`\n{#tests - failures}/{#tests} passed`)
process.exit(if failures == 0 then 0 else 1)
