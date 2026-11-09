/* Eigenständiges natives Dropziel: erzwingt die Übergabe zwischen zwei Prozessen. */
#include <gtk/gtk.h>
#include <gdk/x11/gdkx.h>
static const char *ready_path;
static const char *result_path;
static GMainLoop *loop;
static void mapped(GtkWidget *widget, gpointer unused) {
    (void)unused;
    GdkSurface *surface = gtk_native_get_surface(GTK_NATIVE(widget));
    char *value = g_strdup_printf("%lu", (unsigned long)gdk_x11_surface_get_xid(surface));
    g_assert(g_file_set_contents(ready_path, value, -1, NULL));
    g_free(value);
}
static gboolean dropped(GtkDropTarget *target, const GValue *value, double x, double y, gpointer unused) {
    (void)target; (void)x; (void)y; (void)unused;
    GdkFileList *list = g_value_get_boxed(value);
    GSList *files = gdk_file_list_get_files(list);
    g_assert(files && !files->next);
    GFile *file = G_FILE(files->data);
    char *uri = g_file_get_uri(file);
    char *path = g_file_get_path(file);
    char *bytes = NULL; gsize length = 0;
    g_assert(g_file_get_contents(path, &bytes, &length, NULL));
    char *base64 = g_base64_encode((const guchar *)bytes, length);
    GKeyFile *result = g_key_file_new();
    g_key_file_set_string(result, "drop", "uri", uri);
    g_key_file_set_string(result, "drop", "bytes", base64);
    char *data = g_key_file_to_data(result, NULL, NULL);
    g_assert(g_file_set_contents(result_path, data, -1, NULL));
    g_free(data); g_key_file_unref(result); g_free(uri); g_free(path); g_free(bytes); g_free(base64);
    g_main_loop_quit(loop);
    return TRUE;
}
int main(int argc, char **argv) {
    if (argc != 3) return 2;
    ready_path = argv[1]; result_path = argv[2];
    gtk_init();
    GtkWidget *window = gtk_window_new();
    gtk_window_set_title(GTK_WINDOW(window), "Independent native file receiver");
    gtk_window_set_default_size(GTK_WINDOW(window), 350, 150);
    GtkWidget *label = gtk_label_new("Independent native file receiver");
    gtk_window_set_child(GTK_WINDOW(window), label);
    GtkDropTarget *target = gtk_drop_target_new(GDK_TYPE_FILE_LIST, GDK_ACTION_COPY);
    g_signal_connect(target, "drop", G_CALLBACK(dropped), NULL);
    gtk_widget_add_controller(label, GTK_EVENT_CONTROLLER(target));
    g_signal_connect(window, "map", G_CALLBACK(mapped), NULL);
    loop = g_main_loop_new(NULL, FALSE);
    gtk_window_present(GTK_WINDOW(window));
    g_main_loop_run(loop);
    gtk_window_destroy(GTK_WINDOW(window)); g_main_loop_unref(loop);
    return 0;
}
