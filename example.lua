
local lfs = require("lfs")
local mastodon = require("mastodon")

-- change this to the apprpriate instance, login and username
local instance_url = "https://mastodon.social"
local user_name = "example@example.com"
local user_password = "example123"

if lfs.attributes("secrets.lua") then
   dofile("secrets.lua")
   instance_url, user_name, user_password = get_secrets()
end

if not lfs.attributes("clientcred.txt") then
   local id, err = mastodon.create_app {
      client_name = "Lua Test",
      scopes= { "read", "write" },
      to_file = "clientcred.txt",
      api_base_url = instance_url
   }
   if id then
      print("Successfully registered app - got ID " .. id)
      os.exit(0)
   else
      print("Failed registering app in server :( - error: " .. err)
      os.exit(1)
   end
end

local mclient = mastodon.new {
   client_id = "clientcred.txt",
   api_base_url = instance_url
}
local access, err = mclient:log_in {
   username = user_name,
   password = user_password,
   scopes = { "read", "write" },
   to_file = "usercred.txt"
}
if not access then
   print("Login failed :( - error: " .. err)
   os.exit(1)
end

print("Logged in! :)")

local ok = mclient:toot(arg[1] or "Toot toot from Lua!")
print(ok)
os.exit(0)
