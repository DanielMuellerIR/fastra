/* Eigenständige Dateiliste mit konkurrierendem Textformat für echte Prozess-Drops. */
#include <gtk/gtk.h>
#include <gdk/x11/gdkx.h>
#include <string.h>
static const char *ready_path, *result_path;
static GMainLoop *loop;
static void began(GtkDragSource *source,GdkDrag *drag,gpointer unused) {
    (void)source;(void)unused;g_assert(g_file_set_contents(result_path,"BEGIN",-1,NULL));
    char *formats=gdk_content_formats_to_string(gdk_drag_get_formats(drag));g_printerr("Native file drag formats: %s\n",formats);g_free(formats);
}
static void mapped(GtkWidget *widget, gpointer unused) {
    (void)unused;
    char *value=g_strdup_printf("%lu",(unsigned long)gdk_x11_surface_get_xid(gtk_native_get_surface(GTK_NATIVE(widget))));
    g_assert(g_file_set_contents(ready_path,value,-1,NULL));g_free(value);
}
static void ended(GtkDragSource *source,GdkDrag *drag,gboolean delete_data,gpointer unused) {
    (void)source;(void)unused;
    g_assert(!delete_data);
    const char *result=gdk_drag_get_selected_action(drag)==GDK_ACTION_COPY?"COPY":"CANCEL";
    g_assert(g_file_set_contents(result_path,result,-1,NULL));g_main_loop_quit(loop);
}
int main(int argc,char **argv) {
    if(argc!=5)return 2;
    ready_path=argv[1];result_path=argv[2];gtk_init();
    GtkWidget *window=gtk_window_new();gtk_window_set_title(GTK_WINDOW(window),"Independent native comparison drag");gtk_window_set_default_size(GTK_WINDOW(window),320,120);
    GtkWidget *label=gtk_button_new_with_label("Drag two files (FileList + conflicting text)");gtk_window_set_child(GTK_WINDOW(window),label);
    GFile *files[2]={g_file_new_for_path(argv[3]),g_file_new_for_path(argv[4])};
    GValue value=G_VALUE_INIT;g_value_init(&value,GDK_TYPE_FILE_LIST);g_value_take_boxed(&value,gdk_file_list_new_from_array(files,2));
    char *first=g_file_get_uri(files[0]),*second=g_file_get_uri(files[1]);char *uris=g_strdup_printf("%s\r\n%s\r\n",first,second);g_free(first);g_free(second);
    GBytes *bytes=g_bytes_new_take(uris,strlen(uris));
    GdkContentProvider **providers=g_new(GdkContentProvider *,3);
    providers[0]=gdk_content_provider_new_typed(G_TYPE_STRING,"WRONG LOSSY FILE TEXT");providers[1]=gdk_content_provider_new_for_value(&value);providers[2]=gdk_content_provider_new_for_bytes("text/uri-list",bytes);
    GdkContentProvider *content=gdk_content_provider_new_union(providers,3);g_bytes_unref(bytes);g_value_unset(&value);g_object_unref(files[0]);g_object_unref(files[1]);
    GtkDragSource *source=gtk_drag_source_new();gtk_drag_source_set_actions(source,GDK_ACTION_COPY);gtk_drag_source_set_content(source,content);g_object_unref(content);
    g_signal_connect(source,"drag-begin",G_CALLBACK(began),NULL);g_signal_connect(source,"drag-end",G_CALLBACK(ended),NULL);gtk_widget_add_controller(label,GTK_EVENT_CONTROLLER(source));g_signal_connect(window,"map",G_CALLBACK(mapped),NULL);
    loop=g_main_loop_new(NULL,FALSE);gtk_window_present(GTK_WINDOW(window));g_main_loop_run(loop);gtk_window_destroy(GTK_WINDOW(window));g_main_loop_unref(loop);return 0;
}
