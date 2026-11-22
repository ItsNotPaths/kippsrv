-- pkgit build file. https://git.symlinx.net/pkgit
--
-- Odin is the only declared dependency. It is in few distribution repos, and
-- nothing else here is a library: kippbus links libsystemd in `default`, which
-- a systemd machine already has, and `static` builds basu from its own pinned
-- commit through the Makefile. kippsrv links neither.

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
    "install -Dm755 kippbus " .. prefix .. "/bin/kippbus && " ..
    "mkdir -p " .. prefix .. "/share/kippsrv/sources.d && " ..
    "cp sources.d/*.lua " .. prefix .. "/share/kippsrv/sources.d/")
end

local function uninstall()
  return os.execute(
    "rm -f " .. prefix .. "/bin/kippsrv " .. prefix .. "/bin/kippbus && " ..
    "rm -rf " .. prefix .. "/share/kippsrv")
end

targets = {
  -- kippbus with sd-bus out of libsystemd.
  default = {
    build     = function() return os.execute("make") end,
    install   = install,
    uninstall = uninstall,
  },

  -- kippbus with sd-bus out of basu, linked in, so it needs no D-Bus library
  -- at all. This is the form to package. It needs meson, ninja and gperf.
  static = {
    build     = function() return os.execute("make static") end,
    install   = install,
    uninstall = uninstall,
  },
}
