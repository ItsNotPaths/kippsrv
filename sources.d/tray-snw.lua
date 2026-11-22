-- The tray. kippbus tray owns org.kde.StatusNotifierWatcher and prints
-- tray/<item> lines itself, so this file has no feed and no request: kipp
-- passes through both ways. bus/tray.odin lists the requests it takes.
source { name = "tray", exec = "kippbus tray", retains = "tray/*", takes = "tray/request" }
