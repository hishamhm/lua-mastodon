package = "lua-mastodon"
version = "0.1-1"
source = {
   url = "git+https://github.com/hishamhm/lua-mastodon.git",
   tag = "0.1",
}
description = {
   detailed = "A Lua API for Mastodon, an open source federated social network.",
   homepage = "https://github.com/hishamhm/lua-mastodon",
   license = "MIT"
}
dependencies = {
   "luafilesystem",
   "lua-requests",
   "split",
   "luasocket",
   "luasec",
   "date",
   "mimetypes",
}
build = {
   type = "builtin",
   modules = {
      mastodon = "mastodon.lua",
   }
}
