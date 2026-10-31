#ifndef SUN_APPLE_CAPTURE_H
#define SUN_APPLE_CAPTURE_H
#include <stdint.h>
#include <CoreGraphics/CoreGraphics.h>
/** Converts a bottom-left drag to a bounded top-left display rectangle; no overlap yields zero. */
CGRect sa_region_rectangle(CGPoint first, CGPoint last, CGSize bounds);
/** Owns a main-thread ScreenCaptureKit session; NULL indicates unsupported OS or allocation failure. */
void *sa_capture_new(void);
/** Closes the picker and overlay, stops any stream, and relinquishes the session. */
void sa_capture_free(void *session);
/** Presents the system picker: source 0 display, 1 window, 2 display followed by region selection. */
void sa_capture_select(void *session, int source);
/** Pumps AppKit without blocking; returns 0 idle, 1 selected, 2 cancelled, 3 recording, 4 finished, 5 screenshot, 6 error, 7 region UI. */
int sa_capture_poll(void *session);
/** Borrows the session's last diagnostic until the next call. */
const char *sa_capture_error(void *session);
/** Starts a silent stream or PNG screenshot at a caller-chosen path, after selection. */
void sa_capture_start(void *session, int recording, int cursor, const char *path);
/** Starts live camera composition and microphone capture into fragmented H.264/AAC MP4. */
void sa_capture_start_live(void *session, int cursor, const char *path, int camera, int microphone, int corner, int size);
/** Stops a stream asynchronously; completion is reported by poll. */
void sa_capture_stop(void *session);
/** Allocates a UTF-8 UUID string; release with sa_string_free. */
char *sa_uuid(void);
/** Allocates the user's Pictures or Movies path; release with sa_string_free. */
char *sa_media_directory(int video);
/** Releases a string allocated by this bridge. */
void sa_string_free(char *text);
#endif
