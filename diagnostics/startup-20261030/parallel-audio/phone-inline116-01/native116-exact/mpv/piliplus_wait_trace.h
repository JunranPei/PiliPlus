/* Diagnostic-only Android atrace scopes. Cleanup balances early returns. */
#ifndef PILIPLUS_WAIT_TRACE_H
#define PILIPLUS_WAIT_TRACE_H
#include <stdbool.h>
#include <stdarg.h>
#include <stdio.h>
#ifdef __ANDROID__
#include <android/trace.h>
#endif
typedef struct { bool enabled; } pili_trace_scope;
static inline pili_trace_scope pili_trace_begin(const char *format, ...)
{
    pili_trace_scope scope = {0};
#ifdef __ANDROID__
    scope.enabled = ATrace_isEnabled();
    if (scope.enabled) {
        char name[127];
        va_list args;
        va_start(args, format);
        vsnprintf(name, sizeof(name), format, args);
        va_end(args);
        ATrace_beginSection(name);
    }
#endif
    return scope;
}
static inline void pili_trace_end(pili_trace_scope *scope)
{
#ifdef __ANDROID__
    if (scope->enabled) ATrace_endSection();
#endif
}
#define PILI_TRACE_SCOPE_WHEN(condition, ...) \
    pili_trace_scope pili_scope __attribute__((cleanup(pili_trace_end))) = \
        (condition) ? pili_trace_begin(__VA_ARGS__) : (pili_trace_scope){0}
#define PILI_TRACE_SCOPE(...) \
    pili_trace_scope pili_scope __attribute__((cleanup(pili_trace_end))) = pili_trace_begin(__VA_ARGS__)
#endif
