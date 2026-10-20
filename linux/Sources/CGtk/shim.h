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

// libayatana-appindicator 0.5.94+ also logs a deprecation warning at runtime, once per
// indicator. Drop just that message; other warnings from it still get through.
static void stc_ayatana_log(const gchar *domain, GLogLevelFlags level, const gchar *message, gpointer data) {
    if (message && g_strrstr(message, "is deprecated")) return;
    g_log_default_handler(domain, level, message, data);
}

static inline void stc_quiet_ayatana_deprecation(void) {
    g_log_set_handler("libayatana-appindicator", G_LOG_LEVEL_WARNING, stc_ayatana_log, NULL);
}
