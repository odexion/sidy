// Entry points are called from /usr/bin/perl, the Apple-signed host that is still
// allowed to read MediaRemote. The (unused) arguments match perl's XSUB signature.
void mb_info(void *perl, void *cv);
// Keeps running, printing one mb_info line per change, until stdin closes.
void mb_stream(void *perl, void *cv);
void mb_toggle(void *perl, void *cv);
void mb_next(void *perl, void *cv);
void mb_previous(void *perl, void *cv);
// Seeks to the position (seconds) in the MB_SEEK environment variable.
void mb_seek(void *perl, void *cv);
