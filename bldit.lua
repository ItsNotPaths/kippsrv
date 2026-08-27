-- pkgit build file. https://git.symlinx.net/pkgit
--
-- Odin is the only declared dependency. It is in few distribution repos, and
-- nothing else here is a library: `default` links libsystemd, which a systemd
-- machine already has, and `static` builds basu from its own pinned commit
-- through the Makefile.

bldit_version   = "1.2.0"
package_version = "0.1"

dependencies = {
  odin = {
    url     = "https://github.com/odin-lang/Odin",
    version = "HEAD",
    target  = "default",
  },
}

local function install()
  return os.execute(
    "install -Dm755 kippsrv " .. prefix .. "/bin/kippsrv && " ..
    "mkdir -p " .. prefix .. "/share/kippsrv/lua && " ..
    "cp -r lua/. " .. prefix .. "/share/kippsrv/lua/")
end

local function uninstall()
  return os.execute(
    "rm -f " .. prefix .. "/bin/kippsrv && " ..
    "rm -rf " .. prefix .. "/share/kippsrv")
end

targets = {
  -- sd-bus out of libsystemd.
  default = {
    build     = function() return os.execute("make") end,
    install   = install,
    uninstall = uninstall,
  },

  -- sd-bus out of basu, linked in, so the binary needs no D-Bus library at
  -- all. This is the form to package. It needs meson, ninja and gperf.
  static = {
    build     = function() return os.execute("make static") end,
    install   = install,
    uninstall = uninstall,
  },
}
