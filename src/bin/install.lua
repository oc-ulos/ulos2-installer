#!/usr/bin/env lua
-- at long last, a ULOS 2 installer --

print([[
Welcome to the ULOS 2 installer.  This program will guide you through installing
ULOS 2 on your computer.

ULOS 2 is a fast, feature-filled Unix-like operating system aiming for general
compatibility with standard LuaPosix programs.  It features robust pre-emptive
multitasking, support for arbitrary executable formats and filesystems, and even
basic shell scripting.
]])

local function printf(...)
  io.write(string.format(...))
end

local function promptYN(thing, yes, no)
  printf("%s ", thing)
  local p = "[" .. (yes and "Y" or "y") .. "/" .. (no and "N" or "n") .. "] "
  local input
  repeat
    io.write(p)
    input = io.read("l")
  until (yes or no) or input:match("^[ynYN]$")

  if input == "" and yes then input = "y" end

  return input == "Y" or input == "y"
end

if not promptYN("Install ULOS 2?", false, true) then
  print("Have a nice day.")
  os.exit(0)
end

print("Checking install requirements...")

local function fail(...)
  io.stderr:write(string.format(...) .. "\n")
  io.stderr:write("Press Enter to quit.\n")
  io.read()
  os.exit(1)
end

local sys = require("syscalls")
local stat = require("posix.sys.stat")
local errno = require("posix.errno")
local dirent = require("posix.dirent")
local component = require("component")

local function promptText(thing, default, canBeEmpty, verify, hide)
  local input
  repeat
    if default then
      printf("%s [%s]: ", thing, default)
    else
      printf("%s: ", thing)
    end

    if hide then sys.ioctl(0, "stty", {echo = false}) end
    input = io.read("*l")
    if hide then sys.ioctl(0, "stty", {echo = true}); io.write("\n") end
  until (verify and verify(input)) or canBeEmpty or #input > 0

  return input
end

-- TODO: maybe support more networking schemes?
local fd = sys.request("http://ulos.pickardayune.com/")
if fd then
  sys.close(fd)
else
  fail("no available internet connection")
end

