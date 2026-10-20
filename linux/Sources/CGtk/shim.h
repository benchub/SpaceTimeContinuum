#include <gtk/gtk.h>
#include <libayatana-appindicator/app-indicator.h>

// libayatana-appindicator 0.5.94+ deprecates the whole GTK 3 API in favour of a GLib-only
// rewrite that older distributions (e.g. Ubuntu 24.04) don't have. Call it from one place
// with the warning silenced rather than warning on every build.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static inline AppIndicator *stc_app_indicator_new(const gchar *id, const gchar *icon_name, AppIndicatorCategory category) {
    return app_indicator_new(id, icon_name, category);
}
#pragma clang diagnostic pop
