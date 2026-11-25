#!/usr/bin/env python3
"""A tray item with a dbusmenu, for check.sh. Usage: tray_item.py <watcher name> <log file>.
Registers by path, logs each menu Event as "clicked <id>", and takes
org.kippsrv.TestItem.Change, which drops the separator and renames Open."""
import sys
from gi.repository import Gio, GLib

WATCHER, LOG = sys.argv[1], sys.argv[2]

INTERFACES = Gio.DBusNodeInfo.new_for_xml("""<node>
<interface name="org.kde.StatusNotifierItem">
  <property name="IconName" type="s" access="read"/>
  <property name="Title" type="s" access="read"/>
  <property name="Status" type="s" access="read"/>
  <property name="ItemIsMenu" type="b" access="read"/>
  <property name="Menu" type="o" access="read"/>
  <property name="IconPixmap" type="a(iiay)" access="read"/>
</interface>
<interface name="com.canonical.dbusmenu">
  <method name="GetLayout">
    <arg type="i" direction="in"/><arg type="i" direction="in"/><arg type="as" direction="in"/>
    <arg type="u" direction="out"/><arg type="(ia{sv}av)" direction="out"/>
  </method>
  <method name="Event">
    <arg type="i" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="in"/><arg type="u" direction="in"/>
  </method>
  <method name="AboutToShow"><arg type="i" direction="in"/><arg type="b" direction="out"/></method>
  <signal name="LayoutUpdated"><arg type="u"/><arg type="i"/></signal>
</interface>
<interface name="org.kippsrv.TestItem"><method name="Change"/></interface>
</node>""").interfaces

# 2x2, ARGB in network order: opaque red first
PIXELS = bytes([255, 255, 0, 0] + [255, 0, 255, 0] + [255, 0, 0, 255] + [128, 255, 255, 255])
PROPERTIES = {
    "IconName": GLib.Variant("s", "test-icon"),
    "Title": GLib.Variant("s", "Test Item"),
    "Status": GLib.Variant("s", "Active"),
    "ItemIsMenu": GLib.Variant("b", True),
    "Menu": GLib.Variant("o", "/Menu"),
    "IconPixmap": GLib.Variant("a(iiay)", [(2, 2, PIXELS)]),
}

changed = False


def entry(identifier, properties, children=()):
    return GLib.Variant("(ia{sv}av)", (identifier, properties, list(children)))


# The root as GetLayout's struct; each child an entry() variant.
def layout():
    s, b, i = (lambda value: GLib.Variant("s", value)), (lambda value: GLib.Variant("b", value)), (lambda value: GLib.Variant("i", value))
    children = [entry(1, {"label": s("Re_named" if changed else "_Open")})]
    if not changed:
        children.append(entry(2, {"type": s("separator")}))
    children.append(entry(3, {"label": s("Check"), "toggle-type": s("checkmark"), "toggle-state": i(1)}))
    children.append(entry(4, {"label": s("More"), "children-display": s("submenu")},
                          [entry(5, {"label": s("Inner"), "enabled": b(False)})]))
    children.append(entry(6, {"label": s("Hidden"), "visible": b(False)}))
    return (0, {}, children)


def method(connection, sender, path, interface, member, parameters, invocation):
    global changed
    if member == "GetLayout":
        invocation.return_value(GLib.Variant("(u(ia{sv}av))", (2 if changed else 1, layout())))
    elif member == "Event":
        with open(LOG, "a") as log:
            log.write("clicked %d\n" % parameters[0])
        invocation.return_value(None)
    elif member == "AboutToShow":
        invocation.return_value(GLib.Variant("(b)", (False,)))
    elif member == "Change":
        changed = True
        invocation.return_value(None)
        connection.emit_signal(None, "/Menu", "com.canonical.dbusmenu", "LayoutUpdated", GLib.Variant("(ui)", (2, 0)))


def get(connection, sender, path, interface, name):
    return PROPERTIES[name]


bus = Gio.bus_get_sync(Gio.BusType.SESSION)
bus.register_object("/StatusNotifierItem", INTERFACES[0], None, get, None)
bus.register_object("/Menu", INTERFACES[1], method, None, None)
bus.register_object("/Test", INTERFACES[2], method, None, None)
bus.call_sync(WATCHER, "/StatusNotifierWatcher", "org.kde.StatusNotifierWatcher", "RegisterStatusNotifierItem",
              GLib.Variant("(s)", ("/StatusNotifierItem",)), None, Gio.DBusCallFlags.NONE, -1, None)
print(bus.get_unique_name(), flush=True)
GLib.MainLoop().run()
