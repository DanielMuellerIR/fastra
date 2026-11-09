/* Privater Gegenpart für echte Zustellungsfehler; keine Produktanwendung. */
#include <gio/gio.h>
#include <stdio.h>
#include <stdlib.h>

static int reply_code;

static void deliver(GDBusConnection *connection, const gchar *sender,
                    const gchar *path, const gchar *interface, const gchar *method,
                    GVariant *parameters, GDBusMethodInvocation *invocation,
                    gpointer user_data) {
    (void)connection; (void)sender; (void)path; (void)interface;
    (void)method; (void)parameters; (void)user_data;
    if (reply_code == 999) {
        /* Die absichtlich offene Antwort bleibt bis zum Ende des Testprozesses erhalten. */
        g_object_ref(invocation);
        return;
    }
    g_dbus_method_invocation_return_value(invocation, g_variant_new("(i)", reply_code));
}

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    reply_code = atoi(argv[1]);
    GError *error = NULL;
    GDBusConnection *connection = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, &error);
    if (!connection) return 8;
    GVariant *reply = g_dbus_connection_call_sync(connection, "org.freedesktop.DBus",
        "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName",
        g_variant_new("(su)", "org.fastra.Fastra.Development", 4),
        G_VARIANT_TYPE("(u)"), G_DBUS_CALL_FLAGS_NONE, 2000, NULL, &error);
    guint ownership = 0;
    if (!reply) return 8;
    g_variant_get(reply, "(u)", &ownership);
    g_variant_unref(reply);
    if (ownership != 1) return 8;
    GDBusNodeInfo *info = g_dbus_node_info_new_for_xml(
        "<node><interface name='org.fastra.Diff1'><method name='Deliver'>"
        "<arg type='s' direction='in'/><arg type='i' direction='out'/>"
        "</method></interface></node>", &error);
    if (!info) return 8;
    GDBusInterfaceVTable table = {deliver, NULL, NULL, {0}};
    if (!g_dbus_connection_register_object(connection,
        "/org/fastra/Fastra/Development/Diff", info->interfaces[0],
        &table, NULL, NULL, &error)) return 8;
    puts("READY");
    fflush(stdout);
    GMainLoop *loop = g_main_loop_new(NULL, FALSE);
    g_main_loop_run(loop);
    return 0;
}