local tmpAddress = component.invoke(component.list("computer")(), "tmpAddress")
local filesystems = {}
for address in component.list("filesystem") do
  print(address, tmpAddress)
  if address ~= tmpAddress and not component.invoke(address, "isReadOnly") then
    filesystems[#filesystems+1] = {type = "managed", address = address}
  end
end

for dev in dirent.files("/dev") do
  if dev:match("hd[a-z]$") then
    filesystems[#filesystems+1] = {type = "unmanaged", address = "/dev/"..dev}
  end
end

if #filesystems == 0 then
  fail("no suitable filesystems were found")
end

print("The installer will now guide you through setting up a basic system.")

local fs
while true do
  print("Please select a storage device:")

  for i=1, #filesystems do
    printf("%2d. %s\n", i, filesystems[i].address)
  end

  local num = tonumber(promptText("Select one", nil, false, function(x)
    return filesystems[tonumber(x) or 0]
  end))

  print("\n\27[97mAll data on the selected device will be erased.")
  print("\27[91mProceed with caution.\27[39m")
  if promptYN(string.format("Continue with %s?",
      filesystems[num].address:sub(1,8)), true, false) then
    fs = filesystems[num]
    break
  end
end

if fs.type == "unmanaged" then
  print("Creating partitions...")
  os.execute("mkpart -f -l ULOS2 -p 1:label=cldr2,flags=active,type=BOOTCODE,size=16:2:type=SIMPLEFS,label=ulos2root " .. fs.address)
  os.execute("mkfs.sfs -eF -l ulos2root --i-know-what-im-doing "..fs.address.."2")
end

local ok1, _, err1 = stat.mkdir("/install", 0x1FF)
if (not ok1) and err1 ~= errno.EEXIST then
  fail("could not create /install: %s", errno.errno(err1))
end

local ok2, err2 = sys.mount(
  fs.address .. (fs.type=="unmanaged" and 2 or ""),
  "/install")
if not ok2 then
  fail("could not mount filesystem to /install: %s", errno.errno(err2))
end

do
  -- avoid removing files on the installation medium, because we need
  -- init.lua to stick around so the installer can finish.
  local isInstallDevice

  local h, e = io.open("/proc/mounts", "r")
  if not h then
    return fail("failed opening /proc/mounts: %s", e)
  end

  for line in h:lines() do
    if line:match((fs.address:gsub("%-", "%%-"))) then
      isInstallDevice = true
      break
    end
  end
  h:close()

  if not isInstallDevice then
    if not os.execute("rm -rf /install/*") then
      fail("failed clearing filesystem")
    end
  end
end

local packages = { "cldr", "cynosure2", "liblua", "coreutils",
  "reknit", "upt", "vbls" }

if fs.type == "unmanaged" then packages[#packages+1] = "prismbios" end

local install = require("upt.tools.install")
local upti_r = install.install_repo
local upti_l = install.install_local
local uptl = require("upt.tools.list").update

print("Copying UPT configuration")

os.execute("mkdir -p /install/etc/upt")
os.execute("cp /etc/upt/repos /install/etc/upt/repos")

local okl, errl = uptl("/install")
if not okl and errl then
  fail("updating UPT package lists failed: %s", errl)
end

for i=1, #packages do
  local ok, err = upti_r(packages[i], "/install", 3)
  if not ok then
    fail("installing package %s failed: %s", packages[i], err)
  end
end

print("Installing ULOS-specific config files...")
local ok, err = upti_l("/etc/upt/cache/ulos2-config.mtar", "/install", 3)
if not ok then
  fail("installing package ulos2-config failed: %s", err)
end

-- TODO: rework cldr so this is more fluid
if fs.type == "unmanaged" then
  os.execute("dd /install/init.lua " .. fs.address .. "1")
end

print("The base system is now installed.")

print("\nNow we will perform some basic setup.")

local pwd = require("posix.pwd")
local grp = require("posix.grp")
local unistd = require("posix.unistd")

local function inChroot()
  local okc, errc = sys.chroot("/install")
  if not okc then
    fail("chroot to /install failed: %s", errno.errno(errc))
  end

  local function changePassword(name, prompt)
    local password

    while true do
      password = promptText(prompt, nil, false, nil, true)
      if promptText("Confirm the password",nil,false,nil,true) == password then
        break
      else
        print("Passwords do not match")
      end
    end

    local ent = pwd.getpwnam(name)
    ent.pw_passwd = unistd.crypt(password)

    pwd.update_passwd(ent)
  end

  print("First, choose a new root password.")

  changePassword("root", "Enter a new root password")

  print("\nNow you need to set up a user account.")

  do
    local name = promptText("Enter a name for the new account", nil, false,
      function(n)
        return n:match("^[a-z_][a-z0-9_%-]*%$?$") and #n <= 32
      end)

    -- TODO: figure out why `os.execute("useradd ...") wasn't working here
    pwd.update_passwd {
      pw_name = name,
      pw_passwd = "",
      pw_uid = 1,
      pw_gid = 1,
      pw_gecos = "",
      pw_dir = "/home/"..name,
      pw_shell = "/bin/sh.lua"
    }

    grp.update_group {
      gr_name = name,
      gr_gid = 1,
      gr_mem = {name}
    }

    changePassword(name, "Enter a password for the new account")
  end
end

local npid = sys.fork(inChroot)
local reason, status = sys.wait(npid)
if status ~= 0 then
  print("warning: chroot process " .. reason .. " / " .. status)
end

print("Unmounting install filesystem")
local oku, erru = sys.unmount("/install")
if not oku then
  fail("unmount /install failed: %s", errno.errno(erru))
end

print("The system should now be set up and functional.")
print("Remove the installation media and reboot.\n")

print("Or, press ENTER to quit the installer.")
do local _ = io.read() end
