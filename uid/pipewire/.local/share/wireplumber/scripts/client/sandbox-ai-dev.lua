-- WirePlumber access restrictions for sandbox-ai-dev.
--
-- This user-variant policy intentionally uses the same filenames as the bwrap
-- variant so installing either variant replaces the other instead of mixing both.
--
-- Denies Audio/Source and Audio/Sink/Monitor access
-- to clients connecting through the restricted sandbox socket
-- tagged with pipewire.sec.socket="pipewire-sandbox-ai-dev".
--
-- This runs after the default access rules (access-default.lua)
-- and overrides specific object permissions for sandbox clients.

local log = Log.open_topic("s-sandbox")

local source_nodes = ObjectManager({
    Interest({
        type = "node",
        Constraint({ "media.class", "matches", "Audio/Source*" }),
    }),
    Interest({
        type = "node",
        Constraint({ "media.class", "matches", "Audio/Sink/Monitor*" }),
    }),
})

local all_clients = ObjectManager({
    Interest({ type = "client" }),
})

local function is_sandbox_client(client)
    return client.properties["pipewire.sec.socket"] == "pipewire-sandbox-ai-dev"
end

all_clients:connect("object-added", function(_, client)
    if not is_sandbox_client(client) then
        return
    end
    local cid = client["bound-id"]
    for node in source_nodes:iterate() do
        client:update_permissions({ [node["bound-id"]] = "-" })
    end
    log:info(client, "Restricted Audio/Source access for sandbox client " .. cid)
end)

source_nodes:connect("object-added", function(_, node)
    local nid = node["bound-id"]
    for client in all_clients:iterate() do
        if is_sandbox_client(client) then
            client:update_permissions({ [nid] = "-" })
        end
    end
end)

source_nodes:activate()
all_clients:activate()
