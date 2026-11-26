#ifndef FFMPEG_LOG_BRIDGE_H
#define FFMPEG_LOG_BRIDGE_H

/// Receives one formatted libav* message: its level (AV_LOG_*) and the line, prefix included.
typedef void (*ep_log_sink)(int level, const char *line);

/// Sends libav* messages at `max_level` or worse (a lower AV_LOG_* value) to `sink` instead of
/// stderr. Swift can't take the va_list av_log_set_callback hands over, so it is formatted here.
void ep_log_install(int max_level, ep_log_sink sink);

#endif
