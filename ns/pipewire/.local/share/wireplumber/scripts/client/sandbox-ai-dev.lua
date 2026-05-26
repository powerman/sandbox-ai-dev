-- WirePlumber access restrictions for sandbox-ai-dev.
--
-- Denies Audio/Source and Audio/Sink/Monitor access
-- to clients connecting through the sandbox socket
-- (tagged with pipewire.sec.socket="pipewire-sandbox-ai-dev").
--
-- This runs after the default access rules (access-default.lua)
-- and overrides specific object permissions for sandbox clients.

local log = Log.open_topic("s-sandbox")

source_nodes = ObjectManager({
    Interest({
        type = "node",
        Constraint({ "media.class", "matches", "Audio/Source*" }),
    }),
    Interest({
        type = "node",
        Constraint({ "media.class", "matches", "Audio/Sink/Monitor*" }),
    }),
})

-- Track all clients and filter in callback to avoid silent constraint mismatch.
all_clients = ObjectManager({
    Interest({ type = "client" }),
})

local function is_sandbox_client(client)
    return client.properties["pipewire.sec.socket"] == "pipewire-sandbox-ai-dev"
end

-- When a sandbox client connects, deny all existing source nodes.
all_clients:connect("object-added", function(om, client)
    if not is_sandbox_client(client) then
        return
    end
    local cid = client["bound-id"]
    for node in source_nodes:iterate() do
        client:update_permissions({ [node["bound-id"]] = "-" })
    end
    log:info(client, "Restricted Audio/Source access for sandbox client " .. cid)
end)

-- When a new source node appears, deny it to all existing sandbox clients.
source_nodes:connect("object-added", function(om, node)
    local nid = node["bound-id"]
    for client in all_clients:iterate() do
        if is_sandbox_client(client) then
            client:update_permissions({ [nid] = "-" })
        end
    end
end)

-- Activate source_nodes first so they are populated when
-- a sandbox client connects and all_clients fires.
source_nodes:activate()
all_clients:activate()
