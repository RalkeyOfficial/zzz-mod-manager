#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication
{
  GtkApplication parent_instance;
  char **dart_entrypoint_arguments;
  FlMethodChannel *clipboard_channel;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Handles the "mod_manager/clipboard" channel. Reads the clipboard's
// `text/html` target directly from the GTK clipboard — the same way native
// apps (e.g. LibreOffice) do — so pasting formatted text into the description
// editors works without any external CLI tool. Returns null when the clipboard
// holds no HTML.
static void clipboard_method_call_cb(FlMethodChannel *channel,
                                     FlMethodCall *method_call,
                                     gpointer user_data)
{
  g_autoptr(FlMethodResponse) response = nullptr;
  if (g_strcmp0(fl_method_call_get_name(method_call), "getClipboardHtml") == 0)
  {
    GtkClipboard *clipboard = gtk_clipboard_get(GDK_SELECTION_CLIPBOARD);
    GtkSelectionData *data = gtk_clipboard_wait_for_contents(
        clipboard, gdk_atom_intern("text/html", FALSE));
    g_autoptr(FlValue) result = nullptr;
    if (data != nullptr)
    {
      gint length = 0;
      const guchar *bytes = gtk_selection_data_get_data_with_length(data, &length);
      if (bytes != nullptr && length > 0)
      {
        gchar *utf8 = nullptr;
        // Most sources provide UTF-8; some provide BOM-prefixed UTF-16.
        if (length >= 2 &&
            ((bytes[0] == 0xFF && bytes[1] == 0xFE) ||
             (bytes[0] == 0xFE && bytes[1] == 0xFF)))
        {
          utf8 = g_convert((const gchar *)bytes, length, "UTF-8", "UTF-16",
                           nullptr, nullptr, nullptr);
        }
        else
        {
          utf8 = g_strndup((const gchar *)bytes, length);
        }
        if (utf8 != nullptr)
        {
          result = fl_value_new_string(utf8);
          g_free(utf8);
        }
      }
      gtk_selection_data_free(data);
    }
    if (result == nullptr)
      result = fl_value_new_null();
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  }
  else
  {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  g_autoptr(GError) error = nullptr;
  if (!fl_method_call_respond(method_call, response, &error))
    g_warning("Failed to respond to clipboard method call: %s", error->message);
}

// Gives the window an icon, by whichever of two unrelated mechanisms applies.
//
// **On Wayland neither of these is what the taskbar reads.** There is no
// per-window icon in xdg-shell at all: the compositor matches the surface's app
// id to `<app id>.desktop` and takes `Icon=` from there, so an installed desktop
// entry is the only thing that can put an icon on a Wayland window — see
// `linux/packaging/`. On X11 the icon travels with the window in `_NET_WM_ICON`,
// which is what a pixbuf set here becomes.
//
// The theme name is tried first because that is the mechanism an installed build
// is meant to use, and it scales. The file beside the executable is the fallback
// for a portable build that was never installed, and it is resolved from
// `/proc/self/exe` rather than as a relative path: a relative path resolves only
// when the app happens to be launched from inside its own bundle directory,
// which is true under `flutter run` and false for every shipped build.
static void set_window_icon(GtkWindow *window)
{
  if (gtk_icon_theme_has_icon(gtk_icon_theme_get_default(), APPLICATION_ID))
  {
    gtk_window_set_default_icon_name(APPLICATION_ID);
    return;
  }

  g_autofree gchar *exe = g_file_read_link("/proc/self/exe", nullptr);
  if (exe == nullptr)
    return;

  g_autofree gchar *dir = g_path_get_dirname(exe);
  g_autofree gchar *path = g_build_filename(
      dir, "data", "flutter_assets", "assets", "icon.png", nullptr);

  g_autoptr(GError) error = nullptr;
  GdkPixbuf *icon = gdk_pixbuf_new_from_file(path, &error);
  if (icon == nullptr)
  {
    g_warning("No window icon: %s", error->message);
    return;
  }

  gtk_window_set_icon(window, icon);
  gtk_window_set_default_icon(icon);
  g_object_unref(icon);
}

// Implements GApplication::activate.
static void my_application_activate(GApplication *application)
{
  MyApplication *self = MY_APPLICATION(application);
  GtkWindow *window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // **The window keeps the decoration its window manager draws.** An
  // undecorated window cannot be resized with the mouse — neither GTK nor the
  // compositor offers an edge to grab, measured on both backends — and it
  // reimplements minimise, maximise and close worse than the desktop does,
  // without the window menu, the double-click-to-maximise or the button order
  // the user chose. On Wayland it is worse than that: GTK announces client-side
  // decoration only when it actually draws some, so `set_decorated(FALSE)` here
  // leaves the compositor adding a 28px title bar of its own *above* the app's,
  // which is two title bars on one window.
  gtk_window_set_title(window, "ZZZ Mod Manager");
  set_window_icon(window);

  // Start at a sensible size before the window is shown so it doesn't appear
  // as a tiny square and then grow (window_manager restores the saved size
  // afterwards). Mirrors AppConstants.defaultWindow{Width,Height}.
  gtk_window_set_default_size(window, 1400, 900);

  gtk_widget_show(GTK_WIDGET(window));

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(project, self->dart_entrypoint_arguments);

  FlView *view = fl_view_new(project);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  // Register the clipboard channel for native text/html reads.
  FlEngine *engine = fl_view_get_engine(view);
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->clipboard_channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(engine),
      "mod_manager/clipboard",
      FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      self->clipboard_channel, clipboard_method_call_cb, self, nullptr);

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication *application, gchar ***arguments, int *exit_status)
{
  MyApplication *self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error))
  {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication *application)
{
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication *application)
{
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject *object)
{
  MyApplication *self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  g_clear_object(&self->clipboard_channel);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass *klass)
{
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line = my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication *self) {}

MyApplication *my_application_new()
{
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID,
                                     "flags", G_APPLICATION_NON_UNIQUE,
                                     nullptr));
}
