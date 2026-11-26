#include "FFmpegLogBridge.h"

#include <stdatomic.h>
#include <stdio.h>
#include <EPLibavutil/log.h>

static _Atomic(ep_log_sink) installed_sink;
static atomic_int installed_level;

static void callback(void *context, int level, const char *format, va_list arguments) {
    ep_log_sink sink = atomic_load(&installed_sink);
    if (!sink || level > atomic_load(&installed_level)) return;
    char line[1024];
    int print_prefix = 1;
    av_log_format_line2(context, level, format, arguments, line, sizeof line, &print_prefix);
    sink(level, line);
}

void ep_log_install(int max_level, ep_log_sink sink) {
    atomic_store(&installed_level, max_level);
    atomic_store(&installed_sink, sink);
    av_log_set_callback(callback);
}
