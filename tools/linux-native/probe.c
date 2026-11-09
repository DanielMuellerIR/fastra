#include <gtk/gtk.h>
#include <gtksourceview/gtksource.h>
#include <webkit/webkit.h>
#include <stdio.h>
#include <execinfo.h>
#include <signal.h>
#include <unistd.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <string.h>
static void crashed(int sig) { void *frames[24]; int n=backtrace(frames,24); backtrace_symbols_fd(frames,n,2); _exit(128+sig); }
static GMainLoop *loop;
static int result = 1;
static gboolean finish (gpointer data) { (void)data; g_main_loop_quit (loop); return G_SOURCE_REMOVE; }
static void title_changed (WebKitWebView *web, GParamSpec *spec, gpointer data)
{
  (void)spec; (void)data;
  const char *title = webkit_web_view_get_title (web);
  if (g_strcmp0 (title, "PRIVATE_RUNTIME_JS_OK") == 0)
    {
      result = 0;
      g_print ("RUNTIME_WEBKIT_JS_OK title=%s\n", title);
      fflush (stdout);
      g_timeout_add_seconds (8, finish, NULL);
    }
}
static void check_host_file (const char *path, const char *expected)
{
  gchar *text = NULL; gsize size = 0;
  g_assert_true (g_file_get_contents (path, &text, &size, NULL));
  g_assert_cmpstr (text, ==, expected);
  g_print ("RUNTIME_HOST_BYTES_OK path=%s bytes=%zu\n", path, size);
  g_free (text);
}
static void check_gstreamer (void)
{
  void *library = dlopen ("libgstreamer-1.0.so.0", RTLD_NOW | RTLD_LOCAL);
  g_assert_nonnull (library);
  void (*initialize) (int *, char ***) = dlsym (library, "gst_init");
  gpointer (*find_factory) (const char *) = dlsym (library, "gst_element_factory_find");
  gpointer (*get_plugin) (gpointer) = dlsym (library, "gst_plugin_feature_get_plugin");
  const char *(*get_filename) (gpointer) = dlsym (library, "gst_plugin_get_filename");
  g_assert_nonnull (initialize); g_assert_nonnull (find_factory);
  g_assert_nonnull (get_plugin); g_assert_nonnull (get_filename);
  initialize (NULL, NULL);
  gpointer factory = find_factory ("fakesrc"); g_assert_nonnull (factory);
  gpointer plugin = get_plugin (factory); g_assert_nonnull (plugin);
  const char *filename = get_filename (plugin); g_assert_nonnull (filename);
  g_assert_true (g_str_has_prefix (filename, g_getenv ("GST_PLUGIN_SYSTEM_PATH")));
  g_print ("RUNTIME_GSTREAMER_PRIVATE_PLUGIN_OK path=%s\n", filename);
  g_object_unref (plugin); g_object_unref (factory);
}
int main (void)
{
  signal(SIGSEGV, crashed);
  g_assert_cmpstr (g_getenv ("FASTRA_INTERNAL_HOST_FD"), ==, "3");
  int type = 0; socklen_t type_size = sizeof type;
  g_assert_cmpint (getsockopt (3, SOL_SOCKET, SO_TYPE, &type, &type_size), ==, 0);
  g_assert_cmpint (type, ==, SOCK_STREAM);
  g_assert_cmpint (fcntl (3, F_SETFD, fcntl (3, F_GETFD) | FD_CLOEXEC), ==, 0);
  unsigned int (*capability) (void) = dlsym (RTLD_DEFAULT, "pango_fastra_wrap_capability_v1");
  g_assert_nonnull (capability); g_assert_cmpuint (capability (), ==, 0x46570002u);
  g_print ("RUNTIME_CAPABILITY_OK magic=0x46570002\n");
  check_host_file ("/usr/local/fastra-file-identity-gate.txt", "synthetic host document\n");
  check_host_file ("/usr/share/gtksourceview-5/styles/Adwaita.xml", "<style-scheme id=\"host-fixture\" _name=\"Host fixture\" version=\"1.0\"></style-scheme>\n");
  gtk_init ();
  check_gstreamer ();
  g_print ("RUNTIME_GTK_INITIALIZED\n"); fflush (stdout);
  GtkWidget *window = gtk_window_new ();
  GtkWidget *box = gtk_box_new (GTK_ORIENTATION_VERTICAL, 0);
  GtkWidget *source = gtk_source_view_new ();
  const char *const *languages = gtk_source_language_manager_get_language_ids (gtk_source_language_manager_get_default ());
  unsigned int language_count = 0;
  while (languages && languages[language_count]) language_count++;
  if (language_count < 50) { g_printerr ("RUNTIME_SOURCE_LANGUAGES_MISSING\n"); return 2; }
  GdkPixbuf *pixel = gdk_pixbuf_new (GDK_COLORSPACE_RGB, FALSE, 8, 1, 1);
  gdk_pixbuf_fill (pixel, 0x804020ff);
  const char *formats[] = {"png", "jpeg"};
  for (unsigned int i = 0; i < 2; i++)
    {
      char *bytes = NULL; gsize length = 0; GError *error = NULL;
      if (!gdk_pixbuf_save_to_buffer (pixel, &bytes, &length, formats[i], &error, NULL))
        { g_printerr ("RUNTIME_PIXBUF_ERROR %s\n", error->message); return 2; }
      g_print ("RUNTIME_PIXBUF_OK format=%s bytes=%zu\n", formats[i], length);
      GInputStream *stream = g_memory_input_stream_new_from_data (bytes, length, NULL);
      GdkPixbuf *decoded = gdk_pixbuf_new_from_stream (stream, NULL, &error);
      g_assert_nonnull (decoded);
      g_print ("RUNTIME_PIXBUF_DECODE_OK format=%s\n", formats[i]);
      g_object_unref (decoded); g_object_unref (stream);
      g_free (bytes);
    }
  g_object_unref (pixel);
  g_print ("RUNTIME_SOURCE_LANGUAGES count=%u\n", language_count);
  g_print ("RUNTIME_BEFORE_WEBVIEW\n"); fflush (stdout);
  GtkWidget *web = webkit_web_view_new ();
  g_print ("RUNTIME_AFTER_WEBVIEW\n"); fflush (stdout);
  gtk_window_set_child (GTK_WINDOW (window), box);
  gtk_box_append (GTK_BOX (box), source);
  gtk_box_append (GTK_BOX (box), web);
  gtk_widget_set_vexpand (web, TRUE);
  gtk_window_set_default_size (GTK_WINDOW (window), 600, 400);
  g_print ("RUNTIME_STACK gtk=%u.%u.%u pango=%s source=%u.%u.%u webkit=%u.%u.%u commit_hook=%u\n",
           gtk_get_major_version (), gtk_get_minor_version (), gtk_get_micro_version (),
           pango_version_string (), gtk_source_get_major_version (), gtk_source_get_minor_version (),
           gtk_source_get_micro_version (), webkit_get_major_version (), webkit_get_minor_version (),
           webkit_get_micro_version (), g_signal_lookup ("preflight-commit", GTK_TYPE_TEXT_VIEW));
  fflush (stdout);
  g_signal_connect (web, "notify::title", G_CALLBACK (title_changed), NULL);
  gtk_window_present (GTK_WINDOW (window));
  webkit_web_view_load_html (WEBKIT_WEB_VIEW (web),
    "<!doctype html><html><head><title>loading</title></head><body>Private stack"
    "<script>document.title='PRIVATE_RUNTIME_JS_OK';</script></body></html>", NULL);
  loop = g_main_loop_new (NULL, FALSE);
  g_timeout_add_seconds (35, finish, NULL);
  g_main_loop_run (loop);
  gtk_window_destroy (GTK_WINDOW (window));
  g_main_loop_unref (loop);
  return result;
}
