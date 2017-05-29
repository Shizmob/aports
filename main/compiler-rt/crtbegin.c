extern void *__dso_handle __attribute__((__visibility__("hidden")));
#ifdef SHARED
void *__dso_handle = &__dso_handle;
#endif
