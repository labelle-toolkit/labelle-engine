-- The spike behavior, Lua edition (embedded-VM family).
-- Mirrors rust/src/lib.rs exactly: the host asserts both worlds end
-- identical. Raw contract calls on purpose — a real labelle-lua wraps
-- these in `entity:get/set` sugar (see #237's reference API).

local player

function init()
    player = labelle.entity_create()
    labelle.component_set(player, "Position", '{"x":0,"y":0}')
    labelle.event_subscribe("tick_started")
    labelle.log("lua: player " .. player .. " ready")
end

function update(dt)
    -- Receive side: drain the inbox the host filled before this tick.
    while true do
        local ev = labelle.event_poll()
        if ev == "" then break end
        local n = tonumber(string.match(ev, '"n":(%d+)'))
        if n == 4 then
            labelle.component_set(player, "TickLog", '{"last":4}')
            labelle.log("lua: saw tick 4")
        end
    end

    local json = labelle.component_get(player, "Position")
    local x = tonumber(string.match(json, '"x":(-?%d+)'))
    x = x + 10
    labelle.component_set(player, "Position", string.format('{"x":%d,"y":0}', x))

    -- On the third tick: spawn a bullet and tell the world about it.
    if x == 30 then
        local bullet = labelle.entity_create()
        labelle.component_set(bullet, "Bullet", '{"vx":0,"vy":-500}')
        labelle.event_emit("bullet_spawned", string.format('{"owner":%d}', player))
        labelle.log("lua: bullet away")
    end
end
