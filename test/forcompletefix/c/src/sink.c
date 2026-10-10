#include "monitor.h"

typedef struct Sink
{
    void ( *flush )( Sampler* s );
} Sink;

/* Write every buffered sample out and reset the buffer. */
void flush( Sampler* s )
{
    s->count = 0;
}

void Sink_drainSamples( Sink* sink, Sampler* s )
{
    /* a call through the field: nothing proves sink->flush is the free function flush */
    sink->flush( s );
}

void Monitor_flushSamples( Sampler* s )
{
    flush( s );
}
